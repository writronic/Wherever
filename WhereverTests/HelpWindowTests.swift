import AppKit
import Carbon
import Foundation
import SwiftUI
import Testing
@testable import Wherever

private func shortcutsTitle() -> String {
    Bundle.main.localizedString(forKey: "Keyboard Shortcuts", value: nil, table: "Help")
}

private func visibleShortcuts() -> [NSWindow] {
    NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue == KeyboardShortcutsWindow.windowID }
}

private func helpItem() -> NSMenuItem? {
    func find(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if item.title == shortcutsTitle() { return item }
            if let found = find(in: item.submenu) { return found }
        }
        return nil
    }
    return find(in: NSApp.mainMenu)
}

private func texts(in root: NSObject) -> [String] {
    AXTree.elements(in: root).flatMap { AXTree.names(of: $0) }
}

private func hotkeyModel(_ name: String) -> HotkeyModel {
    let suite = "com.writronic.wherever.tests.help.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return HotkeyModel(defaults: defaults, windows: { [] }, unhide: {}, activate: {})
}

private func escape(_ window: NSWindow) throws {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: UInt16(kVK_Escape)
    ))
    (window.firstResponder ?? window).keyDown(with: event)
}

private let unbounded = NSRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)

private final class Screen {
    var visible: NSRect
    init(_ visible: NSRect) { self.visible = visible }
}

private func isDevicePixelAligned(_ value: CGFloat, _ window: NSWindow) -> Bool {
    let pixels = value * window.backingScaleFactor
    return pixels.rounded() == pixels
}

private func scrollsToTheLastRow(_ window: NSWindow) throws -> Bool {
    let scroll = try #require(window.contentView as? NSScrollView)
    let document = try #require(scroll.documentView)
    document.scrollToVisible(NSRect(x: 0, y: document.bounds.maxY - 1, width: 1, height: 1))
    return scroll.contentView.documentVisibleRect.maxY == document.bounds.maxY
}

private func pixels(_ view: some View) throws -> Data {
    let host = NSHostingView(rootView: view.fixedSize())
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return try #require(rep.tiffRepresentation)
}

@Suite(.serialized) struct HelpWindowTests {
    @Test func theHelpItemOpensOneWindowThatShowsEveryRow() async throws {
        try await untilTrue(waitingFor: "the Help menu's \(shortcutsTitle()) item") { helpItem() != nil }
        let item = try #require(helpItem())
        #expect(item.action != #selector(NSApplication.showHelp(_:)))
        let menu = try #require(item.menu)
        defer { visibleShortcuts().forEach { $0.close() } }
        menu.performActionForItem(at: menu.index(of: item))
        try await untilTrue(waitingFor: "the Keyboard Shortcuts window") { !visibleShortcuts().isEmpty }
        let window = try #require(visibleShortcuts().first)
        #expect(window.title == shortcutsTitle())
        #expect(!MainWindow.isMain(window))

        let current = HotkeyModel(windows: { [] }, unhide: {}, activate: {}).hotkey
        let sections = KeyboardShortcuts.sections(hotkey: current)
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "the table") { AXTree.element(KeyboardShortcutsWindow.tableID, in: content) != nil }
        let table = try #require(AXTree.element(KeyboardShortcutsWindow.tableID, in: content))
        let tableTexts = texts(in: table)
        var found = 0
        for (s, section) in sections.enumerated() {
            #expect(tableTexts.contains(section.title))
            for (r, row) in section.rows.enumerated() {
                let element = try #require(AXTree.element(KeyboardShortcutsWindow.rowID(section: s, row: r), in: table), "row \(s)-\(r)")
                let shown = texts(in: element)
                #expect(shown.contains(row.keys), "row \(s)-\(r) lacks \(row.keys)")
                #expect(shown.contains(row.action), "row \(s)-\(r) lacks \(row.action)")
                found += 1
            }
            #expect(AXTree.element(KeyboardShortcutsWindow.rowID(section: s, row: section.rows.count), in: table) == nil)
        }
        #expect(found == sections.map(\.rows.count).reduce(0, +))
        #expect(found > 30)

        let again = try #require(helpItem())
        let againMenu = try #require(again.menu)
        againMenu.performActionForItem(at: againMenu.index(of: again))
        #expect(visibleShortcuts().count == 1)
        #expect(visibleShortcuts().first === window)

        window.makeFirstResponder(nil)
        try escape(window)
        #expect(!window.isVisible)
    }

    @available(macOS 26.0, *)
    @Test func everyKeyAndExampleReadsAsTypedInARightToLeftLayout() throws {
        let font = TextSize.standard.monospacedBody
        func rightToLeft(_ view: some View) throws -> Data { try pixels(view.writingDirection(strategy: .layoutBased).environment(\.layoutDirection, .rightToLeft)) }
        func typed(_ keys: String) throws -> Data { try rightToLeft(Text(verbatim: "\u{200e}\(keys)\u{200e}").font(font)) }
        let mirrored = try rightToLeft(Text(verbatim: "!draft").font(font))
        #expect(mirrored != (try typed("!draft")), "a right-to-left paragraph moves the leading ! of !draft to the end")
        var reversed: [String] = []
        for section in KeyboardShortcuts.sections(hotkey: .summon) {
            for row in section.rows {
                let shown = try rightToLeft(KeyboardShortcutsView.keysText(row.keys, font: font))
                if shown != (try typed(row.keys)) { reversed.append(row.keys) }
            }
        }
        #expect(reversed.isEmpty, "these read in another order than they are typed: \(reversed)")
    }

    @Test func searchWindowListsCommandDown() {
        let rows = KeyboardShortcuts.sections(hotkey: .summon)[0].rows
        let archive = Bundle.main.localizedString(forKey: "Show archive contents", value: nil, table: "Help")
        #expect(rows.contains { $0.keys == "⌘↓" && $0.action == archive })
    }

    @Test func searchWindowListsReturnInFileContent() {
        let key = "In File content, start Search Content when no text is left"
        #expect(Bundle.main.localizedString(forKey: key, value: "\u{1}", table: "Help") != "\u{1}")
        let rows = KeyboardShortcuts.sections(hotkey: .summon)[0].rows
        let open = rows.firstIndex { $0.keys == "↩" }
        #expect(open != nil)
        #expect(rows[(open ?? 0) + 1].keys == "↩")
        #expect(rows[(open ?? 0) + 1].action == Bundle.main.localizedString(forKey: key, value: nil, table: "Help"))
    }

    @Test func whereverSearchListsCommandDownAfterCommandReturn() throws {
        func help(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: nil, table: "Help") }
        let section = KeyboardShortcuts.sections(hotkey: .summon)[1]
        #expect(section.title == help("Wherever search"))
        let archive = help("Show archive contents in Wherever")
        #expect(Bundle.main.localizedString(forKey: "Show archive contents in Wherever", value: "\u{1}", table: "Help") != "\u{1}")
        let reveal = try #require(section.rows.firstIndex { $0.keys == "⌘↩" })
        #expect(section.rows[reveal + 1].keys == "⌘↓")
        #expect(section.rows[reveal + 1].action == archive)
        #expect(section.rows.filter { $0.keys == "⌘↓" }.count == 1)
        #expect(section.rows[0].keys == Hotkey.summon.displayString)
    }

    @Test func archiveWindowSectionListsItsKeys() throws {
        func help(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: nil, table: "Help") }
        let sections = KeyboardShortcuts.sections(hotkey: .summon)
        let section = try #require(sections.first { $0.title == help("Archive window") })
        let open = help("Open the item, the folder or the archive")
        let space = Bundle.main.localizedString(forKey: "Space", value: nil, table: "Hotkey")
        let expected = [
            ("↩", open), ("⌘↓", open), ("⌘↑", help("Go to the enclosing folder")), (space, help("Show or close Quick Look")),
            ("⌘↩", help("Show the archive in Finder")), ("⌘C", help("Copy the path inside the archive")), ("⎋", help("Clear the search text")),
        ]
        #expect(section.rows.prefix(expected.count).map(\.keys) == expected.map(\.0))
        #expect(section.rows.prefix(expected.count).map(\.action) == expected.map(\.1))
        #expect(sections[1].rows[0].keys == Hotkey.summon.displayString)
    }

    @Test func archiveSectionListsTheEditKeys() throws {
        func help(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: nil, table: "Help") }
        let section = try #require(KeyboardShortcuts.sections(hotkey: .summon).first { $0.title == help("Archive window") })
        let expected = [
            ("⌫", "Delete the selected items"), ("⌘S", "Save the changes"), ("⇧⌘S", "Save the archive under a new name"),
            ("⌘Z", "Undo the last change"), ("⇧⌘Z", "Redo the last change"),
        ]
        for (_, key) in expected {
            #expect(Bundle.main.localizedString(forKey: key, value: "\u{1}", table: "Help") != "\u{1}", "\(key) has no Help string")
        }
        let tail = Array(section.rows.suffix(expected.count))
        #expect(tail.map(\.keys) == expected.map(\.0))
        #expect(tail.map(\.action) == expected.map { help($0.1) })
        #expect(section.rows.count == 12)
    }

    @Test func theLauncherRowFollowsTheRecordedKey() async throws {
        let model = hotkeyModel("launcher")
        let shortcuts = KeyboardShortcutsWindow(hotkey: model, defaults: hostStore())
        defer { shortcuts.window?.close() }
        shortcuts.show()
        let window = try #require(shortcuts.window)
        #expect(window.styleMask == [.titled, .closable])
        #expect(window.identifier?.rawValue == KeyboardShortcutsWindow.windowID)
        #expect(!window.isReleasedWhenClosed)
        let content = try #require(window.contentView)
        let launcherKey = KeyboardShortcutsWindow.rowID(section: 1, row: 0)
        func keys() -> [String] { AXTree.element(launcherKey, in: content).map(texts(in:)) ?? [] }
        try await untilTrue(waitingFor: "the launcher row with ⌃⇧F, not \(keys())") { keys().contains(Hotkey.summon.displayString) }
        let size = window.frame.size

        let other = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | cmdKey | controlKey | shiftKey), character: " ")
        model.set(other)
        try await untilTrue(waitingFor: "the launcher row with \(other.displayString), not \(keys())") { keys().contains(other.displayString) }
        model.set(nil)
        try await untilTrue(waitingFor: "the launcher row with no key, not \(keys())") { keys().contains("–") }
        #expect(window.frame.size == size)
    }

    @Test(arguments: ["ar", "vi", "en"]) func theShortcutsAreNeverShorterAtALargerTextSize(_ language: String) {
        let suite = "com.writronic.wherever.tests.help.tall.store.\(language)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let model = hotkeyModel("tall.\(language)")
        let heights = [TextSize.standard, .larger, .maximum].map { size in
            store.set(size.rawValue, forKey: TextSize.key)
            let view = KeyboardShortcutsView(hotkey: model).fixedSize().defaultAppStorage(store)
            return NSHostingController(rootView: view.typesettingLanguage(.explicit(Locale.Language(identifier: language)))).sizeThatFits(in: .zero).height
        }
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 < $1 }, "the shortcuts in \(language) at 13, 14 and 18 pt: \(heights)")
    }

    @Test func aLiveTextSizeChangeWidensTheWindowAndKeepsItsTopLeftCorner() async throws {
        let store = hostStore()
        let shortcuts = KeyboardShortcutsWindow(hotkey: hotkeyModel("textsize"), defaults: store, visibleFrame: { _ in unbounded })
        defer { shortcuts.window?.close() }
        shortcuts.show()
        let window = try #require(shortcuts.window)
        let before = window.frame
        let standard = 2 * KeyboardShortcutsView.Metrics.actionWidth + KeyboardShortcutsView.Metrics.keysWidth + KeyboardShortcutsView.Metrics.exampleWidth
        let largest = 2 * TextSize.maximum.width(KeyboardShortcutsView.Metrics.actionWidth) + TextSize.maximum.width(KeyboardShortcutsView.Metrics.keysWidth)
            + TextSize.maximum.width(KeyboardShortcutsView.Metrics.exampleWidth)
        store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        try await untilTrue(waitingFor: "the window to widen from \(before)") { window.frame.width > before.width }
        #expect(window.frame.width - before.width >= largest - standard)
        #expect(window.frame.minX - before.minX == 0)
        #expect(window.frame.maxY - before.maxY == 0)
    }

    @Test(arguments: [TextSize.standard, .maximum])
    func aShortScreenCapsTheWindowAndScrollsToEveryRow(_ size: TextSize) async throws {
        let store = hostStore()
        store.set(size.rawValue, forKey: TextSize.key)
        let short = NSRect(x: 0, y: 100, width: 1440, height: 500.25)
        let shortcuts = KeyboardShortcutsWindow(hotkey: hotkeyModel("short.\(size.rawValue)"), defaults: store, visibleFrame: { _ in short })
        defer { shortcuts.window?.close() }
        shortcuts.show()
        let window = try #require(shortcuts.window)
        let scroll = try #require(window.contentView as? NSScrollView, "the rows sit in a scroll view")
        let document = try #require(scroll.documentView)
        #expect(window.frame.height <= short.height, "\(window.frame) on \(short)")
        #expect(window.frame.minY >= short.minY && window.frame.maxY <= short.maxY, "\(window.frame) on \(short)")
        #expect(isDevicePixelAligned(window.frame.height, window) && isDevicePixelAligned(window.frame.minY, window), "\(window.frame)")
        #expect(document.frame.height > scroll.contentView.bounds.height, "the rows are taller than the window, so they scroll")
        #expect(scroll.contentView.bounds.width >= document.frame.width, "both columns keep their width")

        let sections = KeyboardShortcuts.sections(hotkey: Hotkey.summon)
        let last = sections.count - 1
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "the last row") {
            AXTree.element(KeyboardShortcutsWindow.rowID(section: last, row: sections[last].rows.count - 1), in: content) != nil
        }
        for (s, section) in sections.enumerated() {
            for r in section.rows.indices {
                #expect(AXTree.element(KeyboardShortcutsWindow.rowID(section: s, row: r), in: content) != nil, "row \(s)-\(r)")
            }
        }
        #expect(try scrollsToTheLastRow(window))
    }

    @Test func aTallScreenShowsEveryRowWithoutScrolling() async throws {
        let store = hostStore()
        let shortcuts = KeyboardShortcutsWindow(hotkey: hotkeyModel("tall.screen"), defaults: store, visibleFrame: { _ in unbounded })
        defer { shortcuts.window?.close() }
        shortcuts.show()
        let window = try #require(shortcuts.window)
        let scroll = try #require(window.contentView as? NSScrollView)
        let document = try #require(scroll.documentView)
        #expect(scroll.contentView.bounds.height == document.frame.height, "\(scroll.contentView.bounds) for \(document.frame)")
        #expect(scroll.contentView.bounds.width == document.frame.width)
    }

    @Test func aScreenChangeRefitsTheWindowBothWays() async throws {
        let store = hostStore()
        let screen = Screen(unbounded)
        let shortcuts = KeyboardShortcutsWindow(hotkey: hotkeyModel("screen.change"), defaults: store, visibleFrame: { _ in screen.visible })
        defer { shortcuts.window?.close() }
        shortcuts.show()
        let window = try #require(shortcuts.window)
        let full = window.frame.height
        let short = NSRect(x: 0, y: 200, width: 1440, height: (full / 2).rounded(.down))

        screen.visible = short
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        try await untilTrue(waitingFor: "the window to fit \(short), not \(window.frame)") {
            window.frame.height <= short.height && window.frame.minY >= short.minY && window.frame.maxY <= short.maxY
        }
        #expect(try scrollsToTheLastRow(window))

        screen.visible = unbounded
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        try await untilTrue(waitingFor: "the full height \(full) again, not \(window.frame)") { window.frame.height == full }
    }

    @Test func aLargerTextSizeOnAShortScreenStaysOnTheScreen() async throws {
        let store = hostStore()
        let short = NSRect(x: 0, y: 80, width: 1440, height: 600)
        let shortcuts = KeyboardShortcutsWindow(hotkey: hotkeyModel("short.textsize"), defaults: store, visibleFrame: { _ in short })
        defer { shortcuts.window?.close() }
        shortcuts.show()
        let window = try #require(shortcuts.window)
        let before = window.frame
        store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        try await untilTrue(waitingFor: "the window to widen from \(before)") { window.frame.width > before.width }
        #expect(window.frame.height <= short.height && window.frame.minY >= short.minY && window.frame.maxY <= short.maxY, "\(window.frame)")
        #expect(try scrollsToTheLastRow(window))
    }
}
