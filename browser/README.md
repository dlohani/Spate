# Cascade browser capture

Automatically send downloads started in the browser to the Cascade app, so you
never copy/paste a URL. This is the only robust way to capture browser downloads
(the alternative, a system-wide TLS-MITM proxy, is invasive and breaks cert
pinning); IDM and JDownloader use a browser extension for the same reason.

## How it works

```
Browser download starts
  -> extension intercepts it (chrome.downloads.onCreated)
  -> POST http://127.0.0.1:8760/add  { url, cookie, referrer }  (X-Cascade-Token)
  -> Cascade app enqueues + downloads; the browser copy is cancelled
```

If the app is not running or no token is set, the browser download proceeds as
normal, so the extension is safe to leave installed.

**The app must be running for capture to work.** It stays resident: closing its
window only hides it, and it keeps running in the menu bar (with a download
icon). Use **Open Cascade** there to bring the window back, and **Quit** to
actually exit (which stops capture). If capture silently stops working, the
first thing to check is that the app is running (the extension's Options page
"Test connection" button confirms this).

## Setup (macOS, launch-on-demand)

1. Install the app and the native-messaging host, and register the host with
   every Chromium-family browser present (Chromium, Chrome, Brave, Edge,
   Vivaldi):

       scripts/install-macos.sh

   This builds to `~/Library/Application Support/cascade/bin/` and writes
   `com.cascade.host.json` into each browser's `NativeMessagingHosts` folder.
2. Load the extension in the browser you actually download with:
   `chrome://extensions` → **Developer mode** → **Load unpacked** →
   `browser/extension`.
3. Download anything. **You do not need to start the app**: when a download
   begins, the extension asks the browser to run the native host, which
   launches Cascade if it is not running, waits for it, and hands the download
   over. Pairing is automatic through that channel (the browser only lets the
   extension IDs listed in the host manifest invoke it), so there is no token
   to copy and no prompt to click.

If the extension was loaded from a path other than this checkout, its ID
differs from the default; pass it: `scripts/install-macos.sh <EXTENSION_ID>`
(shown on `chrome://extensions`).

Without the native host (e.g. a browser it wasn't registered with), capture
still works as long as the app is running: the extension asks the app to
connect and you click **Allow** once in the Cascade window (or Options →
**Pair with Cascade app**).

Note for custom profiles: a browser started with `--user-data-dir=<dir>` looks
for host manifests in `<dir>/NativeMessagingHosts/`, not the default location.

The app window's "Extension:" line is the quickest health check: it says
"not connected" until the extension is loaded in the browser and has paired.
The extension's Options page also shows the last capture event and why.

Downloads interrupted by a quit or crash are resumed automatically the next
time the app starts (their `.cascade` sidecar is picked up from the download
folder). Re-downloading a file that is already in progress reuses that job
rather than starting a duplicate.

## Security

- The endpoint binds to `127.0.0.1` only and requires the token, so other local
  apps or web pages cannot silently enqueue downloads.
- Cookies for the download's domain are read (so logged-in downloads work) and
  sent only to the local app, never elsewhere.

## Firefox

The manifest targets Chromium MV3 (service worker). Firefox needs
`background.scripts` instead of `service_worker` and a
`browser_specific_settings` block; the rest of the code is compatible. A Firefox
manifest variant is a follow-up.

## Safari

Safari requires a Safari Web Extension bundled in a signed macOS app (needs full
Xcode) and has a more limited downloads API. Not included yet.
