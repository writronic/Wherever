import Foundation
import WhereverInterface

final class SearchSession: SearchSessionClient {
    let id: SearchSessionID
    private let session: EngineSession
    private let listener: EngineEvents

    init(engine: Engine, listener: EngineEvents) throws {
        (session, id) = try WhereverError.mapping {
            let session = try engine.session()
            return (session, SearchSessionID(rawValue: try session.id()))
        }
        self.listener = listener
    }

    deinit {
        listener.forget(id)
    }

    func search(_ query: String, sort: SearchSort) throws -> SearchGeneration {
        try timed(.search) { try session.search(query: query, sort: EngineSort(sort)) }
    }

    func refresh(_ query: String, sort: SearchSort) throws -> SearchGeneration {
        try timed(.refresh) { try session.refresh(query: query, sort: EngineSort(sort)) }
    }

    func sort(_ sort: SearchSort) throws -> SearchGeneration {
        try timed(.sort) { try session.sort(sort: EngineSort(sort)) }
    }

    func searchContent(_ query: String, terms: [String], matchAll: Bool, sort: SearchSort) throws -> SearchGeneration {
        let start = ContinuousClock.now
        let generation = try WhereverError.mapping {
            try session.searchContent(query: query, terms: terms, matchAll: matchAll, sort: EngineSort(sort))
        }
        listener.pressed(id, generation: generation, at: start)
        return SearchGeneration(rawValue: generation)
    }

    func narrow(_ query: String, sort: SearchSort) throws -> SearchGeneration {
        try timed(.search) { try session.narrow(query: query, sort: EngineSort(sort)) }
    }

    func stopContent() throws {
        try WhereverError.mapping { try session.stopContent() }
    }

    func rows(_ generation: SearchGeneration, in range: Range<Int>) throws -> [SearchHit] {
        try SearchHit.page(range) { try session.rows(generation: generation.rawValue, start: $0, count: $1) }
    }

    private func timed(_ kind: EngineEvents.Timing.Call, _ call: () throws -> UInt64) throws -> SearchGeneration {
        let start = ContinuousClock.now
        let generation = try WhereverError.mapping(call)
        listener.started(id, generation: generation, call: kind, at: start)
        return SearchGeneration(rawValue: generation)
    }
}

extension SearchHit {
    static func page(_ range: Range<Int>, _ fetch: (UInt32, UInt32) throws -> [EngineHit]) throws -> [SearchHit] {
        let range = range.clamped(to: 0..<Int(UInt32.max))
        return try WhereverError.mapping { try fetch(UInt32(range.lowerBound), UInt32(range.count)) }.map(SearchHit.init)
    }

    init(_ hit: EngineHit) {
        let kind: Kind = switch hit.kind {
        case .file: .file
        case .folder: .folder
        case .link: .link
        }
        self.init(
            name: hit.name,
            folder: hit.folder,
            size: Int64(clamping: hit.size),
            modified: Date(timeIntervalSince1970: TimeInterval(hit.modified)),
            created: Date(timeIntervalSince1970: TimeInterval(hit.created)),
            opened: Date(timeIntervalSince1970: TimeInterval(hit.opened)),
            kind: kind,
            matches: hit.matches.map { Int($0.start)..<Int($0.start) + Int($0.length) }
        )
    }
}

private extension EngineSort {
    init(_ sort: SearchSort) {
        let column: EngineColumn = switch sort.column {
        case .relevance: .relevance
        case .name: .name
        case .folder: .folder
        case .size: .size
        case .modified: .modified
        case .created: .created
        case .opened: .opened
        case .kind: .kind
        }
        self.init(column: column, ascending: sort.ascending, foldersFirst: sort.foldersFirst)
    }
}
