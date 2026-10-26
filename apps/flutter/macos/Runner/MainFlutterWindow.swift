import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Help menu and notifications: see SpateBridge.swift.
    SpateBridge.shared.setUp(messenger: flutterViewController.engine.binaryMessenger)

    // The app draws its own header as the title bar (native title hidden,
    // traffic lights kept; see main.dart). An empty unified toolbar makes the
    // title bar 52px tall with the traffic lights vertically centred, the
    // same geometry as Finder or Safari; Flutter draws beneath it.
    self.toolbar = NSToolbar()
    self.toolbarStyle = .unified
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    // Utility window: no full-screen mode (the green button zooms within the
    // size limits set from Dart instead).
    self.collectionBehavior.insert(.fullScreenNone)
    self.collectionBehavior.remove(.fullScreenPrimary)

    super.awakeFromNib()
  }

  // Minimise (yellow button, Cmd-M) hides the window into the menu bar
  // instead of the Dock when the "Minimise to the tray" preference is on
  // (default). The preference is read from ui.json, written by the Dart side.
  override func miniaturize(_ sender: Any?) {
    if minimizeToTrayPreferred() {
      orderOut(nil)
      return
    }
    super.miniaturize(sender)
  }

  private func minimizeToTrayPreferred() -> Bool {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    guard let url = support?.appendingPathComponent("spate/ui.json"),
          let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let v = json["minimizeToTray"] as? Bool else { return true }
    return v
  }

  // Keep the window hidden at launch; Dart decides when to show it (normal
  // start shows immediately, --background start leaves it hidden in the tray).
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
