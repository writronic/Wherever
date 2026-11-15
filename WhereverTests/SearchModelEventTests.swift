import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private final class SeenWindow: NSWindow {
    var seen = true

    override var occlusionState: NSWindow.OcclusionState { seen ? .visible : [] }

    func set(seen: Bool) {
        self.seen = seen
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }
}

@Suite struct SearchModelEventTests {
    private static let marker = IndexState(phase: .ready, indexed: 1)

    @Test func aStateChangeReachesIndexState() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        #expect(index.indexState == nil)
        let crawling = IndexState(phase: .crawling, indexed: 100_000)
        fake.send(.stateChanged(crawling))
        try await untilTrue(waitingFor: "the crawling state") { index.indexState == crawling }
        let ready = IndexState(phase: .ready, indexed: 250_000)
        fake.send(.stateChanged(ready))
        try await untilTrue(waitingFor: "the ready state") { index.indexState == ready }
        withExtendedLifetime(model) {}
        #expect(fake.queries.isEmpty)
    }

    @Test func aStateChangeKeepsTheBootPhaseAndTheIndexingDisks() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let state = IndexState(phase: .crawling, bootPhase: .live, indexingDisks: ["Disk 1"], indexed: 5)
        fake.send(.stateChanged(state))
        try await untilTrue(waitingFor: "the state") { index.indexState == state }
        #expect(index.indexState?.bootPhase == .live)
        #expect(index.indexState?.indexingDisks == ["Disk 1"])
    }

    @Test func resultsChangedSearchesTheQueryAgainAndKeepsTheOldRows() async throws {
        let fake = FakeSearchClient(hits: [.named("Old.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the first rows") { model.names == ["Old.app"] }

        fake.setHits([.named("New.app")])
        fake.send(.resultsChanged)
        try await untilTrue(waitingFor: "the second search") { fake.queries == ["a", "a"] }
        #expect(model.names == ["Old.app"])
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the new rows") { model.names == ["New.app"] }
    }

    @Test func aFileChangeRefreshesAndTypingSearches() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the first rows") { model.names == ["Safari.app"] }
        #expect(fake.refreshes.isEmpty, "a typed search is never a refresh")

        fake.send(.resultsChanged)
        try await untilTrue(waitingFor: "the refresh") { fake.queries == ["a", "a"] }
        #expect(fake.refreshes == ["a"])

        model.query = "ab"
        #expect(fake.queries == ["a", "a", "ab"])
        #expect(fake.refreshes == ["a"], "typing asks a search, never a refresh")
    }

    @Test func aRefreshLeavesTheShownSearchTime() async throws {
        let fake = FakeSearchClient(hits: [.named("Old.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the first rows") { model.names == ["Old.app"] }
        let time = try #require(model.lastSearchTime)

        fake.setHits([.named("Old.app"), .named("New.app")])
        fake.send(.resultsChanged)
        try await untilTrue(waitingFor: "the refresh") { fake.refreshes == ["a"] }
        let refreshed = fake.latest
        fake.send(.resultsReady(refreshed, count: 2))
        try await untilTrue(waitingFor: "the refreshed rows") { model.results.generation == refreshed && model.count == 2 }
        #expect(model.names == ["Old.app", "New.app"])
        #expect(model.lastSearchTime == time)
    }

    @Test func resultsChangedWithNoQuerySearchesNothing() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        fake.send(.resultsChanged)
        fake.send(.stateChanged(Self.marker))
        try await untilTrue(waitingFor: "both events") { index.indexState == Self.marker }
        #expect(fake.queries.isEmpty)
        #expect(model.count == 0)
    }

    @Test func tenChangesDuringOneSearchCauseOneMoreSearch() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        let running = fake.latest
        for _ in 0..<10 { fake.send(.resultsChanged) }
        fake.send(.stateChanged(Self.marker))
        try await untilTrue(waitingFor: "the ten changes") { index.indexState == Self.marker }
        #expect(fake.queries == ["a"], "no change restarts the running search")

        fake.send(.resultsReady(running, count: 1))
        try await untilTrue(waitingFor: "the running search's rows") { model.results.generation == running }
        #expect(fake.queries == ["a", "a"], "one catch-up search for all ten")
        #expect(model.names == ["Safari.app"])
        let again = fake.latest
        fake.send(.resultsReady(again, count: 1))
        try await untilTrue(waitingFor: "the live rows") { model.results.generation == again }
        #expect(model.results.live)
        #expect(fake.queries == ["a", "a"])
    }

    @Test func twoResultsChangedInARowLeaveOnlyTheLastSearchCurrent() async throws {
        let fake = FakeSearchClient(hits: [.named("Old.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        let first = fake.latest
        fake.send(.resultsReady(first, count: 1))
        try await untilTrue(waitingFor: "the first rows") { model.names == ["Old.app"] }

        fake.setHits([.named("New.app")])
        fake.send(.resultsChanged)
        fake.send(.resultsChanged)
        fake.send(.stateChanged(Self.marker))
        try await untilTrue(waitingFor: "both changes") { index.indexState == Self.marker }
        #expect(fake.queries == ["a", "a"], "the second change waits for the first one's search")
        let live = fake.latest
        #expect(model.names == ["Old.app"])

        fake.send(.resultsReady(live, count: 1))
        try await untilTrue(waitingFor: "the catch-up search") { fake.queries == ["a", "a", "a"] }
        let last = fake.latest
        #expect(model.results.generation == live)
        #expect(model.names == ["New.app"])
        fake.send(.resultsReady(live, count: 1))
        fake.send(.resultsReady(last, count: 1))
        try await untilTrue(waitingFor: "the last search's rows") { model.results.generation == last && model.names == ["New.app"] }
        #expect(fake.rowRequests.map(\.generation) == [first, live, last])
    }

    @Test func resultsChangedAfterTheQueryWasClearedSearchesNothing() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the rows") { model.names == ["Safari.app"] }
        model.query = ""

        fake.send(.resultsChanged)
        fake.send(.stateChanged(Self.marker))
        try await untilTrue(waitingFor: "both events") { index.indexState == Self.marker }
        #expect(fake.queries == ["a"])
        #expect(model.count == 0)
    }

    @Test func aStaleGenerationsResultsLeaveTheSearchTimeAlone() async throws {
        let fake = FakeSearchClient(hits: [.named("Old.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        let first = fake.latest
        fake.send(.resultsReady(first, count: 1))
        try await untilTrue(waitingFor: "the first rows") { model.names == ["Old.app"] }
        let time = try #require(model.lastSearchTime)

        model.query = "ab"
        let second = fake.latest
        fake.send(.resultsReady(first, count: 5))
        fake.send(.stateChanged(Self.marker))
        try await untilTrue(waitingFor: "both events") { index.indexState == Self.marker }
        #expect(model.lastSearchTime == time)
        #expect(model.count == 1)

        fake.send(.resultsReady(second, count: 1))
        try await untilTrue(waitingFor: "the second rows") { model.results.generation == second }
        #expect(model.lastSearchTime != time)
    }

    @Test func aSecondResultsReadyForTheCurrentGenerationGrowsTheCountAndKeepsRowZero() async throws {
        let fake = FakeSearchClient(hits: [.named("First.app"), .named("Second.app"), .named("Third.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        let generation = fake.latest
        fake.send(.resultsReady(generation, count: 1))
        try await untilTrue(waitingFor: "the first page") { model.names == ["First.app"] }
        #expect(model.results.live == false)

        fake.send(.resultsReady(generation, count: 3))
        try await untilTrue(waitingFor: "the whole count") { model.count == 3 }
        #expect(model.names == ["First.app", "Second.app", "Third.app"])
        #expect(model.results.generation == generation)
        #expect(model.results.live)
        #expect(fake.queries == ["a"])
    }

    @Test func aLateResultForTheReplacedSearchStaysOut() async throws {
        let fake = FakeSearchClient(hits: [.named("Old.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        let first = fake.latest
        fake.send(.resultsReady(first, count: 1))
        try await untilTrue(waitingFor: "the first rows") { model.names == ["Old.app"] }

        fake.setHits([.named("New.app")])
        fake.send(.resultsChanged)
        try await untilTrue(waitingFor: "the second search") { fake.queries == ["a", "a"] }
        fake.send(.resultsReady(first, count: 1))
        fake.send(.stateChanged(Self.marker))
        try await untilTrue(waitingFor: "both events") { index.indexState == Self.marker }
        #expect(fake.rowRequests.map(\.generation) == [first])
        #expect(model.names == ["Old.app"])

        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the new rows") { model.names == ["New.app"] }
    }

    @Test func aThrowingSearchShowsTheFailureLine() {
        let fake = FakeSearchClient(hits: [.named("a.txt")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        fake.fail(with: .io)
        model.query = "a"
        #expect(model.failed)
        #expect(model.results.generation == nil && model.count == 0)
        #expect(!model.isPending)

        fake.fail(with: .staleGeneration)
        model.query = "ab"
        #expect(!model.failed, "a stale generation is no failure")

        let lost = SearchModel(session: nil)
        lost.query = "a"
        #expect(lost.failed, "a window without a session")
    }

    @Test func aNewSearchAfterAFailureClearsTheLine() async throws {
        let fake = FakeSearchClient(hits: [.named("a.txt")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        fake.fail(with: .io)
        model.query = "a"
        #expect(model.failed)

        fake.fail(with: nil)
        model.query = "ab"
        #expect(!model.failed)
        #expect(fake.queries == ["ab"])
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the new rows") { model.names == ["a.txt"] }
        #expect(!model.failed)

        fake.fail(with: .io)
        model.query = "abc"
        #expect(model.failed)
        model.query = ""
        #expect(!model.failed, "an emptied field searches nothing, so nothing failed")
    }

    @Test func aSearchTheEngineCouldNotAnswerShowsTheFailureLine() throws {
        let fake = FakeSearchClient(hits: [.named("a.txt")])
        let model = SearchModel(session: try fake.makeSession())
        model.query = "a"
        let shown = fake.latest
        model.handle(.resultsReady(shown, count: 1))
        model.query = "ab"
        model.handle(.searchFailed(SearchGeneration(rawValue: fake.latest.rawValue + 1)))
        #expect(!model.failed, "another window's search")
        #expect(model.isPending)

        model.handle(.searchFailed(fake.latest))
        #expect(model.failed)
        #expect(!model.isPending)
        #expect(model.results.generation == shown && model.count == 1)

        model.query = "abc"
        #expect(!model.failed)
        model.handle(.resultsChanged)
        model.handle(.searchFailed(fake.latest))
        #expect(fake.queries == ["a", "ab", "abc", "abc"], "the change that waited searches again")
        model.handle(.resultsReady(fake.latest, count: 1))

        model.content = ContentTerms(terms: ["alpha"])
        model.searchContent()
        #expect(model.reading)
        model.handle(.searchFailed(fake.latest))
        #expect(model.failed)
        #expect(!model.reading)
        #expect(fake.stops == 1)
    }

    private func hiddenWindow(_ index: IndexModel, _ model: SearchModel) async throws -> SeenWindow {
        let root = ContentView(index: index, model: model).environment(\.resultActions, ActionRecorder().actions)
        let controller = NSHostingController(rootView: AnyView(root.defaultAppStorage(hostStore())))
        let window = SeenWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        try await untilTrue(waitingFor: "the window's hidden report") {
            controller.view.layoutSubtreeIfNeeded()
            window.set(seen: false)
            return !model.visible
        }
        return window
    }

    private func answered(_ fake: FakeSearchClient, _ model: SearchModel) async throws {
        let generation = fake.latest
        fake.send(.resultsReady(generation, count: 1))
        try await untilTrue(waitingFor: "the answer") { model.results.generation == generation }
    }

    private func handled(_ index: IndexModel, _ fake: FakeSearchClient) async throws {
        let marker = IndexState(phase: .ready, indexed: (index.indexState?.indexed ?? 0) + 1)
        fake.send(.stateChanged(marker))
        try await untilTrue(waitingFor: "every event before the marker") { index.indexState == marker }
    }

    @Test func aHiddenWindowSearchesNothingUntilItShows() async throws {
        let fake = FakeSearchClient(hits: [.named("Old.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        try await answered(fake, model)
        let window = try await hiddenWindow(index, model)
        defer {
            window.contentViewController = nil
            window.close()
        }

        fake.setHits([.named("New.app")])
        for _ in 0..<3 { fake.send(.resultsChanged) }
        try await handled(index, fake)
        #expect(fake.queries == ["a"], "a window nobody can see searches nothing")

        window.set(seen: true)
        #expect(model.visible)
        #expect(fake.queries == ["a", "a"], "it lists again once when it shows")
        try await answered(fake, model)
        #expect(model.results.live)
        #expect(model.names == ["New.app"])
    }

    @Test func aStaleWindowSearchesOnceWhenShown() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        let first = fake.latest
        model.visible = false
        for _ in 0..<5 { fake.send(.resultsChanged) }
        fake.send(.resultsReady(first, count: 1))
        try await handled(index, fake)
        #expect(model.results.generation == first, "the running search's answer still shows")
        #expect(fake.queries == ["a"], "nor does its answer search while the window is hidden")

        model.visible = true
        #expect(fake.queries == ["a", "a"], "one search for every change that waited")
        model.visible = false
        model.visible = true
        #expect(fake.queries == ["a", "a"], "showing it again while that search runs adds none")
        try await answered(fake, model)
        #expect(model.results.live)
        #expect(fake.queries == ["a", "a"])
    }

    @Test func typingWhileStaleSearchesTheTypedTextOnce() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        fake.send(.resultsChanged)
        try await handled(index, fake)
        model.query = "ab"
        #expect(fake.queries == ["a", "ab"])
        try await answered(fake, model)
        #expect(fake.queries == ["a", "ab"], "the typed search saw the change that waited")
        #expect(!model.results.live)

        model.visible = false
        fake.send(.resultsChanged)
        try await handled(index, fake)
        model.query = "abc"
        #expect(fake.queries == ["a", "ab", "abc"], "typing searches at once, seen or not")
        model.visible = true
        try await answered(fake, model)
        #expect(fake.queries == ["a", "ab", "abc"])
    }

    @Test func unminimizingWithNoChangeSearchesNothing() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        try await answered(fake, model)
        model.visible = false
        model.visible = true
        #expect(fake.queries == ["a"])

        fake.send(.resultsChanged)
        try await untilTrue(waitingFor: "the live search") { fake.queries == ["a", "a"] }
    }

    @Test func aWindowClosedWhileStaleSearchesNothing() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        try await answered(fake, model)
        let window = try await hiddenWindow(index, model)
        fake.send(.resultsChanged)
        try await handled(index, fake)

        window.contentViewController = nil
        window.close()
        window.set(seen: true)
        fake.send(.resultsChanged)
        try await handled(index, fake)
        #expect(!model.visible)
        #expect(fake.queries == ["a"])
        withExtendedLifetime(model) {}
    }

    @Test func aSortWhileAChangeWaitsSearchesAgain() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        fake.send(.resultsChanged)
        try await handled(index, fake)
        let bySize = SearchSort(column: .size, ascending: false)
        model.sort = bySize
        #expect(fake.session(fake.lastSession)?.searches.last == .init(query: "a", sort: bySize))
        #expect(fake.session(fake.lastSession)?.sorts.isEmpty == true)
        try await answered(fake, model)
        #expect(fake.queries == ["a", "a"])
    }

    @Test func aKindPillWinsOverATypedKindAndAddsToATypedTypeOrExtension() {
        let steps: [(typed: String, sent: String, set: (inout SearchFilters) -> Void)] = [
            ("kind:folder", "type:image", { $0.kind = .images }),
            ("report kind:folder", "report type:image", { $0.kind = .images }),
            ("kind:file  report", "report kind:folder", { $0.kind = .folders }),
            ("type:video", "type:video type:image", { $0.kind = .images }),
            ("ext:docx", "ext:docx ext:pdf", { $0.extensions = "pdf" }),
            ("kind:folder", "kind:folder ext:pdf", { $0.extensions = "pdf" }),
            ("\"my kind:folder\"", "\"my kind:folder\" type:image", { $0.kind = .images }),
            ("!kind:folder", "!kind:folder type:image", { $0.kind = .images }),
        ]
        for step in steps {
            let fake = FakeSearchClient()
            let index = IndexModel(client: fake)
            let model = index.makeModel()
            model.query = step.typed
            step.set(&model.filters)
            #expect(fake.queries == [step.typed, step.sent], "\(step.typed)")
        }
    }
}
