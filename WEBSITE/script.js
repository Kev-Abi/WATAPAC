/* ==========================================================================
   WATAPAC INTERFACE
   ==========================================================================
   Data chain:   Arduino (sensors) --serial--> Raspberry Pi 4B --HTTP--> here
                 OpenWeatherMap -----HTTPS-----^

   The Pi runs pi/watapac_server.py, which serves everything as one JSON
   document at /api/status: sensor telemetry AND weather. This file polls that
   endpoint once per second and paints the values on screen.

   The browser makes exactly one request per cycle, to one address. Weather is
   fetched by the Pi rather than here, which is what keeps the OpenWeatherMap
   key off the public page.
   ========================================================================== */

// ---------------------------------------------------------------------------
// 1. RASPBERRY PI DATA
// ---------------------------------------------------------------------------
// DEMO_MODE = true  -> ignore the Pi entirely, simulate values in-browser.
//             false -> poll the real Pi at PI_ENDPOINT.
const DEMO_MODE = false;

// Where the Pi's API lives.
//
// The default is RELATIVE ("/api/status"), which resolves against whatever
// address the page was loaded from. That is exactly right when the Pi serves
// the dashboard itself (watapac_server.py does this) — visit
// http://<pi-ip>:5000/ and the data comes from the same place, so there is no
// CORS and no https/http mixed-content problem to solve.
//
// If the dashboard is hosted somewhere ELSE (GitHub Pages, or a separate local
// web server), point this at the Pi's full address instead — or override it
// per-visit with a ?pi= parameter, which is handy for testing:
//
//   index.html?pi=http://192.168.1.42:5000/api/status
//   index.html?pi=https://watapac.trycloudflare.com/api/status
//
const DEFAULT_PI_ENDPOINT = "/api/status";
const PI_ENDPOINT =
  new URLSearchParams(location.search).get("pi") || DEFAULT_PI_ENDPOINT;

// Shown when the Pi is unreachable. Deliberately blank-looking: the dashboard
// must never display a number it did not actually receive.
const OFFLINE_PLACEHOLDER = {
  rainStatus: "—",
  floodRisk: "—",
  emergencyActive: false,
  batteryPercent: 0,
  voltage: "—",
  current: "—",
  power: "—",
  total: "—",
  flowRate: "—",
  waterLevel: "—",
  weather: null,
};

async function fetchFromRaspberryPi() {
  if (DEMO_MODE || !PI_ENDPOINT) return null;
  try {
    const res = await fetch(PI_ENDPOINT, { cache: "no-store" });
    if (!res.ok) throw new Error(`Pi responded ${res.status}`);
    return await res.json();
  } catch (err) {
    // Unreachable Pi, CORS rejection, or bad JSON all land here.
    console.warn("Raspberry Pi fetch failed:", err.message);
    return null;
  }
}

// ---------------------------------------------------------------------------
// 2. WEATHER
// ---------------------------------------------------------------------------
// Nothing to do here. The Pi polls OpenWeatherMap on its own schedule and
// includes the result in /api/status as a "weather" object, or null when no
// API key is configured on the Pi.
//
// Set it up on the Pi, not here:
//     WATAPAC_OWM_KEY=... WATAPAC_OWM_LAT=... WATAPAC_OWM_LON=... \
//       python3 pi/watapac_server.py
//
// Doing it that way means the key is never readable by someone viewing the
// deployed site, and the browser never makes a cross-origin request.

// ---------------------------------------------------------------------------
// 3. 3D MODEL
// ---------------------------------------------------------------------------
// Drop a .glb at assets/model.glb and it renders — no code change needed.
//
// loadModel() probes for the file first and only pulls in <model-viewer> if
// one is actually there. That keeps the "no dependencies" promise true for
// anyone running the dashboard without a model: nothing is fetched, and the
// animated placeholder in index.html stays exactly as it is.
//
// Override the path per-visit for testing:  index.html?model=assets/v2.glb

const DEFAULT_MODEL_PATH = "assets/model.glb";
const MODEL_PATH =
  new URLSearchParams(location.search).get("model") || DEFAULT_MODEL_PATH;

const MODEL_VIEWER_SRC =
  "https://unpkg.com/@google/model-viewer@3.5.0/dist/model-viewer.min.js";

async function modelExists(path) {
  try {
    // HEAD avoids downloading the whole model just to find out it is missing.
    const res = await fetch(path, { method: "HEAD", cache: "no-store" });
    return res.ok;
  } catch {
    return false; // offline, or the host rejects HEAD — fall back to placeholder
  }
}

function injectModelViewer(path) {
  const viewport = document.getElementById("modelViewport");
  if (!viewport) return;

  const script = document.createElement("script");
  script.type = "module";
  script.src = MODEL_VIEWER_SRC;
  script.onerror = () => console.warn("model-viewer failed to load; keeping placeholder");
  document.head.appendChild(script);

  const viewer = document.createElement("model-viewer");
  viewer.setAttribute("src", path);
  viewer.setAttribute("alt", "3D model of the WATAPAC unit");
  viewer.setAttribute("camera-controls", "");
  viewer.setAttribute("auto-rotate", "");
  viewer.setAttribute("shadow-intensity", "1");
  viewer.setAttribute("environment-image", "neutral");
  viewer.className = "model-viewer-el";

  // Swap only once the model is really on screen, so a broken .glb leaves the
  // placeholder up rather than an empty grey box.
  viewer.addEventListener("load", () => {
    viewport.replaceChildren(viewer);
  }, { once: true });
  viewer.addEventListener("error", () => {
    console.warn(`Model at ${path} failed to load; keeping placeholder`);
  }, { once: true });

  // Off-screen until it loads, then replaceChildren() puts it in place.
  viewer.style.position = "absolute";
  viewer.style.inset = "0";
  viewport.appendChild(viewer);
}

async function loadModel() {
  if (await modelExists(MODEL_PATH)) injectModelViewer(MODEL_PATH);
}

// ---------------------------------------------------------------------------
// DEMO DATA GENERATOR (only runs while DEMO_MODE = true)
// ---------------------------------------------------------------------------

function randomWalk(value, step, min, max) {
  const next = value + (Math.random() - 0.5) * step;
  return Math.min(max, Math.max(min, next));
}

let demoState = {
  rainStatus: "DETECTED",
  floodRisk: "MEDIUM",
  emergencyActive: true,
  batteryPercent: 74,
  voltage: 48.2,
  current: 32,
  power: 0.5,
  total: 0.09,
  flowRate: 21.3,
  waterLevel: "NORMAL",
  weather: { condition: "Heavy Rain", temp: 27, humidity: 88, wind: 32, updatedAt: null, stale: false },
};

function generateDemoData() {
  demoState.batteryPercent = Math.round(randomWalk(demoState.batteryPercent, 1.5, 20, 100));
  demoState.voltage = +randomWalk(demoState.voltage, 0.8, 44, 52).toFixed(1);
  demoState.current = Math.round(randomWalk(demoState.current, 2, 20, 40));
  demoState.power = +randomWalk(demoState.power, 0.05, 0.2, 1.2).toFixed(2);
  demoState.total = +(demoState.total + demoState.power / 600).toFixed(2);
  demoState.flowRate = +randomWalk(demoState.flowRate, 1.5, 10, 30).toFixed(1);
  return { ...demoState };
}

// ---------------------------------------------------------------------------
// RENDER HELPERS
// ---------------------------------------------------------------------------

function setText(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}

function setStatusClass(id, level) {
  // level: "good" | "warn" | "bad" | null
  const el = document.getElementById(id);
  if (!el) return;
  el.classList.remove("status-good", "status-warn", "status-bad");
  if (level) el.classList.add(`status-${level}`);
}

/**
 * Three-state connection indicator, so a partial failure is distinguishable
 * from a total one:
 *   "offline" - the Pi itself is unreachable
 *   "pending" - the Pi answered, but the Arduino isn't sending data yet
 *   "online"  - full chain working, values are real sensor readings
 */
function setConnectionStatus(state) {
  const el = document.getElementById("connStatus");
  if (!el) return;
  const labels = {
    offline: "Raspberry Pi: not connected",
    pending: "Raspberry Pi: connected — awaiting Arduino data",
    online: "Raspberry Pi: connected — receiving sensor data",
    demo: "Demo mode — simulated data",
  };
  el.innerHTML = `<i class="dot"></i>${labels[state] || labels.offline}`;
  el.className = "conn " + state;
}

const LEVEL_MAP = {
  LOW: "good", NORMAL: "good", ACTIVE: "good",
  MEDIUM: "warn", RISING: "warn",
  HIGH: "bad", CRITICAL: "bad", INACTIVE: "bad",
};

// Units are appended only to real numbers — never to a "—" placeholder,
// which would render nonsense like "— V".
function withUnit(value, unit) {
  return typeof value === "number" ? `${value} ${unit}` : value;
}

function updateDashboard(piData) {
  let d, connState;

  if (DEMO_MODE) {
    d = generateDemoData();
    connState = "demo";
  } else if (piData) {
    d = piData;
    connState = piData.arduinoConnected ? "online" : "pending";
  } else {
    d = OFFLINE_PLACEHOLDER;
    connState = "offline";
  }

  setConnectionStatus(connState);

  setText("rainStatus", d.rainStatus);

  setText("floodRisk", d.floodRisk);
  setStatusClass("floodRisk", LEVEL_MAP[d.floodRisk] || null);

  const emergencyText = d.emergencyActive ? "ACTIVE" : (connState === "offline" || d.rainStatus === "NO DATA" ? "—" : "INACTIVE");
  setText("emergencyStatus", emergencyText);
  setStatusClass("emergencyStatus", d.emergencyActive ? "good" : null);

  setText("batteryPill", `BATTERY: ${d.batteryPercent}%`);
  const pillEl = document.getElementById("batteryPill");
  if (pillEl) {
    pillEl.classList.remove("low", "critical");
    if (d.batteryPercent < 20) pillEl.classList.add("critical");
    else if (d.batteryPercent < 50) pillEl.classList.add("low");
  }

  setText("energyVoltage", withUnit(d.voltage, "V"));
  setText("energyCurrent", withUnit(d.current, "A"));
  setText("energyPower", withUnit(d.power, "kW"));
  setText("energyTotal", withUnit(d.total, "kWh"));

  setText("flowRate", withUnit(d.flowRate, "L/MIN"));

  setText("waterLevel", d.waterLevel);
  setStatusClass("waterLevel", LEVEL_MAP[d.waterLevel] || null);

  setText("lastUpdate", `Last update: ${new Date().toLocaleTimeString()}`);
}

function updateWeather(w) {
  // No weather means the Pi has no API key configured, or has not managed a
  // successful fetch yet. Either way there is nothing real to show, so show
  // nothing -- the same rule the sensor panels follow. The previous version
  // displayed a hardcoded "Heavy Rain, 27°C" here, which looked exactly like
  // a live reading.
  if (!w) {
    setText("wxCondition", "—");
    setText("wxTemp", "—");
    setText("wxHumidity", "—");
    setText("wxWind", "—");
    setText("wxSource", "Weather not configured on the Pi");
    setText("wxUpdated", "Updated: --");
    return;
  }

  const dash = (value, suffix) => (value === null || value === undefined ? "—" : `${value}${suffix}`);

  setText("wxCondition", w.condition ?? "—");
  setText("wxTemp", dash(w.temp, "°C"));
  setText("wxHumidity", dash(w.humidity, "%"));
  setText("wxWind", dash(w.wind, " km/h"));

  setText("wxSource", w.stale
    ? "Source: OpenWeatherMap (stale — Pi cannot reach it)"
    : "Source: OpenWeatherMap");

  // The Pi's fetch time, not this browser's clock: the point of the line is
  // how old the reading is, and those two differ whenever a fetch fails.
  setText("wxUpdated", w.updatedAt
    ? `Updated: ${new Date(w.updatedAt * 1000).toLocaleTimeString()}`
    : "Updated: --");
}


// ---------------------------------------------------------------------------
// MAIN LOOP
// ---------------------------------------------------------------------------

async function refresh() {
  const piData = await fetchFromRaspberryPi();
  updateDashboard(piData);
  // Sensors and weather arrive in the same document, but they still fail
  // independently: the Pi sends weather: null when it cannot reach
  // OpenWeatherMap, and the sensor panels are unaffected.
  updateWeather(DEMO_MODE ? demoState.weather : (piData ? piData.weather : null));
}

function init() {
  setConnectionStatus(DEMO_MODE ? "demo" : "offline");
  loadModel();

  // Show the banner only while values are simulated.
  const banner = document.getElementById("demoBanner");
  if (banner && !DEMO_MODE) banner.style.display = "none";

  refresh();

  // One timer, one request. The Pi re-polls OpenWeatherMap every 10 minutes on
  // its own schedule, so there is no second timer to keep in step here.
  setInterval(refresh, 1000);
}

document.addEventListener("DOMContentLoaded", init);
