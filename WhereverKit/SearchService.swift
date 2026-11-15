import Foundation
import WhereverInterface

public final class SearchService: SearchClient {
    public let events: AsyncStream<SearchEvent>
    let archive: ArchiveService
    private let engine: Engine
    private let listener: EngineEvents
    let disks: Disks
    private let watcher: VolumeWatcher?

    init(config: EngineConfig, volumes: [MountedVolume], watch: Bool, indexedVolumes: Set<String>) throws {
        let (events, continuation) = AsyncStream<SearchEvent>.makeStream()
        self.events = events
        let listener = EngineEvents(continuation, dataFolder: config.dataFolder)
        let engine = try WhereverError.mapping { try Engine(config: config, listener: listener) }
        self.engine = engine
        self.listener = listener
        archive = ArchiveService(engine: engine, listener: listener)
        disks = Disks(engine: engine, continuation: continuation, mounted: watch ? [] : volumes, indexed: indexedVolumes)
        if watch {
            watcher = VolumeWatcher(disks: disks)
        } else {
            watcher = nil
            try disks.update { _ in }
        }
    }

    public func setExcludedFolders(_ paths: [String]) throws {
        try WhereverError.mapping { try engine.setExcluded(excluded: paths) }
    }

    public func setTypoSearch(_ on: Bool) throws {
        try WhereverError.mapping { try engine.setTypos(on: on) }
    }

    public func setLiveUpdates(_ on: Bool) throws {
        try WhereverError.mapping { try engine.setLiveUpdates(on: on) }
    }

    public func setCommandLine(_ on: Bool) throws {
        try WhereverError.mapping { try engine.serveCommandLine(on: on) }
    }

    public func setIndexedVolumes(_ ids: Set<String>) throws {
        try disks.update { $0.indexed = ids }
    }

    public func volumes() throws -> [IndexedVolume] {
        disks.list
    }

    public func makeSession() throws -> any SearchSessionClient {
        try SearchSession(engine: engine, listener: listener)
    }

    public func recordOpen(_ path: String) throws {
        try WhereverError.mapping { try engine.recordOpen(path: path) }
    }

    public func clearOpens() throws {
        try WhereverError.mapping { try engine.clearOpens() }
    }

    public func flushOpens() throws {
        try WhereverError.mapping { try engine.flushOpens() }
    }

    public func isSettling() throws -> Bool {
        try WhereverError.mapping { try engine.isSettling() }
    }
}
