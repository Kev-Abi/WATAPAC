# WATAPAC — Raspberry Pi telemetry server

Reads the Arduino over USB serial, polls OpenWeatherMap, logs everything to
CSV, and serves the dashboard and all of its data from one address.

```
Arduino  --USB serial--> ┌──────────────────────┐ --HTTP--> browser
OpenWeatherMap --HTTPS-> │  watapac_server.py   │
                         └──────────┬───────────┘
                                    └──────────> logs/*.csv --> MATLAB
```

The browser makes one request per second, to one address. It never calls
OpenWeatherMap, which is what keeps the API key off the public page.

## Install and run

```bash
pip3 install -r pi/requirements.txt
python3 pi/watapac_server.py
```

Then open `http://<pi-ip>:5000/` from any device on the same network.

Because the Pi serves the page *and* the data, `PI_ENDPOINT` in `script.js`
stays the relative `/api/status`: same origin, so no CORS configuration and
no https/http mixed-content problem.

## Configuration

All environment variables, so the same file runs on the bench and on the unit:

| Variable | Default | Meaning |
|---|---|---|
| `WATAPAC_SERIAL_PORT` | `/dev/ttyACM0` | `/dev/ttyUSB0` for a CH340-based clone |
| `WATAPAC_BAUD` | `9600` | must match `Serial.begin()` in the sketch |
| `WATAPAC_HOST` | `0.0.0.0` | `127.0.0.1` to restrict to the Pi itself |
| `WATAPAC_PORT` | `5000` | |
| `WATAPAC_OWM_KEY` | *(empty)* | OpenWeatherMap key; empty disables the weather panel |
| `WATAPAC_OWM_LAT` | *(empty)* | site latitude |
| `WATAPAC_OWM_LON` | *(empty)* | site longitude |
| `WATAPAC_LOG_INTERVAL` | `10` | seconds between logged rows; `0` disables logging |
| `WATAPAC_LOG_DIR` | `pi/logs` | where the CSVs go |

```bash
WATAPAC_SERIAL_PORT=/dev/ttyUSB0 \
WATAPAC_OWM_KEY=your_key_here \
WATAPAC_OWM_LAT=14.5995 WATAPAC_OWM_LON=120.9842 \
python3 pi/watapac_server.py
```

**Put the OpenWeatherMap key here, not in `script.js`.** A key in the
JavaScript is readable by anyone who views the deployed site. Here it never
leaves the Pi.

Without a key the server runs normally and the weather panel reports that it
is not configured. Nothing else is affected.

## What the Arduino should send

One reading per line, in either format. Unknown keys are ignored and missing
keys stay absent, so adding a sensor to the sketch cannot break the server.

```
{"rain":1,"waterCm":42.5,"flow":21.3,"voltage":48.2,"current":32.0,"battery":74,"emergency":1}
```

```
rain=1;waterCm=42.5;flow=21.3;voltage=48.2;current=32.0;battery=74;emergency=1
```

| Key | Unit | Notes |
|---|---|---|
| `rain` | 0/1 | rain sensor |
| `waterCm` | cm | ultrasonic distance **down to the surface** — smaller means higher water |
| `flow` | L/min | flow meter |
| `voltage` | V | generator output |
| `current` | A | generator output |
| `battery` | % | 0–100 |
| `emergency` | 0/1 | emergency light circuit state |

Lines that are not readings (boot banners, debug prints, partial lines) are
ignored rather than treated as zeros.

## What the Pi computes

The Arduino sends raw sensor values; the interpretation happens here, where
it can be changed without reflashing.

- **`waterLevel`** — `NORMAL` / `RISING` / `CRITICAL` from `waterCm` against
  `WATER_RISING_CM` and `WATER_CRITICAL_CM`.
- **`floodRisk`** — additive score over water level (2), rain (1) and high
  flow (1): 0 is `LOW`, 1–2 `MEDIUM`, 3+ `HIGH`. A `CRITICAL` water level
  short-circuits straight to `HIGH`. Scoring means no single sensor glitch
  can drive the reading to `HIGH` on its own.
- **`power`** — V × A, in kW.
- **`weather`** — condition, temperature, humidity and wind from
  OpenWeatherMap, refreshed every 10 minutes on its own thread, or `null`
  when no key is set. A reading older than 30 minutes is still sent, with
  `stale: true` so the dashboard can say so rather than implying it is
  current — weather changes slowly, and an old temperature beats a blank
  panel as long as its age is visible.
- **`total`** — power integrated over the gap between readings, in kWh.
  Skipped on the first reading and after a silence longer than twice
  `STALE_AFTER_SECONDS`, because the real output during a gap is unknown and
  assuming it would quietly inflate the total.

**Calibrate `WATER_RISING_CM`, `WATER_CRITICAL_CM` and `FLOW_HIGH_LPM`
against the real channel.** The defaults are placeholders.

## Reporting honestly

The dashboard distinguishes three states, and the server is what makes that
possible:

| Pi | Arduino | `arduinoConnected` | Dashboard |
|---|---|---|---|
| down | — | *(no response)* | red — "not connected" |
| up | silent > 5 s | `false` | amber — "awaiting Arduino data" |
| up | sending | `true` | green — "receiving sensor data" |

When the Arduino goes quiet the server sends `NO DATA` and em dashes rather
than replaying the last numbers it saw. A stale reading that looks live is
worse than a visible gap.

A sensor missing from a line comes through as `—`, never as `0`, so an
unplugged sensor cannot be mistaken for a real zero.

## Logged data

One CSV per day in `logs/`, so a file can be copied off or deleted without
touching the rest and nothing grows without bound.

```
logs/watapac-2026-09-14.csv
```

```
timestamp,epoch,rain,waterCm,waterLevel,floodRisk,emergency,batteryPercent,
voltage,current,power,totalKwh,flowRate,
weatherCondition,weatherTemp,weatherHumidity,weatherWind
```

Rows are written only while real readings are arriving — a gap in the file
means there genuinely was no data, which is more useful than a run of zeros.

**A sensor that did not report writes an empty cell**, not a `0`. MATLAB's
`readtable` and pandas both read an empty cell as missing, so an unplugged
sensor cannot be averaged in as a real zero. That is the whole reason the
logged form and the displayed form are built separately from one set of
derived values.

Weather is logged alongside the sensors, which is what makes it possible to
correlate rainfall against flow rate later.

### Reading it back

```
GET /api/history?hours=24
GET /api/history?hours=168&limit=500
```

```json
{ "hours": 24, "count": 2000, "columns": [...], "rows": [ {...}, ... ] }
```

Capped at 31 days and 2000 rows. Over the cap the rows are sampled evenly
across the window rather than truncated to the newest, so a chart of "last 7
days" covers seven days instead of the most recent forty minutes.

In MATLAB:

```matlab
T = watapac_load_log('Hours', 72);                         % from the CSVs
T = watapac_load_log('Url', 'http://192.168.1.42:5000');   % from a live Pi
plot(T.timestamp, T.flowRate)
```

See [`../matlab/watapac_load_log.m`](../matlab/watapac_load_log.m).

## Running it as a service

```bash
sudo tee /etc/systemd/system/watapac.service >/dev/null <<'UNIT'
[Unit]
Description=WATAPAC telemetry server
After=network.target

[Service]
ExecStart=/usr/bin/python3 /home/pi/WATAPAC/pi/watapac_server.py
WorkingDirectory=/home/pi/WATAPAC
Environment=WATAPAC_OWM_KEY=your_key_here
Environment=WATAPAC_OWM_LAT=14.5995
Environment=WATAPAC_OWM_LON=120.9842
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl enable --now watapac
```

If the serial port is denied, add the user to the `dialout` group
(`sudo usermod -aG dialout pi`) and log back in.

Anything in `Environment=` is readable by any local user via
`systemctl show watapac`. If that matters, use `EnvironmentFile=` pointing at
a file with `chmod 600` instead.

## Note on the development server

`app.run()` is Flask's development server. For a handful of viewers on a
local network that is fine. If this is ever exposed to the open internet,
put it behind a real WSGI server and a reverse proxy first.
