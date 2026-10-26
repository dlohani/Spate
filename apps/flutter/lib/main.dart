// tray_manager 0.7.0's barrel file only re-exports nativeapi types, while its
// own Menu/MenuItem/TrayListener live in src/; import them explicitly.
// ignore_for_file: implementation_imports
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/src/menu.dart' show Menu, MenuItem;
import 'package:tray_manager/src/tray_listener.dart' show TrayListener;
import 'package:tray_manager/src/tray_manager.dart' show TrayManager;
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/ffi/spate_ffi.dart';
import 'src/model/job.dart';
import 'src/model/ui_prefs.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // The Go core owns the engine, the queue, the browser-capture endpoint and
  // pairing; this app is a thin shell over it via the C ABI. The core refuses
  // to start a second instance, so a duplicate launch (login item + native
  // host + a manual open) asks the running instance to show its window and
  // exits. Any other start failure (a corrupt settings file, an unwritable
  // folder) is shown, never swallowed.
  final Spate core;
  try {
    core = Spate.start(); // concurrency and folder come from settings
  } on SpateException catch (e) {
    if (e.alreadyRunning) {
      Spate.requestShow();
      exit(0);
    }
    runApp(_FatalApp(e.message));
    return;
  } on StateError catch (e) {
    // libspate could not be found.
    runApp(_FatalApp(e.message));
    return;
  } on ArgumentError catch (e) {
    // libspate exists but failed to load (wrong architecture, a missing
    // dependency, a quarantined file).
    runApp(_FatalApp('libspate could not be loaded: ${e.message}'));
    return;
  }
  final controller = SpateController(core);
  // Theme mode + accent, kept in ui.json next to the core's settings.json.
  final configDir = (core.info()['configDir'] as String?) ?? '';
  final prefs = UiPrefs(configDir.isEmpty ? 'ui.json' : '$configDir/ui.json');

  // --background: started at login (or by the native host for a silent hand-off);
  // stay in the tray without showing the window.
  final background = args.contains('--background') || Platform.environment['SPATE_BACKGROUND'] == '1';

  final desktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  if (desktop) {
    await windowManager.ensureInitialized();
    // Open compact (the minimum size unless the user resized it last time);
    // the layout scales up to 1100px wide when the window is stretched and
    // the window may grow to the screen.
    final opts = WindowOptions(
      size: prefs.windowSize ?? kMinWindowSize,
      minimumSize: kMinWindowSize,
      center: true,
      title: 'Spate',
      // macOS: the app's header row is the title bar (one "Spate", not a
      // native title above an in-app one); traffic lights stay. Windows and
      // Linux keep the native bar, which carries their window controls.
      titleBarStyle: Platform.isMacOS ? TitleBarStyle.hidden : TitleBarStyle.normal,
    );
    windowManager.waitUntilReadyToShow(opts, () async {
      // A background start with neither a tray icon nor (off macOS) a Dock
      // icon would leave nothing to open the app from: show the window.
      final nowhereToOpenFrom = !prefs.hasTray && !Platform.isMacOS;
      if (background && !nowhereToOpenFrom) {
        // Stay in the tray until "Open Spate". On macOS the window is hidden
        // at launch by MainFlutterWindow; the Windows/Linux runners show it
        // themselves, so hide it here.
        if (!Platform.isMacOS) await windowManager.hide();
        controller.setVisible(false);
        return;
      }
      await windowManager.show();
      await windowManager.focus();
      controller.setVisible(true);
    });
    // Stay resident: closing the window hides it; downloads and browser
    // capture keep running. Quit from the menu-bar/tray icon.
    await windowManager.setPreventClose(true);
    windowManager.addListener(_Resident(prefs, controller));
    // A second launch (Spotlight, Finder, Dock), or a pairing request while
    // hidden, lands here as a show request.
    controller.onShowRequested = () => showWindow(controller);
    // Menu bar / tray icon and Dock / taskbar presence follow the preference,
    // now and whenever it changes in Settings.
    await _applyPresence(core, controller, prefs);
    prefs.addListener(() => _applyPresence(core, controller, prefs));
    await _setupNotifications(controller, prefs);
  }

  runApp(SpateApp(controller: controller, prefs: prefs));
}

/// System notifications when a download finishes or fails while the window
/// is hidden or in the background (the only feedback channel for a resident
/// app). Open and Show in folder on the finished one, Retry on the failed.
Future<void> _setupNotifications(SpateController controller, UiPrefs prefs) async {
  try {
    await localNotifier.setup(appName: 'Spate', shortcutPolicy: ShortcutPolicy.requireCreate);
  } catch (_) {
    return; // no notification service (some Linux sessions): nothing to hook
  }
  controller.onFinished = (job) {
    if (!prefs.notify) return;
    if (controller.visible && controller.focused) return; // the user is looking at it
    final done = job.state == 'done';
    final n = LocalNotification(
      identifier: job.id,
      title: done ? 'Download finished' : 'Download failed',
      body: done ? '${job.filename}${job.total > 0 ? ' · ${humanBytes(job.total)}' : ''}' : '${job.filename}\n${job.error ?? ''}',
      actions: done
          ? [LocalNotificationAction(text: 'Open'), LocalNotificationAction(text: Platform.isMacOS ? 'Show in Finder' : 'Show in folder')]
          : [LocalNotificationAction(text: 'Retry')],
    );
    n.onClick = () => showWindow(controller);
    n.onClickAction = (i) {
      if (done) {
        i == 0 ? controller.openFile(job.out) : controller.reveal(job.out);
      } else {
        controller.retry(job);
      }
    };
    n.show();
  };
}

/// Shown instead of the app when the core cannot start: the reason from the
/// core and where its files live, so the user can fix or remove them.
class _FatalApp extends StatelessWidget {
  final String message;
  const _FatalApp(this.message);

  @override
  Widget build(BuildContext context) {
    final cfg = Platform.environment['SPATE_SETTINGS'] ?? 'the spate folder in your user config directory';
    return MaterialApp(
      title: 'Spate',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFFE11D48)),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Spate could not start', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  SelectableText(message),
                  const SizedBox(height: 12),
                  Text('Settings and queue files: $cfg. Fix or remove the file named above and open Spate again.', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: () => exit(1), child: const Text('Quit')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Brings the window back from hidden or minimised state.
Future<void> showWindow(SpateController controller) async {
  if (await windowManager.isMinimized()) await windowManager.restore();
  await windowManager.show();
  await windowManager.focus();
  controller.setVisible(true);
}

/// Whether the tray icon is currently up (presence 'both' or 'tray').
bool _trayUp = false;
bool _trayListening = false;

/// Applies the presence preference: creates or removes the tray icon and
/// shows or hides the Dock / taskbar entry (window_manager's skipTaskbar sets
/// the macOS activation policy to accessory, which drops the Dock icon).
Future<void> _applyPresence(Spate core, SpateController controller, UiPrefs prefs) async {
  final wantTray = prefs.hasTray;
  if (wantTray && !_trayUp) {
    _trayUp = true;
    await _setupTray(core, controller);
  } else if (!wantTray && _trayUp) {
    _trayUp = false;
    controller.onJobsRefreshed = null;
    try {
      await TrayManager.instance.destroy();
    } catch (_) {}
  }
  try {
    await windowManager.setSkipTaskbar(prefs.presence == 'tray');
  } catch (_) {}
}

/// Stops the core and exits; used by the tray menu and, with no tray, by the
/// window's close button on Windows and Linux.
Future<void> quitApp(Spate core) async {
  core.stop();
  if (_trayUp) {
    try {
      await TrayManager.instance.destroy();
    } catch (_) {}
  }
  await windowManager.setPreventClose(false);
  exit(0);
}

class _Resident with WindowListener {
  final UiPrefs prefs;
  final SpateController controller;
  _Resident(this.prefs, this.controller);

  @override
  void onWindowClose() async {
    // Dock-only mode off macOS: closing the only visible entry point quits;
    // on macOS the Dock icon stays and reopens the window (AppDelegate).
    if (!prefs.hasTray && !Platform.isMacOS) {
      await quitApp(controller.core);
      return;
    }
    await windowManager.hide();
    controller.setVisible(false);
  }

  // The Dock icon (macOS) or a second launch brought the window back.
  @override
  void onWindowFocus() {
    controller.setFocused(true);
    controller.setVisible(true);
  }

  @override
  void onWindowBlur() => controller.setFocused(false);

  // Minimise -> into the tray (when the preference is on): the window leaves
  // the Dock/taskbar and comes back from the tray menu or a second launch.
  @override
  void onWindowMinimize() async {
    if (!prefs.minimizeToTray || !prefs.hasTray) {
      controller.setVisible(false); // minimised: nothing to paint either
      return;
    }
    // orderOut on the miniaturised window drops it from the Dock/taskbar;
    // showWindow() de-miniaturises before showing it again.
    await windowManager.hide();
    controller.setVisible(false);
  }

  @override
  void onWindowRestore() => controller.setVisible(true);

  // Remember the size the user settled on; next launch opens at that size.
  @override
  void onWindowResized() async {
    prefs.setWindowSize(await windowManager.getSize());
  }
}

/// Menu-bar / tray icon: the Spate glyph (a template image on macOS, so it
/// follows the menu bar's light or dark style; the colour icon elsewhere),
/// plus a live summary while downloading: "2 · 43%" beside the icon on
/// macOS, the same in the tooltip and as the first line of the menu.
Future<void> _setupTray(Spate core, SpateController controller) async {
  final tray = TrayManager.instance;
  if (!_trayListening) {
    tray.addListener(_TrayClicks());
    _trayListening = true;
  }
  try {
    if (Platform.isMacOS) {
      await tray.setIcon('assets/tray/icon.png', isTemplate: true);
    } else {
      await tray.setIcon(Platform.isWindows ? 'assets/tray/icon.ico' : 'assets/tray/icon-color.png');
    }
    final status = _TrayStatus(tray, core, controller);
    await status.apply(force: true);
    controller.onJobsRefreshed = status.apply; // runs hidden or shown
  } catch (_) {
    // No tray available (e.g. some Linux sessions); the window still works.
  }
}

class _TrayStatus {
  final TrayManager tray;
  final Spate core;
  final SpateController controller;
  String _last = '';
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _menuAt = DateTime.fromMillisecondsSinceEpoch(0);
  _TrayStatus(this.tray, this.core, this.controller);

  /// Recomputes the summary at most once a second and pushes it only when
  /// the text changed (menu rebuilds are not free).
  Future<void> apply({bool force = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_lastAt) < const Duration(seconds: 1)) return;
    final jobs = controller.jobs;
    final running = jobs.where((j) => j.state == 'running').toList();
    final queued = jobs.where((j) => j.state == 'pending').length;
    final paused = jobs.where((j) => j.state == 'paused').length;
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
    final key = '$title|$line|$paused';
    if (!force && key == _last) return;
    _last = key;
    _lastAt = now;
    if (Platform.isMacOS) await tray.setTitle(title.isEmpty ? '' : ' $title');
    await tray.setToolTip(title.isEmpty ? 'Spate' : 'Spate: $line');
    // Rebuilding the native menu is the expensive part (it was most of the
    // app's CPU during a long download); the title and tooltip above carry
    // the live numbers every second, the menu's first line can lag a little.
    if (!force && running.isNotEmpty && now.difference(_menuAt) < const Duration(seconds: 3)) return;
    _menuAt = now;
    await tray.setContextMenu(
      Menu(
        items: [
          MenuItem(label: line, disabled: true),
          MenuItem.separator(),
          MenuItem(label: 'Open Spate', onClick: (_) => showWindow(controller)),
          MenuItem.separator(),
          MenuItem(label: 'Pause all', disabled: running.isEmpty && queued == 0, onClick: (_) => controller.pauseAll()),
          MenuItem(label: 'Resume all', disabled: paused == 0, onClick: (_) => controller.resumeAll()),
          MenuItem.separator(),
          MenuItem(label: 'Quit Spate', onClick: (_) => quitApp(core)),
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
