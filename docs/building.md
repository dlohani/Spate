# Building and shipping Spate

Developer reference moved out of the README: how the engine, app, extension and installers are built, installed by hand, tested and measured. The product itself is described in [help.md](help.md); the layering in [architecture.md](architecture.md); the delivery plan in [delivery.md](delivery.md).

## Build

One front door, always from the working tree (uncommitted changes included),
version-stamped artifacts in `dist/`:

    ./build mac [--install]     Spate-<v>.pkg, Spate-<v>-macos.zip
    ./build windows             spate-setup.exe, Spate-Setup-<v>.exe (NSIS), zip
    ./build linux [--cli-only]  spate_<v>_<arch>.deb (full on Linux; CLI-only elsewhere)
    ./build android             libspate .aar + Spate-<v>.apk (needs Android SDK)
    ./build ios                 Spate-<v>.xcframework + unsigned iOS app
    ./build extension           Chrome/Firefox zips, Safari source and app
    ./build all                 everything this host can build
    ./build version | bump x.y.z | clean

`go vet` and the tests run first (`--no-test` skips). `VERSION` is stamped
into binaries, bundles and installers as `x.y.z`; artifact names add
`+<sha>` when the tree is ahead of the last tag and `.dirty` with uncommitted
changes, so a dev build is never mistaken for a release while installers keep
comparing plain `x.y.z`. Missing toolchains (mingw, makensis, Android SDK,
gomobile) are reported in one line and that piece is skipped.

Two things are never skipped silently. A Windows build without the Flutter
UI at `dist/windows-amd64/spate_app` fails; set `SPATE_ALLOW_NO_UI=1`
for a CLI-only artifact, which is then named `...-cli-only.zip` and whose
setup refuses to install unless run with `--no-ui`. And `./build release
<target...>` refuses unless the tree is clean and HEAD is on a tag, so a
release-labelled artifact always comes from a known commit. Script tests:
`scripts/test/run.sh`.

Release builds are obfuscated (Go core via garble, Dart names, minimal C
exports): `./build release` turns on `SPATE_OBFUSCATE=1` and needs
`garble`; set the variable yourself to try it on a dev build. See
[Release obfuscation](docs/delivery.md#release-obfuscation) for what it does,
the size cost, and the symbol maps to keep.

Just the CLI: `go build -o spate ./cmd/spate` (Go 1.22+, standard library
only).

## Installers

| Platform | Build | Result |
|---|---|---|
| macOS | `scripts/package-macos.sh` | `dist/Spate-<ver>.pkg`: per-user installer (Welcome → Install → Finish, no admin password). Installs `~/Applications/Spate.app` plus the host, extension and helpers under `~/Library/Application Support/spate`; postinstall registers the browser host, adds the login item, starts the app. `bin/uninstall` reverses it. |
| Windows | `scripts/package-windows.sh` | `dist/Spate-Setup-<ver>.exe`: NSIS installer (Welcome → Directory → Install → Finish), per-user, registers the host in the registry, autostart, Add/Remove Programs entry, uninstaller. Silent: `/S`. `spate-setup.exe` (from `scripts/build-windows.sh`) is the single-file dev equivalent. |
| Package managers | `packaging/homebrew/spate.rb`, `packaging/winget/` | Homebrew cask and winget manifest templates; they need the installers published at a URL (GitHub release) first. |

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
  `spate-setup.exe`, and the install scripts alike). Override only
  deliberately: `SPATE_FORCE=1` for the scripts, `--force` for
  `spate-setup.exe`, or uninstall first.

Browsers: Chrome, Chromium, Brave, Vivaldi and Edge (one MV3 extension),
Firefox (same code, `manifest.firefox.json`; AMO-signed `.xpi` for permanent
installs) and Safari (`manifest.safari.json` wrapped by
`scripts/safari-extension.sh`; Safari has no downloads API, so capture there
is the right-click "Download with Spate" and click interception of file
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

Settings has a "Show Spate in" choice: menu bar and Dock (default), menu bar
only (no Dock or taskbar entry; the window opens from the icon), or Dock only
(no tray icon; on macOS the Dock icon reopens the window, on Windows and
Linux closing the window quits since nothing is left to reopen it from).

There is exactly one copy of the app per machine: `~/Applications/Spate.app`
on macOS, `%LOCALAPPDATA%\Spate\bin` on Windows, `~/.local/share/spate/bin`
on Linux. Opening the app while it is already running (Spotlight, Finder,
Dock, Start menu) raises the running instance's window instead of starting a
second one.

Both installers are unsigned (Gatekeeper: right-click → Open; SmartScreen:
"Run anyway"). Signing/notarization is a release step: set
`SPATE_SIGN_IDENTITY` for macOS. One manual step remains everywhere: loading
the browser extension (Chrome only allows silent installs from the Web Store);
the installers' final page shows the folder.

## Developer install on macOS (no installer)

    scripts/flutter-macos.sh build   # Flutter UI with the Go core bundled
    scripts/install-macos.sh         # host, app, browser registration, login item

Installs the resident app as `~/Applications/Spate.app` and the browser
native-messaging host into `~/Library/Application Support/spate/bin/`,
registers the host with the Chromium-family browsers on the machine, and adds
a per-user LaunchAgent so Spate starts **hidden at login** (menu-bar icon
only; `SPATE_NO_LOGIN=1` skips it, `launchctl bootout
gui/$UID/com.amlabs.spate` removes it). Re-running it upgrades or
reinstalls; a downgrade is refused unless `SPATE_FORCE=1`. Then load
`browser/extension` in the browser (`chrome://extensions` → Load unpacked). From
then on a download started in the browser launches Spate if it isn't running
and is handed to it, with no copy/paste and no token setup. Closing the window
hides it; quit from the menu-bar icon. The core refuses to start a second
instance, so login item, native host and manual launches never stack up. See
`browser/README.md`.

## Install on Linux

Debian/Ubuntu package (run on the Linux machine; needs Go, gcc and Flutter):

    scripts/package-linux.sh          # -> dist/spate_<ver>_<arch>.deb
    sudo apt install ./dist/spate_<ver>_<arch>.deb

The package installs `/usr/bin/spate` (CLI), the app under
`/usr/lib/spate/`, the extension under `/usr/share/spate/extension`, an
application-menu entry, autostart at login (hidden, tray only) and icons.
Its postinst registers the native host system-wide for Chrome, Chromium and
Edge; `spate-register [ID]` adds per-user registration for Brave, Vivaldi,
snap Chromium, or another extension ID. `apt install` of the same version
reinstalls, a newer version upgrades (running instances are stopped first),
an older one is refused unless `SPATE_FORCE=1`; settings and downloads are
kept. `apt remove spate` reverses it.

On a non-Linux host (or with `--cli-only`) the same script produces
`spate-cli_<ver>_<arch>.deb`: the command-line downloader and native host
only, pure Go, for servers and containers.

Per-user developer install without a package (after `flutter build linux`):

    scripts/install-linux.sh

It builds `libspate.so` and the host, installs the Flutter bundle under
`~/.local/share/spate/bin/`, registers the host for the user's browsers and
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
| Desktop CLI | `dist/spate` | `make cli` |
| Desktop / Flutter FFI | `libspate.{dylib,so}` / `spate.dll` + header | `make lib` |
| Android | `spate.aar` | `make android` (needs Android SDK/NDK) |
| iOS | `Spate.xcframework` | `make ios` (needs Xcode) |

- `export/cshared` is the C ABI (for Flutter `dart:ffi` and native C). It
  exposes the whole app service (`internal/service`: engine, queue, browser
  capture endpoint, pairing, orphan resume), so UI shells stay thin.
- `mobile/` is the gomobile facade (native Kotlin/Swift shells).
- Both expose the same JSON status schema.

### Flutter app (all platforms, one UI)

`apps/flutter` is the unified Material 3 frontend over the C ABI. Its FFI test
drives the real `libspate` (`cd apps/flutter && flutter test`). Building the
macOS app needs full Xcode and CocoaPods: `scripts/flutter-macos.sh run` (dev)
or `scripts/flutter-macos.sh build` (bundles `libspate.dylib` into the app).
It is the only UI; the Go core has no UI code of its own.

## Use

    spate [flags] <url> [url...]

Flags:

    -o <path>          output file (default: derived from URL; single URL only)
    -n <int>           parallel connections (default 8)
    -resume            resume from an existing .spate sidecar if present
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
    -wifi-only         only download while on Wi-Fi (macOS, Linux)
    -battery-min N     only download when battery >= N% or on AC power (macOS, Linux)
    -v                 log engine decisions (retries, resume, gating) to stderr
    -wbuf <size>       write buffer per connection (default 512K; tuning)

Examples:

    spate https://example.com/file.bin -o file.bin -n 8 -sha256 <hex>
    # interrupt with Ctrl-C, then resume:
    spate https://example.com/file.bin -o file.bin -resume
    # download several files, two at a time:
    spate -max-concurrent 2 https://host/a.bin https://host/b.bin https://host/c.bin

Exit codes: 0 success, 1 error, 2 usage, 130 interrupted (resumable).

## Organization and scheduling

Downloads are filed and timed by rules, so you set them once and stop
thinking about them. Everything lives in one document, `settings.json`, in the
per-user config folder (`~/Library/Application Support/spate` on macOS,
`%AppData%\spate` on Windows, `~/.config/spate` on Linux; override with
`SPATE_SETTINGS=<path>`). The Flutter app edits it under Settings; any
front-end can read/write it through `SpateSettingsJSON`/`SpateSettingsApply`.

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

While a download runs its data lives in `<output>.part` (preallocated to the
full size) and progress is tracked in a sidecar `<output>.spate` (JSON)
holding the URL, total size, a validator (ETag or Last-Modified), and each
segment's byte offset. On completion the `.part` is renamed to `<output>`,
never over an existing file (`name (1).ext` is used instead). On resume,
spate re-probes and sends `If-Range`; if the validator changed (the upstream
file changed), it discards the partial data and restarts rather than producing
a corrupt merge. A partial from before `.part` naming (data at `<output>` with
a sidecar beside it) is adopted on the next resume.

The app also keeps `queue.json` beside `settings.json`: every pending, paused
and running job with its priority, schedule and the cookies and headers a
browser hand-off carried, so a restart brings the queue back exactly, and
session-bound downloads still resume. Sidecars not in the queue (CLI downloads
in the download folder) are picked up too.

## Footprint

Body reads arrive in small, unaligned pieces; the engine coalesces them per
connection into 512 KiB aligned writes and, on macOS, bypasses the page cache
(`F_NOCACHE`; `SPATE_PAGE_CACHE=1` restores the old behaviour) so a
multi-GiB download neither burns kernel CPU nor evicts the user's working set.
On Linux the pages are dropped once the file is flushed (`posix_fadvise`).
Measured on APFS, Apple M4, against a loopback server (26 October 2026):

| Workload | Core peak RSS | Kernel CPU | Wall |
|---|---|---|---|
| 4 GiB, 8 connections, before | 19 MB | 7.5 s | 6.7 s |
| 4 GiB, 8 connections, after | 24 MB | 1.0 s | 2.5 s |
| 3 x 2 GiB concurrently, 8 each, after | 50 MB | 1.9 s | 2.3 s |
| Resident app, hidden, idle | 75 to 80 MB | about 0.1% of a core | |
| Resident app, hidden, 3 downloads | about 110 MB | | |
| Resident app, window shown, 3 downloads | about 215 MB while the bars animate, 115 MB after | | |

The hidden app does not rebuild or rasterise its window for progress ticks;
only the tray summary updates. The shown-and-downloading figure is Flutter's
renderer animating the progress bars at the display refresh rate.

On capped links (simulated at the server: 256 KB/s per connection, 40 ms
latency) 8 connections deliver 2 MB/s and 16 deliver 4 MB/s, at about 1% of a
core; a 2 MiB file over four 32 KB/s connections takes 16 s (256 KiB minimum
segment, so every connection gets work); a link that cuts 30% of range
responses midway still completes with the checksum verified.

## Logs

The core writes `spate.log` beside `settings.json` (rotated to `spate.log.1`
past 5 MiB): start and stop, every job state change with the reason, hand-offs
accepted or refused and why, resume decisions, gate closures and connection
reductions. The CLI is silent unless run with `-v`, which logs the same to
stderr. When something "silently stops working", read this file first.

## Test

    go test ./...

Tests use `net/http/httptest` and need no network: segmentation math, multi-
connection happy path with checksum, resume-after-failure, validator-changed
restart, no-range single-connection fallback, and cancellation leaving
resumable state.

## Releasing

Installers are never committed; they are attached to a GitHub Release by
CI. A release is cut from `main` like this:

    ./build bump 0.5.0            # VERSION, pubspec, extension manifests, cask, winget
    git commit -am "Release 0.5.0"
    git tag v0.5.0 && git push origin main v0.5.0

The tag push runs the build matrix on macOS, Ubuntu and Windows runners,
then the `release` job checks that the tag matches `VERSION`, downloads the
three artifact sets, writes `SHA256SUMS`, and creates a **draft** release
named "Spate 0.5.0" with the `.pkg`, `.deb`, `.exe` and extension zips
attached. Read the generated notes on the Releases page, edit if needed,
and press Publish; until then nothing is public. Tag builds are obfuscated
(`SPATE_OBFUSCATE=1`); for an open-source release consider turning that off
in the workflow so the binaries are reproducible from the tag.

The Homebrew cask (`packaging/homebrew/spate.rb`) and the winget manifest
(`packaging/winget/DeepakLohani.Spate.yaml`) download from that release; fill in the asset checksums after the
first published release.

