const PORTS = [8760, 8761, 8762];
const tokenEl = document.getElementById("token");
const enabledEl = document.getElementById("enabled");
const statusEl = document.getElementById("status");

async function load() {
  const cfg = await chrome.storage.local.get({ token: "", enabled: true });
  tokenEl.value = cfg.token;
  enabledEl.checked = cfg.enabled;
}

document.getElementById("save").addEventListener("click", async () => {
  await chrome.storage.local.set({ token: tokenEl.value.trim(), enabled: enabledEl.checked });
  setStatus("Saved.", true);
});

document.getElementById("test").addEventListener("click", async () => {
  for (const p of PORTS) {
    try {
      const r = await fetch(`http://127.0.0.1:${p}/ping`);
      if (r.ok) {
        setStatus(`Cascade app reachable on port ${p}.`, true);
        return;
      }
    } catch (e) {}
  }
  setStatus("Cascade app not reachable. Is it running?", false);
});

function setStatus(msg, ok) {
  statusEl.textContent = msg;
  statusEl.className = ok ? "ok" : "bad";
}

load();
