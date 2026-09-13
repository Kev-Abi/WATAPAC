/* ==========================================================================
   WATAPAC INTERFACE
   ==========================================================================
   Data chain:   Arduino (sensors) --serial--> Raspberry Pi 4B --HTTP--> here

   The Pi runs pi/watapac_server.py, which serves telemetry as JSON at
   /api/status. This file polls that endpoint once per second and paints the
   values on screen.

   Two integration points remain stubbed:
     1. OPENWEATHERMAP -> fetchWeather()
     2. 3D MODEL       -> loadModel()
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
// 2. OPENWEATHERMAP
// ---------------------------------------------------------------------------
// Once you have an API key, fill these in and set WEATHER_DEMO_MODE = false.
// Docs: https://openweathermap.org/current
//
// Note: a key placed here is publicly readable by anyone who views the
// deployed site. On the free tier the worst case is a burned rate limit, but
// the clean fix is to let the Pi fetch weather and fold it into its own JSON.

const OWM_API_KEY = "";      // <-- paste your API key here
const OWM_LAT = "";          // <-- site latitude
const OWM_LON = "";          // <-- site longitude
const WEATHER_DEMO_MODE = true;

async function fetchWeather() {
  if (WEATHER_DEMO_MODE || !OWM_API_KEY || !OWM_LAT || !OWM_LON) return null;
  const url = `https://api.openweathermap.org/data/2.5/weather?lat=${OWM_LAT}&lon=${OWM_LON}&units=metric&appid=${OWM_API_KEY}`;
  try {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`OpenWeatherMap responded ${res.status}`);
    const data = await res.json();
    return {
      condition: data.weather?.[0]?.main ?? "--",
      temp: Math.round(data.main?.temp ?? 0),
      humidity: data.main?.humidity ?? 0,
      wind: Math.round((data.wind?.speed ?? 0) * 3.6), // m/s -> km/h
    };
  } catch (err) {
    console.warn("OpenWeatherMap fetch failed:", err);
    return null;
  }
}

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

function updateWeather(weatherData) {
  const w = weatherData || {
    condition: "Heavy Rain",
    temp: 27,
    humidity: 88,
    wind: 32,
  };
  setText("wxCondition", w.condition);
  setText("wxTemp", `${w.temp}°C`);
  setText("wxHumidity", `${w.humidity}%`);
  setText("wxWind", `${w.wind} km/h`);
  setText("wxSource", WEATHER_DEMO_MODE ? "Source: OpenWeatherMap (pending API key)" : "Source: OpenWeatherMap");
  setText("wxUpdated", `Updated: ${new Date().toLocaleTimeString()}`);
}

// ---------------------------------------------------------------------------
// MAIN LOOP
// ---------------------------------------------------------------------------

async function refresh() {
  const piData = await fetchFromRaspberryPi();
  updateDashboard(piData);
}

function init() {
  setConnectionStatus(DEMO_MODE ? "demo" : "offline");
  loadModel();

  // Show the banner only while values are simulated.
  const banner = document.getElementById("demoBanner");
  if (banner && !DEMO_MODE) banner.style.display = "none";

  refresh();
  updateWeather(null);

  setInterval(refresh, 1000);       // sensor values refresh every second
  setInterval(async () => {         // weather refreshes less often
    const weatherData = await fetchWeather();
    updateWeather(weatherData);
  }, 10 * 60 * 1000);
}

document.addEventListener("DOMContentLoaded", init);
