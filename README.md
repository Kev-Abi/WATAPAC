# WATAPAC

Flood monitoring and water-powered energy generation.

```
┌──────────────┐ serial  ┌──────────────┐  HTTP   ┌─────────┐
│ Arduino      │ ──────▶ │ Raspberry Pi │ ──────▶ │ Browser │
│ sensors      │         │    pi/       │         │ WEBSITE/│
└──────────────┘         └───────┬──────┘         └─────────┘
┌──────────────┐ HTTPS           │
│OpenWeatherMap│ ──────▶         ▼
└──────────────┘          pi/logs/*.csv
                                 │
                                 ▼
                          ┌──────────────┐
                          │   matlab/    │
                          └──────────────┘
```

Everything reaches the browser through the Pi. The weather key never leaves
it, and there is one place where readings are written to disk.

## Layout

| Directory | What it is | Docs |
|---|---|---|
| [`WEBSITE/`](WEBSITE/) | Real-time dashboard. No framework, no build step. | [README](WEBSITE/README.md) |
| [`pi/`](pi/) | Telemetry server. Reads the Arduino, serves the dashboard and its JSON. | [README](pi/README.md) |
| [`matlab/`](matlab/) | Simscape Multibody model of the cascade turbine. | [README](matlab/README.md) |

## Quick start

```bash
pip3 install -r pi/requirements.txt

WATAPAC_OWM_KEY=your_key WATAPAC_OWM_LAT=14.5995 WATAPAC_OWM_LON=120.9842 \
  python3 pi/watapac_server.py
```

The key is optional — without it everything runs and the weather panel says
so. It belongs on the Pi rather than in `script.js`, where anyone viewing the
site could read it.

Open `http://<pi-ip>:5000/`. Without an Arduino attached the server still
runs and the dashboard correctly reports that no sensor data is arriving.

```matlab
cd matlab
watapac_check_env          % first: what does this MATLAB have?
watapac_build_turbine_3d
```

## Where things stand

| | |
|---|---|
| Dashboard | ✅ Complete, live against the Pi |
| Pi telemetry server | ✅ Built and tested — thresholds still need calibrating |
| Weather via the Pi | ✅ Built — ⏳ needs an OpenWeatherMap key |
| Data logging + `/api/history` | ✅ Built and tested |
| MATLAB log loader | ✅ Written — ⏳ untested without a MATLAB licence |
| 3D viewport | ✅ Wired — ⏳ waiting on the `.glb` |
| Turbine geometry model | ✅ Builds — ⏳ dimensions unverified against the prototype |
| Turbine physics | ❌ Not started — the model is geometry only |
| Historical charts | ❌ Not started — the data exists, the panels do not |

## A note on the placeholder numbers

Several constants across the project are **guesses, not measurements**, and
are marked as such where they appear:

- flood-risk and water-level thresholds in `pi/watapac_server.py`
- every dimension in `matlab/watapac_params.m`
- the turbine's overall architecture (`stage_offset_axis`) — whether the
  stages sit side by side in the channel or stack on one shaft

None of them should be quoted as results until they have been checked
against the prototype.
