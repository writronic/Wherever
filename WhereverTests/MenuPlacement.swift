import AppKit
import Foundation

final class MenuPlacement: NSObject {
    let menu: NSMenu
    private(set) var frame: NSRect?
    private var opened = false

    init(_ menu: NSMenu) { self.menu = menu }

    private static var settling = false
    static var popUpShown: Bool { settling || NSApp.windows.contains { $0.isVisible && $0.level == .popUpMenu } }

    static func settle() {
        settling = true
        DispatchQueue.main.async { settling = false }
    }

    static func opens(_ menu: NSRect, under control: NSRect, rightToLeft: Bool) -> Bool {
        rightToLeft ? menu.maxX > control.midX && menu.minX < control.maxX : menu.minX < control.midX && menu.maxX > control.minX
    }

    @objc private func began(_ note: Notification) { opened = true }

    func measure(_ open: () -> Void) {
        NotificationCenter.default.addObserver(self, selector: #selector(began(_:)), name: NSMenu.didBeginTrackingNotification, object: menu)
        let deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.01, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                if opened, let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .popUpMenu }) {
                    frame = window.frame
                    menu.cancelTracking()
                } else if Date() >= deadline {
                    menu.cancelTracking()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate(); NotificationCenter.default.removeObserver(self) }
        open()
        MenuPlacement.settle()
    }
}
