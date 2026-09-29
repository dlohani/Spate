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

  // Keep the window hidden at launch; Dart decides when to show it (normal
  // start shows immediately, --background start leaves it hidden in the tray).
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
