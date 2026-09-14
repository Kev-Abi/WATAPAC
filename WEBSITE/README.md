# WATAPAC — Monitoring Interface

A real-time web dashboard for the WATAPAC flood-monitoring and water-powered energy system. It displays live sensor telemetry, weather conditions, and system status on a single screen, readable at a glance from a phone or a monitor.

**Status:** interface complete. Live against the Raspberry Pi — `../pi/watapac_server.py` serves this dashboard, its telemetry *and* its weather from one address. One integration remains: the 3D model file.

Demo mode still exists (`DEMO_MODE = true` in `script.js`) for showing the interface without hardware.

---

## Contents
- [Dashboard panels](#dashboard-panels)
- [Real-time behavior](#real-time-behavior)
- [Status color system](#status-color-system)
- [Visual design](#visual-design)
- [Responsive layout](#responsive-layout)
- [Technical architecture](#technical-architecture)
- [Current status & integration points](#current-status--integration-points)
- [File structure](#file-structure)
- [Running locally](#running-locally)
- [Deployment](#deployment)
- [Roadmap](#roadmap)

---

## Dashboard panels

Eight panels, each showing one aspect of the system.

### 1. Rain Status
Whether the rain sensor is currently detecting precipitation.
- Values: `DETECTED` / `NOT DETECTED`
- Source: rain sensor on the Pi

### 2. Flood Risk Level
The system's assessed flood risk, color-coded by severity.
- Values: `LOW` (green) / `MEDIUM` (amber) / `HIGH` (red)
- Source: computed on the Pi from water level, flow rate, and rainfall

### 3. Emergency Light Status
Whether the emergency lighting is running, plus its battery reserve.
- Values: `ACTIVE` (green) / `INACTIVE` (red)
- Battery shown as a colored pill: green above 50%, amber below 50%, red below 20%
- Source: light circuit state + battery monitor

### 4. Weather Forecast
Four external weather readings in a 2×2 grid:

| Field | Example |
|---|---|
| Condition | Heavy Rain |
| Temperature | 27°C |
| Humidity | 88% |
| Wind | 32 km/h |

Includes a footer showing the data source and the time of the last successful fetch — the **Pi's** fetch time, not this browser's clock, because the point of that line is how old the reading is.

Fetched by the Pi, not by the browser, so the OpenWeatherMap key is never readable by someone viewing the deployed site. Configure it with `WATAPAC_OWM_KEY` on the Pi; there is nothing to set in `script.js`.

Three degraded states, each shown honestly rather than hidden:

| Situation | Panel shows |
|---|---|
| No key set on the Pi | `—` everywhere, "Weather not configured on the Pi" |
| Pi cannot reach OpenWeatherMap | last good reading, marked "(stale — Pi cannot reach it)" |
| OpenWeatherMap omits a field | `—` for that field only |

### 5. 3D Model
A dedicated viewport for an interactive 3D model of the WATAPAC unit (orbit, zoom, auto-rotate).

**Drop a `.glb` at `assets/model.glb` and it appears — no code change.** On load, `loadModel()` probes for the file and only pulls in Google's `<model-viewer>` if one is actually there, so a deployment with no model fetches nothing and keeps the animated placeholder. A model that fails to load also keeps the placeholder rather than leaving an empty box.

Override the path for testing: `index.html?model=assets/v2.glb`

The 404 in the browser console when no model is present is that probe, not a fault.

### 6. Energy Output
Four electrical readings in a 2×2 grid:

| Field | Unit | Example |
|---|---|---|
| Voltage | V | 48.2 V |
| Current | A | 32 A |
| Power Output | kW | 0.5 kW |
| Total Energy | kWh | 0.09 kWh |

Source: voltage/current sensors on the generator output.

### 7. Flow Rate
Water flow through the system.
- Unit: litres per minute (`21.3 L/MIN`)
- Source: flow meter

### 8. Water Level
Current water level classification.
- Values: `NORMAL` (green) / `RISING` (amber) / `CRITICAL` (red)
- Source: ultrasonic or float-based level sensor

### Connection status bar
A persistent footer showing whether the Raspberry Pi is reachable:
- **Red pulsing dot** — "Raspberry Pi: not connected"
- **Green pulsing dot** — "Raspberry Pi: connected"
- Timestamp of the most recent successful update

This reports the true connection state rather than silently showing stale numbers, so a dead sensor feed is immediately visible.

---

## Real-time behavior

- **1-second refresh** on all sensor values — the dashboard re-fetches from the Pi every second and repaints
- **10-minute refresh** on weather data — done by the Pi on its own thread, so there is no second timer here to keep in step
- **Independent failure handling** — sensors and weather travel together but fail apart: the Pi sends `weather: null` when it cannot reach OpenWeatherMap, and the sensor panels are unaffected; a dead Arduino leaves the weather panel alone
- **Graceful degradation** — a failed fetch logs a warning, flips the connection indicator, and falls back rather than crashing the page
- **No page reloads** — values update in place via DOM updates

---

## Status color system

Values color themselves according to what they mean, so severity is readable without reading the text:

| Level | Color | Applies to |
|---|---|---|
| Good | Green | `LOW`, `NORMAL`, `ACTIVE` |
| Warning | Amber | `MEDIUM`, `RISING` |
| Critical | Red | `HIGH`, `CRITICAL`, `INACTIVE` |

This is driven by a single `LEVEL_MAP` lookup in `script.js`, so it applies automatically to real Pi data — not just the demo values. Adding a new status word means adding one line.

---

## Visual design

- **Dark theme** — high contrast, suited to control-room or low-light viewing
- **Per-panel accent colors** — each panel has its own hue (blue, amber, green, sky, violet, yellow, cyan, teal) shown as a glowing top border and matching header icon, making panels distinguishable at a glance
- **Inline SVG icons** — one per panel header (rain cloud, warning triangle, lightning bolt, cube, waveform, water lines); no icon-font dependency
- **Layered depth** — gradient card surfaces, inset shadows on value boxes, and an ambient background glow
- **Staggered entrance animation** — panels fade and rise in sequence on load
- **Hover interaction** — cards lift slightly with a brightened border
- **Condensed display typography** — Bebas Neue for numbers, Oswald for labels, keeping large values readable in tight space
- **Demo-mode banner** — an unmissable amber notice while values are simulated, so demo data is never mistaken for real readings

---

## Responsive layout

| Screen | Layout |
|---|---|
| Desktop (≥900px) | 6-column grid — three panels per row, wide panels spanning half |
| Tablet | 3-column grid |
| Mobile (≤640px) | Single column, full-width stacked panels |

Tested at 375px (mobile) and 1280px (desktop). All glow and depth effects scale correctly.

---

## Technical architecture

- **Zero dependencies** — no framework, no build step, no `node_modules`. Three files and a Google Fonts link.
- **Pure static hosting** — works on any static host. All live behavior happens client-side in the browser, which polls the Pi directly.
- **Direct browser-to-Pi connection** — sensor data never passes through the web host; it goes straight from the Pi to whoever is viewing the page.
- **Separation of concerns** — every external integration is isolated in a single named function, so connecting real hardware never requires touching the rendering code.

```
┌──────────────┐   loads once   ┌─────────────────┐   polls 1×/sec   ┌──────────────┐
│ Static host  │ ─────────────▶ │  Your browser   │ ───────────────▶ │ Raspberry Pi │
│ (GitHub      │   HTML/CSS/JS  │  runs script.js │ ◀─────────────── │  sensor API  │
│  Pages)      │                │  paints the UI  │    JSON          │              │
└──────────────┘                └─────────────────┘                  └──────────────┘
                                         │
                                         │  every 10 min
                                         ▼
                                 ┌────────────────┐
                                 │ OpenWeatherMap │
                                 └────────────────┘
```

---

## Current status & integration points

Weather and telemetry both arrive in the single `/api/status` document, so the browser makes one request per second to one address:

| # | Integration | Function | Switch to enable | Status |
|---|---|---|---|---|
| 1 | Raspberry Pi | `fetchFromRaspberryPi()` | already on (`DEMO_MODE = false`) | ✅ Server built — see [`../pi/`](../pi/) |
| 2 | OpenWeatherMap | *(none — the Pi does it)* | `WATAPAC_OWM_KEY` on the Pi | ✅ Wired — ⏳ pending an API key |
| 3 | 3D model | `loadModel()` | drop `assets/model.glb` in | ✅ Wired — ⏳ pending the model file |

### Expected JSON from the Pi
The dashboard expects this shape from `PI_ENDPOINT`:

```json
{
  "arduinoConnected": true,
  "rainStatus": "DETECTED",
  "floodRisk": "MEDIUM",
  "emergencyActive": true,
  "batteryPercent": 74,
  "voltage": 48.2,
  "current": 32,
  "power": 0.5,
  "total": 0.09,
  "flowRate": 21.3,
  "waterLevel": "NORMAL",
  "weather": {
    "condition": "Heavy Rain",
    "temp": 27,
    "humidity": 88,
    "wind": 32,
    "updatedAt": 1789401038,
    "stale": false
  }
}
```

`weather` is `null` when the Pi has no API key or has not managed a successful fetch.

`arduinoConnected` is what separates "the Pi is down" from "the Pi is up but the Arduino is silent" in the status bar. Any value the Pi does not have arrives as the string `"—"`, never as `0`, so a missing sensor cannot be misread as a real zero.

The full field-by-field contract, including what the Arduino sends over serial, is in [`../pi/README.md`](../pi/README.md).

### Demo mode
While `DEMO_MODE = true`, `generateDemoData()` produces realistic drifting values using a bounded random walk — numbers move plausibly instead of jumping randomly, so the interface can be demonstrated convincingly without hardware. Deleting this function once the Pi is live has no effect on anything else.

---

## File structure

```
WEBSITE/
├── index.html      Structure and panel markup, inline SVG icons
├── style.css       Theme, grid layout, animations, responsive rules
├── script.js       Data fetching, rendering, model loading, demo simulation
├── assets/         model.glb goes here
└── README.md       This file
```

The repository also holds [`../pi/`](../pi/) (the telemetry server) and
[`../matlab/`](../matlab/) (the Simscape turbine model).

---

## Running locally

**With the Pi server** — the real setup, dashboard and data from one origin:

```bash
pip3 install -r ../pi/requirements.txt
python3 ../pi/watapac_server.py      # http://localhost:5000
```

**Interface only**, no backend — every panel shows `—` and the status bar
reads "not connected", which is correct:

```bash
cd WEBSITE && python3 -m http.server 8000
```

**Against a Pi elsewhere on the network:**

```
http://localhost:8000/?pi=http://192.168.1.42:5000/api/status
```

---

## Deployment

Hosted on **GitHub Pages** — free indefinitely, no server to maintain, no build step. To publish updates:

```bash
git add -A && git commit -m "describe the change" && git push
```

The live site updates about a minute later.

> **Note:** "static hosting" refers to the *files* being unchanging, not the data. The dashboard still updates every second, because the polling happens in the visitor's browser.

---

## Roadmap

**Pending hardware/assets**
- [x] Connect Raspberry Pi 4B sensor API
- [ ] Add an OpenWeatherMap API key and site coordinates (`WATAPAC_OWM_KEY` etc. on the Pi)
- [x] Wire the 3D viewport — [ ] still needs the model file itself
- [ ] Expose the Pi over HTTPS (Cloudflare Tunnel) for access outside the local network
- [ ] Calibrate the water-level and flow thresholds in `../pi/watapac_server.py`

**Not yet built**
- [x] **Data logging** — the Pi writes a daily CSV and serves it back at `/api/history`
- [ ] **Historical graphs** — trends over time for flow rate, energy output, and water level. The data is there now; the panels are not.
- [ ] **Alert thresholds** — visual or audible warning when flood risk hits `HIGH`
- [ ] **CSV export** — for analysis and reporting
