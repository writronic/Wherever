import AppKit
import SwiftUI
import Testing
@testable import Wherever

final class StatusHost {
    let window: KeyedWindow
    let view: NSView

    init(client: FakeSearchClient, locale: Locale, withBar: Bool = true) {
        let index = IndexModel(client: client)
        let root = withBar
            ? AnyView(ContentView(index: index, model: index.makeModel()))
            : AnyView(SearchView(model: index.makeModel()))
        let controller = NSHostingController(rootView: AnyView(
            root.environment(\.locale, locale).environment(\.resultActions, ActionRecorder().actions).defaultAppStorage(hostStore())
        ))
        window = KeyedWindow(contentViewController: controller)
        view = controller.view
        window.setContentSize(NSSize(width: SearchMetrics.windowMinWidth, height: SearchMetrics.windowMinHeight))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            window.reportsKey = true
            window.becomeKey()
        }
    }

    func close() {
        window.contentViewController = nil
        window.close()
    }

    func until(
        _ description: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        try await untilTrue(waitingFor: description(), sourceLocation: sourceLocation) {
            view.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    func shows(_ text: String) -> Bool {
        labels().contains { $0.contains(text) }
    }

    func oneElementReads(_ texts: [String]) -> Bool {
        labels().contains { label in texts.allSatisfy { label.contains($0) } }
    }

    func focusField() async throws {
        try await until("the search field among \(AXTree.nodeCount(in: window)) accessibility nodes") { self.field() != nil }
        let field = try #require(field())
        try #require(window.makeFirstResponder(field))
        try #require(field.currentEditor() != nil)
    }

    func tabStops() async throws -> [String] {
        var stops: [String] = []
        for forward in [true, true, true, true, false, false, false, false] {
            try press(tab: forward)
            try await Task.sleep(for: .milliseconds(20))
            stops.append(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")
        }
        return stops
    }

    private func press(tab: Bool) throws {
        let character = tab ? "\t" : "\u{19}"
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: tab ? [] : [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 48
        ))
        window.sendEvent(event)
    }

    private func field() -> NSTextField? {
        AXTree.textField(SearchView.fieldID, in: window).flatMap { $0.isEditable ? $0 : nil }
    }

    private func labels() -> [String] {
        ([view] + descendants(NSView.self, in: view)).flatMap { texts(in: $0) }
    }

    private func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + descendants(type, in: $0) }
    }

    private func texts(in object: NSObject) -> [String] {
        var found = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { key in
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) as? String : nil
        }
        if object.responds(to: NSSelectorFromString("accessibilityChildren")) {
            for child in object.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] { found += texts(in: child) }
        }
        return found
    }
}
