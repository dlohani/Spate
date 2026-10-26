import 'dart:io';

import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';

/// System notifications. macOS goes through the runner's UserNotifications
/// channel (the current API, with the permission prompt); Windows and Linux
/// through local_notifier. [onAction] receives the index of the action button
/// the user clicked, or -1 for a click on the notification itself.
class Notifier {
  static const _channel = MethodChannel('spate/notify');
  static final Map<String, void Function(int action)> _handlers = {};
  static bool _ready = false;

  static Future<void> setup() async {
    if (_ready) return;
    _ready = true;
    if (Platform.isMacOS) {
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'action') return null;
        final a = call.arguments as Map;
        _handlers.remove(a['id'] as String?)?.call((a['action'] as num?)?.toInt() ?? -1);
        return null;
      });
      return;
    }
    try {
      await localNotifier.setup(appName: 'Spate', shortcutPolicy: ShortcutPolicy.requireCreate);
    } catch (_) {
      _ready = false; // no notification service (some Linux sessions)
    }
  }

  /// Posts a notification; returns false when the user has not allowed them.
  static Future<bool> show({
    required String id,
    required String title,
    required String body,
    List<String> actions = const [],
    void Function(int action)? onAction,
  }) async {
    if (!_ready) return false;
    if (onAction != null) _handlers[id] = onAction;
    if (Platform.isMacOS) {
      try {
        return await _channel.invokeMethod<bool>('notify', {'id': id, 'title': title, 'body': body, 'actions': actions}) ?? false;
      } on PlatformException {
        return false;
      }
    }
    final n = LocalNotification(
      identifier: id,
      title: title,
      body: body,
      actions: [for (final a in actions) LocalNotificationAction(text: a)],
    );
    n.onClick = () => _handlers.remove(id)?.call(-1);
    n.onClickAction = (i) => _handlers.remove(id)?.call(i);
    await n.show();
    return true;
  }
}
