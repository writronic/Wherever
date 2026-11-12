import Dispatch
import Foundation
import os
import WhereverInterface

nonisolated final class FakeSearchClient: SearchClient {
    struct RowRequest: Equatable {
        let generation: SearchGeneration
        let range: Range<Int>
    }

    struct Search: Equatable {
        let query: String
        let sort: SearchSort
    }

    struct Press: Equatable {
        let query: String
        let terms: [String]
        let matchAll: Bool
        let sort: SearchSort
    }

    struct SessionRecord {
        var searches: [Search] = []
        var sorts: [SearchSort] = []
        var presses: [Press] = []
        var narrows: [Search] = []
        var stops = 0
        var rowRequests: [RowRequest] = []
        var latest: UInt64 = 0
        var finished: UInt64 = 0
        var previous: UInt64 = 0

        mutating func finish() {
            guard latest != finished else { return }
            previous = finished
            finished = latest
        }
    }

    nonisolated final class Hold: Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let failure = OSAllocatedUnfairLock<WhereverError?>(initialState: nil)

        func release(throwing error: WhereverError? = nil) {
            failure.withLock { $0 = error }
            gate.signal()
        }

        fileprivate func wait() throws {
            _ = gate.wait(timeout: .now() + 10)
            if let error = failure.withLock({ $0 }) { throw error }
        }
    }

    struct State {
        var hold: Hold?
        var queries: [String] = []
        var refreshes: [String] = []
        var presses: [Press] = []
        var narrows: [String] = []
        var stops = 0
        var generation: UInt64 = 0
        var hits: [SearchHit]
        var rowRequests: [RowRequest] = []
        var opened: [String] = []
        var clears = 0
        var flushes = 0
        var settling = false
        var excluded: [[String]] = []
        var switchedOn: [Set<String>] = []
        var typos: [Bool] = []
        var liveUpdates: [Bool] = []
        var volumes: Result<[IndexedVolume], any Error> = .success([])
        var sessions: [SearchSessionID: SessionRecord] = [:]
        var lastSession: UInt64 = 0
        var released = 0
        var failure: WhereverError?

        mutating func ask(_ id: SearchSessionID, _ record: (inout State, inout SessionRecord) -> Void) -> SearchGeneration {
            generation += 1
            var session = sessions[id, default: .init()]
            record(&self, &session)
            session.latest = generation
            sessions[id] = session
            return SearchGeneration(rawValue: generation)
        }

        mutating func search(_ id: SearchSessionID, _ query: String, sort: SearchSort) -> SearchGeneration {
            ask(id) { state, record in
                state.queries.append(query)
                record.searches.append(Search(query: query, sort: sort))
            }
        }
    }

    let events: AsyncStream<SearchEvent>
    private let continuation: AsyncStream<SearchEvent>.Continuation
    private let state: OSAllocatedUnfairLock<State>

    init(hits: [SearchHit] = []) {
        let (events, continuation) = AsyncStream<SearchEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        state = OSAllocatedUnfairLock(initialState: State(hits: hits))
    }

    deinit { continuation.finish() }

    var queries: [String] { state.withLock { $0.queries } }
    var refreshes: [String] { state.withLock { $0.refreshes } }
    var presses: [Press] { state.withLock { $0.presses } }
    var narrows: [String] { state.withLock { $0.narrows } }
    var stops: Int { state.withLock { $0.stops } }
    var rowRequests: [RowRequest] { state.withLock { $0.rowRequests } }
    var latest: SearchGeneration { SearchGeneration(rawValue: state.withLock { $0.generation }) }

    func setHits(_ hits: [SearchHit]) { state.withLock { $0.hits = hits } }
    func holdNextRead() -> Hold {
        let hold = Hold()
        state.withLock { $0.hold = hold }
        return hold
    }
    func fail(with error: WhereverError?) { state.withLock { $0.failure = error } }
    func send(_ event: SearchEvent) {
        if case let .resultsReady(generation, _) = event {
            state.withLock { state in
                for (id, record) in state.sessions where record.latest == generation.rawValue {
                    state.sessions[id]?.finish()
                }
            }
        }
        continuation.yield(event)
    }

    func publish(_ session: SearchSessionID) {
        state.withLock { $0.sessions[session]?.finish() }
    }

    func finish(_ session: SearchSessionID, count: Int? = nil) {
        let (generation, hits) = state.withLock { (SearchGeneration(rawValue: $0.sessions[session]?.latest ?? 0), $0.hits.count) }
        send(.resultsReady(generation, count: count ?? hits))
    }

    func session(_ id: SearchSessionID) -> SessionRecord? { state.withLock { $0.sessions[id] } }
    var lastSession: SearchSessionID { SearchSessionID(rawValue: state.withLock { $0.lastSession }) }

    func search(in session: SearchSessionID, _ query: String) -> SearchGeneration {
        state.withLock { $0.search(session, query, sort: .bestMatch) }
    }
    var released: Int { state.withLock { $0.released } }

    func makeSession() throws -> any SearchSessionClient {
        let id = state.withLock { state in
            state.lastSession += 1
            let id = SearchSessionID(rawValue: state.lastSession)
            state.sessions[id] = SessionRecord()
            return id
        }
        return FakeSession(id: id, state: state)
    }

    var opened: [String] { state.withLock { $0.opened } }
    var clears: Int { state.withLock { $0.clears } }
    var flushes: Int { state.withLock { $0.flushes } }

    func recordOpen(_ path: String) throws { state.withLock { $0.opened.append(path) } }

    func clearOpens() throws { state.withLock { $0.clears += 1 } }

    func flushOpens() throws { state.withLock { $0.flushes += 1 } }
    func isSettling() throws -> Bool { state.withLock { $0.settling } }
    func setSettling(_ on: Bool) { state.withLock { $0.settling = on } }

    var excluded: [[String]] { state.withLock { $0.excluded } }
    var switchedOn: [Set<String>] { state.withLock { $0.switchedOn } }
    var typos: [Bool] { state.withLock { $0.typos } }
    var liveUpdates: [Bool] { state.withLock { $0.liveUpdates } }
    func setVolumes(_ volumes: Result<[IndexedVolume], any Error>) { state.withLock { $0.volumes = volumes } }

    func setExcludedFolders(_ paths: [String]) throws { state.withLock { $0.excluded.append(paths) } }

    func setIndexedVolumes(_ ids: Set<String>) throws { state.withLock { $0.switchedOn.append(ids) } }

    func setTypoSearch(_ on: Bool) throws { state.withLock { $0.typos.append(on) } }

    func setLiveUpdates(_ on: Bool) throws {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            $0.liveUpdates.append(on)
        }
    }

    func volumes() throws -> [IndexedVolume] { try state.withLock { try $0.volumes.get() } }
}

nonisolated final class FakeSession: SearchSessionClient {
    let id: SearchSessionID
    private let state: OSAllocatedUnfairLock<FakeSearchClient.State>

    fileprivate init(id: SearchSessionID, state: OSAllocatedUnfairLock<FakeSearchClient.State>) {
        self.id = id
        self.state = state
    }

    deinit {
        state.withLock { $0.released += 1 }
    }

    func search(_ query: String, sort: SearchSort) throws -> SearchGeneration {
        try state.withLock { [id] in
            if let failure = $0.failure { throw failure }
            return $0.search(id, query, sort: sort)
        }
    }

    func refresh(_ query: String, sort: SearchSort) throws -> SearchGeneration {
        try state.withLock { [id] in
            if let failure = $0.failure { throw failure }
            $0.refreshes.append(query)
            return $0.search(id, query, sort: sort)
        }
    }

    func sort(_ sort: SearchSort) throws -> SearchGeneration {
        try state.withLock { [id] in
            if let failure = $0.failure { throw failure }
            return $0.ask(id) { $1.sorts.append(sort) }
        }
    }

    func searchContent(_ query: String, terms: [String], matchAll: Bool, sort: SearchSort) throws -> SearchGeneration {
        let press = FakeSearchClient.Press(query: query, terms: terms, matchAll: matchAll, sort: sort)
        return try state.withLock { [id] in
            if let failure = $0.failure { throw failure }
            return $0.ask(id) { state, record in
                state.presses.append(press)
                record.presses.append(press)
            }
        }
    }

    func narrow(_ query: String, sort: SearchSort) throws -> SearchGeneration {
        try state.withLock { [id] in
            if let failure = $0.failure { throw failure }
            return $0.ask(id) { state, record in
                state.narrows.append(query)
                record.narrows.append(FakeSearchClient.Search(query: query, sort: sort))
            }
        }
    }

    func stopContent() throws {
        state.withLock { [id] state in
            state.stops += 1
            state.sessions[id]?.stops += 1
        }
    }

    func rows(_ generation: SearchGeneration, in range: Range<Int>) throws -> [SearchHit] {
        let main = Thread.isMainThread
        let (rows, hold) = try state.withLock { [id] state in
            let request = FakeSearchClient.RowRequest(generation: generation, range: range)
            state.rowRequests.append(request)
            state.sessions[id]?.rowRequests.append(request)
            guard let record = state.sessions[id], generation.rawValue != 0,
                  [record.finished, record.previous].contains(generation.rawValue) else { throw WhereverError.staleGeneration }
            if generation.rawValue == record.finished { state.sessions[id]?.previous = 0 }
            let hold = main ? nil : state.hold
            if !main { state.hold = nil }
            return (Array(state.hits[range.clamped(to: 0..<state.hits.count)]), hold)
        }
        try hold?.wait()
        return rows
    }
}

extension SearchHit {
    static func named(_ name: String, in folder: String = "/Applications") -> SearchHit {
        SearchHit(name: name, folder: folder, size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .folder)
    }
}
