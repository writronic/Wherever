import AppKit
import SwiftUI

final class AboutWindow: NSWindowController {
    enum Metrics {
        static let side: CGFloat = 32
        static let minWidth: CGFloat = 360
    }

    private let dialogs: ModalWindowCoordinator
    private let defaults: UserDefaults
    private var placed = false
    private var watch: TextSizeWatch?

    init(defaults: UserDefaults, open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }, dialogs: ModalWindowCoordinator = .shared) {
        self.dialogs = dialogs
        self.defaults = defaults
        let host = NSHostingController(
            rootView: AboutWindow.pane(defaults, open: open)
                .padding(.horizontal, Metrics.side).padding(.bottom, AboutPane.Metrics.window.top).frame(minWidth: Metrics.minWidth)
        )
        host.sizingOptions = []
        let window = EscapeClosingWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "About Wherever", table: "MenuBar")
        window.identifier = NSUserInterfaceItemIdentifier("about")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        fit()
        watch = TextSizeWatch(defaults) { [weak self] in self?.fit() }
    }

    private static func pane(_ defaults: UserDefaults, open: @escaping (URL) -> Void) -> some View {
        AboutPane(open: open, metrics: .window).fixedSize().defaultAppStorage(defaults)
    }

    func measure() -> CGSize {
        let pane = NSHostingController(rootView: Self.pane(defaults, open: { _ in })).sizeThatFits(in: .zero)
        return CGSize(width: max(Metrics.minWidth, pane.width + 2 * Metrics.side), height: pane.height + AboutPane.Metrics.window.top)
    }

    private func fit() {
        guard let window else { return }
        let fit = measure()
        let scale = window.backingScaleFactor
        let content = NSSize(width: (fit.width * scale).rounded(.up) / scale, height: (fit.height * scale).rounded(.up) / scale)
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        if !placed, let window {
            window.center()
            placed = true
        }
        showWindow(nil)
        if let window { dialogs.register(window) }
    }
}
