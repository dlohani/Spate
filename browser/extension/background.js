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

// ensureApp returns {base, token} for a running app, launching it through the
// native-messaging host if it is not running. With the host installed the
// token comes back over the browser-enforced trusted channel, so no Allow
// prompt is needed; without the host, it falls back to /pair (Allow prompt).
async function ensureApp() {
  let base = await findBase();
  let { token } = await getConfig();
  if (base && token) return { base, token };
  try {
    const r = await chrome.runtime.sendNativeMessage("com.cascade.host", { type: "ensure" });
    if (r && r.ok) {
      base = "http://" + r.addr;
      if (r.token) {
        token = r.token;
        await chrome.storage.local.set({ token });
      }
      if (r.launched) await note("launched Cascade app via native host");
    } else {
      log("native host replied:", r && r.error);
    }
  } catch (e) {
    // Host not installed (run scripts/install-macos.sh) or not allowed for this
    // extension ID; fall back to the app already running + /pair.
    log("native host unavailable:", e && e.message);
  }
  if (!base) base = await findBase();
  if (base && !token) {
    const p = await pair();
    if (p.ok) token = (await getConfig()).token;
  }
  return { base, token };
}

async function heartbeat() {
  // Keep the app's "Extension: connected" indicator fresh; pair if needed. Does
  // not launch the app (launch happens on demand when a download starts).
  const base = await findBase();
  const { token } = await getConfig();
  if (base && !token) await pair();
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

  // P0: make sure the app is running (launch it via the native host if not)
  // and that we hold its token; only then hand the download over.
  const app = await ensureApp();
  const base = app.base;
  token = app.token;
  if (!base) {
    await note("app not running and could not be launched (install the native host); leaving to browser", item.url);
    return;
  }
  if (!token) {
    await note("not paired; leaving to browser", item.url);
    return;
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
