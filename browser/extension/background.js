// Cascade download capture (MV3 service worker).
//
// When a download starts in the browser, if the Cascade app is running and a
// token is configured, this enqueues the download in Cascade (with cookies and
// referrer so authenticated downloads work) and cancels the browser's copy.
// If the app is not reachable or not configured, the browser download proceeds
// normally, so the extension is safe to leave installed.

const PORTS = [8760, 8761, 8762];

async function getConfig() {
  return chrome.storage.local.get({ token: "", enabled: true });
}

async function findBase() {
  for (const p of PORTS) {
    try {
      const r = await fetch(`http://127.0.0.1:${p}/ping`, { method: "GET" });
      if (r.ok) return `http://127.0.0.1:${p}`;
    } catch (e) {
      // try next port
    }
  }
  return null;
}

async function cookieHeader(url) {
  try {
    const cookies = await chrome.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch (e) {
    return "";
  }
}

chrome.downloads.onCreated.addListener(async (item) => {
  const { token, enabled } = await getConfig();
  if (!enabled || !token) return;
  if (!item.url || !/^https?:/i.test(item.url)) return;
  if (item.url.includes("127.0.0.1")) return;

  const base = await findBase();
  if (!base) return; // app not running: let the browser handle it

  const cookie = await cookieHeader(item.url);
  const filename = item.filename ? item.filename.split(/[\\/]/).pop() : "";

  let handedOff = false;
  try {
    const resp = await fetch(`${base}/add`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Cascade-Token": token },
      body: JSON.stringify({
        url: item.url,
        filename,
        cookie,
        referrer: item.referrer || "",
      }),
    });
    handedOff = resp.ok;
  } catch (e) {
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
