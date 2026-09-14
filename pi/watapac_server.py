#!/usr/bin/env python3
"""
WATAPAC telemetry server.

    Arduino --USB serial--> Raspberry Pi 4B (this file) --HTTP--> browser
                                      |
                            OpenWeatherMap (HTTPS)

Everything the dashboard shows comes through here. That is deliberate: the
browser talks to exactly one address, the OpenWeatherMap key never leaves the
Pi, and there is one place where readings can be written to disk.

Three jobs:

  1. Read sensor lines from the Arduino on a background thread, parse them,
     and derive the values the dashboard shows (water level class, flood
     risk, instantaneous power, accumulated energy).

  2. Poll OpenWeatherMap on its own schedule and fold the result into the
     same JSON. The browser never calls OpenWeatherMap, so the API key stays
     here instead of being readable by anyone who views the page.

  3. Append readings to a daily CSV, and serve them back at /api/history for
     charts and for MATLAB analysis.

Plus serving the dashboard itself, so the browser loads the page and the data
from the same origin. That is what makes PI_ENDPOINT = "/api/status" work in
script.js with no CORS setup and no mixed-content problem.

Run:  python3 pi/watapac_server.py
Then: http://<pi-ip>:5000/

Every tunable is an environment variable, so the same file runs on a bench
with no Arduino attached and on the deployed unit:

    WATAPAC_SERIAL_PORT   default /dev/ttyACM0
    WATAPAC_BAUD          default 9600
    WATAPAC_HOST          default 0.0.0.0
    WATAPAC_PORT          default 5000
    WATAPAC_OWM_KEY       default ""  (empty disables the weather panel)
    WATAPAC_OWM_LAT       default ""
    WATAPAC_OWM_LON       default ""
    WATAPAC_LOG_INTERVAL  default 10  seconds; 0 disables logging
    WATAPAC_LOG_DIR       default pi/logs
"""

from __future__ import annotations

import csv
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify, request, send_from_directory

try:
    import serial  # pyserial
except ImportError:  # pragma: no cover - lets the server boot without hardware
    serial = None


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SERIAL_PORT = os.environ.get("WATAPAC_SERIAL_PORT", "/dev/ttyACM0")
BAUD_RATE = int(os.environ.get("WATAPAC_BAUD", "9600"))
HTTP_HOST = os.environ.get("WATAPAC_HOST", "0.0.0.0")
HTTP_PORT = int(os.environ.get("WATAPAC_PORT", "5000"))

# The dashboard is a sibling directory, not a copy inside pi/.
WEBSITE_DIR = Path(__file__).resolve().parent.parent / "WEBSITE"

# A reading older than this means the Arduino stopped talking. The dashboard
# then shows "connected — awaiting Arduino data" rather than stale numbers.
STALE_AFTER_SECONDS = 5.0

# Retry delay after a serial open fails, so an unplugged Arduino does not
# spin the CPU.
SERIAL_RETRY_SECONDS = 3.0

# --- Weather --------------------------------------------------------------
# Leave the key empty and the weather panel simply reports that it is not
# configured. Nothing else is affected.
OWM_API_KEY = os.environ.get("WATAPAC_OWM_KEY", "").strip()
OWM_LAT = os.environ.get("WATAPAC_OWM_LAT", "").strip()
OWM_LON = os.environ.get("WATAPAC_OWM_LON", "").strip()

WEATHER_REFRESH_SECONDS = 600.0   # free tier allows far more; no reason to push it
WEATHER_RETRY_SECONDS = 60.0      # after a failed fetch
WEATHER_TIMEOUT_SECONDS = 10.0

# A reading older than this is still shown -- weather changes slowly and an
# hour-old temperature beats a blank panel -- but it is flagged, so the
# dashboard can say so rather than implying it is current.
WEATHER_STALE_AFTER_SECONDS = 3 * WEATHER_REFRESH_SECONDS

# --- Logging --------------------------------------------------------------
LOG_INTERVAL_SECONDS = float(os.environ.get("WATAPAC_LOG_INTERVAL", "10"))
LOG_DIR = Path(os.environ.get("WATAPAC_LOG_DIR", "")) if os.environ.get("WATAPAC_LOG_DIR") \
    else Path(__file__).resolve().parent / "logs"

# Guards /api/history against a request that would try to read a year of rows
# into memory at once.
HISTORY_MAX_HOURS = 24 * 31
HISTORY_DEFAULT_HOURS = 24
HISTORY_MAX_ROWS = 2000


# --- Calibration ------------------------------------------------------------
# CALIBRATE THESE AGAINST THE REAL UNIT. The defaults are placeholders chosen
# to be obviously wrong rather than plausibly wrong.

# Ultrasonic sensor reads the distance DOWN to the water surface, so a
# smaller number means a higher water level.
WATER_RISING_CM = 30.0    # closer than this -> RISING
WATER_CRITICAL_CM = 15.0  # closer than this -> CRITICAL

# Flow above this counts as one flood-risk point.
FLOW_HIGH_LPM = 25.0


# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------

def classify_water_level(distance_cm: float | None) -> str:
    """Ultrasonic distance -> the words the dashboard colors."""
    if distance_cm is None:
        return "NO DATA"
    if distance_cm <= WATER_CRITICAL_CM:
        return "CRITICAL"
    if distance_cm <= WATER_RISING_CM:
        return "RISING"
    return "NORMAL"


def assess_flood_risk(water_level: str, rain_detected: bool, flow_lpm: float | None) -> str:
    """
    Additive score across the three independent signals, so no single sensor
    glitch can drive the reading to HIGH on its own -- except a CRITICAL water
    level, which is a direct measurement of the thing we care about and short
    -circuits the score.
    """
    if water_level == "CRITICAL":
        return "HIGH"
    if water_level == "NO DATA":
        return "NO DATA"

    score = 0
    if water_level == "RISING":
        score += 2
    if rain_detected:
        score += 1
    if flow_lpm is not None and flow_lpm > FLOW_HIGH_LPM:
        score += 1

    if score >= 3:
        return "HIGH"
    if score >= 1:
        return "MEDIUM"
    return "LOW"


# ---------------------------------------------------------------------------
# Serial parsing
# ---------------------------------------------------------------------------
#
# The Arduino may send either form, one reading per line:
#
#   JSON      {"rain":1,"waterCm":42.5,"flow":21.3,"voltage":48.2,
#              "current":32.0,"battery":74,"emergency":1}
#
#   key=value rain=1;waterCm=42.5;flow=21.3;voltage=48.2;current=32.0;
#             battery=74;emergency=1
#
# Unknown keys are ignored and missing keys stay None, so adding a sensor to
# the sketch never breaks the server.

_NUMERIC_KEYS = {"waterCm", "flow", "voltage", "current", "battery"}
_BOOLEAN_KEYS = {"rain", "emergency"}


def parse_line(line: str) -> dict | None:
    """Parse one serial line. Returns None if the line is not a reading."""
    line = line.strip()
    if not line:
        return None

    if line.startswith("{"):
        try:
            raw = json.loads(line)
        except json.JSONDecodeError:
            return None
        if not isinstance(raw, dict):
            return None
    else:
        if "=" not in line:
            return None  # boot banner, debug print, partial line
        raw = {}
        for pair in line.replace(",", ";").split(";"):
            if "=" not in pair:
                continue
            key, _, value = pair.partition("=")
            raw[key.strip()] = value.strip()

    reading: dict = {}
    for key, value in raw.items():
        try:
            if key in _NUMERIC_KEYS:
                reading[key] = float(value)
            elif key in _BOOLEAN_KEYS:
                reading[key] = str(value).strip().lower() in ("1", "true", "yes", "on")
        except (TypeError, ValueError):
            continue  # one bad field should not discard the whole line

    return reading or None


# ---------------------------------------------------------------------------
# Shared state
# ---------------------------------------------------------------------------

@dataclass
class Telemetry:
    """
    Latest reading plus the running energy total.

    Written by the serial thread, read by Flask request threads, so every
    access goes through the lock.
    """

    lock: threading.Lock = field(default_factory=threading.Lock)
    last_reading: dict | None = None
    last_reading_at: float = 0.0
    total_kwh: float = 0.0
    _last_energy_at: float = 0.0

    def update(self, reading: dict) -> None:
        now = time.monotonic()
        with self.lock:
            voltage = reading.get("voltage")
            current = reading.get("current")

            # Integrate power over the gap since the previous reading. Skipped
            # on the first reading (no interval yet) and after a long silence,
            # where the true output in between is unknown -- guessing would
            # quietly inflate the total.
            if voltage is not None and current is not None and self._last_energy_at:
                elapsed_h = (now - self._last_energy_at) / 3600.0
                if 0 < elapsed_h < (STALE_AFTER_SECONDS * 2 / 3600.0):
                    self.total_kwh += (voltage * current / 1000.0) * elapsed_h

            self._last_energy_at = now
            self.last_reading = reading
            self.last_reading_at = now

    def _derive(self) -> dict | None:
        """
        Everything the dashboard shows, as numbers or None -- never as display
        text. This is the one place the sensor readings are interpreted; the
        display form and the logged form are both built from it, so they can
        never disagree about what the water level was.

        Returns None when there is no fresh reading to interpret.
        """
        with self.lock:
            reading = self.last_reading
            age = time.monotonic() - self.last_reading_at if self.last_reading_at else None
            total_kwh = self.total_kwh

        fresh = reading is not None and age is not None and age < STALE_AFTER_SECONDS
        if not fresh:
            return None

        voltage = reading.get("voltage")
        current = reading.get("current")
        flow = reading.get("flow")
        battery = reading.get("battery")
        rain = bool(reading.get("rain", False))
        water_level = classify_water_level(reading.get("waterCm"))

        return {
            "rain": rain,
            "waterCm": reading.get("waterCm"),
            "waterLevel": water_level,
            "floodRisk": assess_flood_risk(water_level, rain, flow),
            "emergency": bool(reading.get("emergency", False)),
            "battery": int(battery) if battery is not None else None,
            "voltage": voltage,
            "current": current,
            "power": (voltage * current / 1000.0) if (voltage is not None and current is not None) else None,
            "total": total_kwh,
            "flow": flow,
        }

    def raw(self) -> dict | None:
        """Numeric view, for logging and analysis. None means 'not measured'."""
        return self._derive()

    def snapshot(self) -> dict:
        """Build the exact JSON shape script.js expects."""
        d = self._derive()

        if d is None:
            # Pi is up, Arduino is not talking. Report that honestly instead of
            # replaying the last numbers we happened to see.
            with self.lock:
                total_kwh = self.total_kwh
            return {
                "arduinoConnected": False,
                "rainStatus": "NO DATA",
                "floodRisk": "NO DATA",
                "emergencyActive": False,
                "batteryPercent": 0,
                "voltage": "—",
                "current": "—",
                "power": "—",
                "total": round(total_kwh, 2),
                "flowRate": "—",
                "waterLevel": "NO DATA",
            }

        # script.js appends units only to numbers, so a missing sensor must
        # come through as the em dash and never as 0.
        def num(value, digits):
            return round(value, digits) if value is not None else "—"

        return {
            "arduinoConnected": True,
            "rainStatus": "DETECTED" if d["rain"] else "NOT DETECTED",
            "floodRisk": d["floodRisk"],
            "emergencyActive": d["emergency"],
            "batteryPercent": d["battery"] if d["battery"] is not None else 0,
            "voltage": num(d["voltage"], 1),
            "current": num(d["current"], 1),
            "power": num(d["power"], 2),
            "total": round(d["total"], 2),
            "flowRate": num(d["flow"], 1),
            "waterLevel": d["waterLevel"],
        }


@dataclass
class WeatherCache:
    """
    Last successful OpenWeatherMap reading, refreshed on its own thread.

    Kept separate from Telemetry because the two fail independently: losing
    the internet must not blank the sensor panels, and losing the Arduino must
    not blank the weather.
    """

    lock: threading.Lock = field(default_factory=threading.Lock)
    data: dict | None = None
    fetched_at: float = 0.0          # epoch seconds, for display
    fetched_monotonic: float = 0.0   # for age, immune to clock changes
    last_error: str | None = None

    def update(self, data: dict) -> None:
        with self.lock:
            self.data = data
            self.fetched_at = time.time()
            self.fetched_monotonic = time.monotonic()
            self.last_error = None

    def note_failure(self, message: str) -> None:
        with self.lock:
            self.last_error = message

    def snapshot(self) -> dict | None:
        """None means the panel has nothing to show and should say so."""
        if not weather_configured():
            return None
        with self.lock:
            data = self.data
            fetched_at = self.fetched_at
            fetched_monotonic = self.fetched_monotonic
            last_error = self.last_error

        if data is None:
            return None

        age = time.monotonic() - fetched_monotonic
        return {
            **data,
            "updatedAt": fetched_at,
            # Weather changes slowly, so an old reading still beats a blank
            # panel -- but the dashboard is told it is old rather than left to
            # present it as current.
            "stale": age > WEATHER_STALE_AFTER_SECONDS,
            "error": last_error,
        }


telemetry = Telemetry()
weather = WeatherCache()


# ---------------------------------------------------------------------------
# Serial reader thread
# ---------------------------------------------------------------------------

def serial_loop() -> None:
    """Read the Arduino forever, reconnecting if it is unplugged."""
    if serial is None:
        print("[serial] pyserial not installed — running without hardware.")
        print("[serial] pip install -r pi/requirements.txt")
        return

    while True:
        try:
            with serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=2) as port:
                print(f"[serial] connected to {SERIAL_PORT} @ {BAUD_RATE}")
                while True:
                    raw = port.readline()
                    if not raw:
                        continue  # read timeout; loop and let staleness handle it
                    reading = parse_line(raw.decode("utf-8", errors="replace"))
                    if reading:
                        telemetry.update(reading)
        except Exception as exc:  # unplugged, permissions, bad baud
            print(f"[serial] {SERIAL_PORT} unavailable ({exc}); retrying in {SERIAL_RETRY_SECONDS}s")
            time.sleep(SERIAL_RETRY_SECONDS)


# ---------------------------------------------------------------------------
# Weather thread
# ---------------------------------------------------------------------------

def weather_configured() -> bool:
    return bool(OWM_API_KEY and OWM_LAT and OWM_LON)


def fetch_weather_once() -> dict:
    """One OpenWeatherMap call. Raises on any failure; the caller decides."""
    query = urllib.parse.urlencode({
        "lat": OWM_LAT,
        "lon": OWM_LON,
        "units": "metric",
        "appid": OWM_API_KEY,
    })
    url = f"https://api.openweathermap.org/data/2.5/weather?{query}"

    with urllib.request.urlopen(url, timeout=WEATHER_TIMEOUT_SECONDS) as response:
        payload = json.loads(response.read().decode("utf-8"))

    wind_ms = (payload.get("wind") or {}).get("speed")
    main = payload.get("main") or {}
    conditions = payload.get("weather") or [{}]

    return {
        "condition": conditions[0].get("main") or "—",
        "temp": round(main["temp"]) if main.get("temp") is not None else None,
        "humidity": main.get("humidity"),
        "wind": round(wind_ms * 3.6) if wind_ms is not None else None,  # m/s -> km/h
    }


def weather_loop() -> None:
    """Refresh the weather forever, backing off after a failure."""
    if not weather_configured():
        print("[weather] WATAPAC_OWM_KEY/LAT/LON not set — weather panel disabled.")
        return

    print(f"[weather] polling OpenWeatherMap every {WEATHER_REFRESH_SECONDS / 60:.0f} min")
    while True:
        try:
            weather.update(fetch_weather_once())
            delay = WEATHER_REFRESH_SECONDS
        except urllib.error.HTTPError as exc:
            # 401 means a bad key and will not fix itself; say so plainly
            # rather than burying it in a generic retry message.
            detail = "bad API key" if exc.code == 401 else f"HTTP {exc.code}"
            weather.note_failure(detail)
            print(f"[weather] {detail}; retrying in {WEATHER_RETRY_SECONDS:.0f}s")
            delay = WEATHER_RETRY_SECONDS
        except Exception as exc:  # DNS, timeout, malformed payload
            weather.note_failure(str(exc))
            print(f"[weather] fetch failed ({exc}); retrying in {WEATHER_RETRY_SECONDS:.0f}s")
            delay = WEATHER_RETRY_SECONDS

        time.sleep(delay)


# ---------------------------------------------------------------------------
# Logging thread
# ---------------------------------------------------------------------------
#
# One CSV per day, so a file can be deleted or copied off without touching the
# rest, and so nothing ever grows without bound. Columns are raw numbers with
# empty cells for "not measured" -- MATLAB's readtable and pandas both read
# that as missing, which an em dash or a 0 would not.

LOG_COLUMNS = [
    "timestamp", "epoch",
    "rain", "waterCm", "waterLevel", "floodRisk", "emergency",
    "batteryPercent", "voltage", "current", "power", "totalKwh", "flowRate",
    "weatherCondition", "weatherTemp", "weatherHumidity", "weatherWind",
]


def log_path_for(when: float) -> Path:
    day = datetime.fromtimestamp(when, timezone.utc).strftime("%Y-%m-%d")
    return LOG_DIR / f"watapac-{day}.csv"


def build_log_row(now: float, reading: dict, weather_data: dict | None) -> list:
    w = weather_data or {}

    def fmt(value, digits=None):
        if value is None:
            return ""          # missing, not zero
        if digits is not None and isinstance(value, (int, float)):
            return f"{value:.{digits}f}"
        if isinstance(value, bool):
            return "1" if value else "0"
        return value

    return [
        datetime.fromtimestamp(now, timezone.utc).isoformat(timespec="seconds"),
        f"{now:.0f}",
        fmt(reading["rain"]),
        fmt(reading["waterCm"], 1),
        reading["waterLevel"],
        reading["floodRisk"],
        fmt(reading["emergency"]),
        fmt(reading["battery"]),
        fmt(reading["voltage"], 2),
        fmt(reading["current"], 2),
        fmt(reading["power"], 4),
        fmt(reading["total"], 5),
        fmt(reading["flow"], 2),
        fmt(w.get("condition")),
        fmt(w.get("temp")),
        fmt(w.get("humidity")),
        fmt(w.get("wind")),
    ]


def append_log_row(row: list, path: Path) -> None:
    is_new = not path.exists()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        if is_new:
            writer.writerow(LOG_COLUMNS)
        writer.writerow(row)


def log_loop() -> None:
    """Append one row per interval, but only while real data is arriving."""
    if LOG_INTERVAL_SECONDS <= 0:
        print("[log] WATAPAC_LOG_INTERVAL=0 — logging disabled.")
        return

    print(f"[log] writing to {LOG_DIR} every {LOG_INTERVAL_SECONDS:.0f}s")
    while True:
        time.sleep(LOG_INTERVAL_SECONDS)
        reading = telemetry.raw()
        if reading is None:
            continue  # nothing real to record; a gap in the file is the truth
        try:
            now = time.time()
            append_log_row(build_log_row(now, reading, weather.snapshot()), log_path_for(now))
        except OSError as exc:
            # A full or read-only disk must not take the dashboard down.
            print(f"[log] write failed ({exc})")


def read_history(hours: float, max_rows: int) -> list:
    """Rows from the last HOURS, newest last, downsampled to at most MAX_ROWS."""
    cutoff = time.time() - hours * 3600.0
    rows = []

    if not LOG_DIR.is_dir():
        return rows

    # Only the day files that can overlap the window, oldest first.
    for path in sorted(LOG_DIR.glob("watapac-*.csv")):
        try:
            if path.stat().st_mtime < cutoff:
                continue
        except OSError:
            continue
        try:
            with path.open(newline="", encoding="utf-8") as handle:
                for record in csv.DictReader(handle):
                    try:
                        epoch = float(record.get("epoch") or 0)
                    except ValueError:
                        continue
                    if epoch >= cutoff:
                        rows.append(record)
        except OSError:
            continue

    rows.sort(key=lambda r: float(r.get("epoch") or 0))

    # Evenly spaced sample rather than the newest N, so a chart of "last 7
    # days" covers seven days instead of the most recent forty minutes.
    if len(rows) > max_rows:
        step = len(rows) / max_rows
        rows = [rows[int(i * step)] for i in range(max_rows)]

    return rows


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

app = Flask(__name__, static_folder=None)


@app.after_request
def no_store(response):
    """Telemetry is never cacheable, and neither is the page during dev."""
    response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/api/status")
def api_status():
    payload = telemetry.snapshot()
    payload["weather"] = weather.snapshot()
    return jsonify(payload)


@app.get("/api/history")
def api_history():
    """
    Logged readings, for charts and for MATLAB.

        /api/history?hours=24
        /api/history?hours=168&limit=500
    """
    try:
        hours = float(request.args.get("hours", HISTORY_DEFAULT_HOURS))
        limit = int(request.args.get("limit", HISTORY_MAX_ROWS))
    except ValueError:
        return jsonify({"error": "hours and limit must be numbers"}), 400

    if hours <= 0 or limit <= 0:
        return jsonify({"error": "hours and limit must be positive"}), 400

    hours = min(hours, HISTORY_MAX_HOURS)
    limit = min(limit, HISTORY_MAX_ROWS)

    rows = read_history(hours, limit)
    return jsonify({
        "hours": hours,
        "count": len(rows),
        "columns": LOG_COLUMNS,
        "rows": rows,
    })


@app.get("/")
def index():
    return send_from_directory(WEBSITE_DIR, "index.html")


@app.get("/<path:filename>")
def static_files(filename):
    return send_from_directory(WEBSITE_DIR, filename)


def main() -> None:
    if not WEBSITE_DIR.is_dir():
        raise SystemExit(f"Dashboard directory not found: {WEBSITE_DIR}")

    threading.Thread(target=serial_loop, name="serial", daemon=True).start()
    threading.Thread(target=weather_loop, name="weather", daemon=True).start()
    threading.Thread(target=log_loop, name="log", daemon=True).start()

    print(f"[http] serving {WEBSITE_DIR} on http://{HTTP_HOST}:{HTTP_PORT}/")
    print(f"[http] telemetry at http://{HTTP_HOST}:{HTTP_PORT}/api/status")
    print(f"[http] history   at http://{HTTP_HOST}:{HTTP_PORT}/api/history?hours=24")
    app.run(host=HTTP_HOST, port=HTTP_PORT, threaded=True)


if __name__ == "__main__":
    main()
