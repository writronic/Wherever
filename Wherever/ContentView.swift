import AppKit
import Combine
import Dispatch
import Foundation
import SwiftUI

struct ContentView: View {
    let index: IndexModel
    @StateObject private var model: SearchModel
    @AppStorage(WindowMode.key) private var mode = WindowMode.simple
    @AppStorage(SearchFilters.hidesHiddenKey) private var hidesHidden = false

    init(index: IndexModel, model: @escaping @autoclosure () -> SearchModel) {
        self.index = index
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        SearchView(model: model, mode: mode)
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBarView(index: index, model: model) }
            .background(ModeSwitch(mode: mode) {
                guard $0 == .simple else { return }
                model.dropNormalControls()
            })
            .background(Occlusion(model: model))
            .onAppear { model.filters.hidesHidden = hidesHidden }
            .onChange(of: hidesHidden) { model.filters.hidesHidden = $0 }
    }
}

private struct ModeSwitch: NSViewRepresentable {
    let mode: WindowMode
    let switched: @MainActor (WindowMode) -> Void

    final class Coordinator {
        var mode: WindowMode?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let old = context.coordinator.mode
        context.coordinator.mode = mode
        guard let old, old != mode else { return }
        let (mode, switched) = (mode, switched)
        DispatchQueue.main.async { [weak nsView] in
            switched(mode)
            guard let window = nsView?.window, window.firstResponder === window else { return }
            window.focusSearchField()
        }
    }
}

private struct Occlusion: NSViewRepresentable {
    let model: SearchModel

    final class Watcher: NSView {
        var model: SearchModel?
        private var watch: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watch = window.map { window in
                NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
                    .sink { [weak self, weak window] note in
                        guard let window, (note.object as? NSWindow) === window else { return }
                        self?.model?.visible = window.occlusionState.contains(.visible)
                    }
            }
            if let window { model?.visible = window.occlusionState.contains(.visible) }
        }
    }

    func makeNSView(context: Context) -> Watcher {
        let view = Watcher()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: Watcher, context: Context) {}
}
