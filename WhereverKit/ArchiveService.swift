import WhereverInterface

public final class ArchiveService: ArchiveClient {
    private let engine: Engine
    private let listener: EngineEvents

    init(engine: Engine, listener: EngineEvents) {
        self.engine = engine
        self.listener = listener
    }

    public func archiveExtensions() throws -> [String] {
        try WhereverError.mapping { try engine.archiveExtensions() }
    }

    public func openArchive(path: String, shownAs: String) throws -> any ArchiveSessionClient {
        try ArchiveSessionAdapter(engine: engine, listener: listener, path: path, shownAs: shownAs)
    }
}
