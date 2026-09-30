# cascade

A segmented, resumable HTTP download engine in Go. It fetches a file over
multiple parallel byte-range connections, writing each range at its offset in a
single preallocated file, and persists per-segment progress so an interrupted
transfer resumes cleanly.

## What it does (and does not) do

cascade makes full use of the bandwidth your connection provides and defeats
**per-connection / server-side** throttling (a server that caps each TCP
connection): N connections aggregate up to what your link allows.

It does **not** evade an ISP's aggregate rate shaping or data cap. If your line
is shaped to X Mbps total, N connections still sum to X. There is no DPI evasion,
packet crafting, or tunneling here, by design.

## Status

Implemented (headless engine + CLI):

- HTTP, HTTPS, FTP and FTPS (explicit TLS) sources. FTP uses `SIZE`, `MDTM`
  and `REST`/`RETR` over passive data connections, so segmented multi-connection
  downloads and resume work as with HTTP ranges; credentials come from the URL
  (`ftp://user:pass@host/path`), else `-user`, else anonymous. Scheduled and
  recurring downloads accept any of these. (Browsers dropped FTP years ago, so
  FTP links are pasted into the app rather than captured from the browser.)
- Multi-connection segmented downloads with dynamic work-stealing.
- Resume, broken-download recovery (retry/backoff, `If-Range` revalidation).
- Speed limiter; SHA-256 verification; automatic filename + file-type detection.
- Auth (basic), custom headers, cookies, explicit/authenticated proxy, TLS-skip.
- URL expiry/refresh via a caller hook.
- Job manager: queue, priority, scheduled start, multiple downloads in parallel,
  per-job pause/resume.
- Post-download `.zip` extraction (with zip-slip protection).
- Wi-Fi-only and battery-aware gating (macOS provider; other OSes report
  unsupported).

Not implemented yet: desktop GUI; the browser extension with a floating download
button for non-DRM streaming media; native `.rar`/`.7z` extraction.

## Build

One front door, always from the working tree (uncommitted changes included),
version-stamped artifacts in `dist/`:

    ./build mac [--install]     Cascade-<v>.pkg, Cascade-<v>-macos.zip
    ./build windows             cascade-setup.exe, Cascade-Setup-<v>.exe (NSIS), zip
    ./build linux [--cli-only]  cascade_<v>_<arch>.deb (full on Linux; CLI-only elsewhere)
    ./build android             libcascade .aar + Cascade-<v>.apk (needs Android SDK)
    ./build ios                 Cascade-<v>.xcframework + unsigned iOS app
    ./build extension           Chrome/Firefox zips, Safari source and app
    ./build all                 everything this host can build
    ./build version | bump x.y.z | clean

`go vet` and the tests run first (`--no-test` skips). `VERSION` is stamped
into binaries, bundles and installers as `x.y.z`; artifact names add
`+<sha>` when the tree is ahead of the last tag and `.dirty` with uncommitted
changes, so a dev build is never mistaken for a release while installers keep
comparing plain `x.y.z`. Missing toolchains (mingw, makensis, Android SDK,
gomobile) are reported in one line and that piece is skipped.

Just the CLI: `go build -o cascade ./cmd/cascade` (Go 1.22+, standard library
only).

## Installers

| Platform | Build | Result |
|---|---|---|
| macOS | `scripts/package-macos.sh` | `dist/Cascade-<ver>.pkg`: per-user installer (Welcome → Install → Finish, no admin password). Installs `~/Applications/Cascade.app` plus the host, extension and helpers under `~/Library/Application Support/cascade`; postinstall registers the browser host, adds the login item, starts the app. `bin/uninstall` reverses it. |
| Windows | `scripts/package-windows.sh` | `dist/Cascade-Setup-<ver>.exe`: NSIS installer (Welcome → Directory → Install → Finish), per-user, registers the host in the registry, autostart, Add/Remove Programs entry, uninstaller. Silent: `/S`. `cascade-setup.exe` (from `scripts/build-windows.sh`) is the single-file dev equivalent. |
| Package managers | `packaging/homebrew/cascade.rb`, `packaging/winget/` | Homebrew cask and winget manifest templates; they need the installers published at a URL (GitHub release) first. |

Every installer and script is version-aware. `VERSION` is the single source
of truth: it is stamped into the Go binaries (`internal/version`, shown by
`/ping` and in Settings), into the app bundle (`CFBundleShortVersionString`)
and into the Windows Add/Remove Programs entry. On install:

- not installed: installs;
- same version installed: reinstalls (macOS Installer warns first, NSIS asks,
  the scripts say so); settings, the browser pairing and downloads are kept;
- older version installed: upgrades in place, stopping the running app first
  so the browser's native host cannot keep an old copy alive;
- newer version installed: refused with a message (macOS Installer, NSIS,
  `cascade-setup.exe`, and the install scripts alike). Override only
  deliberately: `CASCADE_FORCE=1` for the scripts, `--force` for
  `cascade-setup.exe`, or uninstall first.

Browsers: Chrome, Chromium, Brave, Vivaldi and Edge (one MV3 extension),
Firefox (same code, `manifest.firefox.json`; AMO-signed `.xpi` for permanent
installs) and Safari (`manifest.safari.json` wrapped by
`scripts/safari-extension.sh`; Safari has no downloads API, so capture there
is the right-click "Download with Cascade" and click interception of file
links). `scripts/package-extension.sh` builds all three; `browser/STORE.md`
has the details.

Browser extension, automatically: every installer detects the Chromium-family
browsers on the machine (Chrome, Chromium, Brave, Vivaldi, Edge) and Firefox
and registers the native host with each. Once the extension is published in the Chrome Web
Store (and Edge Add-ons for Edge), the installers also register the extension
itself, and each browser installs it from the store on its next start: silent
on Linux, one "Enable extension" click on Windows and macOS (browsers do not
allow silent installs of unpublished extensions, so until it is published the
one manual "Load unpacked" step remains). The switch is
`browser/extension/store-ids.env`; `scripts/package-extension.sh` builds the
store upload and `browser/STORE.md` walks through publishing.

There is exactly one copy of the app per machine: `~/Applications/Cascade.app`
on macOS, `%LOCALAPPDATA%\Cascade\bin` on Windows, `~/.local/share/cascade/bin`
on Linux. Opening the app while it is already running (Spotlight, Finder,
Dock, Start menu) raises the running instance's window instead of starting a
second one.

Both installers are unsigned (Gatekeeper: right-click → Open; SmartScreen:
"Run anyway"). Signing/notarization is a release step: set
`CASCADE_SIGN_IDENTITY` for macOS. One manual step remains everywhere: loading
the browser extension (Chrome only allows silent installs from the Web Store);
the installers' final page shows the folder.

## Developer install on macOS (no installer)

    scripts/flutter-macos.sh build   # Flutter UI with the Go core bundled
    scripts/install-macos.sh         # host, app, browser registration, login item

Installs the resident app as `~/Applications/Cascade.app` and the browser
native-messaging host into `~/Library/Application Support/cascade/bin/`,
registers the host with the Chromium-family browsers on the machine, and adds
a per-user LaunchAgent so Cascade starts **hidden at login** (menu-bar icon
only; `CASCADE_NO_LOGIN=1` skips it, `launchctl bootout
gui/$UID/dev.d3xt3r.cascade` removes it). Re-running it upgrades or
reinstalls; a downgrade is refused unless `CASCADE_FORCE=1`. Then load
`browser/extension` in the browser (`chrome://extensions` → Load unpacked). From
then on a download started in the browser launches Cascade if it isn't running
and is handed to it, with no copy/paste and no token setup. Closing the window
hides it; quit from the menu-bar icon. The core refuses to start a second
instance, so login item, native host and manual launches never stack up. See
`browser/README.md`.

## Install on Linux

Debian/Ubuntu package (run on the Linux machine; needs Go, gcc and Flutter):

    scripts/package-linux.sh          # -> dist/cascade_<ver>_<arch>.deb
    sudo apt install ./dist/cascade_<ver>_<arch>.deb

The package installs `/usr/bin/cascade` (CLI), the app under
`/usr/lib/cascade/`, the extension under `/usr/share/cascade/extension`, an
application-menu entry, autostart at login (hidden, tray only) and icons.
Its postinst registers the native host system-wide for Chrome, Chromium and
Edge; `cascade-register [ID]` adds per-user registration for Brave, Vivaldi,
snap Chromium, or another extension ID. `apt install` of the same version
reinstalls, a newer version upgrades (running instances are stopped first),
an older one is refused unless `CASCADE_FORCE=1`; settings and downloads are
kept. `apt remove cascade` reverses it.

On a non-Linux host (or with `--cli-only`) the same script produces
`cascade-cli_<ver>_<arch>.deb`: the command-line downloader and native host
only, pure Go, for servers and containers.

Per-user developer install without a package (after `flutter build linux`):

    scripts/install-linux.sh

It builds `libcascade.so` and the host, installs the Flutter bundle under
`~/.local/share/cascade/bin/`, registers the host for the user's browsers and
adds menu and autostart entries. Either way a tray icon needs a desktop with
AppIndicator support (KDE, or GNOME with the extension); without one the app
still works from its window. Prepared and syntax-checked here; the desktop
package still needs a run on a Linux machine.

## Cross-platform

One Go core exports to all five targets through a stable binding boundary; each
platform adds only a thin native shell. See `docs/architecture.md` for the full
design (layers, the media-capture analysis for TikTok/IG/YouTube, per-OS gating).

| Target | Artifact | Command |
|---|---|---|
| Desktop CLI | `dist/cascade` | `make cli` |
| Desktop / Flutter FFI | `libcascade.{dylib,so}` / `cascade.dll` + header | `make lib` |
| Android | `cascade.aar` | `make android` (needs Android SDK/NDK) |
| iOS | `Cascade.xcframework` | `make ios` (needs Xcode) |

- `export/cshared` is the C ABI (for Flutter `dart:ffi` and native C). It
  exposes the whole app service (`internal/service`: engine, queue, browser
  capture endpoint, pairing, orphan resume), so UI shells stay thin.
- `mobile/` is the gomobile facade (native Kotlin/Swift shells).
- Both expose the same JSON status schema.

### Flutter app (all platforms, one UI)

`apps/flutter` is the unified Material 3 frontend over the C ABI. Its FFI test
drives the real `libcascade` (`cd apps/flutter && flutter test`). Building the
macOS app needs full Xcode and CocoaPods: `scripts/flutter-macos.sh run` (dev)
or `scripts/flutter-macos.sh build` (bundles `libcascade.dylib` into the app).
`apps/macapp` (Fyne) remains as the lightweight fallback shell.

## Use

    cascade [flags] <url> [url...]

Flags:

    -o <path>          output file (default: derived from URL; single URL only)
    -n <int>           parallel connections (default 8)
    -resume            resume from an existing .cascade sidecar if present
    -limit <size>      aggregate rate limit, e.g. 2M or 500K (default: unlimited)
    -sha256 <hex>      expected SHA-256 to verify on completion
    -retries <int>     per-segment retry attempts (default 5)
    -H "Key: Value"    extra request header (repeatable)
    -cookie <value>    Cookie header value
    -user user:pass    HTTP basic auth
    -proxy <url>       proxy URL, e.g. http://user:pass@host:port
    -insecure          skip TLS certificate verification
    -extract <dir>     after download, extract a .zip into <dir>
    -max-concurrent N  simultaneous downloads when several URLs are given (default 2)
    -wifi-only         only download while on Wi-Fi (macOS)
    -battery-min N     only download when battery >= N%% or on AC power (macOS)

Examples:

    cascade https://example.com/file.bin -o file.bin -n 8 -sha256 <hex>
    # interrupt with Ctrl-C, then resume:
    cascade https://example.com/file.bin -o file.bin -resume
    # download several files, two at a time:
    cascade -max-concurrent 2 https://host/a.bin https://host/b.bin https://host/c.bin

Exit codes: 0 success, 1 error, 2 usage, 130 interrupted (resumable).

## Organization and scheduling

Downloads are filed and timed by rules, so you set them once and stop
thinking about them. Everything lives in one document, `settings.json`, in the
per-user config folder (`~/Library/Application Support/cascade` on macOS,
`%AppData%\cascade` on Windows, `~/.config/cascade` on Linux; override with
`CASCADE_SETTINGS=<path>`). The Flutter app edits it under Settings; any
front-end can read/write it through `CascadeSettingsJSON`/`CascadeSettingsApply`.

- Destination rules: a base folder, optional category folders by extension
  (editable defaults), and per-site folders (`host` matches the host and its
  subdomains). Resolution order: site rule > category > base. Browser hand-offs
  and pasted links use the same rules unless a folder is given explicitly.
- Scheduled start: any download can be given a start time ("Schedule" in the
  add bar, `startAt` in the JSON spec); it sits in the queue as Scheduled until
  then, or until "Start now".
- Download window: only start queued downloads inside a time window (e.g.
  22:00 to 06:00 on weekdays). Running downloads finish normally. Windows may
  span midnight and can be restricted to weekdays.
- Speed limit with time windows: a default cap plus per-window caps, so the
  limit can be 500 KB/s during work hours and unlimited at night. The cap is
  shared by every running download and changes on schedule.
- Recurring downloads: re-fetch a link hourly, daily or weekly (a report, a
  nightly build); the scheduler enqueues it when due and advances `nextAt`.

## How resume works

Progress is tracked in a sidecar `<output>.cascade` (JSON) holding the URL, total
size, a validator (ETag or Last-Modified), and each segment's byte offset. On
resume, cascade re-probes and sends `If-Range`; if the validator changed (the
upstream file changed), it discards the partial data and restarts rather than
producing a corrupt merge.

## Test

    go test ./...

Tests use `net/http/httptest` and need no network: segmentation math, multi-
connection happy path with checksum, resume-after-failure, validator-changed
restart, no-range single-connection fallback, and cancellation leaving
resumable state.
