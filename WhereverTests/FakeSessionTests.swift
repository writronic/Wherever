import Testing
import WhereverInterface

@Suite struct FakeSessionTests {
    @Test func eachSessionRecordsItsOwnSearchesSortsAndRowRequests() throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let first = try fake.makeSession()
        let second = try fake.makeSession()
        #expect(first.id != second.id)

        let bySize = SearchSort(column: .size, ascending: false)
        let searched = try first.search("saf", sort: .bestMatch)
        let sorted = try first.sort(bySize)
        let other = try second.search("mail", sort: bySize)
        #expect(Set([searched, sorted, other]).count == 3)
        _ = try? first.rows(sorted, in: 0..<5)

        let one = try #require(fake.session(first.id))
        #expect(one.searches == [FakeSearchClient.Search(query: "saf", sort: .bestMatch)])
        #expect(one.sorts == [bySize])
        #expect(one.rowRequests == [FakeSearchClient.RowRequest(generation: sorted, range: 0..<5)])
        let two = try #require(fake.session(second.id))
        #expect(two.searches == [FakeSearchClient.Search(query: "mail", sort: bySize)])
        #expect(two.sorts.isEmpty)
        #expect(two.rowRequests.isEmpty)
        #expect(fake.queries == ["saf", "mail"])
        #expect(fake.rowRequests == one.rowRequests)
    }

    @Test func eachSessionRecordsItsPressesNarrowsAndStops() throws {
        let fake = FakeSearchClient()
        let first = try fake.makeSession()
        let second = try fake.makeSession()
        let pressed = try first.searchContent("report", terms: ["alpha"], matchAll: true, sort: .bestMatch)
        let narrowed = try first.narrow("reports", sort: .bestMatch)
        try first.stopContent()
        #expect(narrowed.rawValue == pressed.rawValue + 1, "each call takes the next generation")
        let one = try #require(fake.session(first.id))
        #expect(one.presses == [FakeSearchClient.Press(query: "report", terms: ["alpha"], matchAll: true, sort: .bestMatch)])
        #expect(one.narrows == [FakeSearchClient.Search(query: "reports", sort: .bestMatch)])
        #expect(one.stops == 1)
        #expect(one.latest == narrowed.rawValue)
        #expect(try #require(fake.session(second.id)).presses.isEmpty)
        #expect(fake.presses == one.presses)
        #expect(fake.narrows == ["reports"])
        #expect(fake.stops == 1)
        #expect(fake.queries.isEmpty)
    }

    @Test func onlyTheSessionsLatestFinishedGenerationAnswersRows() throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app"), .named("Mail.app")])
        let session = try fake.makeSession()
        let other = try fake.makeSession()

        let first = try session.search("a", sort: .bestMatch)
        #expect(throws: WhereverError.staleGeneration) { try session.rows(first, in: 0..<2) }
        let second = try session.search("ab", sort: .bestMatch)
        fake.finish(session.id)
        #expect(throws: WhereverError.staleGeneration) { try session.rows(first, in: 0..<2) }
        #expect(try session.rows(second, in: 0..<2).map(\.name) == ["Safari.app", "Mail.app"])

        let third = try session.search("abc", sort: .bestMatch)
        #expect(try session.rows(second, in: 1..<2).map(\.name) == ["Mail.app"])
        #expect(throws: WhereverError.staleGeneration) { try session.rows(third, in: 0..<2) }
        #expect(throws: WhereverError.staleGeneration) { try other.rows(second, in: 0..<2) }
        #expect(fake.session(session.id)?.rowRequests.count == 5)
    }

    @Test func finishSendsResultsReadyForTheSessionsLatestGeneration() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let session = try fake.makeSession()
        _ = try session.search("s", sort: .bestMatch)
        let latest = try session.sort(SearchSort(column: .name, ascending: true))
        fake.finish(session.id)
        var events = fake.events.makeAsyncIterator()
        #expect(await events.next() == .resultsReady(latest, count: 1))
        #expect(try session.rows(latest, in: 0..<1).map(\.name) == ["Safari.app"])
    }

    @Test func theReleaseCountMovesWhenTheLastReferenceGoes() throws {
        let fake = FakeSearchClient()
        var session: (any SearchSessionClient)? = try fake.makeSession()
        let copy = session
        let id = try #require(session).id
        _ = try #require(session).search("a", sort: .bestMatch)
        session = nil
        #expect(fake.released == 0)
        withExtendedLifetime(copy) {}
        _ = consume copy
        #expect(fake.released == 1)
        #expect(fake.session(id)?.searches.map(\.query) == ["a"])
    }
}
