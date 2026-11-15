import AppKit

final class KeyedWindow: NSWindow {
    var reportsKey: Bool?

    override var isKeyWindow: Bool { reportsKey ?? super.isKeyWindow }

    @objc(_isKeyWindow) func reportsKeyToAppKit() -> Bool { isKeyWindow }
}
