// Cascade download capture (MV3 service worker).
//
// When a download starts in the browser, the extension either asks the user
// ("Download with Cascade?" popup), or acts on a remembered per-site rule or the
// global mode. Handing off means: make sure the app is running (launching it
// through the native-messaging host if needed), POST the download to it (with
// cookies and referrer so authenticated downloads work), and only then cancel
// the browser's copy. The browser download keeps running until the user (or a
// rule) chooses Cascade, so nothing is ever lost.
//
// Modes: "ask" (default), "always" (Cascade without asking), "never" (off).
// Site rules: {host: "cascade" | "browser"} remembered from the popup.

const PORTS = [8760, 8761, 8762];
const CLIENT_HEADERS = { "X-Cascade-Client": "extension" };
const log = (...a) => console.log("[cascade]", ...a);

async function getConfig() {
  return chrome.storage.local.get({ token: "", enabled: true, mode: "ask", siteRules: {} });
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
    const t = setTimeout(() => ctrl.abort(), 95000);
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
// token comes back over the browser-enforced trusted channel (no prompt);
// without it, falls back to /pair (Allow prompt in the app).
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

// cookieHeader returns the Cookie header for url from the right cookie store.
// Incognito windows have their own store; reading the default one there would
// hand off a download with no session, which is exactly how a session-bound
// host answers 403. Requires "Allow in Incognito" on chrome://extensions for
// incognito downloads to be visible to the extension at all.
async function cookieHeader(url, incognito) {
  try {
    let storeId;
    if (incognito) {
      const stores = await chrome.cookies.getAllCookieStores();
      const inc = stores.find((s) => s.id !== "0"); // "0" is the regular store
      if (!inc) return "";
      storeId = inc.id;
    }
    const cookies = await chrome.cookies.getAll(storeId ? { url, storeId } : { url });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch (e) {
    return "";
  }
}

// browserLikeHeaders mimics a top-level navigation so hosts that inspect
// fetch metadata treat the app's request like the browser's.
function browserLikeHeaders(url, referrer) {
  const h = {
    Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": navigator.language || "en-US,en;q=0.9",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-User": "?1",
  };
  try {
    const same = referrer && new URL(referrer).origin === new URL(url).origin;
    h["Sec-Fetch-Site"] = referrer ? (same ? "same-origin" : "cross-site") : "none";
  } catch (e) {
    h["Sec-Fetch-Site"] = "none";
  }
  return h;
}

function hostOf(url) {
  try {
    return new URL(url).hostname;
  } catch (e) {
    return "";
  }
}

// handOff sends the download to the app and, on success, cancels the browser's
// copy. If the browser already finished it, nothing is handed off.
async function handOff(item) {
  try {
    const [cur] = await chrome.downloads.search({ id: item.id });
    if (cur && cur.state === "complete") {
      await note("already finished in browser; not handed off", item.url);
      return;
    }
  } catch (e) {}

  const app = await ensureApp();
  if (!app.base) {
    await note("app not running and could not be launched (install the native host); leaving to browser", item.url);
    return;
  }
  if (!app.token) {
    await note("not paired; leaving to browser", item.url);
    return;
  }

  const cookie = await cookieHeader(item.url, item.incognito);
  const filename = item.filename ? item.filename.split(/[\\/]/).pop() : "";

  // Stop the browser's own stream BEFORE the app probes: free-tier hosts allow
  // one connection per IP and answer 503 to a second one while the browser is
  // still downloading. The app verifies fetchability before accepting; if it
  // refuses, the download is restarted in the browser below (the generated
  // direct URLs are time-limited, not single-use).
  let cancelled = false;
  try {
    await chrome.downloads.cancel(item.id);
    cancelled = true;
    await new Promise((r) => setTimeout(r, 1500)); // let the host release the slot
  } catch (e) {}

  let handedOff = false;
  try {
    const resp = await fetch(`${app.base}/add`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Cascade-Token": app.token, ...CLIENT_HEADERS },
      body: JSON.stringify({
        url: item.url,
        filename,
        cookie,
        referrer: item.referrer || "",
        userAgent: navigator.userAgent,
        headers: browserLikeHeaders(item.url, item.referrer),
      }),
    });
    handedOff = resp.ok;
    if (handedOff) {
      await note("handed off to app", item.url);
    } else {
      // The app verifies it can fetch the URL before accepting; a refusal
      // (e.g. 403 to a plain GET on a session-bound link) means the browser's
      // own download is left running, so nothing is lost.
      let reason = `HTTP ${resp.status}`;
      try {
        const j = await resp.json();
        if (j && j.error) reason = j.error;
      } catch (e) {}
      await note("app refused (" + reason + "); left to browser", item.url);
    }
  } catch (e) {
    await note("POST failed: " + (e && e.message), item.url);
  }
  if (handedOff) {
    try {
      await chrome.downloads.erase({ id: item.id });
    } catch (e) {}
    flashBadge("↓");
  } else if (cancelled) {
    // Give the download back to the browser (same URL, same referer).
    try {
      await chrome.downloads.erase({ id: item.id });
      const opts = { url: item.url, conflictAction: "uniquify" };
      if (filename) opts.filename = filename;
      if (item.referrer) opts.headers = [{ name: "Referer", value: item.referrer }];
      await chrome.downloads.download(opts);
      await note("app refused; restarted in browser", item.url);
    } catch (e) {
      await note("app refused and browser restart failed: " + (e && e.message), item.url);
    }
  }
}

async function askUser(item) {
  await chrome.storage.session.set({ ["pending:" + item.id]: item });
  await chrome.windows.create({
    url: chrome.runtime.getURL("choose.html?d=" + item.id),
    type: "popup",
    width: 440,
    height: 230,
    focused: true,
  });
  await note("asked user", item.url);
}

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg && msg.type === "pair") {
    pair().then(reply);
    return true;
  }
  if (msg && msg.type === "choice") {
    (async () => {
      const { siteRules } = await getConfig();
      if (msg.remember && msg.item && msg.item.host) {
        siteRules[msg.item.host] = msg.choice;
        await chrome.storage.local.set({ siteRules });
      }
      await chrome.storage.session.remove("pending:" + msg.id);
      if (msg.choice === "cascade") await handOff(msg.item);
      else await note("user chose browser", msg.item && msg.item.url);
      reply({ ok: true });
    })();
    return true;
  }
});

chrome.downloads.onCreated.addListener(async (raw) => {
  const { enabled, mode, siteRules } = await getConfig();
  // Prefer the final URL (after redirects): that is the one a plain GET can
  // actually fetch. raw.url may be the page that initiated the download.
  const url = raw.finalUrl || raw.url;
  const item = {
    id: raw.id,
    url,
    filename: raw.filename || "",
    referrer: raw.referrer || "",
    host: hostOf(url),
    incognito: !!raw.incognito, // read cookies from the incognito store
  };
  log("download detected:", item.url, "mode:", mode);
  if (!enabled || mode === "never") {
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
  const rule = siteRules[item.host];
  if (rule === "browser") {
    await note("site rule: browser", item.url);
    return;
  }
  if (mode === "always" || rule === "cascade") {
    await handOff(item);
    return;
  }
  await askUser(item);
});

function flashBadge(text) {
  try {
    chrome.action.setBadgeText({ text });
    setTimeout(() => chrome.action.setBadgeText({ text: "" }), 1500);
  } catch (e) {}
}
