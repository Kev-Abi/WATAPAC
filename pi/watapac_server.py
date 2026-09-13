#!/usr/bin/env python3
"""
WATAPAC telemetry server.

    Arduino --USB serial--> Raspberry Pi 4B (this file) --HTTP--> browser

Two jobs:

  1. Read sensor lines from the Arduino on a background thread, parse them,
     and derive the values the dashboard shows (water level class, flood
     risk, instantaneous power, accumulated energy).

  2. Serve the dashboard itself plus GET /api/status, so the browser loads
     the page and the data from the same origin. That is what makes
     PI_ENDPOINT = "/api/status" work in script.js with no CORS setup and
     no mixed-content problem.

Run:  python3 pi/watapac_server.py
Then: http://<pi-ip>:5000/

Every tunable is an environment variable, so the same file runs on a bench
with no Arduino attached and on the deployed unit:

    WATAPAC_SERIAL_PORT   default /dev/ttyACM0
    WATAPAC_BAUD          default 9600
    WATAPAC_HOST          default 0.0.0.0
    WATAPAC_PORT          default 5000
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from flask import Flask, jsonify, send_from_directory

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

    def snapshot(self) -> dict:
        """Build the exact JSON shape script.js expects."""
        with self.lock:
            reading = self.last_reading
            age = time.monotonic() - self.last_reading_at if self.last_reading_at else None
            total_kwh = self.total_kwh

        fresh = reading is not None and age is not None and age < STALE_AFTER_SECONDS

        if not fresh:
            # Pi is up, Arduino is not talking. Report that honestly instead of
            # replaying the last numbers we happened to see.
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

        voltage = reading.get("voltage")
        current = reading.get("current")
        flow = reading.get("flow")
        battery = reading.get("battery")
        rain = bool(reading.get("rain", False))

        water_level = classify_water_level(reading.get("waterCm"))
        power_kw = (voltage * current / 1000.0) if (voltage is not None and current is not None) else None

        # script.js appends units only to numbers, so a missing sensor must
        # come through as the em dash and never as 0.
        def num(value, digits):
            return round(value, digits) if value is not None else "—"

        return {
            "arduinoConnected": True,
            "rainStatus": "DETECTED" if rain else "NOT DETECTED",
            "floodRisk": assess_flood_risk(water_level, rain, flow),
            "emergencyActive": bool(reading.get("emergency", False)),
            "batteryPercent": int(battery) if battery is not None else 0,
            "voltage": num(voltage, 1),
            "current": num(current, 1),
            "power": num(power_kw, 2),
            "total": round(total_kwh, 2),
            "flowRate": num(flow, 1),
            "waterLevel": water_level,
        }


telemetry = Telemetry()


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
    return jsonify(telemetry.snapshot())


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

    print(f"[http] serving {WEBSITE_DIR} on http://{HTTP_HOST}:{HTTP_PORT}/")
    print(f"[http] telemetry at http://{HTTP_HOST}:{HTTP_PORT}/api/status")
    app.run(host=HTTP_HOST, port=HTTP_PORT, threaded=True)


if __name__ == "__main__":
    main()
