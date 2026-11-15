import AppKit
import Carbon
import Testing

enum AXTree {
    static func value<T>(_ key: String, of element: NSObject) -> T? {
        element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) as? T : nil
    }

    static func elements(in root: NSObject) -> [NSObject] {
        if root is NSTableView { return [root] }
        let children: [NSObject] = value("accessibilityChildren", of: root) ?? []
        return [root] + children.flatMap { elements(in: $0) }
    }

    static func identifier(of element: NSObject) -> String? { value("accessibilityIdentifier", of: element) }

    static func names(of element: NSObject) -> [String] {
        var own: [String] = ["accessibilityLabel", "accessibilityTitle"].compactMap { value($0, of: element) }
        if value("accessibilityRole", of: element) as String? == NSAccessibility.Role.staticText.rawValue,
           let text: String = value("accessibilityValue", of: element) { own.append(text) }
        let titleElement: NSObject? = value("accessibilityTitleUIElement", of: element)
        return own + [titleElement.flatMap { value("accessibilityValue", of: $0) as String? }].compactMap { $0 }
    }

    static func element(_ id: String, in root: NSObject) -> NSObject? {
        elements(in: root).first { identifier(of: $0) == id }
    }

    static func control(_ name: String, in root: NSView) -> NSObject? {
        let roles = [NSAccessibility.Role.button, .checkBox, .popUpButton].map(\.rawValue)
        return elements(in: root).first { element in
            (value("accessibilityRole", of: element) as String?).map { roles.contains($0) } == true && names(of: element).contains(name)
        }
    }

    static func textField(_ id: String, in root: NSObject) -> NSTextField? {
        (element(id, in: root) as? NSCell)?.controlView as? NSTextField
    }

    static func focusedIdentifier(in root: NSView) -> String? {
        elements(in: root).filter { (value("isAccessibilityFocused", of: $0) as Bool?) == true }
            .compactMap(identifier(of:)).first { !$0.isEmpty }
    }

    static func isOn(_ element: NSObject) -> Bool? { value("accessibilityValue", of: element) }

    static func isEnabled(_ element: NSObject) -> Bool? { value("isAccessibilityEnabled", of: element) }

    static func frame(of element: NSObject) -> NSRect? { value("accessibilityFrame", of: element) }

    static func focusedElement(of object: NSObject) -> NSObject? { value("accessibilityFocusedUIElement", of: object) }

    static func press(_ element: NSObject) -> Bool {
        let press = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: press) else { return false }
        _ = element.perform(press)
        return true
    }

    static func nodeCount(in root: NSObject) -> Int { elements(in: root).count }

    static func choose(_ menu: NSObject, item index: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await EventQueueLock.run {
            let state = Tracking()
            NotificationCenter.default.addObserver(state, selector: #selector(Tracking.began(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
            NotificationCenter.default.addObserver(state, selector: #selector(Tracking.finished(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
            let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                MainActor.assumeIsolated { step(state, to: index) }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            defer {
                timer.invalidate()
                NotificationCenter.default.removeObserver(state)
                if let window = openMenu() { post("\u{1b}", code: UInt16(kVK_Escape), to: window) }
            }
            try #require(press(menu), "the menu took no press")
            try await untilTrue(
                waitingFor: "the menu to open, highlight item \(index) of \(state.titles) and close; the highlight started on "
                    + "\(state.start ?? "nothing seen") and ended on \(state.last ?? "nothing seen"); its tracking ended: \(state.closed)",
                sourceLocation: sourceLocation
            ) { state.sent && state.closed && openMenu() == nil }
        }
    }

    private final class Tracking: NSObject {
        var menu: NSMenu?
        var titles: [String] = []
        var start: String?
        var last: String?
        var arrowFrom: Int??
        var sent = false
        var closed = false

        @objc func began(_ note: Notification) {
            if menu == nil { menu = note.object as? NSMenu }
        }

        @objc func finished(_ note: Notification) {
            if let menu, note.object as? NSMenu === menu { closed = true }
        }
    }

    private static func step(_ state: Tracking, to index: Int) {
        guard !state.sent, let menu = state.menu, let window = openMenu() else { return }
        let items = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && $0.isEnabled }
        let current = menu.highlightedItem.flatMap { items.firstIndex(of: $0) }
        state.titles = items.map(\.title)
        state.last = menu.highlightedItem?.title ?? "no item"
        if state.start == nil { state.start = state.last }
        if let from = state.arrowFrom {
            guard current != from else { return }
            state.arrowFrom = nil
        }
        guard items.indices.contains(index) else { return }
        if current == index {
            post("\r", code: UInt16(kVK_Return), to: window)
            state.sent = true
        } else if let current, current > index {
            post("\u{F700}", code: UInt16(kVK_UpArrow), to: window)
            state.arrowFrom = .some(current)
        } else {
            post("\u{F701}", code: UInt16(kVK_DownArrow), to: window)
            state.arrowFrom = .some(current)
        }
    }

    private static func openMenu() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.level == .popUpMenu }
    }

    private static func post(_ key: String, code: UInt16, to window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: code
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
