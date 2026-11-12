import AppKit
import SwiftUI

struct LaunchGate: NSViewRepresentable {
    var ask: () -> Void = {}

    func makeNSView(context: Context) -> NSView { GateView(ask: ask) }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class GateView: NSView {
        private let ask: () -> Void

        init(ask: @escaping () -> Void) {
            self.ask = ask
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.alphaValue = 0
            ask()
            Task { [weak window] in window?.close() }
        }
    }
}
