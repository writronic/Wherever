import AppKit
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

@Suite(.serialized) struct WindowSearchTests {
    private static let marker = IndexState(phase: .ready, indexed: 987)

    private func queries(_ fake: FakeSearchClient, _ session: SearchSessionID) -> [String]? {
        fake.session(session)?.searches.map(\.query)
    }

    @Test func twoWindowsSearchApartAndEachShowsOnlyItsOwnResults() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let firstModel = index.makeModel()
        let firstSession = fake.lastSession
        let secondModel = index.makeModel()
        let secondSession = fake.lastSession
        let first = SearchHost(index: index, model: firstModel)
        defer { first.close() }
        try await first.type("sa")
        first.resignKey()
        let second = SearchHost(index: index, model: secondModel)
        defer { second.close() }
        try await second.until("the second field to hold focus") { second.fieldHasFocus }
        try second.sendKeys("m")
        #expect(queries(fake, firstSession) == ["s", "sa"])
        #expect(queries(fake, secondSession) == ["m"])

        fake.finish(firstSession)
        try await first.until("the first window's row") { first.shows("Safari.app") }
        #expect(!second.shows("Safari.app"))
        #expect(secondModel.count == 0)
        #expect(secondModel.isPending)
        #expect(secondModel.query == "m")
    }

    @Test func resultsChangedSearchesAgainOnlyInWindowsWithSomethingToSearch() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let typed = index.makeModel()
        let typedSession = fake.lastSession
        let hiddenOnly = index.makeModel()
        let hiddenSession = fake.lastSession
        let kindOnly = index.makeModel()
        let kindSession = fake.lastSession
        typed.query = "sa"
        hiddenOnly.filters.hidesHidden = true
        kindOnly.filters.kind = .folders
        fake.finish(typedSession)
        fake.finish(kindSession)

        fake.send(.resultsChanged)
        fake.send(.stateChanged(Self.marker))
        try await untilTrue(waitingFor: "the event after resultsChanged") { index.indexState == Self.marker }
        #expect(queries(fake, typedSession) == ["sa", "sa"])
        #expect(queries(fake, hiddenSession) == [])
        #expect(queries(fake, kindSession) == ["kind:folder", "kind:folder"])
    }

    @Test func aStateChangeShowsInEveryWindowsStatusBar() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let first = SearchHost(index: index, model: index.makeModel())
        defer { first.close() }
        try await first.until("the first field to hold focus") { first.fieldHasFocus }
        first.resignKey()
        let second = SearchHost(index: index, model: index.makeModel())
        defer { second.close() }
        try await second.until("the second field to hold focus") { second.fieldHasFocus }
        #expect(!first.windowShows("987"))
        #expect(!second.windowShows("987"))

        fake.send(.stateChanged(Self.marker))
        try await first.until("the count in the first window") { first.windowShows("987") }
        try await second.until("the count in the second window") { second.windowShows("987") }
    }

    @Test func closingAWindowFreesItsSessionAndLeavesTheOtherWorking() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let firstSession = fake.lastSession
        let first = SearchHost(index: index, model: model)
        defer { first.close() }
        try await first.type("s")
        first.resignKey()

        weak var closedModel: SearchModel?
        let stale: SearchGeneration
        do {
            let secondModel = index.makeModel()
            closedModel = secondModel
            let second = SearchHost(index: index, model: secondModel)
            try await second.type("m")
            stale = fake.latest
            second.close()
        }
        first.becomeKey()
        try await first.until("the first field to hold focus again") { first.fieldHasFocus }
        try await untilTrue(waitingFor: "the closed window's session to go, released \(fake.released)") { fake.released == 1 }
        #expect(closedModel == nil)

        fake.send(.resultsReady(stale, count: 1))
        fake.send(.stateChanged(Self.marker))
        try await untilTrue(waitingFor: "the event after the closed window's results") { index.indexState == Self.marker }
        #expect(model.results.generation == nil)
        #expect(model.isPending)

        try first.sendKeys("a")
        #expect(queries(fake, firstSession) == ["s", "sa"])
        fake.finish(firstSession)
        try await first.until("the first window's row") { first.shows("Safari.app") }
    }

    @Test func typingInTheFirstWindowAfterASecondOpenedReachesOnlyTheFirst() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let firstModel = index.makeModel()
        let firstSession = fake.lastSession
        let secondModel = index.makeModel()
        let secondSession = fake.lastSession
        let first = SearchHost(index: index, model: firstModel)
        defer { first.close() }
        try await first.until("the first field to hold focus") { first.fieldHasFocus }
        first.resignKey()
        let second = SearchHost(index: index, model: secondModel)
        defer { second.close() }
        try await second.until("the second field to hold focus") { second.fieldHasFocus }
        second.resignKey()
        first.becomeKey()
        try await first.until("the first field to hold focus again") { first.fieldHasFocus }
        try first.sendKeys("s")
        #expect(queries(fake, firstSession) == ["s"])
        #expect(queries(fake, secondSession) == [])
        #expect(firstModel.query == "s")
        #expect(secondModel.query.isEmpty)
        #expect(second.field()?.stringValue == "")
    }

    @Test func aFilterSetInOneWindowStaysOutOfTheOthersQueries() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let firstModel = index.makeModel()
        let firstSession = fake.lastSession
        let secondModel = index.makeModel()
        let secondSession = fake.lastSession
        firstModel.filters.kind = .folders
        secondModel.query = "m"
        #expect(queries(fake, firstSession) == ["kind:folder"])
        #expect(queries(fake, secondSession) == ["m"])
        #expect(secondModel.filters == SearchFilters())
    }

    @Test func aNewWindowAfterEveryWindowClosedSearchesInAFreshSession() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let closedSession: SearchSessionID
        do {
            let host = SearchHost(index: index, model: index.makeModel())
            closedSession = fake.lastSession
            try await host.type("s")
            host.close()
        }
        try await untilTrue(waitingFor: "the closed window's session to go, released \(fake.released)") { fake.released == 1 }

        let model = index.makeModel()
        let session = fake.lastSession
        #expect(session != closedSession)
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the new field to hold focus") { host.fieldHasFocus }
        #expect(host.field()?.stringValue == "")
        try host.sendKeys("m")
        #expect(queries(fake, session) == ["m"])
        fake.finish(session)
        try await host.until("the new window's row") { host.shows("Safari.app") }
        #expect(model.query == "m")
    }
}
