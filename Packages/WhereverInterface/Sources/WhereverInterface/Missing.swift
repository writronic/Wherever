enum Missing {
    static func trap(_ key: String) -> Never {
        fatalError("Inject \\.\(key) into the environment before using it.")
    }
}

struct MissingSearchClient: SearchClient {
    var events: AsyncStream<SearchEvent> { Missing.trap("searchClient") }
    func makeSession() throws -> any SearchSessionClient { Missing.trap("searchClient") }
    func recordOpen(_ path: String) throws { Missing.trap("searchClient") }
    func clearOpens() throws { Missing.trap("searchClient") }
    func flushOpens() throws { Missing.trap("searchClient") }
    func isSettling() throws -> Bool { Missing.trap("searchClient") }
    func setExcludedFolders(_ paths: [String]) throws { Missing.trap("searchClient") }
    func setTypoSearch(_ on: Bool) throws { Missing.trap("searchClient") }
    func setLiveUpdates(_ on: Bool) throws { Missing.trap("searchClient") }
    func setIndexedVolumes(_ ids: Set<String>) throws { Missing.trap("searchClient") }
    func volumes() throws -> [IndexedVolume] { Missing.trap("searchClient") }
}

struct MissingArchiveClient: ArchiveClient {
    func archiveExtensions() throws -> [String] { Missing.trap("archiveClient") }
    func openArchive(path: String, shownAs: String) throws -> any ArchiveSessionClient { Missing.trap("archiveClient") }
}
