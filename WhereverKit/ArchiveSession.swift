import WhereverInterface

final class ArchiveSessionAdapter: ArchiveSessionClient {
    let id: SearchSessionID
    private let session: ArchiveSession
    private let listener: EngineEvents

    init(engine: Engine, listener: EngineEvents, path: String, shownAs: String) throws {
        (session, id) = try WhereverError.mapping {
            let session = try engine.openArchive(path: path, shownAs: shownAs)
            return (session, SearchSessionID(rawValue: try session.id()))
        }
        self.listener = listener
    }

    deinit {
        listener.forget(id)
    }

    func browse(_ folder: String) throws -> SearchGeneration {
        try timed(.search) { try session.browse(folder: folder) }
    }

    func search(_ query: String, sort: SearchSort) throws -> SearchGeneration {
        try timed(.search) { try session.search(query: query, sort: EngineSort(archiveSort: sort)) }
    }

    func refresh(_ query: String, sort: SearchSort) throws -> SearchGeneration {
        try WhereverError.mapping {
            SearchGeneration(rawValue: try session.refresh(query: query, sort: EngineSort(archiveSort: sort)))
        }
    }

    func sort(_ sort: SearchSort) throws -> SearchGeneration {
        try timed(.sort) { try session.sort(sort: EngineSort(archiveSort: sort)) }
    }

    func rows(_ generation: SearchGeneration, in range: Range<Int>) throws -> [SearchHit] {
        try SearchHit.page(range) { try session.rows(generation: generation.rawValue, start: $0, count: $1) }
    }

    func summary() throws -> WhereverInterface.ArchiveSummary {
        let value = try WhereverError.mapping { try session.summary() }
        return WhereverInterface.ArchiveSummary(
            path: value.path, format: value.format, items: value.items, bytes: value.bytes,
            encrypted: value.encrypted, skipped: value.skipped, problem: value.problem.map(WhereverInterface.ArchiveProblem.init),
            editing: WhereverInterface.ArchiveEditing(value.editing)
        )
    }

    func unlock(_ password: String) throws -> Bool {
        try WhereverError.mapping { try session.unlock(password: password) }
    }

    func encrypted(_ entry: String) throws -> Bool {
        try WhereverError.mapping { try session.encrypted(entry: entry) }
    }

    func extract(entries: [String], folder: String, readOnly: Bool) throws -> ArchiveJobID {
        try WhereverError.mapping {
            ArchiveJobID(rawValue: try session.extract(entries: entries, folder: folder, readOnly: readOnly))
        }
    }

    func expand(entries: [String], folder: String, whole: Bool) throws -> ArchiveJobID {
        try WhereverError.mapping {
            ArchiveJobID(rawValue: try session.expand(entries: entries, folder: folder, whole: whole))
        }
    }

    func job(_ id: ArchiveJobID) throws -> WhereverInterface.ArchiveJob {
        let value = try WhereverError.mapping { try session.job(id: id.rawValue) }
        return WhereverInterface.ArchiveJob(
            doneBytes: value.doneBytes, totalBytes: value.totalBytes, doneItems: value.doneItems, totalItems: value.totalItems,
            finished: value.finished, problem: value.problem.map(WhereverInterface.ArchiveProblem.init), written: value.written,
            skipped: value.skipped
        )
    }

    func cancel(_ id: ArchiveJobID) throws {
        try WhereverError.mapping { try session.cancel(id: id.rawValue) }
    }

    func setChanges(_ changes: [WhereverInterface.ArchiveChange]) throws -> SearchGeneration {
        try timed(.search) { try session.setChanges(changes: changes.map(ArchiveChange.init)) }
    }

    func clashes(folder: String, names: [String]) throws -> [WhereverInterface.ArchiveClash] {
        try WhereverError.mapping { try session.clashes(folder: folder, names: names) }.map {
            WhereverInterface.ArchiveClash(name: $0.name, existing: $0.existing, folder: $0.folder, freeName: $0.freeName)
        }
    }

    func writeEdited(to out: String) throws -> ArchiveJobID {
        try WhereverError.mapping { ArchiveJobID(rawValue: try session.writeEdited(out: out)) }
    }

    func close() throws {
        try WhereverError.mapping { try session.close() }
        listener.forget(id)
    }

    private func timed(_ kind: EngineEvents.Timing.Call, _ call: () throws -> UInt64) throws -> SearchGeneration {
        let start = ContinuousClock.now
        let generation = try WhereverError.mapping(call)
        listener.started(id, generation: generation, call: kind, at: start)
        return SearchGeneration(rawValue: generation)
    }
}

extension WhereverInterface.ArchiveProblem {
    init(_ problem: ArchiveProblem) {
        self = switch problem {
        case .damaged: .damaged
        case .encrypted: .encrypted
        case .unsupported: .unsupported
        case .empty: .empty
        case .changed: .changed
        case let .gone(name): .gone(name: name)
        case let .noSpace(needed, volume): .noSpace(needed: needed, volume: volume)
        case .passwordNeeded: .passwordNeeded
        case .wrongPassword: .wrongPassword
        case let .pointsOutside(name): .pointsOutside(name: name)
        case let .linkedItem(name): .linkedItem(name: name)
        case .oldEncryption: .oldEncryption
        case let .duplicate(name): .duplicate(name: name)
        }
    }
}

private extension WhereverInterface.ArchiveEditing {
    init(_ editing: ArchiveEditing) {
        self = switch editing {
        case .all: .all
        case .oldEncryption: .oldEncryption
        case .none: .none
        }
    }
}

private extension ArchiveChange {
    init(_ change: WhereverInterface.ArchiveChange) {
        self = switch change {
        case let .delete(path): .delete(path: path)
        case let .add(source, folder, name): .add(source: source, folder: folder, name: name)
        }
    }
}

private extension EngineSort {
    init(archiveSort sort: SearchSort) {
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
