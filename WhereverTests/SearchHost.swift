import AppKit
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

@MainActor
func untilTrue(
    within limit: Duration = .seconds(5),
    waitingFor description: @autoclosure () -> String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while !condition() {
        if ContinuousClock.now >= deadline {
            let message = description()
            try #require(ContinuousClock.now < deadline, "\(message) never came true", sourceLocation: sourceLocation)
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
enum EventQueueLock {
    private static var held = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    static func run<T>(_ body: () async throws -> T) async rethrows -> T {
        if held { await withCheckedContinuation { waiting.append($0) } } else { held = true }
        defer { if waiting.isEmpty { held = false } else { waiting.removeFirst().resume() } }
        return try await body()
    }
}

func drainEvents() {
    while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
}

func pumpEvents(for duration: Duration) async throws {
    let deadline = ContinuousClock.now.advanced(by: duration)
    while ContinuousClock.now < deadline {
        drainEvents()
        try await Task.sleep(for: .milliseconds(5))
    }
    drainEvents()
}

func pressMouse<T>(on table: NSTableView, row: Int, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1, whileDown: @escaping @MainActor () -> T) async throws -> T {
    let pressed = PressedButton<T>()
    let timer = Timer(timeInterval: 0.03, repeats: false) { _ in
        MainActor.assumeIsolated {
            pressed.seen = whileDown()
            pressed.up = try? mouseEvent(.leftMouseUp, on: table, row: row, modifiers: modifiers, clickCount: clickCount)
            if let up = pressed.up { NSApp.postEvent(up, atStart: false) }
        }
    }
    let down = try mouseEvent(.leftMouseDown, on: table, row: row, modifiers: modifiers, clickCount: clickCount)
    RunLoop.main.add(timer, forMode: .common)
    NSApp.postEvent(down, atStart: false)
    drainEvents()
    try await untilTrue(waitingFor: "the button to go up on row \(row)") { pressed.seen != nil }
    try #require(pressed.up != nil, "no mouse-up for row \(row)")
    try await pumpEvents(for: .milliseconds(30))
    return try #require(pressed.seen)
}

private final class PressedButton<T> {
    var seen: T?
    var up: NSEvent?
}

private func mouseEvent(_ type: NSEvent.EventType, on table: NSTableView, row: Int, modifiers: NSEvent.ModifierFlags, clickCount: Int) throws -> NSEvent {
    let window = try #require(table.window, "the table is in no window")
    let rect = table.rect(ofRow: row)
    return try #require(NSEvent.mouseEvent(
        with: type, location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
        clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0
    ))
}

extension SearchModel {
    var names: [String] { rows(in: 0..<count).map(\.name) }
}

final class ActionRecorder {
    var opened: [URL] = []
    var revealed: [URL] = []
    var reveals = 0
    var asked: [String] = []
    var confirms = true
    var refused = 0
    var copied: [String] = []
    var removed: [[String]] = []
    var recorded: [String] = []
    var shown: [URL?] = []
    var hides = 0
    var refreshed: [URL?] = []
    var quickLookOpen = false
    var entered: [String] = []
    var enclosings = 0

    var actions: ResultActions {
        ResultActions(
            open: { [self] in opened.append($0) },
            reveal: { [self] in
                revealed += $0
                reveals += 1
            },
            quickLook: ResultActions.QuickLook(
                isOpen: { [self] in quickLookOpen },
                show: { [self] in
                    shown.append($0)
                    quickLookOpen = true
                },
                hide: { [self] in
                    hides += 1
                    quickLookOpen = false
                },
                refresh: { [self] in refreshed.append($0) }
            ),
            copyPath: { [self] in copied.append($0) }, recordOpen: { [self] in recorded.append($0) },
            confirmOpen: { [self] in
                asked.append("open \($0)")
                return confirms
            },
            confirmReveal: { [self] in
                asked.append("reveal \($0)")
                return confirms
            },
            refuse: { [self] in refused += 1 }
        )
    }

    func actions(inside allows: @escaping (SearchHit) -> Bool, enclosing: Bool = false) -> ResultActions {
        var result = self.actions
        result.inside = ResultActions.Inside(
            allows: allows, enter: { [self] in entered.append($0.path) }, enclosing: enclosing ? { [self] in enclosings += 1 } : nil
        )
        return result
    }

    var nothingHappened: Bool {
        opened.isEmpty && revealed.isEmpty && copied.isEmpty && removed.isEmpty && recorded.isEmpty && shown.isEmpty && hides == 0 && refreshed.isEmpty
            && asked.isEmpty && refused == 0 && entered.isEmpty && enclosings == 0
    }
}

func hostStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.host"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
}

final class SearchHost {
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        " ": 49, "\u{7f}": 51,
    ]

    let window: NSWindow
    let view: NSView
    let recorder = ActionRecorder()
    private var keyGuard: Any?

    convenience init(index: IndexModel, model: SearchModel, reportsKey: Bool = false) {
        self.init(root: AnyView(ContentView(index: index, model: model)), reportsKey: reportsKey)
    }

    init(root: AnyView, reportsKey: Bool = false, actions: ResultActions? = nil, guardsKeys: Bool = true) {
        let controller = NSHostingController(
            rootView: AnyView(root.environment(\.resultActions, actions ?? recorder.actions).defaultAppStorage(hostStore()))
        )
        let keyed = reportsKey ? KeyedWindow(contentViewController: controller) : nil
        window = keyed ?? NSWindow(contentViewController: controller)
        view = controller.view
        window.setContentSize(NSSize(width: SearchMetrics.windowMinWidth, height: SearchMetrics.windowMinHeight))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        if let keyed, !keyed.isKeyWindow {
            keyed.reportsKey = true
            keyed.becomeKey()
        }
        guard guardsKeys else { return }
        keyGuard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window = self.window] event in
            let ours = MainActor.assumeIsolated { window.map { (event.window ?? NSApp.keyWindow) === $0 } ?? false }
            return ours ? nil : event
        }
    }

    func becomeKey() { window.becomeKey() }

    func resignKey() { window.resignKey() }

    func close() {
        if let keyGuard { NSEvent.removeMonitor(keyGuard) }
        keyGuard = nil
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

    func type(_ text: String) async throws {
        let field = try await searchField()
        if !fieldHasFocus { try #require(window.makeFirstResponder(field)) }
        try sendKeys(text)
    }

    func sendKeys(_ text: String) throws {
        for character in text {
            let key = String(character)
            let code = try #require(Self.keyCodes[character], "no key code for \(key)")
            try send(key, code: code)
        }
    }

    func pressEscape() throws { try send("\u{1b}", code: 53) }

    func pressDelete(forward: Bool = false, flags: NSEvent.ModifierFlags = []) throws {
        guard forward else { return try send("\u{7f}", code: 51, flags: flags) }
        try send(String(Character(NSEvent.SpecialKey.deleteForward.unicodeScalar)), code: 117, flags: flags.union(.function))
    }

    func press(_ arrow: NSEvent.SpecialKey, flags: NSEvent.ModifierFlags = []) throws {
        let codes: [NSEvent.SpecialKey: UInt16] = [.upArrow: 126, .downArrow: 125, .leftArrow: 123, .rightArrow: 124]
        let code = try #require(codes[arrow], "no key code for \(arrow)")
        try send(String(Character(arrow.unicodeScalar)), code: code, flags: flags.union([.numericPad, .function]))
    }

    func clickClear() async throws {
        let field = try await searchField()
        let cancel = try #require((field.cell as? NSSearchFieldCell)?.cancelButtonCell)
        let action = try #require(cancel.action)
        try #require(NSApp.sendAction(action, to: cancel.target, from: cancel))
    }

    func pressReturn(command: Bool = false) throws {
        try send("\r", code: 36, flags: command ? [.command] : [])
    }

    private func send(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: code
        ))
        if flags.contains(.command), window.performKeyEquivalent(with: event) { return }
        window.sendEvent(event)
    }

    func doubleClick(row: Int) throws {
        let table = try #require(list())
        let rect = table.rect(ofRow: row)
        try postClicks(at: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), counts: 1...2)
    }

    func postClicks(at point: NSPoint, counts: ClosedRange<Int>, modifiers: NSEvent.ModifierFlags = []) throws {
        let start = ProcessInfo.processInfo.systemUptime
        var events: [NSEvent] = []
        for clicks in counts {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                events.append(try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: modifiers, timestamp: start + Double(events.count) * 0.008,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks,
                    pressure: type == .leftMouseDown ? 1 : 0
                )))
            }
        }
        for event in events { NSApp.postEvent(event, atStart: false) }
    }

    func click(row: Int, modifiers: NSEvent.ModifierFlags = []) throws {
        let table = try #require(list())
        let rect = table.rect(ofRow: row)
        try postClicks(at: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), counts: 1...1, modifiers: modifiers)
    }

    func sendQueuedEvents() { drainEvents() }

    func keyViewLoop(from start: NSView) -> [NSView] {
        window.recalculateKeyViewLoop()
        var loop: [NSView] = [start]
        while let next = loop.last?.nextValidKeyView, next !== field(), !loop.contains(where: { $0 === next }) { loop.append(next) }
        return loop
    }

    func copyTarget() -> NSResponder? {
        var responder = window.firstResponder
        while let current = responder, !current.responds(to: NSSelectorFromString("copy:")) { responder = current.nextResponder }
        return responder
    }

    func windowShows(_ text: String) -> Bool { shows(text, in: view) }

    func shows(_ text: String, in root: NSView?) -> Bool {
        guard let root else { return false }
        return ([root] + descendants(NSView.self, in: root)).flatMap { texts(in: $0) }.contains { $0.contains(text) }
    }

    func focusList() async throws {
        try await until("the list") { self.list() != nil }
        try #require(window.makeFirstResponder(list()))
    }

    func pressTab(backward: Bool = false) throws {
        let character = backward ? "\u{19}" : "\t"
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: backward ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: 48
        ))
        window.sendEvent(event)
    }

    func clear() async throws {
        let field = try await searchField()
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    var fieldHasFocus: Bool {
        field()?.currentEditor().map { window.firstResponder === $0 } ?? false
    }

    var listHasFocus: Bool {
        list().map { window.firstResponder === $0 } ?? false
    }

    func shows(_ text: String) -> Bool {
        listedTexts().contains { $0.contains(text) }
    }

    private func searchField() async throws -> NSSearchField {
        try await until("the search field among \(AXTree.nodeCount(in: window)) accessibility nodes") { self.field() != nil }
        return try #require(field())
    }

    func field() -> NSSearchField? { window.searchField }

    func list() -> NSTableView? {
        descendants(NSTableView.self, in: view).first
    }

    private func listedTexts() -> [String] {
        guard let table = list() else { return [] }
        let visible = table.rows(in: table.visibleRect)
        return (visible.location..<visible.location + visible.length).flatMap { row in
            (0..<table.numberOfColumns).compactMap { column in
                (table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField?.stringValue
            }
        }
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
