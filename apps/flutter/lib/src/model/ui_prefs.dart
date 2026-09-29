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

/// Largest window: a download list does not benefit from a full screen, and
/// the layout is designed for a utility-sized window.
const kMaxWindowSize = Size(1100, 800);

/// UI-only preferences (theme mode, accent, last window size). Stored as
/// ui.json next to the core's settings.json so they survive reinstalls like
/// everything else; the core never reads them.
class UiPrefs extends ChangeNotifier {
  final String path;
  ThemeMode mode = ThemeMode.system;
  String accent = 'blue';
  Size? windowSize;

  /// Saved without notifying: the window itself already has the size.
  void setWindowSize(Size s) {
    if (s.width < kMinWindowSize.width || s.height < kMinWindowSize.height) return;
    if (s.width > kMaxWindowSize.width || s.height > kMaxWindowSize.height) return;
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
      final w = (j['windowW'] as num?)?.toDouble();
      final h = (j['windowH'] as num?)?.toDouble();
      if (w != null &&
          h != null &&
          w >= kMinWindowSize.width &&
          h >= kMinWindowSize.height &&
          w <= kMaxWindowSize.width &&
          h <= kMaxWindowSize.height) {
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
          if (windowSize != null) 'windowW': windowSize!.width,
          if (windowSize != null) 'windowH': windowSize!.height,
        }),
      );
    } catch (_) {
      // Preferences are a convenience; never fail the UI over them.
    }
  }
}
