import Foundation
import os
import SwiftUI
import WhereverInterface

nonisolated struct PreviewArchiveClient: ArchiveClient {
    func archiveExtensions() throws -> [String] { [] }
    func openArchive(path: String, shownAs: String) throws -> any ArchiveSessionClient { throw WhereverError.stopped }
}

nonisolated final class PreviewSearchClient: SearchClient {
    let events: AsyncStream<SearchEvent>
    private let continuation: AsyncStream<SearchEvent>.Continuation
    fileprivate let catalog: [SearchHit]
    private let state = OSAllocatedUnfairLock(initialState: State())

    struct State {
        var generation: UInt64 = 0
        var sessions: UInt64 = 0
        var on: Set<String> = [PreviewSearchClient.disks[0].id]
    }

    init(catalog: [SearchHit] = PreviewSearchClient.sample, state: IndexState? = nil) {
        let (events, continuation) = AsyncStream<SearchEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.catalog = catalog
        continuation.yield(.stateChanged(state ?? IndexState(phase: .ready, indexed: catalog.count)))
    }

    func recordOpen(_ path: String) throws {}

    func clearOpens() throws {}

    func flushOpens() throws {}
    func isSettling() throws -> Bool { false }

    func setExcludedFolders(_ paths: [String]) throws {}

    func setTypoSearch(_ on: Bool) throws {}
    func setLiveUpdates(_ on: Bool) throws {}

    func setIndexedVolumes(_ ids: Set<String>) throws {
        state.withLock { $0.on = ids }
        continuation.yield(.volumesChanged)
    }

    func volumes() throws -> [IndexedVolume] {
        let on = state.withLock { $0.on }
        return Self.disks.map { IndexedVolume(id: $0.id, name: $0.name, path: $0.path, indexed: on.contains($0.id)) }
    }

    func makeSession() throws -> any SearchSessionClient {
        PreviewSession(client: self, id: SearchSessionID(rawValue: state.withLock { $0.sessions += 1; return $0.sessions }))
    }

    fileprivate func nextGeneration() -> UInt64 {
        state.withLock { $0.generation += 1; return $0.generation }
    }

    fileprivate func send(_ event: SearchEvent) { continuation.yield(event) }

    static let disks = [
        IndexedVolume(id: "0A0A0A0A-0000-4000-8000-00000000000A", name: "Archive", path: "/Volumes/Archive", indexed: true),
        IndexedVolume(id: "0B0B0B0B-0000-4000-8000-00000000000B", name: "Backup", path: "/Volumes/Backup", indexed: true),
    ]

    static let sample: [SearchHit] = ["Calendar", "Mail", "Maps", "Notes", "Numbers", "Pages", "Safari"].map { name in
        SearchHit(name: "\(name).app", folder: "/Applications", size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .folder)
    }
}

nonisolated final class PreviewSession: SearchSessionClient {
    struct State {
        var query = ""
        var generation: UInt64 = 0
        var matches: [SearchHit] = []
    }

    let id: SearchSessionID
    private let client: PreviewSearchClient
    private let state = OSAllocatedUnfairLock(initialState: State())

    fileprivate init(client: PreviewSearchClient, id: SearchSessionID) {
        self.client = client
        self.id = id
    }

    func search(_ query: String, sort: SearchSort) throws -> SearchGeneration { answer(query, sort) }

    func refresh(_ query: String, sort: SearchSort) throws -> SearchGeneration { answer(query, sort) }

    func sort(_ sort: SearchSort) throws -> SearchGeneration { answer(nil, sort) }

    func searchContent(_ query: String, terms: [String], matchAll: Bool, sort: SearchSort) throws -> SearchGeneration {
        let generation = answer(query, sort)
        let total = state.withLock { $0.matches.count }
        client.send(.contentProgress(generation, read: total, total: total, notDownloaded: 0, unreadable: 0, done: true))
        return generation
    }

    func narrow(_ query: String, sort: SearchSort) throws -> SearchGeneration { answer(query, sort) }

    func stopContent() throws {}

    func rows(_ generation: SearchGeneration, in range: Range<Int>) throws -> [SearchHit] {
        try state.withLock { state in
            guard generation.rawValue == state.generation else { throw WhereverError.staleGeneration }
            return Array(state.matches[range.clamped(to: 0..<state.matches.count)])
        }
    }

    private func answer(_ query: String?, _ sort: SearchSort) -> SearchGeneration {
        let generation = client.nextGeneration()
        let catalog = client.catalog
        let count = state.withLock { state in
            state.query = query ?? state.query
            state.generation = generation
            var matches = catalog.filter { state.query.isEmpty || $0.name.localizedCaseInsensitiveContains(state.query) }
            if sort.column != .relevance {
                matches.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            let natural = sort.column == .relevance ? !sort.ascending : sort.ascending
            state.matches = natural ? matches : matches.reversed()
            return state.matches.count
        }
        client.send(.resultsReady(SearchGeneration(rawValue: generation), count: count))
        return SearchGeneration(rawValue: generation)
    }
}

extension View {
    func previewEnvironment(search: any SearchClient = PreviewSearchClient()) -> some View {
        environment(\.searchClient, search).environment(\.resultActions, .live(client: search))
    }
}
