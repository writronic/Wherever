import SwiftUI
import Testing
import WhereverInterface

@Suite struct SearchClientKeyTests {
    @Test func theMissingDefaultReadsWithoutTrappingAndGivesWayToTheInjectedClient() {
        var environment = EnvironmentValues()
        _ = environment.searchClient
        environment.searchClient = StubSearchClient()
        #expect(environment.searchClient is StubSearchClient)
    }
}

private struct StubSearchClient: SearchClient {
    let events = AsyncStream<SearchEvent> { $0.finish() }
    func makeSession() throws -> any SearchSessionClient { throw WhereverError.stopped }
    func recordOpen(_ path: String) throws {}
    func clearOpens() throws {}
    func flushOpens() throws {}
    func isSettling() throws -> Bool { false }
    func setExcludedFolders(_ paths: [String]) throws {}
    func setTypoSearch(_ on: Bool) throws {}
    func setLiveUpdates(_ on: Bool) throws {}
    func setIndexedVolumes(_ ids: Set<String>) throws {}
    func volumes() throws -> [IndexedVolume] { [] }
}
