// tray_manager 0.7.0's barrel file only re-exports nativeapi types, while its
// own Menu/MenuItem/TrayListener live in src/; import them explicitly.
// ignore_for_file: implementation_imports
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/src/menu.dart' show Menu, MenuItem;
import 'package:tray_manager/src/tray_listener.dart' show TrayListener;
import 'package:tray_manager/src/tray_manager.dart' show TrayManager;
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/ffi/cascade_ffi.dart';
import 'src/model/ui_prefs.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // The Go core owns the engine, the queue, the browser-capture endpoint and
  // pairing; this app is a thin shell over it via the C ABI. The core refuses
  // to start a second instance, so a duplicate launch (login item + native
  // host + a manual open) asks the running instance to show its window and
  // exits.
  final Cascade core;
  try {
    core = Cascade.start(); // concurrency and folder come from settings
  } on StateError {
    Cascade.requestShow();
    exit(0);
  }
  final controller = CascadeController(core);
  // Theme mode + accent, kept in ui.json next to the core's settings.json.
  final configDir = (core.info()['configDir'] as String?) ?? '';
  final prefs = UiPrefs(configDir.isEmpty ? 'ui.json' : '$configDir/ui.json');

  // --background: started at login (or by the native host for a silent hand-off);
  // stay in the tray without showing the window.
  final background = args.contains('--background') || Platform.environment['CASCADE_BACKGROUND'] == '1';

  final desktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  if (desktop) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(size: Size(960, 660), minimumSize: Size(640, 480), center: true, title: 'Cascade');
    windowManager.waitUntilReadyToShow(opts, () async {
      if (background) {
        // Stay in the tray until "Open Cascade". On macOS the window is hidden
        // at launch by MainFlutterWindow; the Windows/Linux runners show it
        // themselves, so hide it here.
        if (!Platform.isMacOS) await windowManager.hide();
        return;
      }
      await windowManager.show();
      await windowManager.focus();
    });
    // Stay resident: closing the window hides it; downloads and browser
    // capture keep running. Quit from the menu-bar/tray icon.
    await windowManager.setPreventClose(true);
    windowManager.addListener(_Resident());
    // A second launch (Spotlight, Finder, Dock) lands here as a show request.
    controller.onShowRequested = () async {
      await windowManager.show();
      await windowManager.focus();
    };
    await _setupTray(core);
  }

  runApp(CascadeApp(controller: controller, prefs: prefs));
}

class _Resident with WindowListener {
  @override
  void onWindowClose() async {
    await windowManager.hide();
  }
}

Future<void> _setupTray(Cascade core) async {
  final tray = TrayManager.instance;
  tray.addListener(_TrayClicks());
  try {
    await tray.setIcon(
      Platform.isWindows ? 'assets/tray/icon.ico' : 'assets/tray/icon.png',
      isTemplate: true,
    );
    await tray.setToolTip('Cascade');
    await tray.setContextMenu(Menu(items: [
      MenuItem(
        label: 'Open Cascade',
        onClick: (_) async {
          await windowManager.show();
          await windowManager.focus();
        },
      ),
      MenuItem.separator(),
      MenuItem(
        label: 'Quit Cascade',
        onClick: (_) async {
          core.stop();
          await tray.destroy();
          await windowManager.setPreventClose(false);
          exit(0);
        },
      ),
    ]));
  } catch (_) {
    // No tray available (e.g. some Linux sessions); the window still works.
  }
}

class _TrayClicks with TrayListener {
  @override
  void onTrayIconMouseDown() => TrayManager.instance.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => TrayManager.instance.popUpContextMenu();
}
