import AppKit
import SwiftUI
import WhereverInterface

struct SearchView: View {
    static let fieldID = "search-field"

    @ObservedObject var model: SearchModel
    var mode = WindowMode.simple
    var bundle: Bundle = .main

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .simple:
                SearchField(model: model, bundle: bundle, roundedRectangle: true)
                    .controlSize(.large)
                    .padding(.vertical, SearchMetrics.fieldInset)
                    .padding(.horizontal, SearchMetrics.sideInset)
                Divider()
            case .normal:
                NormalForm(model: model, bundle: bundle)
                    .padding(.horizontal, SearchMetrics.sideInset)
                Divider()
                FilterBar(filters: $model.filters)
                Divider()
            }
            ResultsPane(model: model)
        }
        .frame(minWidth: mode == .simple ? SearchMetrics.windowMinWidth : nil, minHeight: SearchMetrics.windowMinHeight)
        .themedWindowBackground()
        .background(WindowStyle())
        .background(KeyViewRestorer())
    }
}

private struct WindowStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> Styler { Styler() }
    func updateNSView(_ nsView: Styler, context: Context) {}

    final class Styler: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarSeparatorStyle = .line
        }
    }
}

private struct KeyViewRestorer: NSViewRepresentable {
    func makeNSView(context: Context) -> Watcher { Watcher() }
    func updateNSView(_ nsView: Watcher, context: Context) {}

    final class Watcher: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window
            )
        }

        @objc private func windowDidBecomeKey() {
            guard let window, window.firstResponder === window else { return }
            window.focusSearchField()
        }
    }
}
