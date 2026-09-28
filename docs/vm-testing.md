# Testing Cascade on Windows and Linux VMs

The Go core, the browser extension, the native host and the Flutter UI are the
same on every desktop OS; only the installer and the toolchain differ. These
are the exact steps for a fresh VM, and what to check.

## The one thing that bites: the extension ID

An unpacked extension's ID is derived from the folder it is loaded from, so it
is different on every machine. The native-host manifest must list that ID or
the browser will refuse to launch Cascade (downloads then fall back to "Allow"
pairing, and launch-on-demand silently does nothing).

1. Load `browser/extension` in `chrome://extensions` (Developer mode, Load
   unpacked).
2. Open the extension's Options: it shows **Extension ID** with a Copy button.
3. Pass it to the installer (below). Re-run the installer if you move the folder.

## Windows (VM)

Prerequisites: Git, Go, Flutter, Visual Studio 2022 with "Desktop development
with C++" (Flutter's Windows requirement).

```powershell
git clone <repo> cascade; cd cascade
# 1. core DLL: either build it natively (needs a C compiler, e.g. MSYS2 gcc on PATH)
#    or copy cascade.dll from the macOS-built zip into dist\windows-amd64\
# 2. Flutter UI
powershell -ExecutionPolicy Bypass -File scripts\flutter-windows.ps1
# 3. stage an install folder next to the installer
mkdir stage; copy dist\windows-amd64\* stage\ ; xcopy /E /I apps\flutter\build\windows\x64\runner\Release stage\cascade_app
xcopy /E /I browser\extension stage\extension
# 4. install (use the ID from the extension's Options page)
powershell -ExecutionPolicy Bypass -File stage\install-windows.ps1 -ExtensionIds <ID>
```

`install-windows.ps1` copies to `%LOCALAPPDATA%\Cascade\bin`, writes the
native-host manifest, registers it under `HKCU\Software\{Google\Chrome,
Chromium, Microsoft\Edge, BraveSoftware\Brave-Browser}\NativeMessagingHosts`,
and adds a Run-key autostart (`cascade_app.exe --background`).

## Ubuntu (VM)

```bash
sudo apt install -y git golang clang cmake ninja-build pkg-config libgtk-3-dev \
  liblzma-dev libstdc++-12-dev libayatana-appindicator3-dev
# Flutter: https://docs.flutter.dev/get-started/install/linux (snap or tarball)
git clone <repo> cascade && cd cascade
(cd apps/flutter && flutter config --enable-linux-desktop && flutter pub get && flutter build linux)
scripts/install-linux.sh <ID>     # ID from the extension's Options page
```

`install-linux.sh` builds `libcascade.so` and the host, installs the Flutter
bundle under `~/.local/share/cascade/bin`, registers the host for Chromium,
Chrome, Brave, Edge and Vivaldi (`~/.config/<browser>/NativeMessagingHosts`,
plus the snap Chromium path), and adds an app-menu entry and an XDG autostart
entry (`--background`). A tray icon needs AppIndicator support (KDE, or GNOME
with the AppIndicator extension); without it the app is window-only.

## What to check, in order

1. `chrome://extensions` shows the extension enabled; Options → **Test
   connection** says the app is reachable when Cascade is running.
2. Quit Cascade. Download any file in the browser → the **Cascade** choice
   popup appears → choose Cascade → the app launches by itself (native host)
   and the download appears in it. Options → "Last event" says
   "handed off to app". If it says "native host unavailable", the ID in the
   manifest is wrong: re-run the installer with the ID from Options.
3. Close the window: the process keeps running (tray icon). Reopen from the
   tray. Log out/in (or reboot the VM): Cascade starts hidden.
4. Pause / resume / cancel a download; "Show in folder" opens Explorer /
   the file manager.
5. Windows only: SmartScreen warns on first run (unsigned). Allow it.

## What to report back

- The exact text of any red line from the installer.
- The extension Options page's "Last event" after a browser download.
- Whether the tray icon appeared, and whether closing the window kept the
  process alive.
