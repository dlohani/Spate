# Spate help

Spate is a download manager for macOS, Linux and Windows. It takes downloads
over from your browser, fetches them over several connections at once,
resumes anything that breaks, and files and schedules them by rules you set
once. This page is what the app's Help menu opens.

## Getting started

1. **Install** the package for your platform (`Spate-<version>.pkg` on macOS,
   `Spate-Setup-<version>.exe` on Windows, `spate_<version>_<arch>.deb` on
   Debian and Ubuntu). Spate starts hidden in the menu bar or tray at login
   and stays running; closing its window only hides it.
2. **Load the browser extension.** Until it is published in the stores:
   Chrome, Brave, Edge or Vivaldi → `chrome://extensions` → Developer mode →
   Load unpacked → the `extension` folder the installer printed. Firefox →
   `about:debugging` → Load Temporary Add-on. The installer registered the
   native host, so the extension pairs with the app by itself; if it ever
   asks, click **Allow** in the Spate window.
3. **Download something.** Either start a download in the browser and choose
   **Download with Spate** in the popup, or paste links into the field at the
   top of the window.

## Adding downloads

- **Paste links**: one or several, separated by spaces or line breaks. Press
  Return or click Download. Cmd-V (Ctrl-V on Windows and Linux) anywhere in
  the window pastes and adds whatever links are on the clipboard.
- **Drop links**: drag links, or a text file of links, onto the window.
- **From the browser**: every download the browser starts shows the Spate
  popup (Ask), or is handed over automatically (Always), or left alone
  (Never); set the mode in the extension's options, and remember a choice per
  site from the popup. Right-click any link for **Download with Spate**.
- **Where it goes**: the folder button inside the field picks a folder for
  the next links; otherwise the folder rules in Settings decide (per-site
  rule, then category, then the base folder).
- **When it starts**: the clock button offers tonight at 22:00, tomorrow at
  09:00, when the download window opens, or a custom time. The chosen time
  stays selected for the next links until you clear it.

## The list

Rows show what is happening first: downloading, queued (with position),
scheduled (with the start time), paused, then a collapsible **Finished**
group that keeps the last 200 downloads for 30 days.

- Click a row to select it; Shift-click and Cmd-click (Ctrl-click) extend
  the selection. Arrow keys move, **Space** pauses or resumes, **Delete**
  removes (a running download asks first), **Cmd-A** selects everything,
  **Escape** clears.
- Right-click a row, or use its **...** button, for Copy link, Pause, Resume,
  Schedule, Open, Show in Finder, Retry, Cancel and Remove. With several rows
  selected the action applies to all of them.
- A failed row shows its reason; click it to read the full message and
  Retry. Retry re-queues the same link into the same folder and continues
  from whatever was already saved.
- The header shows total speed with a 30-second sparkline, how many are
  downloading and queued, and the speed limit in force. Its **...** menu has
  Pause all, Resume all and Clear finished.

## Settings

Changes apply as you make them; a refused value (an impossible time, more
than 32 connections) reverts and says why.

- **Appearance**: system, light or dark; an accent colour for controls.
- **Behaviour**: where Spate shows itself (menu bar and Dock, menu bar only,
  Dock only); minimise to the menu bar; the menu-bar icon style; pulse the
  icon while downloading; notifications when a download finishes.
- **Downloads folder**: the base folder (Browse opens the system picker) and
  how many downloads run at the same time.
- **Organize by category**: Video, Audio, Documents, Archives and so on by
  file extension, under the base folder. Edit or add categories.
- **Per-site folders**: downloads from a site and its subdomains go to a
  folder of your choice; site rules win over categories.
- **Speed limit**: a default cap (presets or a custom value) and time windows
  that override it, for instance slower during work hours and unlimited at
  night.
- **Download window**: only start queued downloads inside a time window;
  running ones always finish.
- **Recurring downloads**: re-fetch a link hourly, daily or weekly.
- **Advanced**: connections per download (8 by default; Spate drops to what a
  server allows by itself).
- **About**: version, licence, Buy me a coffee, and the log file.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| Return (in the field) | Add the links in the field |
| Cmd-V / Ctrl-V (anywhere) | Paste links and add them |
| Cmd-, / Ctrl-, | Settings |
| Up / Down | Move the selection |
| Shift-click, Cmd-click | Extend or toggle the selection |
| Space | Pause or resume the selection |
| Delete / Backspace | Remove the selection |
| Cmd-A | Select every row |
| Escape | Clear the selection |
| Cmd-? | This help |

## The menu bar / tray icon

The icon shows the count and overall percentage while downloading
("2 · 43%") and pulses gently. Its menu has Open Spate, Pause all, Resume all
and Quit. Quitting stops downloads and browser capture; the login item starts
Spate again at the next login.

## Troubleshooting

- **Capture stopped working.** Make sure Spate is running (the icon is in the
  menu bar or tray). The extension's options page has **Test connection** and
  shows the last capture event and why. If the browser was updated, reload
  the extension once.
- **"App refused" on a download.** The link needs the browser's own session
  (a one-time token or a form post) and cannot be fetched a second time. The
  download stays in the browser by design; nothing is lost.
- **A download fails repeatedly.** Click the row to read the error. Servers
  that limit connections per address are handled automatically; a changed
  file on the server restarts the download from zero rather than merging
  stale data.
- **Where are my settings and logs?** `~/Library/Application Support/spate`
  on macOS, `~/.config/spate` on Linux, `%AppData%\spate` on Windows:
  `settings.json`, `queue.json`, the pairing `token`, `ui.json` and
  `spate.log` (rotated at 5 MB). Settings → About → **Show log file** opens
  the folder.
- **Partial files.** A download in progress lives in `<name>.part` with a
  `<name>.spate` sidecar beside it; both disappear when it completes.
  Removing a row deletes its partial; finished files are never deleted.

## Command line

The `spate` command downloads without the app: `spate <url> [-o out] [-n 8]
[-resume] [-limit 2M] [-sha256 <hex>]`, with proxies, headers, cookies, FTP
and FTPS, and `-v` for the engine log. See the README for the full flag list.

## Reporting a problem

Open an issue on the project's GitHub page (Help → Report a problem) with the
version from Settings → About, what you did, and the relevant lines from
`spate.log`. Pairing tokens and cookies are never written to the log.
