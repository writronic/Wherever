import AppKit
import Dispatch
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private func modeStore(_ mode: String? = nil, inspectorShown: Bool = false) -> UserDefaults {
    let name = "com.writronic.wherever.tests.modeswitch"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    if let mode { store.set(mode, forKey: WindowMode.key) }
    if inspectorShown { store.set(true, forKey: InspectorPane.shownKey) }
    return store
}

private func hits(_ names: [String]) -> [SearchHit] {
    names.map { SearchHit(name: $0, folder: "/Users/test/Documents", size: 1_000, modified: Date(), created: .distantPast, opened: .distantPast, kind: .file) }
}

private func find<T: NSView>(_ type: T.Type, in root: NSView, where matches: (T) -> Bool = { _ in true }) -> T? {
    for view in root.subviews {
        if let found = (view as? T).flatMap({ matches($0) ? $0 : nil }) ?? find(type, in: view, where: matches) { return found }
    }
    return nil
}

@MainActor
private struct ModeRig {
    let fake: FakeSearchClient
    let index: IndexModel
    let model: SearchModel
    let host: SearchHost

    init(store: UserDefaults, hits: [SearchHit] = []) {
        let fake = FakeSearchClient(hits: hits)
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        self.fake = fake
        self.index = index
        self.model = model
        host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.searchClient, fake).defaultAppStorage(store)))
    }

    var showsForm: Bool { find(NSPopUpButton.self, in: host.view) { $0.identifier?.rawValue == NormalForm.nameModeID } != nil }

    func untilMode(_ mode: WindowMode) async throws {
        try await host.until("the \(mode) top") { host.field() != nil && showsForm == (mode == .normal) }
    }

    var buttonIsInsideWindow: Bool {
        guard let button = find(NSButton.self, in: host.view, where: { $0.identifier?.rawValue == NormalForm.searchContentID }) else { return false }
        guard let row = button.superview else { return false }
        let frame = host.window.convertToScreen(row.convert(button.alignmentRect(forFrame: button.frame), to: nil))
        let area = host.window.convertToScreen(host.window.contentLayoutRect).insetBy(dx: SearchMetrics.sideInset, dy: 0)
        return frame.minX >= area.minX && frame.maxX <= area.maxX
    }

    func split() -> InspectorSplitController? {
        find(NSSplitView.self, in: host.view) { $0.delegate is InspectorSplitController }?.delegate as? InspectorSplitController
    }

    func search(_ query: String, count: Int) async throws {
        model.query = query
        fake.send(.resultsReady(fake.latest, count: count))
        try await host.until("\(count) rows for \(query)") { !model.isPending && host.list()?.numberOfRows == count }
    }

    func select(_ row: Int) async throws {
        try await host.focusList()
        try #require(host.list()).selectRowIndexes([row], byExtendingSelection: false)
    }

    func queryEnds(_ expected: String) async throws {
        try await host.until("the query \(expected); sent \(fake.queries)") { fake.queries.last == expected }
    }
}

@MainActor
private func mainQueueTurn() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
}

private let tabActions: Set<Selector> = [NSSelectorFromString("toggleTabBar:"), NSSelectorFromString("toggleTabOverview:")]

private func mainMenuItem(_ title: String) -> NSMenuItem? {
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

@MainActor
private func withStandardMode(_ value: String?, _ body: () async throws -> Void) async throws {
    let standard = UserDefaults.standard
    let before = standard.object(forKey: WindowMode.key)
    defer { if let before { standard.set(before, forKey: WindowMode.key) } else { standard.removeObject(forKey: WindowMode.key) } }
    if let value { standard.set(value, forKey: WindowMode.key) } else { standard.removeObject(forKey: WindowMode.key) }
    try await body()
}

private struct ModeItems {
    let simple: NSMenuItem
    let normal: NSMenuItem

    @MainActor
    static func checked(_ mode: WindowMode) async throws -> ModeItems {
        let (simple, normal) = (String(localized: "Simple"), String(localized: "Normal"))
        try await untilTrue(waitingFor: "\(mode) checked in the View menu") {
            guard let s = mainMenuItem(simple), let n = mainMenuItem(normal) else { return false }
            return (s.state == .on) == (mode == .simple) && (n.state == .on) == (mode == .normal)
        }
        return try ModeItems(simple: #require(mainMenuItem(simple)), normal: #require(mainMenuItem(normal)))
    }

    @MainActor
    func perform(_ item: NSMenuItem) throws {
        let menu = try #require(item.menu)
        menu.performActionForItem(at: menu.index(of: item))
    }
}

@Suite(.serialized) struct ModeSwitchTests {
    @Test func theViewMenuStartsWithSimpleCheckedThenNormal() async throws {
        try await withStandardMode(nil) {
            let items = try await ModeItems.checked(.simple)
            let menu = try #require(items.simple.menu)
            let tabItems = menu.items.filter { $0.action.map(tabActions.contains) == true }
            #expect(tabItems.isEmpty, "tab items in the View menu: \(tabItems.map(\.title))")
            #expect(menu.items.first?.title == items.simple.title, "the View menu reads \(menu.items.map(\.title))")
            #expect(menu.index(of: items.normal) == menu.index(of: items.simple) + 1)
            #expect(items.simple.state == .on)
            #expect(items.normal.state == .off)
            let divider = menu.index(of: items.normal) + 1
            #expect(divider < menu.items.count && menu.items[divider].isSeparatorItem, "a divider after Normal")
        }
    }

    @Test func pickingNormalChecksItAndStoresIt() async throws {
        try await withStandardMode(nil) {
            let items = try await ModeItems.checked(.simple)
            try items.perform(items.normal)
            try await untilTrue(waitingFor: "normal stored") { UserDefaults.standard.string(forKey: WindowMode.key) == "normal" }
            let after = try await ModeItems.checked(.normal)
            try after.perform(after.simple)
            try await untilTrue(waitingFor: "simple stored") { UserDefaults.standard.string(forKey: WindowMode.key) == "simple" }
            _ = try await ModeItems.checked(.simple)
        }
    }

    @Test func pickingTheCheckedModeChangesNothing() async throws {
        try await withStandardMode(nil) {
            let items = try await ModeItems.checked(.simple)
            try items.perform(items.simple)
            await mainQueueTurn()
            #expect(UserDefaults.standard.object(forKey: WindowMode.key) == nil)
            _ = try await ModeItems.checked(.simple)
        }
        try await withStandardMode("normal") {
            let items = try await ModeItems.checked(.normal)
            try items.perform(items.normal)
            await mainQueueTurn()
            #expect(UserDefaults.standard.string(forKey: WindowMode.key) == "normal")
            _ = try await ModeItems.checked(.normal)
        }
    }

    @Test func anUnknownStoredModeOpensSimple() async throws {
        let rig = ModeRig(store: modeStore("sideways"))
        defer { rig.host.close() }
        try await rig.untilMode(.simple)
        await mainQueueTurn()
        #expect(!rig.showsForm)
    }

    @Test func normalKeepsTheQueryRowsAndSelectionInEveryWindow() async throws {
        let store = modeStore()
        let first = ModeRig(store: store, hits: hits(["report-a.txt", "report-b.txt", "report-c.txt"]))
        let second = ModeRig(store: store, hits: hits(["report-d.txt"]))
        defer { first.host.close(); second.host.close() }
        try await first.search("report", count: 3)
        try await second.search("report", count: 1)
        try await first.select(1)
        let table = try #require(first.host.list())
        for rig in [first, second] { try await rig.untilMode(.simple) }

        store.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
        for rig in [first, second] {
            try await rig.untilMode(.normal)
            #expect(rig.host.field()?.stringValue == "report")
            #expect(rig.model.query == "report")
        }
        #expect(first.host.list() === table, "the same table, so its rows and selection")
        #expect(table.selectedRow == 1)
        #expect(first.host.list()?.numberOfRows == 3)
        #expect(second.host.list()?.numberOfRows == 1)
    }

    @Test func switchingWithTheCaretInTheFieldKeepsTypingInFileName() async throws {
        let store = modeStore()
        let rig = ModeRig(store: store)
        defer { rig.host.close() }
        try await rig.untilMode(.simple)
        try await rig.host.type("box")
        try await rig.queryEnds("box")

        for (mode, key, query) in [(WindowMode.normal, "s", "boxs"), (.simple, "a", "boxsa")] {
            store.set(mode.rawValue, forKey: WindowMode.key)
            try await rig.untilMode(mode)
            try await rig.host.until("the \(mode) field holds focus") { rig.host.fieldHasFocus }
            try rig.host.sendKeys(key)
            try await rig.queryEnds(query)
            #expect(rig.host.field()?.stringValue == query)
        }
    }

    @Test func switchingWhileTheTableHoldsFocusKeepsIt() async throws {
        let store = modeStore()
        let rig = ModeRig(store: store, hits: hits(["report-a.txt", "report-b.txt", "report-c.txt"]))
        defer { rig.host.close() }
        try await rig.search("report", count: 3)
        try await rig.select(0)
        store.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
        try await rig.untilMode(.normal)
        await mainQueueTurn()
        #expect(rig.host.listHasFocus)
        #expect(!rig.host.fieldHasFocus)
        try rig.host.press(.downArrow)
        try await rig.host.until("row 1 after Down Arrow") { rig.host.list()?.selectedRow == 1 }
    }

    @Test func switchingKeepsTheInspectorAndItsFile() async throws {
        let store = modeStore(inspectorShown: true)
        let rig = ModeRig(store: store, hits: hits(["inspected-a.txt", "inspected-b.txt"]))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 2)
        try await rig.select(1)
        try await rig.host.until("the pane shows the second file") {
            rig.split().map { !$0.inspectorItem.isCollapsed && rig.host.shows("inspected-b.txt", in: $0.pane.view) } == true
        }
        let split = try #require(rig.split())
        store.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
        try await rig.untilMode(.normal)
        #expect(rig.split() === split, "the same split view controller")
        #expect(!split.inspectorItem.isCollapsed)
        #expect(rig.host.shows("inspected-b.txt", in: split.pane.view))
    }

    @Test func backToSimpleDropsThePillsAndTheNameMode() async throws {
        let store = modeStore(WindowMode.normal.rawValue)
        let rig = ModeRig(store: store)
        defer { rig.host.close() }
        try await rig.untilMode(.normal)
        rig.model.query = "report"
        rig.model.filters = SearchFilters(kind: .documents, folder: "/Users/test/Documents", nameMode: .beginsWith)
        try await rig.queryEnds("begins:\"report\" type:doc in:\"/Users/test/Documents\"")

        store.set(WindowMode.simple.rawValue, forKey: WindowMode.key)
        try await rig.untilMode(.simple)
        try await rig.host.until("the filters cleared, now \(rig.model.filters)") { rig.model.filters == SearchFilters() }
        try await rig.queryEnds("report")
        #expect(rig.model.query == "report")
        #expect(rig.host.field()?.stringValue == "report")
    }

    @Test func aNewWindowOpensInTheKeptMode() async throws {
        let store = modeStore()
        let first = ModeRig(store: store)
        defer { first.host.close() }
        try await first.untilMode(.simple)
        store.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
        try await first.untilMode(.normal)

        let second = ModeRig(store: store)
        defer { second.host.close() }
        try await second.untilMode(.normal)
        try await second.host.type("box")
        try await second.queryEnds("box")
    }

    @Test func normalGrowsAFloorWidthSimpleWindowToHoldTheForm() async throws {
        let store = modeStore()
        let rig = ModeRig(store: store)
        defer { rig.host.close() }
        try await rig.untilMode(.simple)
        let window = rig.host.window
        window.setContentSize(NSSize(width: 100, height: SearchMetrics.windowMinHeight))
        try await rig.host.until("Simple at the floor, now \(window.contentLayoutRect.width)") {
            window.contentLayoutRect.width == SearchMetrics.windowMinWidth && window.contentMinSize.width == SearchMetrics.windowMinWidth
        }

        store.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
        try await rig.untilMode(.normal)
        try await rig.host.until("the button inside a \(window.contentLayoutRect.width) pt window") { rig.buttonIsInsideWindow }
        #expect(window.contentMinSize.width > SearchMetrics.windowMinWidth)
        #expect(window.contentLayoutRect.width >= window.contentMinSize.width)

        store.set(WindowMode.simple.rawValue, forKey: WindowMode.key)
        try await rig.untilMode(.simple)
        try await rig.host.until("the minimum back at the floor, now \(window.contentMinSize.width)") {
            window.contentMinSize.width == SearchMetrics.windowMinWidth
        }
    }

    @Test func aNewNormalWindowHoldsTheForm() async throws {
        let rig = ModeRig(store: modeStore(WindowMode.normal.rawValue))
        defer { rig.host.close() }
        try await rig.untilMode(.normal)
        try await rig.host.until("the button inside a \(rig.host.window.contentLayoutRect.width) pt window") { rig.buttonIsInsideWindow }
        #expect(rig.host.window.contentMinSize.width > SearchMetrics.windowMinWidth)
    }

    @Test func backToSimpleDropsTheContentTerms() async throws {
        try await droppedOnTheWayToSimple(terms: ["alpha"], draft: "bet")
    }

    @Test func backToSimpleDropsTermsAlone() async throws {
        try await droppedOnTheWayToSimple(terms: ["alpha"], draft: "")
    }

    @Test func backToSimpleDropsADraftAlone() async throws {
        try await droppedOnTheWayToSimple(terms: [], draft: "bet")
    }

    private func droppedOnTheWayToSimple(terms: [String], draft: String) async throws {
        let store = modeStore(WindowMode.normal.rawValue)
        let rig = ModeRig(store: store)
        defer { rig.host.close() }
        try await rig.untilMode(.normal)
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: terms)
        rig.model.contentDraft = draft
        rig.model.searchContent()
        let words = terms + (draft.isEmpty ? [] : [draft])
        #expect(rig.fake.presses == [FakeSearchClient.Press(query: "report", terms: words, matchAll: false, sort: .bestMatch)])
        let before = rig.fake.queries.count

        store.set(WindowMode.simple.rawValue, forKey: WindowMode.key)
        try await rig.untilMode(.simple)
        try await rig.host.until("the content dropped") { rig.model.content == ContentTerms() && rig.model.contentDraft.isEmpty }
        try await rig.host.until("the read stopped and the name search ran") { rig.fake.stops == 1 && rig.fake.queries.count > before }
        try await rig.queryEnds("report")
        rig.model.query = "reports"
        try await rig.queryEnds("reports")
        #expect(rig.fake.narrows.isEmpty, "Simple narrows nothing")
        #expect(rig.model.press == nil)
    }
}
