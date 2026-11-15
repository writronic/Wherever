import AppKit
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private func menuItem(_ title: String) -> NSMenuItem? {
    func find(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if item.title == title { return item }
            if let found = find(in: item.submenu) { return found }
        }
        return nil
    }
    return find(in: NSApp.mainMenu)
}

private func perform(_ item: NSMenuItem) throws {
    let menu = try #require(item.menu)
    menu.performActionForItem(at: menu.index(of: item))
}

private func find<T: NSView>(_ type: T.Type, in root: NSView?, where matches: (T) -> Bool = { _ in true }) -> T? {
    for view in root?.subviews ?? [] {
        if let found = (view as? T).flatMap({ matches($0) ? $0 : nil }) ?? find(type, in: view, where: matches) { return found }
    }
    return nil
}

private func resultsTable(in window: NSWindow) -> NSTableView? { find(NSTableView.self, in: window.contentView) }

private func showsForm(_ window: NSWindow) -> Bool {
    find(NSPopUpButton.self, in: window.contentView) { $0.identifier?.rawValue == NormalForm.nameModeID } != nil
}

private func split(in window: NSWindow) -> InspectorSplitController? {
    find(NSSplitView.self, in: window.contentView) { $0.delegate is InspectorSplitController }?.delegate as? InspectorSplitController
}

private func cellTexts(_ table: NSTableView) -> [String] {
    (0..<table.numberOfRows).flatMap { row in
        (0..<table.numberOfColumns).compactMap { (table.view(atColumn: $0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue }
    }
}

private func withStandardDefaults(_ body: () async throws -> Void) async throws {
    let standard = UserDefaults.standard
    let keys = [WindowMode.key, InspectorPane.shownKey, SearchFilters.hidesHiddenKey]
    let before = keys.map { standard.object(forKey: $0) }
    defer {
        for (key, value) in zip(keys, before) {
            if let value { standard.set(value, forKey: key) } else { standard.removeObject(forKey: key) }
        }
    }
    standard.removeObject(forKey: WindowMode.key)
    standard.set(false, forKey: InspectorPane.shownKey)
    standard.set(false, forKey: SearchFilters.hidesHiddenKey)
    try await body()
}

private func withNewWindow(_ body: (NSWindow) async throws -> Void) async throws {
    let known = Set(NSApp.windows.filter(MainWindow.isMain).map { ObjectIdentifier($0) })
    func fresh() -> [NSWindow] { NSApp.windows.filter { MainWindow.isMain($0) && !known.contains(ObjectIdentifier($0)) } }
    let title = String(localized: "New Window", table: "MenuBar")
    try await untilTrue(waitingFor: "the \(title) item in the main menu") { menuItem(title) != nil }
    try perform(try #require(menuItem(title)))
    try await untilTrue(waitingFor: "a new main window holding the field and the table, windows now \(NSApp.windows.map { $0.identifier?.rawValue ?? "-" })") {
        fresh().contains { $0.searchField != nil && resultsTable(in: $0) != nil }
    }
    try await Task.sleep(for: .milliseconds(300))
    let windows = fresh()
    #expect(windows.count == 1, "one press opened \(windows.count) windows")
    let window = try #require(windows.first)
    func close() async throws {
        window.close()
        try await untilTrue(waitingFor: "the new window to be gone") { !window.isVisible && !fresh().contains { $0.isVisible } }
    }
    do { try await body(window) } catch {
        try await close()
        throw error
    }
    try await close()
}

private func enter(_ text: String, in window: NSWindow) throws {
    let field = try #require(window.searchField)
    try #require(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
}

private func pickMode(_ mode: WindowMode, in window: NSWindow) async throws {
    let (simple, normal) = (String(localized: "Simple"), String(localized: "Normal"))
    try await untilTrue(waitingFor: "the other mode checked in the View menu") {
        guard let s = menuItem(simple), let n = menuItem(normal) else { return false }
        return mode == .normal ? s.state == .on : n.state == .on
    }
    try perform(try #require(menuItem(mode == .normal ? normal : simple)))
    try await untilTrue(waitingFor: "the \(mode) top") { showsForm(window) == (mode == .normal) }
}

private func showInspector(in window: NSWindow) async throws {
    let show = String(localized: "Show Inspector", table: "Inspector")
    try await untilTrue(waitingFor: "\(show) in the View menu") { menuItem(show) != nil }
    try perform(try #require(menuItem(show)))
    try await untilTrue(waitingFor: "the inspector open") { split(in: window)?.inspectorItem.isCollapsed == false }
}

private func expectPlainTitleBar(of window: NSWindow, _ when: String) async throws {
    try await untilTrue(waitingFor: "the title bar set up \(when)") {
        window.styleMask.contains(.fullSizeContentView) && window.titlebarSeparatorStyle == .line
    }
    let reference = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true
    )
    reference.isReleasedWhenClosed = false
    defer { reference.close() }
    let plainArea = reference.frame.height - reference.contentLayoutRect.height
    #expect(window.toolbar == nil, "a toolbar \(when)")
    #expect(window.titlebarSeparatorStyle == .line, "the separator \(when)")
    #expect(window.styleMask.contains(.fullSizeContentView), "the style mask \(when)")
    #expect((window.frame.height - window.contentLayoutRect.height - plainArea) * window.backingScaleFactor == 0, "the title area \(when)")
}

@Suite(.serialized) struct RealWindowTests {
    @Test func aNewMainWindowListsEveryEntryAToZ() async throws {
        try await withStandardDefaults {
            for mode in [WindowMode.simple, .normal] {
                UserDefaults.standard.set(mode.rawValue, forKey: WindowMode.key)
                try await withNewWindow { window in
                    let table = try #require(resultsTable(in: window))
                    try await untilTrue(waitingFor: "the whole catalog") { table.numberOfRows == PreviewSearchClient.sample.count }
                    #expect(window.searchField?.stringValue == "")
                    #expect(showsForm(window) == (mode == .normal))
                    let name = try #require(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")))
                    #expect(name.headerCell.accessibilitySortDirection() == .ascending)
                    let names = (0..<table.numberOfRows).compactMap {
                        (table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
                    }
                    #expect(names == PreviewSearchClient.sample.map(\.name).sorted())
                }
            }
        }
    }

    @Test func aSecondWindowListsOnItsOwn() async throws {
        try await withStandardDefaults {
            try await withNewWindow { first in
                let table = try #require(resultsTable(in: first))
                try await untilTrue(waitingFor: "the first full list") { table.numberOfRows == PreviewSearchClient.sample.count }
                table.selectRowIndexes([1], byExtendingSelection: false)
                try await withNewWindow { second in
                    let other = try #require(resultsTable(in: second))
                    try await untilTrue(waitingFor: "the second full list") { other.numberOfRows == PreviewSearchClient.sample.count }
                    #expect(table.selectedRow == 1)
                    try enter("Maps", in: second)
                    try await untilTrue(waitingFor: "the second window's own search") { other.numberOfRows == 1 }
                    #expect(table.numberOfRows == PreviewSearchClient.sample.count && table.selectedRow == 1)
                    #expect(first.searchField?.stringValue == "")
                }
            }
        }
    }

    @Test func fileNewWindowOpensOneRealWindowWhoseFieldSearchesOnItsOwn() async throws {
        try await withStandardDefaults {
            try await withNewWindow { window in
                #expect(MainWindow.isMain(window))
                let field = try #require(window.searchField)
                #expect(AXTree.textField(SearchView.fieldID, in: window) === field)
                let table = try #require(resultsTable(in: window))

                try enter("Ma", in: window)
                try await untilTrue(waitingFor: "two rows for Ma, now \(table.numberOfRows)") { table.numberOfRows == 2 }
                try enter("Maps", in: window)
                try await untilTrue(waitingFor: "Maps alone, now \(table.numberOfRows) rows \(cellTexts(table))") {
                    table.numberOfRows == 1 && cellTexts(table).contains { $0.contains("Maps") }
                }
                #expect(field.stringValue == "Maps")
            }
        }
    }

    @Test func theRealWindowKeepsItsPlainTitleBarThroughModesAndTheInspector() async throws {
        try await withStandardDefaults {
            try await withNewWindow { window in
                try await expectPlainTitleBar(of: window, "when the window opens")
                try await pickMode(.normal, in: window)
                try await expectPlainTitleBar(of: window, "in Normal")
                try await pickMode(.simple, in: window)
                try await expectPlainTitleBar(of: window, "back in Simple")
                try await showInspector(in: window)
                try await expectPlainTitleBar(of: window, "with the inspector shown")
            }
        }
    }

    @Test func theInspectorButtonsAreReachableFromTheRealWindow() async throws {
        try await withStandardDefaults {
            try await withNewWindow { window in
                try await showInspector(in: window)
                #expect(AXTree.element(InspectorPane.quickLookID, in: window) == nil, "buttons with no row selected")
                try enter("Maps", in: window)
                let table = try #require(resultsTable(in: window))
                try await untilTrue(waitingFor: "one row, now \(table.numberOfRows)") { table.numberOfRows == 1 }
                try #require(window.makeFirstResponder(table))
                table.selectRowIndexes([0], byExtendingSelection: false)
                try await untilTrue(waitingFor: "Quick Look and Show in Finder under the window among \(AXTree.nodeCount(in: window)) nodes") {
                    AXTree.element(InspectorPane.quickLookID, in: window) != nil && AXTree.element(InspectorPane.showInFinderID, in: window) != nil
                }
            }
        }
    }
}
