import Cocoa
import FlutterMacOS
import UserNotifications

/// Native pieces the Dart shell cannot do itself on macOS: the Help menu in
/// the menu bar and notifications through the UserNotifications framework.
/// Set up from MainFlutterWindow.awakeFromNib (the one place guaranteed to
/// run with a live engine), not from the app delegate.
final class SpateBridge: NSObject, UNUserNotificationCenterDelegate {
  static let shared = SpateBridge()
  private var notifyChannel: FlutterMethodChannel?
  private var menuChannel: FlutterMethodChannel?

  func setUp(messenger: FlutterBinaryMessenger) {
    setUpNotifications(messenger)
    menuChannel = FlutterMethodChannel(name: "spate/menu", binaryMessenger: messenger)
    // The main menu comes from the same nib and may not be installed yet.
    NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { [weak self] _ in
      self?.fillHelpMenu()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.fillHelpMenu() }
  }

  // MARK: Help menu

  // Spate Help (Cmd-?), Keyboard Shortcuts, Report a Problem, Buy Me a
  // Coffee. Each item hands its name to Dart over "spate/menu", which owns
  // the URLs, so this menu and the in-app menu on Windows and Linux stay one
  // list.
  private func fillHelpMenu() {
    let fromMain = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Help" || $0.title == "Help" })?.submenu
    guard let help = fromMain ?? NSApp.helpMenu else { return }
    if help.items.contains(where: { $0.representedObject as? String == "help" }) { return }
    help.removeAllItems()
    func add(_ title: String, _ action: String, key: String = "", mods: NSEvent.ModifierFlags = []) {
      let item = NSMenuItem(title: title, action: #selector(helpItem(_:)), keyEquivalent: key)
      item.keyEquivalentModifierMask = mods
      item.representedObject = action
      item.target = self
      help.addItem(item)
    }
    add("Spate Help", "help", key: "?", mods: [.command])
    add("Keyboard Shortcuts", "shortcuts")
    help.addItem(.separator())
    add("Report a Problem…", "report")
    help.addItem(.separator())
    add("Buy Me a Coffee…", "coffee")
    NSApp.helpMenu = help
  }

  @objc private func helpItem(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? String else { return }
    if let window = NSApp.windows.first, !window.isVisible {
      window.makeKeyAndOrderFront(nil) // the shortcuts dialog needs a window
    }
    menuChannel?.invokeMethod("help", arguments: action)
  }

  // MARK: Notifications

  // "notify" {id, title, body, actions[]} posts one and asks for permission
  // the first time; a click comes back on the same channel as "action"
  // {id, action: index or -1 for the body}.
  private func setUpNotifications(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "spate/notify", binaryMessenger: messenger)
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
        let post = {
          center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
          DispatchQueue.main.async { result(true) }
        }
        if actions.isEmpty {
          post()
          return
        }
        let category = "spate." + actions.joined(separator: "|")
        let unActions = actions.enumerated().map { UNNotificationAction(identifier: "\($0.offset)", title: $0.element, options: [.foreground]) }
        center.getNotificationCategories { existing in
          var set = existing
          set.insert(UNNotificationCategory(identifier: category, actions: unActions, intentIdentifiers: [], options: []))
          center.setNotificationCategories(set)
          content.categoryIdentifier = category
          post()
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
