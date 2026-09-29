# Publishing the extension (one-time), and what it unlocks

Browsers do not let an installer drop an extension in silently. What they do
allow is for an installer to *register* an extension that lives in a store;
the browser then installs it from the store on its next start (Linux: silent;
Windows and macOS: Chrome shows a one-click "Enable extension" bubble). This
is how IDM, JDownloader and antivirus vendors ship their browser pieces.

Every Cascade installer already contains that registration code. It is
switched on by `browser/extension/store-ids.env`:

    CHROME_WEBSTORE_ID=<id from the Chrome Web Store>   # Chrome, Brave, Vivaldi, Chromium
    EDGE_ADDONS_ID=<id from Microsoft Partner Center>    # Edge (separate store)

Until those are set, installers print the "Load unpacked" instructions.

## Steps

1. `scripts/package-extension.sh` -> `dist/cascade-extension-<version>.zip`
   (sets the manifest version from `VERSION`; each upload needs a new one).
2. Chrome Web Store: https://chrome.google.com/webstore/devconsole
   (developer account, one-time fee). New item -> upload the zip -> fill the
   listing (below) -> submit. Review takes from hours to a few days. The item
   ID is the 32-letter string in the item's URL.
3. Edge Add-ons (optional): https://partner.microsoft.com/dashboard, same zip.
4. Put the IDs in `store-ids.env`, bump `VERSION`, rebuild the installers.
   From then on: install Cascade -> restart the browser -> the extension is
   there (Windows/macOS: click "Enable").

Later versions: upload a new zip; browsers update from the store on their own,
nothing changes in the installers.

## Listing text

- Name: Cascade Download Capture
- Summary: Sends downloads from the browser to the Cascade download manager.
- Description: When a download starts, Cascade offers to take it over (once
  per site, remembered) and downloads it with several connections, resume and
  scheduling. Requires the Cascade desktop app.
- Category: Productivity / Tools. Language: English.
- Privacy: no data leaves the machine. The extension talks only to the Cascade
  app on 127.0.0.1 (loopback) and passes the download URL, referrer and the
  cookies of that site so the app can fetch the same file. No analytics.
- Permission justifications (the store asks for each):
  - downloads: to notice a download starting and cancel it once handed off.
  - cookies: session-bound links need the site's cookies to be fetchable.
  - storage: the per-site "remember my choice" rules and the mode setting.
  - alarms: heartbeat to the app while the service worker is asleep.
  - nativeMessaging: to launch the Cascade app when it is not running.
  - host_permissions `<all_urls>`: downloads can start on any site; the
    extension reads the cookies for the download's own host only.
- Assets: 128x128 icon (`browser/extension/icons/128.png`), at least one
  1280x800 screenshot of the choice popup, and the 440x280 small tile.

## Firefox and Safari

Not covered yet: Firefox needs a WebExtension variant (mostly the same code)
signed by addons.mozilla.org; Safari needs an App Extension built in Xcode.
Both are follow-ups.
