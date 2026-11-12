import AppKit

enum MainWindow {
    static let id = "main"

    static func isMain(_ window: NSWindow) -> Bool {
        guard let name = window.identifier?.rawValue else { return false }
        return name == id || name.hasPrefix("\(id)-")
    }
}
