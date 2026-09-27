// Cascade download capture (MV3 service worker).
//
// When a download starts in the browser, if the Cascade app is running and the
// extension is paired, this enqueues the download in Cascade (with cookies and
// referrer so authenticated downloads work) and cancels the browser's copy.
// If the app is not reachable or not paired, the browser download proceeds
// normally, so the extension is safe to leave installed.
//
// Pairing: on first run the extension asks the app for its token (GET /pair);
// the app shows an "Allow?" prompt and the user clicks once. No copy/paste.
// Heartbeat: a periodic ping lets the app display "Extension: connected".

const PORTS = [8760, 8761, 8762];
const CLIENT_HEADERS = { "X-Cascade-Client": "extension" };
const log = (...a) => console.log("[cascade]", ...a);

async function getConfig() {
  return chrome.storage.local.get({ token: "", enabled: true });
}

async function findBase() {
  for (const p of PORTS) {
    try {
      const r = await fetch(`http://127.0.0.1:${p}/ping?client=extension`, { headers: CLIENT_HEADERS });
      if (r.ok) return `http://127.0.0.1:${p}`;
    } catch (e) {
      // try next port
    }
  }
  return null;
}

async function note(result, url) {
  log(result, url || "");
  try {
    await chrome.storage.local.set({
      lastEvent: { time: new Date().toISOString(), url: url || "", result },
    });
  } catch (e) {}
}

// pair asks the running app for its token; the user approves in the app.
async function pair() {
  const base = await findBase();
  if (!base) return { ok: false, reason: "app not reachable" };
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 95000); // app prompt times out at 90s
    const r = await fetch(`${base}/pair`, { headers: CLIENT_HEADERS, signal: ctrl.signal });
    clearTimeout(t);
    if (!r.ok) return { ok: false, reason: `HTTP ${r.status}` };
    const { token } = await r.json();
    if (!token) return { ok: false, reason: "empty token" };
    await chrome.storage.local.set({ token });
    await note("paired with app");
    return { ok: true };
  } catch (e) {
    return { ok: false, reason: e && e.message };
  }
}

async function heartbeat() {
  const base = await findBase();
  const { token } = await getConfig();
  if (base && !token) {
    // Not paired yet but the app is running: ask now (prompts the user once).
    await pair();
  }
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create("cascade-heartbeat", { periodInMinutes: 0.5 });
  heartbeat();
});
chrome.runtime.onStartup.addListener(() => {
  chrome.alarms.create("cascade-heartbeat", { periodInMinutes: 0.5 });
  heartbeat();
});
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === "cascade-heartbeat") heartbeat();
});
chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg && msg.type === "pair") {
    pair().then(reply);
    return true; // async reply
  }
});

async function cookieHeader(url) {
  try {
    const cookies = await chrome.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch (e) {
    return "";
  }
}

chrome.downloads.onCreated.addListener(async (item) => {
  let { token, enabled } = await getConfig();
  log("download detected:", item.url, "enabled:", enabled, "paired:", !!token);
  if (!enabled) {
    await note("skipped: capture disabled", item.url);
    return;
  }
  if (!item.url || !/^https?:/i.test(item.url)) {
    await note("skipped: non-http url", item.url);
    return;
  }
  if (item.url.includes("127.0.0.1")) {
    await note("skipped: localhost url", item.url);
    return;
  }

  const base = await findBase();
  if (!base) {
    await note("app not reachable on 8760-8762 (is it running?)", item.url);
    return;
  }
  if (!token) {
    // Try to pair on the spot; the app prompts the user.
    const p = await pair();
    if (!p.ok) {
      await note("not paired (" + p.reason + "); leaving to browser", item.url);
      return;
    }
    token = (await getConfig()).token;
  }

  const cookie = await cookieHeader(item.url);
  const filename = item.filename ? item.filename.split(/[\\/]/).pop() : "";

  let handedOff = false;
  try {
    const resp = await fetch(`${base}/add`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Cascade-Token": token, ...CLIENT_HEADERS },
      body: JSON.stringify({ url: item.url, filename, cookie, referrer: item.referrer || "" }),
    });
    handedOff = resp.ok;
    await note(handedOff ? "handed off to app" : `app rejected: HTTP ${resp.status}`, item.url);
  } catch (e) {
    await note("POST failed: " + (e && e.message), item.url);
    handedOff = false;
  }

  // Only cancel the browser's download once Cascade has accepted it, so a
  // failed hand-off never loses the download.
  if (handedOff) {
    try {
      await chrome.downloads.cancel(item.id);
      await chrome.downloads.erase({ id: item.id });
    } catch (e) {
      // already finished or gone; harmless
    }
    flashBadge("↓");
  }
});

function flashBadge(text) {
  try {
    chrome.action.setBadgeText({ text });
    setTimeout(() => chrome.action.setBadgeText({ text: "" }), 1500);
  } catch (e) {}
}
