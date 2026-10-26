import Cocoa
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate {
  private var notifyChannel: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Resident app: keep running with no windows (menu-bar icon, background
    // downloads, browser capture). Quit only from the tray menu.
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Dock icon click (or `open -a`) while the window is hidden: bring it back.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag, let window = NSApp.windows.first {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  // Notifications through the current UserNotifications framework (the
  // Dart-side plugin covers Windows and Linux; on macOS its legacy API no
  // longer delivers). "notify" {id, title, body, actions[]} posts one and
  // asks for permission the first time; a click comes back on the same
  // channel as "action" {id, action: index or -1 for the body}.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "spate/notify", binaryMessenger: controller.engine.binaryMessenger)
    notifyChannel = channel
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    channel.setMethodCallHandler { call, result in
      guard call.method == "notify", let a = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      let id = a["id"] as? String ?? UUID().uuidString
      let actions = a["actions"] as? [String] ?? []
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { DispatchQueue.main.async { result(false) }; return }
        let content = UNMutableNotificationContent()
        content.title = a["title"] as? String ?? ""
        content.body = a["body"] as? String ?? ""
        content.sound = .default
        content.userInfo = ["id": id]
        if !actions.isEmpty {
          let category = "spate." + actions.joined(separator: "|")
          let unActions = actions.enumerated().map { UNNotificationAction(identifier: "\($0.offset)", title: $0.element, options: [.foreground]) }
          center.getNotificationCategories { existing in
            var set = existing
            set.insert(UNNotificationCategory(identifier: category, actions: unActions, intentIdentifiers: [], options: []))
            center.setNotificationCategories(set)
            content.categoryIdentifier = category
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            DispatchQueue.main.async { result(true) }
          }
        } else {
          center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
          DispatchQueue.main.async { result(true) }
        }
      }
    }
  }

  // Show the banner even while the app is frontmost (Dart decides whether to
  // post one at all).
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    let id = response.notification.request.content.userInfo["id"] as? String ?? ""
    let action = Int(response.actionIdentifier) ?? -1 // -1: the body itself
    notifyChannel?.invokeMethod("action", arguments: ["id": id, "action": action])
    completionHandler()
  }
}
