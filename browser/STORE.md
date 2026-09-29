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

## Firefox

Same code, `manifest.firefox.json` (MV2 event page, fixed add-on ID
`cascade@d3xt3r.dev`). `scripts/package-extension.sh` produces
`dist/cascade-extension-firefox-<version>.zip` and the unpacked
`dist/firefox-extension/` (about:debugging -> This Firefox -> Load Temporary
Add-on -> manifest.json; lasts until Firefox restarts).

Permanent installs need the add-on signed by addons.mozilla.org, which is
free and automated for unlisted (self-distributed) add-ons:

1. https://addons.mozilla.org/developers/ -> Submit a New Add-on -> "On your
   own" (unlisted) -> upload the zip. Signing usually completes in minutes.
2. Download the signed `.xpi`. Users install it by opening it in Firefox
   (about:addons -> gear -> Install Add-on From File). Every installer
   already registers the native host for Firefox, so launch-on-demand and
   pairing work the same as in Chrome.
3. Optional, for hands-off installs: ship the signed `.xpi` in the installers
   and register it through Firefox's `ExtensionSettings` policy
   (`install_url` + `installation_mode: force_installed`; Windows HKCU
   policy key, Linux `/etc/firefox/policies/policies.json`, macOS
   `org.mozilla.firefox` defaults). Not wired yet: it needs the signed file
   first.

Later versions: upload a new zip to AMO for a new signed `.xpi`; Firefox
updates self-distributed add-ons only if the manifest names an
`update_url`, so either host an updates.json or ship the new `.xpi` with the
next installer.

## Safari

Safari has no `downloads` API, so a download cannot be intercepted after it
starts. The Safari build (`manifest.safari.json`) therefore captures
through the right-click "Download with Cascade" on links and through
`capture.js`, which intercepts clicks on links that are clearly files
(download attribute, or archive/installer/media/document extensions) and
hands them to the app before Safari navigates; if the app is not running or
refuses, the click proceeds normally.

Safari extensions ship inside a macOS app: `scripts/safari-extension.sh`
wraps the extension with Xcode's converter, builds "Cascade for Safari.app"
ad hoc signed and installs it to ~/Applications. Enable it in Safari ->
Settings -> Extensions; for an ad hoc build Safari also needs Develop ->
"Allow Unsigned Extensions" (Develop menu: Settings -> Advanced). Shipping
it to other Macs needs a Developer ID signature and notarization
(`CASCADE_SIGN_IDENTITY`), or the Mac App Store.
