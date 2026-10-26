# Spate browser capture

Automatically send downloads started in the browser to the Spate app, so you
never copy/paste a URL. This is the only robust way to capture browser downloads
(the alternative, a system-wide TLS-MITM proxy, is invasive and breaks cert
pinning); IDM and JDownloader use a browser extension for the same reason.

## What happens when a download starts

The extension's mode (Options) decides:

- **Ask** (default): a small popup offers **Download with Spate** or **Use the
  browser**, with "Remember my choice for this site". The browser's own
  download keeps running while the popup is open, so choosing the browser (or
  just closing the popup) loses nothing; only choosing Spate hands it off.
- **Always**: hand off without asking.
- **Never**: leave everything to the browser.

Remembered per-site rules override Ask; clear them in Options.

Before accepting a hand-off, the app checks that it can actually fetch the URL
with the same cookies, referrer and User-Agent the browser had. If the server
refuses (typically 403 on a session-bound or POST-only link from a file-sharing
site), the app declines, the extension leaves the browser's download running,
and the Options page shows "app refused (...)". Those downloads stay in the
browser by design rather than being lost.

**Hosts that allow one connection per IP** (free tiers of file-sharing sites
such as send.now): while the browser's own download is streaming, any second
connection is answered 503 (the site shows it as a "continue" page). So when
you choose Spate, the extension first cancels the browser's stream, waits a
moment for the host to release the slot, then hands off; if the app cannot
fetch the link after all, the extension restarts the download in the browser
(the generated links are time-limited, not single-use). The engine also adapts:
if a host refuses extra segment connections (503/429), it drops to however many
are actually streaming (down to one) instead of colliding.

**Incognito:** enable **Allow in Incognito** for the extension on
`chrome://extensions`, otherwise incognito downloads are invisible to it.
Incognito windows have their own cookie store; the extension reads the session
from the correct store so session-bound hosts (file-sharing sites) get the same
cookies the browser had.

**Links that can only stay in the browser:** some hosts issue one-time download
tokens (the browser's own request consumes them) or start the download from a
POST. No second client can re-fetch those, so the app refuses and the browser
completes the download; you'll see "app refused (...)" in Options.

The app's queue, with each job's state and last error, is available at
`GET /jobs` (token-guarded) and is what the app window shows.

## How it works

```
Browser download starts
  -> extension intercepts it (chrome.downloads.onCreated)
  -> POST http://127.0.0.1:8760/add  { url, cookie, referrer }  (X-Spate-Token)
  -> Spate app enqueues + downloads; the browser copy is cancelled
```

If the app is not running or no token is set, the browser download proceeds as
normal, so the extension is safe to leave installed.

**The app must be running for capture to work.** It stays resident: closing its
window only hides it, and it keeps running in the menu bar (with a download
icon). Use **Open Spate** there to bring the window back, and **Quit** to
actually exit (which stops capture). If capture silently stops working, the
first thing to check is that the app is running (the extension's Options page
"Test connection" button confirms this).

## Setup (macOS, launch-on-demand)

1. Install the app and the native-messaging host, and register the host with
   every Chromium-family browser present (Chromium, Chrome, Brave, Edge,
   Vivaldi):

       scripts/install-macos.sh

   This builds to `~/Library/Application Support/spate/bin/` and writes
   `com.amlabs.spate.host.json` into each browser's `NativeMessagingHosts` folder.
2. Load the extension in the browser you actually download with:
   `chrome://extensions` → **Developer mode** → **Load unpacked** →
   `browser/extension`.
3. Download anything. **You do not need to start the app**: when a download
   begins, the extension asks the browser to run the native host, which
   launches Spate if it is not running, waits for it, and hands the download
   over. Pairing is automatic through that channel (the browser only lets the
   extension IDs listed in the host manifest invoke it), so there is no token
   to copy and no prompt to click.

If the extension was loaded from a path other than this checkout, its ID
differs from the default; pass it: `scripts/install-macos.sh <EXTENSION_ID>`
(shown on `chrome://extensions`).

Without the native host (e.g. a browser it wasn't registered with), capture
still works as long as the app is running: the extension asks the app to
connect and you click **Allow** once in the Spate window (or Options →
**Pair with Spate app**).

Note for custom profiles: a browser started with `--user-data-dir=<dir>` looks
for host manifests in `<dir>/NativeMessagingHosts/`, not the default location.

The app window's "Extension:" line is the quickest health check: it says
"not connected" until the extension is loaded in the browser and has paired.
The extension's Options page also shows the last capture event and why.

Downloads interrupted by a quit or crash are resumed automatically the next
time the app starts (their `.spate` sidecar is picked up from the download
folder). Re-downloading a file that is already in progress reuses that job
rather than starting a duplicate.

## Security

- The endpoint binds to `127.0.0.1` only and requires the token, so other local
  apps or web pages cannot silently enqueue downloads.
- Cookies for the download's domain are read (so logged-in downloads work) and
  sent only to the local app, never elsewhere.

## Firefox

`manifest.firefox.json` is the same code as an MV2 event page
(`background.scripts`, `browser_action`, a fixed add-on ID
`spate@amlabs.dev` so the native host manifest can allow it). The installers
register the host for Firefox too. `scripts/package-extension.sh` builds
`spate-extension-firefox-<ver>.zip`; permanent installs need the AMO-signed
`.xpi` (see `STORE.md`), temporary ones load from `about:debugging`.

## Safari

`manifest.safari.json` plus `scripts/safari-extension.sh` (runs Xcode's
`safari-web-extension-converter`) produce "Spate for Safari.app" with the
extension inside; `./build extension` on a Mac with Xcode does this. Safari
has no downloads API, so capture there is the right-click "Download with
Spate" menu and `capture.js` intercepting clicks on file links.
