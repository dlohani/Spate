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

## Setup

1. Run the Cascade app. Its window shows the capture endpoint and a token.
2. Load the extension (Chromium: Chrome/Edge/Brave/Vivaldi):
   - Go to `chrome://extensions`, enable **Developer mode**.
   - **Load unpacked** and select `browser/extension`.
3. Click the extension's icon (or its Options), paste the **token** from the app
   window, keep "Capture browser downloads" checked, Save. Use **Test
   connection** to confirm the app is reachable.
4. Download anything in the browser: it appears in the Cascade window instead.

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
