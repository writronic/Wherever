import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

@objc private protocol LegacyDragMask {
    func draggingSourceOperationMaskForLocal(_ isLocal: Bool) -> NSDragOperation
}

private let folder = "/Users/me"

private let six = (0..<6).map { SearchHit.named("hit-\($0)", in: folder) }

private func url(_ row: Int) -> URL { six[row].fileURL }

private func path(_ row: Int) -> String { six[row].path }

private let copySelector = NSSelectorFromString("copy:")

private let selectAllSelector = #selector(NSResponder.selectAll(_:))

private let thirty = (0..<30).map { SearchHit.named("hit-\($0)", in: folder) }

private let big = (0...ThemedTable.actionLimit).map { SearchHit.named("hit-\($0)", in: folder) }

private let bigPaths = big.map(\.path).joined(separator: "\n")

@MainActor
private struct Rig {
    let fake: FakeSearchClient
    let index: IndexModel
    let model: SearchModel
    let host: SearchHost

    var recorder: ActionRecorder { host.recorder }

    init(hits: [SearchHit] = six, reportsKey: Bool = false, root: ((SearchModel) -> AnyView)? = nil, actions: ResultActions? = nil) {
        let fake = FakeSearchClient(hits: hits)
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        self.fake = fake
        self.index = index
        self.model = model
        host = SearchHost(root: root?(model) ?? AnyView(SearchView(model: model)), reportsKey: reportsKey, actions: actions)
    }

    func table() throws -> NSTableView { try #require(host.list()) }

    func search(_ text: String, count: Int) async throws {
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        try await host.type(text)
        fake.send(.resultsReady(fake.latest, count: count))
        try await host.until("\(count) rows for \(model.query)") { !model.isPending && host.list()?.numberOfRows == count }
    }

    func select(_ row: Int) async throws {
        try await host.focusList()
        try table().selectRowIndexes([row], byExtendingSelection: false)
    }

    func pressEnter(command: Bool = false) throws {
        let flags: NSEvent.ModifierFlags = command ? [.command] : []
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window.windowNumber, context: nil, characters: "\u{3}", charactersIgnoringModifiers: "\u{3}",
            isARepeat: false, keyCode: 76
        ))
        if command, host.window.performKeyEquivalent(with: event) { return }
        host.window.sendEvent(event)
    }

    func sizeHeader() throws -> NSTableColumn {
        try #require(table().tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(ResultsTable.Column.size.rawValue)))
    }
}

private final class KeySpy: NSResponder {
    var keys = 0

    override func keyDown(with event: NSEvent) { keys += 1 }
}

private func hit(_ name: String, in folder: String, kind: SearchHit.Kind = .file) -> SearchHit {
    SearchHit(name: name, folder: folder, size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: kind)
}

@Suite(.serialized) struct ResultActionsTests {
    @Test func theMissingDefaultReadsWithoutTrappingAndGivesWayToTheInjectedRecorder() {
        var environment = EnvironmentValues()
        _ = environment.resultActions
        let recorder = ActionRecorder()
        environment.resultActions = recorder.actions
        environment.resultActions.open(URL(filePath: "/a", directoryHint: .notDirectory))
        environment.resultActions.recordOpen("/a")
        #expect(recorder.opened == [URL(filePath: "/a", directoryHint: .notDirectory)])
        #expect(recorder.recorded == ["/a"])
    }

    @Test func aFolderHitMakesADirectoryURLAndAFileOrLinkHitDoesNot() {
        #expect(hit("Docs", in: "/Users/me", kind: .folder).fileURL.hasDirectoryPath)
        #expect(!hit("a.txt", in: "/Users/me").fileURL.hasDirectoryPath)
        #expect(!hit("l", in: "/Users/me", kind: .link).fileURL.hasDirectoryPath)
        #expect(hit("a.txt", in: "/Users/me").fileURL.path == "/Users/me/a.txt")
    }

    @Test func aHitInTheRootFolderGivesSlashName() {
        #expect(hit("x", in: "/").fileURL.path == "/x")
        #expect(hit("x", in: "/").path == "/x")
    }

    @Test func liveUnderTheTestHostIsInertAndRecordsNothingInTheEngine() throws {
        try #require(WhereverApp.usesPreviewServices)
        let client = FakeSearchClient()
        let sentinel = "wherever-inert-\(UUID().uuidString)"
        let actions = ResultActions.live(client: client)
        actions.open(URL(filePath: "/wherever-test-missing", directoryHint: .notDirectory))
        actions.reveal([URL(filePath: "/wherever-test-missing", directoryHint: .notDirectory)])
        actions.copyPath(sentinel)
        actions.recordOpen("/x")
        #expect(client.opened.isEmpty)
        #expect(NSPasteboard.general.string(forType: .string) != sentinel)
    }

    @Test func liveOffTheTestHostWritesTheGivenPasteboardOnlyAndRecordsTheOpen() throws {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old", forType: .string)
        let client = FakeSearchClient()
        let actions = ResultActions.live(client: client, preview: false, pasteboard: pasteboard)
        actions.copyPath("/Users/me/a.txt")
        actions.recordOpen("/Users/me/a.txt")
        #expect(pasteboard.string(forType: .string) == "/Users/me/a.txt")
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(client.opened == ["/Users/me/a.txt"])
    }

    @Test func returnInTheTableOpensAndRecordsTheSelectedRowAgainOnTheNextReturn() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(2)
        try rig.host.pressReturn()
        #expect(rig.recorder.opened == [url(2)])
        #expect(rig.recorder.recorded == [path(2)])
        try rig.host.pressReturn()
        #expect(rig.recorder.opened == [url(2), url(2)])
        #expect(rig.recorder.recorded == [path(2), path(2)])
        #expect(rig.recorder.revealed.isEmpty)
    }

    @Test func doubleClickOpensAndRecordsTheClickedRow() async throws {
        let rig = Rig(reportsKey: true)
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await EventQueueLock.run {
            try rig.host.doubleClick(row: 1)
            try await rig.host.until("the double-click to open row 1, opened \(rig.recorder.opened)") {
                rig.host.sendQueuedEvents()
                return !rig.recorder.opened.isEmpty
            }
        }
        #expect(rig.recorder.opened == [url(1)])
        #expect(rig.recorder.recorded == [path(1)])
    }

    @Test func commandReturnInTheTableRevealsTheSelectedRowAndRecordsNothing() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(3)
        try rig.host.pressReturn(command: true)
        #expect(rig.recorder.revealed == [url(3)])
        #expect(rig.recorder.opened.isEmpty)
        #expect(rig.recorder.recorded.isEmpty)
    }

    @Test func returnInTheFieldOpensRowZeroWithNoSelectionAndTheSelectedRowWithOne() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try rig.host.pressReturn()
        #expect(rig.recorder.opened == [url(0)])
        #expect(rig.recorder.recorded == [path(0)])
        try await rig.select(3)
        try #require(rig.host.window.focusSearchField() != nil)
        try rig.host.pressReturn()
        #expect(rig.recorder.opened == [url(0), url(3)])
        #expect(rig.recorder.recorded == [path(0), path(3)])
        #expect(rig.host.fieldHasFocus)
        #expect(rig.model.query == "a")
    }

    @Test func returnInTheFieldWithNoRowsDoesNothing() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 0)
        try rig.host.pressReturn()
        try rig.host.pressReturn(command: true)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func commandReturnInTheFieldRevealsTheRowReturnWouldOpen() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try rig.host.pressReturn(command: true)
        #expect(rig.recorder.revealed == [url(0)])
        try await rig.select(4)
        try #require(rig.host.window.focusSearchField() != nil)
        try rig.host.pressReturn(command: true)
        #expect(rig.recorder.revealed == [url(0), url(4)])
        #expect(rig.recorder.opened.isEmpty)
        #expect(rig.recorder.recorded.isEmpty)
    }

    @Test func returnRightAfterTypingOpensTheNewQuerysTopRowWhenItLands() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("s", count: 6)
        try rig.host.sendKeys("a")
        #expect(rig.model.isPending)
        try rig.host.pressReturn()
        #expect(rig.recorder.nothingHappened)
        let fresh = SearchHit.named("safari", in: "/Applications")
        rig.fake.setHits([fresh])
        rig.fake.send(.resultsReady(rig.fake.latest, count: 1))
        try await rig.host.until("the top row of sa opened, opened \(rig.recorder.opened)") { !rig.recorder.opened.isEmpty }
        #expect(rig.recorder.opened == [fresh.fileURL])
        #expect(rig.recorder.recorded == ["/Applications/safari"])
        #expect(rig.host.fieldHasFocus)
    }

    @Test func commandReturnRightAfterTypingRevealsTheNewQuerysTopRowWhenItLands() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("s", count: 6)
        try rig.host.sendKeys("a")
        try rig.host.pressReturn(command: true)
        #expect(rig.recorder.nothingHappened)
        let fresh = SearchHit.named("safari", in: "/Applications")
        rig.fake.setHits([fresh])
        rig.fake.send(.resultsReady(rig.fake.latest, count: 1))
        try await rig.host.until("the top row of sa revealed, revealed \(rig.recorder.revealed)") { !rig.recorder.revealed.isEmpty }
        #expect(rig.recorder.revealed == [fresh.fileURL])
        #expect(rig.recorder.opened.isEmpty && rig.recorder.recorded.isEmpty)
    }

    @Test func aLetterAfterAPendingReturnDropsIt() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("s", count: 6)
        try rig.host.sendKeys("a")
        try rig.host.pressReturn()
        try rig.host.sendKeys("f")
        rig.fake.send(.resultsReady(rig.fake.latest, count: 1))
        try await rig.host.until("the results of saf") { !rig.model.isPending && rig.host.list()?.numberOfRows == 1 }
        #expect(rig.recorder.nothingHappened)
    }

    @Test func aPendingReturnDropsWhenFocusLeavesTheField() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("s", count: 6)
        try rig.host.sendKeys("a")
        try rig.host.pressReturn()
        try rig.host.press(.downArrow)
        #expect(rig.host.listHasFocus)
        rig.fake.send(.resultsReady(rig.fake.latest, count: 1))
        try await rig.host.until("the results of sa") { !rig.model.isPending && rig.host.list()?.numberOfRows == 1 }
        #expect(rig.recorder.nothingHappened)
    }

    @Test func aPendingReturnDropsWhenFocusLeavesAndComesBack() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("s", count: 6)
        try rig.host.sendKeys("a")
        try rig.host.pressReturn()
        try rig.host.press(.downArrow)
        #expect(rig.host.listHasFocus)
        try rig.host.press(.upArrow)
        #expect(rig.host.fieldHasFocus)
        rig.fake.send(.resultsReady(rig.fake.latest, count: 1))
        try await rig.host.until("the results of sa") { !rig.model.isPending && rig.host.list()?.numberOfRows == 1 }
        #expect(rig.recorder.nothingHappened)
    }

    @Test func aPendingReturnOpensNothingWhenItsSearchFindsNothingOrFails() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("s", count: 6)
        try rig.host.sendKeys("a")
        try rig.host.pressReturn()
        rig.fake.send(.resultsReady(rig.fake.latest, count: 0))
        try await rig.host.until("no rows for sa") { !rig.model.isPending && rig.host.list()?.numberOfRows == 0 }
        #expect(rig.recorder.nothingHappened)
        try rig.host.sendKeys("f")
        try rig.host.pressReturn()
        rig.fake.send(.searchFailed(rig.fake.latest))
        try await rig.host.until("the failed search") { rig.model.failed && !rig.model.isPending }
        let searches = rig.fake.queries.count
        rig.fake.send(.resultsChanged)
        try await rig.host.until("the live re-search") { rig.fake.queries.count == searches + 1 }
        rig.fake.send(.resultsReady(rig.fake.latest, count: 6))
        try await rig.host.until("six rows for saf") { rig.host.list()?.numberOfRows == 6 }
        #expect(rig.recorder.nothingHappened)
    }

    @Test func aNewSortAfterAPendingReturnDropsIt() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("s", count: 6)
        try rig.host.sendKeys("a")
        let pending = rig.fake.latest
        try rig.host.pressReturn()
        rig.model.sort = SearchSort(column: .name, ascending: true, foldersFirst: false)
        #expect(rig.fake.latest != pending)
        rig.fake.send(.resultsReady(rig.fake.latest, count: 6))
        try await rig.host.until("the sorted rows of sa") { !rig.model.isPending && rig.host.list()?.numberOfRows == 6 }
        #expect(rig.recorder.nothingHappened)
    }

    @Test func returnDuringALiveReSearchStillOpensRowZero() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        let searches = rig.fake.queries.count
        rig.fake.send(.resultsChanged)
        try await rig.host.until("the live re-search") { rig.fake.queries.count == searches + 1 }
        #expect(!rig.model.isPending)
        try rig.host.pressReturn()
        #expect(rig.recorder.opened == [url(0)])
        #expect(rig.recorder.recorded == [path(0)])
    }

    @Test func aHostRecordsInItsOwnRecorderUnlessGivenActions() async throws {
        let bare = Rig(root: { AnyView(ResultsTable(model: $0)) })
        defer { bare.host.close() }
        bare.model.query = "a"
        bare.fake.send(.resultsReady(bare.fake.latest, count: 6))
        try await bare.host.until("six rows") { bare.host.list()?.numberOfRows == 6 }
        try await bare.select(1)
        try bare.host.pressReturn()
        #expect(bare.recorder.opened == [url(1)])

        let own = ActionRecorder()
        let given = Rig(actions: own.actions)
        defer { given.host.close() }
        try await given.search("a", count: 6)
        try given.host.pressReturn()
        #expect(own.opened == [url(0)])
        #expect(own.recorded == [path(0)])
        #expect(given.recorder.nothingHappened)
    }

    @Test func spaceInTheTableShowsQuickLookAndSpaceAgainHidesIt() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(2)
        try rig.host.sendKeys(" ")
        #expect(rig.recorder.shown == [url(2)])
        #expect(rig.recorder.hides == 0)
        try rig.host.sendKeys(" ")
        #expect(rig.recorder.shown == [url(2)])
        #expect(rig.recorder.hides == 1)
        #expect(rig.model.query == "a")
    }

    @Test func spaceInTheFieldTypesASpaceAndLeavesQuickLookAlone() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try rig.host.sendKeys(" ")
        #expect(rig.model.query == "a ")
        #expect(rig.recorder.nothingHappened)
    }

    @Test func downArrowWithQuickLookOpenMovesTheSelectionAndThePanelFollows() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(0)
        try rig.host.sendKeys(" ")
        try rig.host.press(.downArrow)
        #expect(try rig.table().selectedRow == 1)
        #expect(rig.recorder.refreshed == [url(1)])
        #expect(rig.recorder.shown == [url(0)])
    }

    @Test func keypadEnterInTheTableOpensTheSelectedRowOnceAndCommandEnterRevealsIt() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(2)
        try rig.pressEnter()
        #expect(rig.recorder.opened == [url(2)])
        #expect(rig.recorder.recorded == [path(2)])
        #expect(rig.recorder.revealed.isEmpty)
        try rig.pressEnter(command: true)
        #expect(rig.recorder.revealed == [url(2)])
        #expect(rig.recorder.opened == [url(2)])
    }

    @Test func keypadEnterInTheFieldOpensTheTopRowAndCommandEnterRevealsIt() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try rig.pressEnter()
        #expect(rig.recorder.opened == [url(0)])
        try rig.pressEnter(command: true)
        #expect(rig.recorder.revealed == [url(0)])
        #expect(rig.model.query == "a")
    }

    @Test func aHeaderClickWithQuickLookOpenEmptiesThePanelAndTheNextArrowPreviewsAgain() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(1)
        rig.recorder.quickLookOpen = true
        let table = try rig.table()
        table.delegate?.tableView?(table, didClick: try rig.sizeHeader())
        #expect(table.selectedRow == -1)
        #expect(rig.recorder.refreshed == [nil])
        #expect(rig.recorder.shown.isEmpty)
        rig.fake.send(.resultsReady(rig.fake.latest, count: 6))
        try await rig.host.until("the sorted rows") { !rig.model.isPending }
        #expect(rig.recorder.refreshed == [nil], "the sorted rows alone refresh nothing")
        try await rig.select(0)
        #expect(rig.recorder.refreshed == [nil, url(0)])
    }

    @Test func aHeaderClickWithQuickLookClosedRefreshesAndShowsNothing() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(1)
        let table = try rig.table()
        table.delegate?.tableView?(table, didClick: try rig.sizeHeader())
        #expect(rig.recorder.refreshed.isEmpty)
        #expect(rig.recorder.shown.isEmpty)
    }

    @Test func aLiveUpdateThatDropsTheSelectedRowEmptiesAnOpenPanelOnce() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(1)
        rig.recorder.quickLookOpen = true
        rig.fake.setHits(six.filter { $0.name != "hit-1" })
        let queries = rig.fake.queries.count
        rig.fake.send(.resultsChanged)
        try await rig.host.until("the live search") { rig.fake.queries.count == queries + 1 }
        rig.fake.send(.resultsReady(rig.fake.latest, count: 5))
        try await rig.host.until("the live results") { rig.model.results.live && rig.model.results.generation == rig.fake.latest }
        #expect(try rig.table().selectedRow == -1)
        #expect(rig.recorder.refreshed == [nil])
    }

    @Test func spaceInTheSecondWindowPreviewsThatWindowsRow() async throws {
        let first = Rig()
        defer { first.host.close() }
        try await first.search("a", count: 6)
        try await first.select(1)
        first.host.resignKey()
        let other = (0..<3).map { SearchHit.named("other-\($0)", in: "/Volumes/Disk") }
        let second = Rig(hits: other)
        defer { second.host.close() }
        try await second.search("o", count: 3)
        try await second.select(2)
        try second.host.sendKeys(" ")
        #expect(second.recorder.shown == [other[2].fileURL])
        #expect(first.recorder.nothingHappened)
    }

    @Test func copyInTheTablePutsExactlyThePathOnThePasteboard() async throws {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let own = ActionRecorder()
        var writing = own.actions
        writing.copyPath = ResultActions.live(client: FakeSearchClient(), preview: false, pasteboard: pasteboard).copyPath
        let actions = writing
        let rig = Rig(actions: actions)
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(3)
        #expect(rig.host.copyTarget() === rig.host.list())
        try #require(rig.host.window.firstResponder?.tryToPerform(copySelector, with: nil) == true)
        #expect(pasteboard.string(forType: .string) == path(3))
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(own.recorded.isEmpty)
        #expect(own.opened.isEmpty)
    }

    @Test func copyInTheFieldGoesToTheFieldEditorAndNeverCopiesAPath() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("as", count: 6)
        let editor = try #require(rig.host.field()?.currentEditor())
        editor.selectAll(nil)
        #expect(rig.host.copyTarget() === editor)
        editor.selectedRange = NSRange(location: 2, length: 0)
        #expect(rig.host.copyTarget() === editor)
        #expect(rig.host.copyTarget() !== rig.host.list())
        #expect(rig.recorder.copied.isEmpty)
    }

    @Test func aHitInTheRootFolderGivesSlashNameToEveryAction() async throws {
        let root = SearchHit(name: "x", folder: "/", size: 1, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .file)
        let rig = Rig(hits: [root])
        defer { rig.host.close() }
        try await rig.search("x", count: 1)
        try rig.host.pressReturn()
        try rig.host.pressReturn(command: true)
        try await rig.select(0)
        try #require(rig.host.window.firstResponder?.tryToPerform(copySelector, with: nil) == true)
        let table = try rig.table()
        let dragged = try #require(table.dataSource?.tableView?(table, pasteboardWriterForRow: 0) as? NSURL)
        #expect(rig.recorder.opened.map(\.path) == ["/x"])
        #expect(rig.recorder.revealed.map(\.path) == ["/x"])
        #expect(rig.recorder.copied == ["/x"])
        #expect(rig.recorder.recorded == ["/x"])
        #expect(dragged.path == "/x")
    }

    @Test func aDragCarriesTheRowsFileURLWithTheCopyOperationForOtherApps() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        let table = try rig.table()
        let writer = try #require(table.dataSource?.tableView?(table, pasteboardWriterForRow: 2) as? NSURL)
        #expect(writer as URL == url(2))
        try #require(table.responds(to: NSSelectorFromString("draggingSourceOperationMaskForLocal:")))
        let mask = unsafeBitCast(table, to: (any LegacyDragMask).self)
        #expect(mask.draggingSourceOperationMaskForLocal(false) == .copy)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func theContextMenuSelectsTheClickedRowAndEachItemActsOnItOnce() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        let table = try rig.table()
        let rect = table.rect(ofRow: 4)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: rig.host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try #require(table.menu(for: click))
        #expect(table.selectedRow == 4)
        menu.update()
        #expect(menu.items.filter { !$0.isEnabled }.isEmpty)
        let keys = menu.items.map { "\($0.keyEquivalent)|\($0.keyEquivalentModifierMask.rawValue)" }
        #expect(keys == ["\r|0", "\r|\(NSEvent.ModifierFlags.command.rawValue)", " |0", "c|\(NSEvent.ModifierFlags.command.rawValue)"])
        let titles = [
            String(localized: "Open", table: "Results"), String(localized: "Show in Finder", table: "Results"),
            String(localized: "Quick Look", table: "Results"), String(localized: "Copy Path", table: "Results"),
        ]
        #expect(menu.items.map(\.title) == titles)
        for item in menu.items {
            let action = try #require(item.action)
            try #require(NSApp.sendAction(action, to: item.target, from: item))
        }
        #expect(rig.recorder.opened == [url(4)])
        #expect(rig.recorder.recorded == [path(4)])
        #expect(rig.recorder.revealed == [url(4)])
        #expect(rig.recorder.shown == [url(4)])
        #expect(rig.recorder.copied == [path(4)])
    }

    @Test func mainWindowDeleteKeyStillReachesSuper() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("hit", count: 6)
        try await rig.select(2)
        let table = try #require(try rig.table() as? ThemedTable)
        let spy = KeySpy()
        rig.host.window.nextResponder = spy
        let main = table.actions
        let removes = main.remove != nil
        #expect(!removes)

        var removing = main
        removing.remove = { [recorder = rig.recorder] in recorder.removed.append($0.map(\.path)) }
        table.actions = removing
        try rig.host.pressDelete()
        #expect(rig.recorder.removed == [[path(2)]])
        #expect(table.selectedRowIndexes.isEmpty)
        #expect(spy.keys == 0)

        table.actions = main
        rig.recorder.removed = []
        table.selectRowIndexes([2], byExtendingSelection: false)
        try rig.host.pressDelete()
        try rig.host.pressDelete(forward: true)
        try rig.host.pressDelete(flags: .command)
        #expect(spy.keys == 3)
        #expect(rig.recorder.nothingHappened)
        #expect(table.selectedRowIndexes == [2])
        #expect(rig.model.count == 6)
        let rect = table.rect(ofRow: 2)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.host.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
        let menu = try #require(table.menu(for: click))
        #expect(!menu.items.contains { $0.identifier?.rawValue == ThemedTable.deleteItemID || $0.action == #selector(ThemedTable.delete(_:)) })
        #expect(menu.items.count == 4)
        #expect(!table.validateUserInterfaceItem(NSMenuItem(title: "", action: #selector(ThemedTable.delete(_:)), keyEquivalent: "")))
    }

    @Test func noTableKeyActsOnAnEmptyTable() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 0)
        try await rig.host.focusList()
        try rig.host.pressReturn()
        try rig.host.pressReturn(command: true)
        try rig.host.sendKeys(" ")
        _ = rig.host.window.firstResponder?.tryToPerform(copySelector, with: nil)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func returnInTheTableDoesNothingAfterAFailedSearchAndWorksAfterTheNextGoodOne() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.failSearch(thenSelecting: 2)
        try rig.host.pressReturn()
        #expect(rig.recorder.nothingHappened)
        try await rig.recover(selecting: 2)
        try rig.host.pressReturn()
        #expect(rig.recorder.opened == [url(2)])
    }

    @Test func commandReturnInTheTableDoesNothingAfterAFailedSearchAndWorksAfterTheNextGoodOne() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.failSearch(thenSelecting: 3)
        try rig.host.pressReturn(command: true)
        #expect(rig.recorder.nothingHappened)
        try await rig.recover(selecting: 3)
        try rig.host.pressReturn(command: true)
        #expect(rig.recorder.revealed == [url(3)])
    }

    @Test func aDoubleClickDoesNothingAfterAFailedSearchAndWorksAfterTheNextGoodOne() async throws {
        let rig = Rig(reportsKey: true)
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try rig.host.sendKeys("b")
        rig.fake.send(.searchFailed(rig.fake.latest))
        try await rig.host.until("the failed search") { rig.model.failed && !rig.model.isPending }
        try await EventQueueLock.run {
            try rig.host.doubleClick(row: 1)
            try await rig.host.until("the double-click to select row 1") {
                rig.host.sendQueuedEvents()
                return rig.host.list()?.selectedRowIndexes == [1]
            }
        }
        #expect(rig.recorder.nothingHappened)
        try await rig.recover(selecting: 1)
        try await EventQueueLock.run {
            try rig.host.doubleClick(row: 1)
            try await rig.host.until("the double-click to open row 1, opened \(rig.recorder.opened)") {
                rig.host.sendQueuedEvents()
                return !rig.recorder.opened.isEmpty
            }
        }
        #expect(rig.recorder.opened == [url(1)])
    }

    @Test func copyInTheTableDoesNothingAfterAFailedSearchAndWorksAfterTheNextGoodOne() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.failSearch(thenSelecting: 4)
        try #require(rig.host.window.firstResponder?.tryToPerform(copySelector, with: nil) == true)
        #expect(rig.recorder.nothingHappened)
        try await rig.recover(selecting: 4)
        try #require(rig.host.window.firstResponder?.tryToPerform(copySelector, with: nil) == true)
        #expect(rig.recorder.copied == [path(4)])
    }

    @Test(arguments: [0, 1, 3]) func aContextMenuItemDoesNothingAfterAFailedSearchAndWorksAfterTheNextGoodOne(index: Int) async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.failSearch(thenSelecting: 4)
        let table = try rig.table()
        var item = try #require(table.menu(for: rig.rightClick(4))).items[index]
        try #require(NSApp.sendAction(#require(item.action), to: item.target, from: item))
        #expect(rig.recorder.nothingHappened)
        try await rig.recover(selecting: 4)
        item = try #require(table.menu(for: rig.rightClick(4))).items[index]
        try #require(NSApp.sendAction(#require(item.action), to: item.target, from: item))
        #expect(rig.recorder.opened.count + rig.recorder.revealed.count + rig.recorder.copied.count == 1)
    }

    @Test func deleteInAnArchiveTableRemovesNothingAfterAFailedSearchAndWorksAfterTheNextGoodOne() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.failSearch(thenSelecting: 2)
        let table = try rig.themed()
        table.actions.remove = { [recorder = rig.recorder] in recorder.removed.append($0.map(\.path)) }
        try rig.host.pressDelete()
        #expect(rig.recorder.removed.isEmpty)
        #expect(table.selectedRowIndexes == [2])
        try await rig.recover(selecting: 2)
        table.actions.remove = { [recorder = rig.recorder] in recorder.removed.append($0.map(\.path)) }
        try rig.host.pressDelete()
        #expect(rig.recorder.removed == [[path(2)]])
    }

    @Test func spaceAndTheQuickLookMenuItemShowNothingAfterAFailedSearchAndWorkAfterTheNextGoodOne() async throws {
        let own = ActionRecorder()
        let rig = Rig(actions: own.actions)
        defer { rig.host.close() }
        try await rig.failSearch(thenSelecting: 2)
        let table = try rig.themed()
        try rig.host.sendKeys(" ")
        try #require(NSApp.sendAction(#selector(ThemedTable.showQuickLook(_:)), to: table, from: nil))
        #expect(own.nothingHappened)
        #expect(table.selectedRowIndexes == [2])
        try await rig.recover(selecting: 2)
        try rig.host.sendKeys(" ")
        #expect(own.shown == [url(2)])
    }

    @Test func spaceStillClosesAnOpenQuickLookAfterAFailedSearchAndTheNextGoodOneOpensItAgain() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.failSearch(withQuickLookOpenOn: 2)
        try rig.host.sendKeys(" ")
        #expect(rig.recorder.hides == 1)
        #expect(rig.recorder.quickLookOpen == false)
        #expect(rig.recorder.shown == [url(2)])
        try await rig.recover(selecting: 2)
        try rig.host.sendKeys(" ")
        #expect(rig.recorder.shown == [url(2), url(2)])
        #expect(rig.recorder.hides == 1)
    }

    @Test func anOpenQuickLookIsNotRefreshedWithAnOldRowAfterAFailedSearchAndFollowsTheSelectionAfterTheNextGoodOne() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.failSearch(withQuickLookOpenOn: 2)
        try rig.host.press(.downArrow)
        #expect(try rig.table().selectedRow == 3)
        #expect(rig.recorder.refreshed.isEmpty)
        try await rig.recover(selecting: 2)
        try await rig.select(4)
        #expect(rig.recorder.refreshed.last == url(4))
    }

    @Test func showArchiveContentsDoesNothingAfterAFailedSearchAndWorksAfterTheNextGoodOne() async throws {
        let own = ActionRecorder()
        let rig = Rig(actions: own.actions(inside: { _ in true }))
        defer { rig.host.close() }
        try await rig.failSearch(thenSelecting: 2)
        let table = try rig.themed()
        try rig.host.press(.downArrow, flags: .command)
        try #require(NSApp.sendAction(#selector(ThemedTable.showInside(_:)), to: table, from: nil))
        #expect(own.nothingHappened)
        #expect(table.selectedRowIndexes == [2])
        try await rig.recover(selecting: 2)
        try rig.host.press(.downArrow, flags: .command)
        #expect(own.entered == [path(2)])
    }

    @Test func theMenuItemsOfRowActionsAreDisabledAfterAFailedSearchAndEnabledAfterTheNextGoodOne() async throws {
        let own = ActionRecorder()
        let rig = Rig(actions: own.actions(inside: { _ in true }, enclosing: true))
        defer { rig.host.close() }
        try await rig.failSearch(thenSelecting: 2)
        let table = try rig.themed()
        table.actions.remove = { _ in }
        let rowActions = [
            copySelector, #selector(ThemedTable.openSelected(_:)), #selector(ThemedTable.revealSelected(_:)),
            #selector(ThemedTable.showQuickLook(_:)), #selector(ThemedTable.showInside(_:)), #selector(ThemedTable.delete(_:)),
        ]
        let goEnclosing = NSMenuItem(title: "", action: #selector(ThemedTable.goEnclosing(_:)), keyEquivalent: "")
        for action in rowActions {
            #expect(!table.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: "")), "\(action)")
        }
        #expect(table.validateUserInterfaceItem(goEnclosing))
        #expect(table.selectedRowIndexes == [2])
        try await rig.recover(selecting: 2)
        table.actions.remove = { _ in }
        for action in rowActions {
            #expect(table.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: "")), "\(action)")
        }
    }
}

extension Rig {
    func select(_ first: Int, through last: Int) async throws {
        try await select(first)
        for _ in first..<last { try host.press(.downArrow, flags: .shift) }
        try #require(try table().selectedRowIndexes == IndexSet(first...last))
    }

    func click(_ row: Int, modifiers: NSEvent.ModifierFlags = [], selects rows: IndexSet) async throws {
        let table = try table()
        try host.click(row: row, modifiers: modifiers)
        try await host.until("rows \(Array(rows)) after a click on row \(row), selected \(Array(table.selectedRowIndexes))") {
            host.sendQueuedEvents()
            return table.selectedRowIndexes == rows
        }
    }

    func themed() throws -> ThemedTable { try #require(host.list() as? ThemedTable) }

    func failSearch(thenSelecting row: Int) async throws {
        try await search("a", count: 6)
        try host.sendKeys("b")
        fake.send(.searchFailed(fake.latest))
        try await host.until("the failed search") { model.failed && !model.isPending }
        try #require(host.list()?.numberOfRows == 6)
        try await select(row)
    }

    func failSearch(withQuickLookOpenOn row: Int) async throws {
        try await search("a", count: 6)
        try await select(row)
        try host.sendKeys(" ")
        try #require(recorder.shown == [url(row)])
        try #require(host.window.focusSearchField() != nil)
        try host.sendKeys("b")
        fake.send(.searchFailed(fake.latest))
        try await host.until("the failed search") { model.failed && !model.isPending }
        try await select(row)
    }

    func recover(selecting row: Int) async throws {
        try #require(host.window.focusSearchField() != nil)
        try host.sendKeys("c")
        fake.send(.resultsReady(fake.latest, count: 6))
        try await host.until("a good search") { !model.failed && !model.isPending && host.list()?.numberOfRows == 6 }
        try await select(row)
    }

    func rightClick(_ row: Int) throws -> NSEvent {
        let table = try table()
        let rect = table.rect(ofRow: row)
        return try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
    }

    func arrow(_ key: NSEvent.SpecialKey, code: UInt16) throws -> NSEvent {
        let character = String(Character(key.unicodeScalar))
        return try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: code
        ))
    }
}

private func selectAllItem(in menu: NSMenu?) -> NSMenuItem? {
    for item in menu?.items ?? [] {
        if item.action == selectAllSelector { return item }
        if let found = selectAllItem(in: item.submenu) { return found }
    }
    return nil
}

extension ResultActionsTests {
    @Test func shiftDownExtendsTheSelection() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(1)
        try rig.host.press(.downArrow, flags: .shift)
        try rig.host.press(.downArrow, flags: .shift)
        #expect(try rig.table().selectedRowIndexes == IndexSet(1...3))
        #expect(rig.recorder.nothingHappened)
    }

    @Test func commandClickAddsAndRemovesRows() async throws {
        let rig = Rig(reportsKey: true)
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await EventQueueLock.run {
            try await rig.click(1, selects: [1])
            try await rig.click(4, modifiers: .command, selects: [1, 4])
            try await rig.click(1, modifiers: .command, selects: [4])
        }
        #expect(rig.recorder.nothingHappened)
    }

    @Test func shiftClickSelectsARange() async throws {
        let rig = Rig(reportsKey: true)
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await EventQueueLock.run {
            try await rig.click(1, selects: [1])
            try await rig.click(4, modifiers: .shift, selects: IndexSet(1...4))
        }
    }

    @Test func selectAllSelectsEveryRowInTheTableAndTheTextInTheField() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("as", count: 6)
        let menu: NSMenu = try #require(NSApp.mainMenu)
        let item = try #require(selectAllItem(in: menu))
        #expect(item.keyEquivalent == "a")
        #expect(item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == .command)
        try await rig.host.focusList()
        try #require(rig.host.window.firstResponder?.tryToPerform(selectAllSelector, with: nil) == true)
        #expect(try rig.table().selectedRowIndexes == IndexSet(0..<6))

        let editor = try #require(rig.host.window.focusSearchField())
        try #require(rig.host.window.firstResponder?.tryToPerform(selectAllSelector, with: nil) == true)
        #expect(editor.selectedRange == NSRange(location: 0, length: 2))
        #expect(try rig.table().selectedRowIndexes == IndexSet(0..<6))
        #expect(rig.recorder.nothingHappened)
    }

    @Test func returnOpensAndRecordsEverySelectedRowInRowOrder() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(1, through: 3)
        try rig.host.pressReturn()
        #expect(rig.recorder.opened == [url(1), url(2), url(3)])
        #expect(rig.recorder.recorded == [path(1), path(2), path(3)])
        try rig.host.pressReturn()
        #expect(rig.recorder.opened == [url(1), url(2), url(3), url(1), url(2), url(3)])
        #expect(rig.recorder.recorded == [path(1), path(2), path(3), path(1), path(2), path(3)])
        #expect(rig.recorder.revealed.isEmpty)
        #expect(rig.recorder.asked.isEmpty)
    }

    @Test func commandReturnRevealsTheSelectionInOneCall() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(1, through: 3)
        try rig.host.pressReturn(command: true)
        #expect(rig.recorder.revealed == [url(1), url(2), url(3)])
        #expect(rig.recorder.reveals == 1)
        #expect(rig.recorder.opened.isEmpty)
        #expect(rig.recorder.recorded.isEmpty)
    }

    @Test func spaceShowsQuickLookOverTheSelection() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(1, through: 3)
        try rig.host.sendKeys(" ")
        #expect(rig.recorder.shown == [url(1)])
        let table = try rig.themed()
        #expect(table.numberOfPreviewItems(in: nil) == 3)
        #expect((table.previewPanel(nil, previewItemAt: 0) as? NSURL) as URL? == url(1))
        #expect((table.previewPanel(nil, previewItemAt: 2) as? NSURL) as URL? == url(3))
        let left = try rig.arrow(.leftArrow, code: 123)
        let right = try rig.arrow(.rightArrow, code: 124)
        let down = try rig.arrow(.downArrow, code: 125)
        #expect(!table.previewPanel(nil, handle: left))
        #expect(!table.previewPanel(nil, handle: right))
        #expect(table.selectedRowIndexes == IndexSet(1...3))
        #expect(table.previewPanel(nil, handle: down))
        #expect(table.selectedRowIndexes.count == 1)
        #expect(table.numberOfPreviewItems(in: nil) == 1)
    }

    @Test func copyPutsEveryPathOnePerLine() async throws {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let own = ActionRecorder()
        var writing = own.actions
        writing.copyPath = ResultActions.live(client: FakeSearchClient(), preview: false, pasteboard: pasteboard).copyPath
        let actions = writing
        let rig = Rig(actions: actions)
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(1, through: 3)
        try #require(rig.host.window.firstResponder?.tryToPerform(copySelector, with: nil) == true)
        #expect(pasteboard.string(forType: .string) == "\(path(1))\n\(path(2))\n\(path(3))")
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(own.opened.isEmpty && own.recorded.isEmpty)
    }

    @Test func theContextMenuInsideTheSelectionKeepsItAndActsOnAll() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(1, through: 3)
        let table = try rig.table()
        let inside = try rig.rightClick(2)
        let menu = try #require(table.menu(for: inside))
        #expect(table.selectedRowIndexes == IndexSet(1...3))
        menu.update()
        #expect(menu.items.filter { !$0.isEnabled }.isEmpty)
        for item in menu.items {
            let action = try #require(item.action)
            try #require(NSApp.sendAction(action, to: item.target, from: item))
        }
        #expect(rig.recorder.opened == [url(1), url(2), url(3)])
        #expect(rig.recorder.recorded == [path(1), path(2), path(3)])
        #expect(rig.recorder.revealed == [url(1), url(2), url(3)])
        #expect(rig.recorder.reveals == 1)
        #expect(rig.recorder.shown == [url(1)])
        #expect(rig.recorder.copied == ["\(path(1))\n\(path(2))\n\(path(3))"])

        let outside = try rig.rightClick(5)
        _ = try #require(table.menu(for: outside))
        #expect(table.selectedRowIndexes == [5])
    }

    @Test func twentyFiveOrMoreAskFirstAndANoOpensNothing() async throws {
        let rig = Rig(hits: thirty)
        defer { rig.host.close() }
        try await rig.search("a", count: 30)
        try await rig.select(0, through: 23)
        try rig.host.pressReturn()
        #expect(rig.recorder.asked.isEmpty)
        #expect(rig.recorder.opened == thirty[0..<24].map(\.fileURL))
        #expect(rig.recorder.recorded.count == 24)

        try rig.host.press(.downArrow, flags: .shift)
        try #require(try rig.table().selectedRowIndexes == IndexSet(0...24))
        rig.recorder.confirms = false
        try rig.host.pressReturn()
        #expect(rig.recorder.asked == ["open 25"])
        #expect(rig.recorder.opened.count == 24)
        #expect(rig.recorder.recorded.count == 24)

        rig.recorder.confirms = true
        try rig.host.pressReturn()
        #expect(rig.recorder.asked == ["open 25", "open 25"])
        #expect(Array(rig.recorder.opened.dropFirst(24)) == thirty[0..<25].map(\.fileURL))
        #expect(rig.recorder.recorded.count == 49)

        try rig.host.pressReturn(command: true)
        #expect(rig.recorder.asked == ["open 25", "open 25", "reveal 25"])
        #expect(rig.recorder.reveals == 1)
        #expect(rig.recorder.revealed == thirty[0..<25].map(\.fileURL))
        #expect(rig.recorder.refused == 0)
    }

    @Test func returnInTheFieldActsOnTheWholeSelection() async throws {
        let rig = Rig(reportsKey: true)
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await EventQueueLock.run {
            try await rig.click(1, selects: [1])
            try await rig.click(3, modifiers: .command, selects: [1, 3])
        }
        try #require(rig.host.window.focusSearchField() != nil)
        try rig.host.pressReturn()
        #expect(rig.recorder.opened == [url(1), url(3)])
        #expect(rig.recorder.recorded == [path(1), path(3)])
        try rig.host.pressReturn(command: true)
        #expect(rig.recorder.revealed == [url(1), url(3)])
        #expect(rig.recorder.reveals == 1)
        #expect(rig.host.fieldHasFocus)
    }

    @Test func shiftUpOnRowZeroStaysInTheTable() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try rig.host.press(.downArrow)
        try #require(rig.host.listHasFocus)
        let table = try rig.table()
        try #require(table.selectedRowIndexes == [0])
        try rig.host.press(.downArrow, flags: .shift)
        #expect(table.selectedRowIndexes == [0, 1])
        try rig.host.press(.upArrow, flags: .shift)
        #expect(table.selectedRowIndexes == [0])
        try rig.host.press(.upArrow, flags: .shift)
        #expect(rig.host.listHasFocus)
        #expect(table.selectedRowIndexes == [0])
        try rig.host.press(.upArrow)
        #expect(rig.host.fieldHasFocus)
    }

    @Test func aHugeSelectionIsRefusedAndAnOrdinaryOneDrags() async throws {
        let rig = Rig()
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        let table = try rig.themed()
        let rect = table.rect(ofRow: 2)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        #expect(table.canDragRows(with: IndexSet(1...3), at: point))
        let writers = (1...3).map { table.dataSource?.tableView?(table, pasteboardWriterForRow: $0) as? NSURL }
        #expect(writers.map { $0 as URL? } == [url(1), url(2), url(3)])
        #expect(!table.canDragRows(with: IndexSet(0...ThemedTable.actionLimit), at: point))
        #expect(rig.recorder.nothingHappened)
    }
}

extension Rig {
    func selectEveryRow() throws -> ThemedTable {
        let table = try themed()
        table.selectRowIndexes(IndexSet(0..<table.numberOfRows), byExtendingSelection: false)
        try #require(table.selectedRowIndexes.count == table.numberOfRows)
        return table
    }

    func reads(_ span: Range<Int>) -> Int { fake.rowRequests.filter { $0.range == span }.count }
}

extension ResultActionsTests {
    @Test func copyOverTheBoundPutsEveryPathOnThePasteboard() async throws {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let own = ActionRecorder()
        var writing = own.actions
        writing.copyPath = ResultActions.live(client: FakeSearchClient(), preview: false, pasteboard: pasteboard).copyPath
        let actions = writing
        let rig = Rig(hits: big, actions: actions)
        defer { rig.host.close() }
        try await rig.search("a", count: big.count)
        let table = try rig.selectEveryRow()
        try #require(table.tryToPerform(copySelector, with: nil))
        #expect(pasteboard.string(forType: .string) == nil)
        try await rig.host.until("10,001 paths on the pasteboard") { pasteboard.string(forType: .string) != nil }
        #expect(pasteboard.string(forType: .string) == bigPaths)
        #expect(rig.reads(0..<big.count) == 1)
        #expect(own.refused == 0)
    }

    @Test func aSelectionThatGrowsDuringTheQuestionAsksAgainAndNeverOpensMoreThanConfirmed() async throws {
        let own = ActionRecorder()
        var growing = own.actions
        var table: NSTableView?
        var grows = true
        var answers = [true, false, true]
        growing.confirmOpen = { count in
            own.asked.append("open \(count)")
            if grows {
                grows = false
                table?.selectRowIndexes(IndexSet(0...27), byExtendingSelection: false)
            }
            return answers.removeFirst()
        }
        let rig = Rig(hits: thirty, actions: growing)
        defer { rig.host.close() }
        try await rig.search("a", count: 30)
        try await rig.select(0, through: 24)
        table = try rig.table()

        try rig.host.pressReturn()
        #expect(own.asked == ["open 25", "open 28"])
        #expect(own.opened.isEmpty)
        #expect(own.recorded.isEmpty)

        try rig.host.pressReturn()
        #expect(own.asked == ["open 25", "open 28", "open 28"])
        #expect(own.opened == thirty[0..<28].map(\.fileURL))
    }

    @Test func openAndShowInFinderOverTheBoundAskFirstThenActOnEveryRow() async throws {
        let rig = Rig(hits: big)
        defer { rig.host.close() }
        try await rig.search("a", count: big.count)
        let table = try rig.selectEveryRow()
        rig.recorder.confirms = false
        table.revealSelected(nil)
        #expect(rig.recorder.asked == ["reveal 10001"])
        #expect(rig.reads(0..<big.count) == 0)

        rig.recorder.confirms = true
        table.revealSelected(nil)
        #expect(rig.recorder.asked == ["reveal 10001", "reveal 10001"])
        #expect(rig.recorder.reveals == 0)
        try await rig.host.until("one reveal") { rig.recorder.reveals == 1 }
        #expect(rig.recorder.revealed == big.map(\.fileURL))

        try rig.host.pressReturn()
        #expect(rig.recorder.asked.last == "open 10001")
        try await rig.host.until("10,001 opens") { rig.recorder.opened.count == big.count }
        #expect(rig.recorder.opened == big.map(\.fileURL))
        #expect(rig.recorder.recorded == big.map(\.path))
        #expect(rig.recorder.reveals == 1)
        #expect(rig.recorder.refused == 0)
    }

    @Test func aHeldReadLeavesTheMainActorFreeAndIgnoresEveryOtherPress() async throws {
        let rig = Rig(hits: big)
        defer { rig.host.close() }
        try await rig.search("a", count: big.count)
        let table = try rig.selectEveryRow()
        let hold = rig.fake.holdNextRead()
        defer { hold.release() }
        table.copy(nil)
        try await rig.host.until("the read to start") { rig.reads(0..<big.count) == 1 }
        #expect(rig.model.rows(in: 9_000..<9_002) == Array(big[9_000..<9_002]))
        table.copy(nil)
        table.openSelected(nil)
        table.revealSelected(nil)
        #expect(rig.reads(0..<big.count) == 1)
        #expect(rig.recorder.asked.isEmpty)
        #expect(rig.recorder.copied.isEmpty)

        hold.release()
        try await rig.host.until("the copy") { rig.recorder.copied.count == 1 }
        #expect(rig.recorder.copied == [bigPaths])
        #expect(rig.reads(0..<big.count) == 1)
        #expect(rig.recorder.opened.isEmpty && rig.recorder.revealed.isEmpty)
        #expect(rig.recorder.refused == 0)
    }

    @Test func aNewSearchDuringTheReadStillCopiesThePressTimeRows() async throws {
        let rig = Rig(hits: big)
        defer { rig.host.close() }
        try await rig.search("a", count: big.count)
        let table = try rig.selectEveryRow()
        let hold = rig.fake.holdNextRead()
        defer { hold.release() }
        table.copy(nil)
        try await rig.host.until("the read to start") { rig.reads(0..<big.count) == 1 }

        let other = big.map { SearchHit.named("new-\($0.name)", in: "/Volumes/Other") }
        rig.fake.setHits(other)
        try await rig.search("b", count: other.count)
        try await rig.host.until("the new rows in the table") { rig.model.rows(in: 0..<1) == [other[0]] }
        hold.release()
        try await rig.host.until("the copy") { rig.recorder.copied.count == 1 }
        #expect(rig.recorder.copied == [bigPaths])
        #expect(rig.recorder.refused == 0)
    }

    @Test func aReadThatThrowsBeepsOnceAndTheNextPressCopies() async throws {
        let rig = Rig(hits: big)
        defer { rig.host.close() }
        try await rig.search("a", count: big.count)
        let table = try rig.selectEveryRow()
        let hold = rig.fake.holdNextRead()
        defer { hold.release() }
        table.copy(nil)
        try await rig.host.until("the read to start") { rig.reads(0..<big.count) == 1 }
        hold.release(throwing: .staleGeneration)
        try await rig.host.until("one beep") { rig.recorder.refused == 1 }
        #expect(rig.recorder.copied.isEmpty)

        table.copy(nil)
        try await rig.host.until("the copy") { rig.recorder.copied.count == 1 }
        #expect(rig.recorder.copied == [bigPaths])
        #expect(rig.recorder.refused == 1)
    }

    @Test func aShortReadBeepsAndNeverActsOnShiftedRows() async throws {
        let rig = Rig(hits: big)
        defer { rig.host.close() }
        try await rig.search("a", count: big.count + 5)
        let table = try rig.selectEveryRow()
        table.copy(nil)
        try await rig.host.until("one beep") { rig.recorder.refused == 1 }
        #expect(rig.recorder.copied.isEmpty)
    }

    @Test func aSelectionWithGapsOverTheBoundCopiesOnlyTheSelectedRows() async throws {
        let hits = (0..<big.count + 2).map { SearchHit.named("hit-\($0)", in: folder) }
        let rig = Rig(hits: hits)
        defer { rig.host.close() }
        try await rig.search("a", count: hits.count)
        let table = try rig.themed()
        var rows = IndexSet(0..<hits.count)
        rows.remove(7)
        rows.remove(5_000)
        table.selectRowIndexes(rows, byExtendingSelection: false)
        try #require(table.selectedRowIndexes.count == big.count)
        table.copy(nil)
        try await rig.host.until("the copy") { rig.recorder.copied.count == 1 }
        #expect(rig.recorder.copied == [rows.map { hits[$0].path }.joined(separator: "\n")])
        #expect(rig.reads(0..<hits.count) == 1)
    }

    @Test func atTheBoundEveryActionRunsAtOnce() async throws {
        let hits = Array(big.prefix(ThemedTable.actionLimit))
        let rig = Rig(hits: hits)
        defer { rig.host.close() }
        try await rig.search("a", count: hits.count)
        let table = try rig.selectEveryRow()
        table.copy(nil)
        #expect(rig.recorder.copied == [hits.map(\.path).joined(separator: "\n")])
        table.revealSelected(nil)
        #expect(rig.recorder.revealed == hits.map(\.fileURL))
        #expect(rig.recorder.reveals == 1)
        table.openSelected(nil)
        #expect(rig.recorder.opened == hits.map(\.fileURL))
        #expect(rig.recorder.asked == ["reveal 10000", "open 10000"])
        #expect(rig.reads(0..<hits.count) == 0)
        #expect(rig.recorder.refused == 0)
    }
}

extension ResultActionsTests {
    @Test func plainTableBehaviourForCommandArrowsIsRecordedFirst() async throws {
        let rig = Rig(hits: thirty)
        defer { rig.host.close() }
        try await rig.search("a", count: 30)
        let table = try rig.table()
        let clip = try #require(table.enclosingScrollView?.contentView)
        let visible = table.rows(in: table.visibleRect)
        let last = visible.location + visible.length - 1
        try #require(last + 1 < thirty.count)
        try await rig.select(last)
        let top = clip.bounds.origin.y
        try rig.host.press(.downArrow, flags: .command)
        #expect(table.selectedRowIndexes == [last + 1])
        #expect(clip.bounds.origin.y > top)
        #expect(table.rows(in: table.visibleRect).contains(last + 1))
        let scrolled = clip.bounds.origin.y
        try rig.host.press(.upArrow, flags: .command)
        #expect(table.selectedRowIndexes == [last])
        #expect(clip.bounds.origin.y == scrolled)
        try await rig.select(0)
        try rig.host.press(.upArrow, flags: .command)
        #expect(table.selectedRowIndexes == [0])
        #expect(rig.host.listHasFocus)
        try rig.host.press(.downArrow, flags: .command)
        #expect(table.selectedRowIndexes == [1])
        #expect(rig.recorder.nothingHappened)
    }
}

private let archives = [
    hit("a.zip", in: folder), hit("b.zip", in: folder), hit("notes.txt", in: folder), hit("c.zip", in: folder),
    hit("Docs", in: folder, kind: .folder),
]

private func isZip(_ hit: SearchHit) -> Bool { hit.name.hasSuffix(".zip") }

private func marker(_ row: Int) -> URL { URL(filePath: "/preview/hit-\(row)", directoryHint: .notDirectory) }

private let standardTitles = [
    String(localized: "Open", table: "Results"), String(localized: "Show in Finder", table: "Results"),
    String(localized: "Quick Look", table: "Results"), String(localized: "Copy Path", table: "Results"),
]

private let showArchiveTitle = String(localized: "Show Archive Contents", table: "Results")

extension ResultActionsTests {
    @Test func commandDownOnAnArchiveRowGoesInside() async throws {
        let own = ActionRecorder()
        let rig = Rig(hits: archives, actions: own.actions(inside: isZip))
        defer { rig.host.close() }
        try await rig.search("as", count: archives.count)
        let table = try rig.table()
        table.selectRowIndexes([0], byExtendingSelection: false)
        let editor = try #require(rig.host.field()?.currentEditor() as? NSTextView)
        editor.selectedRange = NSRange(location: 0, length: 0)
        try rig.host.press(.downArrow, flags: .command)
        #expect(editor.selectedRange == NSRange(location: 2, length: 0))
        try rig.host.press(.upArrow, flags: .command)
        #expect(editor.selectedRange == NSRange(location: 0, length: 0))
        #expect(rig.host.fieldHasFocus)
        #expect(rig.model.query == "as")
        #expect(own.nothingHappened)

        try await rig.host.focusList()
        try rig.host.press(.downArrow, flags: .command)
        #expect(own.entered == [archives[0].path])
        #expect(table.selectedRowIndexes == [0])
        #expect(rig.host.listHasFocus)
        #expect(own.opened.isEmpty && own.shown.isEmpty && own.refused == 0)
        try rig.host.pressReturn()
        #expect(own.opened == [archives[0].fileURL])
        #expect(own.entered == [archives[0].path])
    }

    @Test func commandDownOnAPlainFileOrFolderKeepsTodaysTableBehaviour() async throws {
        let own = ActionRecorder()
        let rig = Rig(hits: archives, actions: own.actions(inside: isZip))
        defer { rig.host.close() }
        try await rig.search("a", count: archives.count)
        let table = try rig.table()
        try await rig.select(2)
        try rig.host.press(.downArrow, flags: .command)
        #expect(table.selectedRowIndexes == [3])
        #expect(own.nothingHappened)
        try #require(rig.host.window.firstResponder?.tryToPerform(copySelector, with: nil) == true)
        #expect(own.copied == [archives[3].path])

        try await rig.select(4)
        try rig.host.press(.downArrow, flags: .command)
        #expect(table.selectedRowIndexes == [4])
        try rig.host.sendKeys(" ")
        #expect(own.shown == [archives[4].fileURL])
        #expect(own.entered.isEmpty && own.refused == 0)
    }

    @Test func commandUpCallsEnclosingOnlyWhenSet() async throws {
        do {
            let own = ActionRecorder()
            let rig = Rig(hits: archives, actions: own.actions(inside: isZip))
            defer { rig.host.close() }
            try await rig.search("a", count: archives.count)
            try await rig.select(2)
            try rig.host.press(.upArrow, flags: .command)
            #expect(try rig.table().selectedRowIndexes == [1])
            #expect(own.nothingHappened)
            try rig.host.press(.downArrow)
            #expect(try rig.table().selectedRowIndexes == [2])
        }
        let own = ActionRecorder()
        let rig = Rig(hits: archives, actions: own.actions(inside: isZip, enclosing: true))
        defer { rig.host.close() }
        try await rig.search("a", count: archives.count)
        try await rig.select(2)
        try rig.host.press(.upArrow, flags: .command)
        #expect(own.enclosings == 1)
        #expect(try rig.table().selectedRowIndexes == [2])
        #expect(own.entered.isEmpty && own.refused == 0)
        try rig.host.press(.downArrow)
        #expect(try rig.table().selectedRowIndexes == [3])
        #expect(own.enclosings == 1)
    }

    @Test func menuAddsShowArchiveContentsWithCommandDownOnlyForArchiveRows() async throws {
        do {
            let bare = Rig(hits: archives)
            defer { bare.host.close() }
            try await bare.search("a", count: archives.count)
            let none = try #require(try bare.table().menu(for: try bare.rightClick(0)))
            #expect(none.items.map(\.title) == standardTitles)
            #expect(bare.recorder.nothingHappened)
        }
        let own = ActionRecorder()
        let rig = Rig(hits: archives, actions: own.actions(inside: isZip))
        defer { rig.host.close() }
        try await rig.search("a", count: archives.count)
        try await rig.select(2)
        let table = try rig.table()
        let menu = try #require(table.menu(for: try rig.rightClick(1)))
        #expect(table.selectedRowIndexes == [1])
        #expect(menu.items.map(\.title) == [standardTitles[0], showArchiveTitle, standardTitles[1], standardTitles[2], standardTitles[3]])
        let item = menu.items[1]
        #expect(item.keyEquivalent == String(Character(NSEvent.SpecialKey.downArrow.unicodeScalar)))
        #expect(item.keyEquivalentModifierMask == .command)
        menu.update()
        #expect(menu.items.filter { !$0.isEnabled }.isEmpty)
        let action = try #require(item.action)
        try #require(NSApp.sendAction(action, to: item.target, from: item))
        #expect(own.entered == [archives[1].path])
        #expect(own.opened.isEmpty && own.revealed.isEmpty && own.shown.isEmpty && own.refused == 0)

        for row in [2, 4] {
            let plain = try #require(table.menu(for: try rig.rightClick(row)))
            #expect(plain.items.map(\.title) == standardTitles)
        }
        try #require(NSApp.sendAction(#selector(ThemedTable.showInside(_:)), to: table, from: nil))
        #expect(own.refused == 1)
        #expect(own.entered == [archives[1].path])
    }

    @Test func commandDownActsOnTheFirstSelectedRowOnly() async throws {
        let own = ActionRecorder()
        let rig = Rig(hits: archives, actions: own.actions(inside: isZip))
        defer { rig.host.close() }
        try await rig.search("a", count: archives.count)
        try await rig.select(0, through: 1)
        try rig.host.press(.downArrow, flags: .command)
        #expect(own.entered == [archives[0].path])
        #expect(try rig.table().selectedRowIndexes == [0, 1])
        try rig.host.pressReturn(command: true)
        #expect(own.revealed == [archives[0].fileURL, archives[1].fileURL])
        #expect(own.reveals == 1)
        #expect(own.entered == [archives[0].path])

        try await rig.select(2, through: 3)
        try rig.host.press(.downArrow, flags: .command)
        #expect(own.entered == [archives[0].path])
        #expect(try rig.table().selectedRowIndexes == [4])
    }

    @Test func quickLookAsksPreviewItem() async throws {
        let own = ActionRecorder()
        var writing = own.actions
        writing.previewItem = { $0.name == "hit-3" ? nil : URL(filePath: "/preview/\($0.name)", directoryHint: .notDirectory) }
        let actions = writing
        let rig = Rig(actions: actions)
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        try await rig.select(1)
        let table = try rig.themed()
        try rig.host.sendKeys(" ")
        #expect(own.shown == [marker(1)])
        #expect((table.previewPanel(nil, previewItemAt: 0) as? NSURL) as URL? == marker(1))
        try rig.host.press(.downArrow)
        #expect(own.refreshed == [marker(2)])
        try rig.host.press(.downArrow)
        #expect(own.refreshed == [marker(2), nil])
        #expect((table.previewPanel(nil, previewItemAt: 0) as? NSURL) == nil)
        try rig.host.sendKeys(" ")
        #expect(own.hides == 1)
        try rig.host.sendKeys(" ")
        #expect(own.shown == [marker(1), nil])

        own.quickLookOpen = false
        let menu = try #require(table.menu(for: try rig.rightClick(4)))
        let quickLook = try #require(menu.items.first { $0.action == #selector(ThemedTable.showQuickLook(_:)) })
        try #require(NSApp.sendAction(#selector(ThemedTable.showQuickLook(_:)), to: quickLook.target, from: quickLook))
        #expect(own.shown == [marker(1), nil, marker(4)])
        try #require(NSApp.sendAction(#selector(ThemedTable.showQuickLook(_:)), to: quickLook.target, from: quickLook))
        #expect(own.refreshed == [marker(2), nil, marker(4)])
        #expect(own.opened.isEmpty && own.copied.isEmpty)
    }

    @Test func quickLookFromTheMenuFocusesTheTableSoThePanelFindsItsData() async throws {
        final class Panel {
            var window: NSWindow?
            var open = false
            var hides = 0
            var shown: [NSResponder?] = []
            var refreshed: [NSResponder?] = []
        }
        let panel = Panel()
        var writing = ActionRecorder().actions
        writing.quickLook = ResultActions.QuickLook(
            isOpen: { panel.open },
            show: { _ in
                panel.shown.append(panel.window?.firstResponder)
                panel.open = true
            },
            hide: {
                panel.hides += 1
                panel.open = false
            },
            refresh: { _ in panel.refreshed.append(panel.window?.firstResponder) }
        )
        let rig = Rig(actions: writing)
        defer { rig.host.close() }
        panel.window = rig.host.window
        try await rig.search("a", count: 6)
        let table = try rig.themed()
        let chooseQuickLook: (Int) throws -> Void = { row in
            let menu = try #require(table.menu(for: try rig.rightClick(row)))
            let item = try #require(menu.items.first { $0.action == #selector(ThemedTable.showQuickLook(_:)) })
            try #require(NSApp.sendAction(#selector(ThemedTable.showQuickLook(_:)), to: item.target, from: item))
        }

        try #require(rig.host.window.focusSearchField() != nil)
        try chooseQuickLook(2)
        #expect(panel.shown.count == 1 && (panel.shown.last ?? nil) === table, "the field held focus: \(String(describing: panel.shown.last))")
        #expect(rig.host.listHasFocus)

        try #require(rig.host.window.focusSearchField() != nil)
        let refreshes = panel.refreshed.count
        try chooseQuickLook(3)
        #expect(panel.shown.count == 1)
        #expect(panel.refreshed.count > refreshes && (panel.refreshed.last ?? nil) === table, "an open panel: \(String(describing: panel.refreshed.last))")

        try rig.host.sendKeys(" ")
        #expect(panel.hides == 1 && !panel.open)
        #expect(rig.model.query == "a")

        try await rig.host.focusList()
        try chooseQuickLook(4)
        #expect(panel.shown.count == 2 && (panel.shown.last ?? nil) === table)
        #expect(table.selectedRowIndexes == [4])
    }

    @Test func dragAsksDragItem() async throws {
        let own = ActionRecorder()
        let promise = NSPasteboardItem()
        var asked: [String] = []
        var writing = own.actions
        writing.dragItem = {
            asked.append($0.path)
            return promise
        }
        let actions = writing
        let rig = Rig(actions: actions)
        defer { rig.host.close() }
        try await rig.search("a", count: 6)
        let table = try rig.table()
        let writer = try #require(table.dataSource?.tableView?(table, pasteboardWriterForRow: 2))
        #expect(writer as AnyObject === promise)
        #expect(asked == [path(2)])
        #expect((ResultActions.inert.dragItem(six[2]) as? NSURL) as URL? == url(2))
        #expect(own.nothingHappened)
    }

    @Test func moreMenuRunsAfterTheStandardItems() async throws {
        let own = ActionRecorder()
        var asked: [String] = []
        var writing = own.actions(inside: isZip)
        writing.moreMenu = { menu, hit in
            asked.append(hit.path)
            menu.addItem(withTitle: "More", action: nil, keyEquivalent: "")
        }
        let actions = writing
        let rig = Rig(hits: archives, actions: actions)
        defer { rig.host.close() }
        try await rig.search("a", count: archives.count)
        let table = try rig.table()
        let plain = try #require(table.menu(for: try rig.rightClick(2)))
        #expect(plain.items.map(\.title) == standardTitles + ["More"])
        let archive = try #require(table.menu(for: try rig.rightClick(0)))
        #expect(archive.items.map(\.title) == [standardTitles[0], showArchiveTitle, standardTitles[1], standardTitles[2], standardTitles[3], "More"])
        #expect(asked == [archives[2].path, archives[0].path])
        #expect(own.nothingHappened)
    }
}
