# Testing Spate on Windows and Linux VMs

The Go core, the browser extension, the native host and the Flutter UI are the
same on every desktop OS; only the installer and the toolchain differ. These
are the exact steps for a fresh VM, and what to check.

## The one thing that bites: the extension ID

An unpacked extension's ID is derived from the folder it is loaded from, so it
is different on every machine. The native-host manifest must list that ID or
the browser will refuse to launch Spate (downloads then fall back to "Allow"
pairing, and launch-on-demand silently does nothing).

1. Load `browser/extension` in `chrome://extensions` (Developer mode, Load
   unpacked).
2. Open the extension's Options: it shows **Extension ID** with a Copy button.
3. Pass it to the installer (below). Re-run the installer if you move the folder.

## Windows (VM), quickest: the installer

Copy `dist/Spate-Setup-<ver>.exe` (built on the Mac with
`scripts/package-windows.sh`) to the VM and run it: Welcome → Directory →
Install → Finish ("Start Spate"). It registers the browser host, adds a
hidden autostart and an Add/Remove Programs entry. Then load the extension from
`%LOCALAPPDATA%\Spate\extension`. If Options shows a different Extension ID,
run `%LOCALAPPDATA%\Spate\bin\register-extension.cmd <ID>`.
The installer needs the Flutter UI, which is built on Windows (below).
`./build windows` refuses to package without it, and a setup built with
`SPATE_ALLOW_NO_UI=1` refuses to install without `--no-ui`, so a build
missing the UI cannot be mistaken for a complete one.

## Windows (VM), building the Flutter UI

The Windows UI is the Flutter app and it can only be compiled on Windows, so
every release needs this once on the VM (a few minutes; incremental after
the first time).

One-time tooling in the VM (PowerShell as your user):

```powershell
winget install Git.Git
winget install Microsoft.VisualStudio.2022.Community --override "--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --passive"
git clone https://github.com/flutter/flutter.git -b stable C:\src\flutter
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\src\flutter\bin", "User")   # then open a new PowerShell
flutter doctor                     # Windows toolchain and Visual Studio must show green
start ms-settings:developers       # turn on Developer Mode (Flutter plugins need symlinks)
```

Check the Mac share is visible: in Explorer open `\\Mac\Home` (Parallels ->
VM configuration -> Options -> Sharing -> Share Mac: Home folder). Then:

```powershell
git clone \\Mac\Home\Projects\spate C:\src\spate     # clones straight from the Mac checkout
cd C:\src\spate                                          # later releases: git pull
powershell -ExecutionPolicy Bypass -File scripts\flutter-windows.ps1 -CopyTo \\Mac\Home\Projects\spate
```

`-CopyTo` drops the bundle into the Mac checkout's `dist\windows-amd64\spate_app`
(Parallels shares the Mac home as `\\Mac\Home`; adjust the path otherwise).
Then on the Mac: `./build windows` -> `dist/Spate-Setup-<v>.exe` and
`spate-setup.exe`, both carrying the UI. Running either on the VM upgrades
the old install: the pre-0.4.0 `spate-gui.exe` is stopped and removed so the
new app owns the port.

Prerequisites: Git, Go, Flutter, Visual Studio 2022 with "Desktop development
with C++" (Flutter's Windows requirement).

```powershell
git clone <repo> spate; cd spate
# 1. core DLL: either build it natively (needs a C compiler, e.g. MSYS2 gcc on PATH)
#    or copy spate.dll from the macOS-built zip into dist\windows-amd64\
# 2. Flutter UI
powershell -ExecutionPolicy Bypass -File scripts\flutter-windows.ps1
# 3. stage an install folder next to the installer
mkdir stage; copy dist\windows-amd64\* stage\ ; xcopy /E /I apps\flutter\build\windows\x64\runner\Release stage\spate_app
xcopy /E /I browser\extension stage\extension
# 4. install (use the ID from the extension's Options page)
powershell -ExecutionPolicy Bypass -File stage\install-windows.ps1 -ExtensionIds <ID>
```

`install-windows.ps1` copies to `%LOCALAPPDATA%\Spate\bin`, writes the
native-host manifest, registers it under `HKCU\Software\{Google\Chrome,
Chromium, Microsoft\Edge, BraveSoftware\Brave-Browser}\NativeMessagingHosts`,
and adds a Run-key autostart (`spate_app.exe --background`).

## Ubuntu (VM)

```bash
sudo apt install -y git golang clang cmake ninja-build pkg-config libgtk-3-dev \
  liblzma-dev libstdc++-12-dev libayatana-appindicator3-dev
# Flutter: https://docs.flutter.dev/get-started/install/linux (snap or tarball)
git clone <repo> spate && cd spate
(cd apps/flutter && flutter config --enable-linux-desktop && flutter pub get)
scripts/package-linux.sh                      # builds the UI if needed -> dist/spate_<ver>_amd64.deb
sudo apt install ./dist/spate_*_amd64.deb   # then log out/in, or start "Spate" from the menu
spate-register <ID>                         # only for Brave/Vivaldi or a different extension ID
```

The package puts the CLI in `/usr/bin/spate`, the app under
`/usr/lib/spate/`, the extension under `/usr/share/spate/extension`
(load that folder in `chrome://extensions`), registers the native host
system-wide for Chrome/Chromium/Edge, and adds the menu entry, icons and
autostart (`--background`). Package checks to run as well: `sudo apt install
./dist/spate_*.deb` a second time (prints "already installed; reinstalling"),
and an older build (`VERSION` lowered, repackaged) must be refused with
"downgrades are not supported". `sudo apt remove spate` must stop the app
and drop the registrations; `~/.config/spate` stays.

Without a package: `flutter build linux` then `scripts/install-linux.sh <ID>`
installs per-user under `~/.local/share/spate/bin` (same registrations,
menu and autostart entries). A tray icon needs AppIndicator support (KDE, or
GNOME with the AppIndicator extension); without it the app is window-only.

## What to check, in order

1. `chrome://extensions` shows the extension enabled; Options → **Test
   connection** says the app is reachable when Spate is running.
2. Quit Spate. Download any file in the browser → the **Spate** choice
   popup appears → choose Spate → the app launches by itself (native host)
   and the download appears in it. Options → "Last event" says
   "handed off to app". If it says "native host unavailable", the ID in the
   manifest is wrong: re-run the installer with the ID from Options.
3. Close the window: the process keeps running (tray icon). Reopen from the
   tray. Log out/in (or reboot the VM): Spate starts hidden.
4. Pause / resume / cancel a download; "Show in folder" opens Explorer /
   the file manager.
5. Windows only: SmartScreen warns on first run (unsigned). Allow it.

## What to report back

- The exact text of any red line from the installer.
- The extension Options page's "Last event" after a browser download.
- Whether the tray icon appeared, and whether closing the window kept the
  process alive.
