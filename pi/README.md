# WATAPAC — Raspberry Pi telemetry server

Reads the Arduino over USB serial, derives the values the dashboard shows,
and serves both the dashboard and its JSON from one address.

```
Arduino --USB serial--> Raspberry Pi (watapac_server.py) --HTTP--> browser
```

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

```bash
WATAPAC_SERIAL_PORT=/dev/ttyUSB0 python3 pi/watapac_server.py
```

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

## Running it as a service

```bash
sudo tee /etc/systemd/system/watapac.service >/dev/null <<'UNIT'
[Unit]
Description=WATAPAC telemetry server
After=network.target

[Service]
ExecStart=/usr/bin/python3 /home/pi/WATAPAC/pi/watapac_server.py
WorkingDirectory=/home/pi/WATAPAC
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl enable --now watapac
```

If the serial port is denied, add the user to the `dialout` group
(`sudo usermod -aG dialout pi`) and log back in.

## Note on the development server

`app.run()` is Flask's development server. For a handful of viewers on a
local network that is fine. If this is ever exposed to the open internet,
put it behind a real WSGI server and a reverse proxy first.
