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
    // traffic lights kept; see main.dart). A taller title bar keeps the
    // traffic lights vertically centred on that 52px header.
    let spacer = NSTitlebarAccessoryViewController()
    spacer.view = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
    spacer.layoutAttribute = .right
    self.addTitlebarAccessoryViewController(spacer)

    super.awakeFromNib()
  }

  // Keep the window hidden at launch; Dart decides when to show it (normal
  // start shows immediately, --background start leaves it hidden in the tray).
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
