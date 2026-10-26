const PORTS = [8760, 8761, 8762];
const CLIENT_HEADERS = { "X-Spate-Client": "extension" };
const tokenEl = document.getElementById("token");
const enabledEl = document.getElementById("enabled");
const statusEl = document.getElementById("status");
const tokenStateEl = document.getElementById("tokenState");
const lastEventEl = document.getElementById("lastEvent");

const modeEl = document.getElementById("mode");
const rulesEl = document.getElementById("rules");

async function load() {
  const cfg = await chrome.storage.local.get({ token: "", enabled: true, mode: "ask", siteRules: {}, lastEvent: null });
  tokenEl.value = cfg.token;
  enabledEl.checked = cfg.enabled;
  modeEl.value = cfg.mode;
  const n = Object.keys(cfg.siteRules || {}).length;
  rulesEl.textContent = n ? `${n} remembered site rule${n === 1 ? "" : "s"}` : "No remembered site rules";
  tokenStateEl.textContent = cfg.token ? "Paired with app" : "Not paired yet";
  tokenStateEl.className = cfg.token ? "ok" : "bad";
  lastEventEl.textContent = cfg.lastEvent
    ? `Last event (${cfg.lastEvent.time}): ${cfg.lastEvent.result}`
    : "Last event: none yet";
}

async function findBase() {
  for (const p of PORTS) {
    try {
      const r = await fetch(`http://127.0.0.1:${p}/ping?client=extension`, { headers: CLIENT_HEADERS });
      if (r.ok) return `http://127.0.0.1:${p}`;
    } catch (e) {}
  }
  return null;
}

// One-click pairing: the app shows an Allow? prompt; no token to copy.
document.getElementById("pair").addEventListener("click", async () => {
  setStatus("Asking the Spate app... click Allow in the app window.", true);
  const res = await chrome.runtime.sendMessage({ type: "pair" });
  if (res && res.ok) setStatus("Paired.", true);
  else setStatus("Pairing failed: " + (res && res.reason), false);
  load();
});

document.getElementById("save").addEventListener("click", async () => {
  await chrome.storage.local.set({ token: tokenEl.value.trim(), enabled: enabledEl.checked, mode: modeEl.value });
  setStatus("Saved.", true);
  load();
});

document.getElementById("clearRules").addEventListener("click", async () => {
  await chrome.storage.local.set({ siteRules: {} });
  setStatus("Site rules cleared.", true);
  load();
});

document.getElementById("test").addEventListener("click", async () => {
  const base = await findBase();
  if (base) setStatus(`Spate app reachable at ${base}.`, true);
  else setStatus("Spate app not reachable. Is it running?", false);
});

// Runs the exact token + POST the background uses, from the extension origin.
document.getElementById("testadd").addEventListener("click", async () => {
  const token = tokenEl.value.trim();
  if (!token) { setStatus("Pair first.", false); return; }
  const base = await findBase();
  if (!base) { setStatus("App not reachable.", false); return; }
  try {
    const resp = await fetch(`${base}/add`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Spate-Token": token, ...CLIENT_HEADERS },
      body: JSON.stringify({ url: "https://cdimage.ubuntu.com/ubuntu/releases/24.04.2/release/SHA256SUMS" }),
    });
    const text = await resp.text();
    setStatus(`POST /add -> HTTP ${resp.status} ${text}`, resp.ok);
  } catch (e) {
    setStatus("POST /add failed: " + (e && e.message), false);
  }
});

// The unpacked extension's ID depends on its folder path, so it differs per
// machine; the native-host manifest must list it. Show it and let it be copied.
document.getElementById("extId").textContent = chrome.runtime.id;
document.getElementById("copyId").addEventListener("click", async () => {
  await navigator.clipboard.writeText(chrome.runtime.id);
  setStatus("Extension ID copied.", true);
});

function setStatus(msg, ok) {
  statusEl.textContent = msg;
  statusEl.className = ok ? "ok" : "bad";
}

load();
