import Testing
@testable import Wherever
import WhereverInterface

@Suite struct SearchModelSortTests {
    private static let bySize = SearchSort(column: .size, ascending: false)
    private static let marker = IndexState(phase: .ready, indexed: 1)

    @Test func aSortAsksTheSessionAndItsResultsReadyRefreshesTheRows() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let session = fake.lastSession
        model.query = "s"
        let searched = fake.latest
        fake.send(.resultsReady(searched, count: 1))
        try await untilTrue(waitingFor: "the first rows") { model.results.generation == searched && !model.isPending }

        model.sort = Self.bySize
        #expect(fake.session(session)?.sorts == [Self.bySize])
        #expect(fake.queries == ["s"], "a sort never searches again")
        #expect(model.isPending, "row 0 still belongs to the old order")
        let sorted = fake.latest
        #expect(sorted != searched)
        #expect(model.results.generation == searched)

        fake.setHits([.named("Mail.app")])
        fake.send(.resultsReady(sorted, count: 1))
        try await untilTrue(waitingFor: "the sorted rows") { model.results.generation == sorted }
        #expect(!model.isPending)
        #expect(!model.results.live)
        #expect(model.names == ["Mail.app"])
        #expect(fake.rowRequests.last?.generation == sorted)
    }

    @Test func theSameSortTwiceAsksOnce() {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "s"
        model.sort = Self.bySize
        model.sort = Self.bySize
        #expect(fake.session(fake.lastSession)?.sorts == [Self.bySize])
    }

    @Test func withNothingSearchableASortWaitsForTheNextSearch() throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let byName = SearchSort(column: .name, ascending: true)
        model.sort = byName
        let record = try #require(fake.session(fake.lastSession))
        #expect(record.sorts.isEmpty)
        #expect(record.searches.isEmpty)
        #expect(!model.isPending)

        model.query = "a"
        #expect(fake.session(fake.lastSession)?.searches == [FakeSearchClient.Search(query: "a", sort: byName)])
    }

    @Test func aNewQueryKeepsTheSort() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        #expect(model.sort == .bestMatch)
        model.query = "a"
        model.sort = Self.bySize
        model.query = "ab"
        fake.send(.resultsReady(fake.latest, count: 0))
        fake.send(.resultsChanged)
        try await untilTrue(waitingFor: "the live search") { fake.queries.count == 3 }
        let searches = try #require(fake.session(fake.lastSession)).searches
        #expect(searches == [
            FakeSearchClient.Search(query: "a", sort: .bestMatch),
            FakeSearchClient.Search(query: "ab", sort: Self.bySize),
            FakeSearchClient.Search(query: "ab", sort: Self.bySize),
        ])
    }

    @Test func theModelIgnoresAnotherSessionsGeneration() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let other = try fake.makeSession()
        model.query = "a"
        let mine = fake.latest
        let theirs = try other.search("b", sort: .bestMatch)
        #expect(mine != theirs)

        fake.send(.resultsReady(theirs, count: 1))
        fake.send(.stateChanged(Self.marker))
        try await untilTrue(waitingFor: "the event after their results") { index.indexState == Self.marker }
        #expect(model.results.generation == nil)
        #expect(model.isPending)

        fake.send(.resultsReady(mine, count: 1))
        try await untilTrue(waitingFor: "the model's own rows") { model.results.generation == mine }
        #expect(model.names == ["Safari.app"])
    }

    @Test func aThrowingSortKeepsTheShownRows() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "s"
        let searched = fake.latest
        fake.send(.resultsReady(searched, count: 1))
        try await untilTrue(waitingFor: "the first rows") { model.names == ["Safari.app"] && !model.isPending }

        fake.fail(with: .io)
        model.sort = Self.bySize
        #expect(model.failed)
        #expect(fake.latest == searched, "the failed sort made no generation")
        #expect(model.results.generation == searched)
        #expect(model.count == 1)
        #expect(!model.isPending)
        #expect(model.names == ["Safari.app"])
    }
}
