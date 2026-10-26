import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Accent colours the user can pick; the Material 3 scheme is seeded from
/// the chosen one in both light and dark mode.
const accentColors = <String, Color>{
  'blue': Color(0xFF2563EB),
  'indigo': Color(0xFF4F46E5),
  'teal': Color(0xFF0D9488),
  'green': Color(0xFF16A34A),
  'orange': Color(0xFFEA580C),
  'rose': Color(0xFFE11D48),
  'graphite': Color(0xFF52525B),
};

/// Smallest window the layout is designed for; also the default size.
const kMinWindowSize = Size(600, 440);

/// UI-only preferences (theme mode, accent, last window size). Stored as
/// ui.json next to the core's settings.json so they survive reinstalls like
/// everything else; the core never reads them.
class UiPrefs extends ChangeNotifier {
  final String path;
  ThemeMode mode = ThemeMode.system;
  String accent = 'blue';
  Size? windowSize;

  /// Minimising hides the window into the tray/menu bar instead of the Dock
  /// or taskbar (closing already does), so the app is not quit by accident.
  bool minimizeToTray = true;

  /// Where the app shows itself: 'both' (menu-bar/tray icon and a Dock/
  /// taskbar entry while the window is open), 'tray' (icon only, no Dock or
  /// taskbar entry) or 'dock' (no tray icon; the window is the whole app).
  String presence = 'both';
  static const presences = ['both', 'tray', 'dock'];

  /// With no tray icon there is nothing to minimise into.
  bool get hasTray => presence != 'dock';

  /// System notification when a download finishes or fails while the window
  /// is hidden or in the background.
  bool notify = true;

  /// Pulse the menu-bar / tray icon while something is downloading.
  bool pulseTray = true;

  /// Menu-bar icon style on macOS: a monochrome template glyph that follows
  /// the menu bar like Apple's own items (the platform convention, default),
  /// or the coloured app icon.
  String trayIconStyle = 'mono';
  static const trayIconStyles = ['color', 'mono'];

  void setTrayIconStyle(String v) {
    if (!trayIconStyles.contains(v) || v == trayIconStyle) return;
    trayIconStyle = v;
    _save();
    notifyListeners();
  }

  void setPulseTray(bool v) {
    if (v == pulseTray) return;
    pulseTray = v;
    _save();
    notifyListeners();
  }

  void setNotify(bool v) {
    if (v == notify) return;
    notify = v;
    _save();
    notifyListeners();
  }

  void setPresence(String p) {
    if (!presences.contains(p) || p == presence) return;
    presence = p;
    _save();
    notifyListeners();
  }

  void setMinimizeToTray(bool v) {
    if (v == minimizeToTray) return;
    minimizeToTray = v;
    _save();
    notifyListeners();
  }

  /// Saved without notifying: the window itself already has the size.
  void setWindowSize(Size s) {
    if (s.width < kMinWindowSize.width || s.height < kMinWindowSize.height) return;
    if (windowSize == s) return;
    windowSize = s;
    _save();
  }

  UiPrefs(this.path) {
    _load();
  }

  Color get seed => accentColors[accent] ?? accentColors['blue']!;

  void setMode(ThemeMode m) {
    if (m == mode) return;
    mode = m;
    _save();
    notifyListeners();
  }

  void setAccent(String a) {
    if (!accentColors.containsKey(a) || a == accent) return;
    accent = a;
    _save();
    notifyListeners();
  }

  void _load() {
    try {
      final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      mode = switch (j['theme']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      final a = j['accent'] as String?;
      if (a != null && accentColors.containsKey(a)) accent = a;
      minimizeToTray = j['minimizeToTray'] as bool? ?? true;
      final p = j['presence'] as String?;
      if (p != null && presences.contains(p)) presence = p;
      notify = j['notify'] as bool? ?? true;
      pulseTray = j['pulseTray'] as bool? ?? true;
      final ts = j['trayIconStyle'] as String?;
      if (ts != null && trayIconStyles.contains(ts)) trayIconStyle = ts;
      final w = (j['windowW'] as num?)?.toDouble();
      final h = (j['windowH'] as num?)?.toDouble();
      if (w != null && h != null && w >= kMinWindowSize.width && h >= kMinWindowSize.height) {
        windowSize = Size(w, h);
      }
    } catch (_) {
      // Missing or unreadable: defaults.
    }
  }

  void _save() {
    try {
      File(path).parent.createSync(recursive: true);
      File(path).writeAsStringSync(
        jsonEncode({
          'theme': mode.name,
          'accent': accent,
          'minimizeToTray': minimizeToTray,
          'presence': presence,
          'notify': notify,
          'pulseTray': pulseTray,
          'trayIconStyle': trayIconStyle,
          if (windowSize != null) 'windowW': windowSize!.width,
          if (windowSize != null) 'windowH': windowSize!.height,
        }),
      );
    } catch (_) {
      // Preferences are a convenience; never fail the UI over them.
    }
  }
}
