import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private let nameAscending = SearchSort(column: .name, ascending: true)

private final class FullListRig {
    let fake: FakeSearchClient
    let index: IndexModel
    let model: SearchModel
    let session: SearchSessionID
    let store: UserDefaults
    let host: SearchHost

    init(mode: WindowMode = .simple, hidesHidden: Bool = false, count: Int = 5) {
        let name = "com.writronic.wherever.tests.fulllist"
        store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        store.set(mode.rawValue, forKey: WindowMode.key)
        store.set(hidesHidden, forKey: SearchFilters.hidesHiddenKey)
        fake = FakeSearchClient(hits: (0..<count).map { .named(String(format: "report-%03d", $0)) })
        index = IndexModel(client: fake)
        let model = index.makeModel(listsAll: true, defaults: store)
        self.model = model
        session = fake.lastSession
        host = SearchHost(root: AnyView(ContentView(index: index, model: model)
            .environment(\.searchClient, fake).defaultAppStorage(store)), reportsKey: true)
    }

    var searches: [FakeSearchClient.Search] { fake.session(session)?.searches ?? [] }

    func table() throws -> NSTableView { try #require(host.list()) }

    func column(_ column: ResultsTable.Column) throws -> NSTableColumn {
        try #require(table().tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)))
    }

    func finish(_ count: Int = 5) async throws {
        let generation = SearchGeneration(rawValue: try #require(fake.session(session)?.latest))
        fake.finish(session, count: count)
        try await host.until("the listing's answer and table") {
            self.model.results.generation == generation && self.host.list()?.numberOfRows == count
        }
    }

    func click(_ column: ResultsTable.Column, at fraction: CGFloat = 0.5) async throws {
        let table = try table()
        let header = try #require(table.headerView)
        let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
        table.scrollColumnToVisible(index)
        host.view.layoutSubtreeIfNeeded()
        let rect = header.headerRect(ofColumn: index)
        let point = NSPoint(x: rect.minX + rect.width * fraction, y: rect.midY)
        try #require(header.visibleRect.contains(point))
        try await EventQueueLock.run {
            try host.postClicks(at: header.convert(point, to: nil), counts: 1...1)
            host.sendQueuedEvents()
        }
    }
}

@Suite(.serialized) struct FullListTests {
    @Test func aListingModelSearchesOnceAToZ() {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let store = hostStore()
        store.set(true, forKey: SearchFilters.hidesHiddenKey)
        let model = index.makeModel(listsAll: true, defaults: store)
        #expect(model.query.isEmpty && model.filters.hidesHidden)
        #expect(fake.session(fake.lastSession)?.searches == [.init(query: "hidden:no", sort: nameAscending)])
        #expect(model.sort == .bestMatch && model.shownSort == nameAscending)
    }

    @Test func aNewListingWindowSendsOneSearch() async throws {
        for mode in [WindowMode.simple, .normal] {
            for hidden in [false, true] {
                let rig = FullListRig(mode: mode, hidesHidden: hidden)
                defer { rig.host.close() }
                try await rig.host.until("the new field") { rig.host.field() != nil }
                try await rig.finish()
                #expect(rig.model.filters.hidesHidden == hidden)
                #expect(rig.searches == [.init(query: hidden ? "hidden:no" : "", sort: nameAscending)])
            }
        }
    }

    @Test func typingAfterTheFullListSearchesBestMatch() async throws {
        let rig = FullListRig(count: 400)
        defer { rig.host.close() }
        try await rig.finish(400)
        let table = try rig.table()
        table.selectRowIndexes([200], byExtendingSelection: false)
        table.scrollRowToVisible(200)
        try #require(table.visibleRect.minY > table.rect(ofRow: 0).maxY)
        try await rig.host.type("r")
        #expect(rig.searches == [.init(query: "", sort: nameAscending), .init(query: "r", sort: .bestMatch)])
        try await rig.finish(400)
        #expect(table.selectedRow == -1)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 0)))
        for column in table.tableColumns {
            #expect(table.indicatorImage(in: column) == nil)
            #expect(column.headerCell.accessibilitySortDirection() == .unknown)
        }
    }

    @Test func clearingTheFieldListsEverythingAToZAgain() async throws {
        for mode in [WindowMode.simple, .normal] {
            for escape in [false, true] {
                let rig = FullListRig(mode: mode, count: 400)
                defer { rig.host.close() }
                try await rig.finish(400)
                try await rig.host.type("r")
                try await rig.finish(400)
                let table = try rig.table()
                table.selectRowIndexes([200], byExtendingSelection: false)
                table.scrollRowToVisible(200)
                if escape { try rig.host.pressEscape() } else { try rig.host.sendKeys("\u{7f}") }
                #expect(rig.model.query.isEmpty)
                #expect(rig.searches == [
                    .init(query: "", sort: nameAscending), .init(query: "r", sort: .bestMatch), .init(query: "", sort: nameAscending),
                ])
                try await rig.finish(400)
                #expect(table.selectedRow == -1)
                #expect(table.visibleRect.intersects(table.rect(ofRow: 0)))
                #expect(try rig.column(.name).headerCell.accessibilitySortDirection() == .ascending)
            }
        }
    }

    @Test func aSpaceAloneListsAToZ() async throws {
        let rig = FullListRig()
        defer { rig.host.close() }
        try await rig.finish()
        let before = rig.model.names
        try await rig.host.type(" ")
        #expect(rig.searches == [.init(query: "", sort: nameAscending), .init(query: " ", sort: nameAscending)])
        try await rig.finish()
        #expect(rig.model.names == before)
        #expect(try rig.column(.name).headerCell.accessibilitySortDirection() == .ascending)
    }

    @Test func nameClicksOnTheFullListToggleTheDirection() async throws {
        let rig = FullListRig()
        defer { rig.host.close() }
        try await rig.finish()
        for (fraction, ascending) in [(0.3, false), (0.5, true), (0.7, false)] {
            let table = try rig.table()
            table.selectRowIndexes([1], byExtendingSelection: false)
            try await rig.click(.name, at: fraction)
            #expect(table.selectedRow == -1)
            #expect(rig.fake.session(rig.session)?.sorts.last == SearchSort(column: .name, ascending: ascending))
            try await rig.finish()
            #expect(try rig.column(.name).headerCell.accessibilitySortDirection() == (ascending ? .ascending : .descending))
        }
        #expect(rig.searches == [.init(query: "", sort: nameAscending)])
        #expect(rig.fake.session(rig.session)?.sorts.count == 3)
    }

    @Test func aColumnPickedOnTheFullListStaysForTypedText() async throws {
        let rig = FullListRig()
        defer { rig.host.close() }
        try await rig.finish()
        try await rig.click(.size)
        try await rig.finish()
        try await rig.host.type("r")
        let largest = SearchSort(column: .size, ascending: false)
        #expect(rig.searches == [.init(query: "", sort: nameAscending), .init(query: "r", sort: largest)])
        try await rig.finish()
        #expect(try rig.column(.size).headerCell.accessibilitySortDirection() == .descending)
    }

    @Test func aPillAloneNarrowsTheListAToZ() async throws {
        let rig = FullListRig(mode: .normal)
        defer { rig.host.close() }
        try await rig.finish()
        rig.model.filters.kind = .documents
        #expect(rig.searches == [.init(query: "", sort: nameAscending), .init(query: "type:doc", sort: nameAscending)])
        try await rig.finish()
        #expect(try rig.column(.name).headerCell.accessibilitySortDirection() == .ascending)
    }

    @Test func theOtherNameControlsAloneKeepAToZ() throws {
        let fake = FakeSearchClient()
        let model = SearchModel(session: try fake.makeSession(), listsAll: true)
        let filters: [(SearchFilters, String)] = [
            (SearchFilters(extensions: "pdf"), "ext:pdf"),
            (SearchFilters(size: .small), "size:<=1mb"),
            (SearchFilters(modified: .day), "mtime:<1d"),
            (SearchFilters(folder: "/Users/me"), "in:\"/Users/me\""),
        ]
        for (filter, query) in filters {
            model.filters = filter
            #expect(fake.session(fake.lastSession)?.searches.last == .init(query: query, sort: nameAscending))
        }
        #expect(fake.queries.count == 1 + filters.count)
    }

    @Test func hideInvisibleAloneNarrowsTheFullList() async throws {
        let rig = FullListRig()
        defer { rig.host.close() }
        try await rig.finish()
        rig.store.set(true, forKey: SearchFilters.hidesHiddenKey)
        try await rig.host.until("the hidden setting") { rig.model.filters.hidesHidden }
        #expect(rig.searches == [.init(query: "", sort: nameAscending), .init(query: "hidden:no", sort: nameAscending)])
        try await rig.finish()
        rig.store.set(false, forKey: SearchFilters.hidesHiddenKey)
        try await rig.host.until("the visible setting") { !rig.model.filters.hidesHidden }
        #expect(rig.searches.last == .init(query: "", sort: nameAscending))
        #expect(rig.searches.count == 3)
    }

    @Test func aLiveChangeRepeatsTheFullListAndKeepsTheSelection() async throws {
        let rig = FullListRig(count: 400)
        defer { rig.host.close() }
        try await rig.finish(400)
        let table = try rig.table()
        table.selectRowIndexes([200], byExtendingSelection: false)
        table.scrollRowToVisible(200)
        let place = table.visibleRect.origin
        let row = rig.model.rows(in: 200..<201)
        rig.model.visible = true
        rig.fake.send(.resultsChanged)
        try await rig.host.until("one live search") { rig.searches.count == 2 }
        #expect(rig.searches == Array(repeating: .init(query: "", sort: nameAscending), count: 2))
        #expect(table.selectedRow == 200 && table.visibleRect.origin == place)
        try await rig.finish(400)
        #expect(rig.model.results.live)
        #expect(table.selectedRow == 200 && table.visibleRect.origin == place)
        #expect(rig.model.rows(in: 200..<201) == row)
    }

    @Test func switchingToSimpleKeepsAToZ() async throws {
        let rig = FullListRig(mode: .normal)
        defer { rig.host.close() }
        try await rig.finish()
        rig.model.filters.kind = .documents
        try await rig.finish()
        rig.store.set(WindowMode.simple.rawValue, forKey: WindowMode.key)
        try await rig.host.until("the pills cleared") { rig.model.filters.kind == .any }
        #expect(rig.searches == [
            .init(query: "", sort: nameAscending), .init(query: "type:doc", sort: nameAscending), .init(query: "", sort: nameAscending),
        ])
        try await rig.finish()
        #expect(try rig.column(.name).headerCell.accessibilitySortDirection() == .ascending)
    }

    @Test func anExtensionModeWithNoNameListsAToZ() throws {
        let fake = FakeSearchClient()
        let model = SearchModel(session: try fake.makeSession(), listsAll: true)
        model.filters.nameMode = .fileExtension
        model.query = ","
        #expect(fake.session(fake.lastSession)?.searches.last == .init(query: "", sort: nameAscending))
        model.dropNormalControls()
        #expect(fake.session(fake.lastSession)?.searches.last == .init(query: ",", sort: .bestMatch))
    }

    @Test func theFullListWaitsForTheFirstAnswer() async throws {
        let rig = FullListRig()
        defer { rig.host.close() }
        rig.fake.send(.stateChanged(IndexState(phase: .crawling, indexed: 5)))
        try await rig.host.until("the indexing status") { rig.host.windowShows(StatusBarView.text(.crawling)) }
        #expect(rig.model.isPending && rig.model.results.generation == nil)
        #expect(try rig.table().numberOfRows == 0)
        #expect(!rig.host.windowShows("Search:"))
        rig.fake.send(.stateChanged(IndexState(phase: .ready, indexed: 5)))
        try await rig.finish()
        try await rig.host.until("the search count") { rig.host.windowShows("Search:") }
        #expect(rig.model.count == 5 && !rig.model.isPending)
    }

    @Test func contentWithNoFileNameUsesAToZAndNeverRereadsOnAFileChange() throws {
        let fake = FakeSearchClient()
        let model = SearchModel(session: try fake.makeSession(), listsAll: true)
        let session = fake.lastSession
        model.contentDraft = "needle"
        model.searchContent()
        #expect(fake.presses == [.init(query: "", terms: ["needle"], matchAll: false, sort: nameAscending)])
        model.handle(.resultsChanged)
        #expect(fake.queries == [""] && fake.presses.count == 1 && fake.narrows.isEmpty)
        model.query = "r"
        model.query = ""
        #expect(fake.session(session)?.narrows == [.init(query: "r", sort: .bestMatch), .init(query: "", sort: nameAscending)])
        model.sort = SearchSort(column: .size, ascending: false)
        #expect(fake.session(session)?.sorts == [SearchSort(column: .size, ascending: false)])
        model.contentDraft = ""
        #expect(fake.stops == 1)
        #expect(fake.session(session)?.searches == [.init(query: "", sort: nameAscending), .init(query: "", sort: model.sort)])
        #expect(fake.presses.count == 1)
    }

    @Test func theFullListSpeaksItsCountOnce() async throws {
        var spoken: [String] = []
        var waiting: [@MainActor () -> Void] = []
        let voice = Announcer(post: { _, text in spoken.append(text) }, schedule: { waiting.append($0) })
        let fake = FakeSearchClient(hits: [.named("report")])
        let index = IndexModel(client: fake, announcer: voice)
        let model = index.makeModel(listsAll: true, defaults: hostStore())
        let host = SearchHost(root: AnyView(ResultsTable(model: model, announcer: voice)), reportsKey: true)
        defer { host.close() }
        func answer() async throws {
            let generation = fake.latest
            fake.finish(fake.lastSession)
            try await host.until("the announcement after the answer") {
                model.results.generation == generation && host.list()?.numberOfRows == 1 && !waiting.isEmpty
            }
            let due = waiting
            waiting = []
            for work in due { work() }
        }
        try await answer()
        #expect(spoken == [ResultsTable.countText(1)])
        model.query = "r"
        try await answer()
        model.query = ""
        try await answer()
        #expect(spoken == Array(repeating: ResultsTable.countText(1), count: 3))
        model.query = "r"
        model.query = ""
        try await answer()
        #expect(spoken == Array(repeating: ResultsTable.countText(1), count: 4))
        model.handle(.resultsChanged)
        let generation = fake.latest
        fake.finish(fake.lastSession)
        try await host.until("the live table") { model.results.generation == generation && model.results.live }
        #expect(waiting.isEmpty)
        #expect(spoken.count == 4)
    }
}
