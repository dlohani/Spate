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
import 'src/model/job.dart' show humanBytes;
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
    // Open compact (the minimum size unless the user resized it last time);
    // the layout scales up to 900px wide when the window is stretched.
    final opts = WindowOptions(
      size: prefs.windowSize ?? kMinWindowSize,
      minimumSize: kMinWindowSize,
      maximumSize: kMaxWindowSize,
      center: true,
      title: 'Cascade',
      // macOS: the app's header row is the title bar (one "Cascade", not a
      // native title above an in-app one); traffic lights stay. Windows and
      // Linux keep the native bar, which carries their window controls.
      titleBarStyle: Platform.isMacOS ? TitleBarStyle.hidden : TitleBarStyle.normal,
    );
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
    windowManager.addListener(_Resident(prefs));
    // A second launch (Spotlight, Finder, Dock) lands here as a show request.
    controller.onShowRequested = () async {
      await windowManager.show();
      await windowManager.focus();
    };
    await _setupTray(core, controller);
  }

  runApp(CascadeApp(controller: controller, prefs: prefs));
}

class _Resident with WindowListener {
  final UiPrefs prefs;
  _Resident(this.prefs);

  @override
  void onWindowClose() async {
    await windowManager.hide();
  }

  // Remember the size the user settled on; next launch opens at that size.
  @override
  void onWindowResized() async {
    prefs.setWindowSize(await windowManager.getSize());
  }
}

/// Menu-bar / tray icon: the app icon's silhouette (template on macOS so it
/// follows the menu bar tint; colour on Linux/Windows), plus a live summary
/// while downloading: "2 · 43%" beside the icon on macOS, the same in the
/// tooltip and as the first line of the menu everywhere.
Future<void> _setupTray(Cascade core, CascadeController controller) async {
  final tray = TrayManager.instance;
  tray.addListener(_TrayClicks());
  try {
    final icon = Platform.isWindows
        ? 'assets/tray/icon.ico'
        : Platform.isLinux
        ? 'assets/tray/icon-color.png'
        : 'assets/tray/icon.png';
    await tray.setIcon(icon, isTemplate: Platform.isMacOS);
    final status = _TrayStatus(tray, core, controller);
    await status.apply(force: true);
    controller.addListener(status.apply);
  } catch (_) {
    // No tray available (e.g. some Linux sessions); the window still works.
  }
}

class _TrayStatus {
  final TrayManager tray;
  final Cascade core;
  final CascadeController controller;
  String _last = '';
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  _TrayStatus(this.tray, this.core, this.controller);

  /// Recomputes the summary at most once a second and pushes it only when
  /// the text changed (menu rebuilds are not free).
  Future<void> apply({bool force = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_lastAt) < const Duration(seconds: 1)) return;
    final jobs = controller.jobs;
    final running = jobs.where((j) => j.state == 'running').toList();
    final queued = jobs.where((j) => j.state == 'pending').length;
    var title = '';
    var line = queued > 0 ? '$queued queued' : 'Nothing downloading';
    if (running.isNotEmpty) {
      // Aggregate progress over the running downloads with a known size.
      final known = running.where((j) => j.total > 0);
      final done = known.fold<int>(0, (a, j) => a + j.bytes);
      final total = known.fold<int>(0, (a, j) => a + j.total);
      final pct = total > 0 ? (done * 100 / total).round() : null;
      final n = running.length;
      final speed = '${humanBytes(controller.totalSpeed.round())}/s';
      title = pct == null ? '$n' : '$n · $pct%';
      line = '$n downloading${pct == null ? '' : ' · $pct%'} · $speed${queued > 0 ? ' · $queued queued' : ''}';
    }
    final key = '$title|$line';
    if (!force && key == _last) return;
    _last = key;
    _lastAt = now;
    if (Platform.isMacOS) await tray.setTitle(title.isEmpty ? '' : ' $title');
    await tray.setToolTip(title.isEmpty ? 'Cascade' : 'Cascade: $line');
    await tray.setContextMenu(
      Menu(
        items: [
          MenuItem(label: line, disabled: true),
          MenuItem.separator(),
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
        ],
      ),
    );
  }
}

class _TrayClicks with TrayListener {
  @override
  void onTrayIconMouseDown() => TrayManager.instance.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => TrayManager.instance.popUpContextMenu();
}
