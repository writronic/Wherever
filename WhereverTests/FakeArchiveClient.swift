import Foundation
import os
import WhereverInterface

nonisolated final class FakeArchiveClient: ArchiveClient {
    struct Entry: Sendable {
        let path: String
        let kind: SearchHit.Kind
        let size: Int64
        let target: String?
        let source: String?

        init(_ path: String, kind: SearchHit.Kind = .file, size: Int64 = 0, target: String? = nil, source: String? = nil) {
            self.path = path
            self.kind = kind
            self.size = size
            self.target = target
            self.source = source
        }
    }

    struct Extract: Equatable, Sendable {
        let entries: [String]
        let folder: String
        let readOnly: Bool
    }

    struct Expand: Equatable, Sendable {
        let entries: [String]
        let folder: String
        let whole: Bool
    }

    struct Expanded: Sendable {
        var written: [String] = []
        var items: UInt64 = 0
        var skipped: UInt64 = 0
        var problem: ArchiveProblem?
    }

    static func staging(_ id: ArchiveJobID, in folder: String) -> URL {
        URL(filePath: folder, directoryHint: .isDirectory).appending(path: ".Wherever-fake-\(id.rawValue)", directoryHint: .isDirectory)
    }

    fileprivate struct Job: Sendable {
        let extract: Extract
        let entries: [Entry]
        let locked: Set<String>
        var finished = false
        var done = 0
        var problem: ArchiveProblem?
        var failed = false
        var expanded: Expanded?
        var bytes: (done: UInt64, total: UInt64) = (0, 0)
        var stopped = false
        var out: String?
    }

    struct Opened: Equatable {
        let path: String
        let shownAs: String
    }

    struct Record {
        var browses: [String] = []
        var searches: [String] = []
        var sorts: [SearchSort] = []
        var refreshes = 0
        var closes = 0
        var staleReads = 0
        var unlocks = 0
        var unlocksOnMain = 0
        var changes: [[ArchiveChange]] = []
        var writes: [String] = []
    }

    fileprivate struct State {
        var opened: [Opened] = []
        var generation: UInt64 = 1 << 40
        var sessions: [SearchSessionID: Record] = [:]
        var lastSession: UInt64 = 1 << 40
        var holds = false
        var stale = 0
        var problems: [String: ArchiveProblem] = [:]
        var extracts: [Extract] = []
        var expands: [Expand] = []
        var jobs: [UInt64: Job] = [:]
        var cancels: [ArchiveJobID] = []
        var closeOrder: [String] = []
        var heldFolders: Set<String> = []
        var waiting: [SearchSessionID: (generation: SearchGeneration, count: Int)] = [:]
        var later: ArchiveSummary?
        var expanded = Expanded()
        var writeProblem: ArchiveProblem?
        var created: [String] = []
    }

    let search: FakeSearchClient
    let extensions: [String]
    let entries: [Entry]
    let summary: ArchiveSummary
    let nested: [String: [Entry]]
    let broken: Set<String>
    let passwords: [String: String]
    let locked: Set<String>
    let editing: [String: ArchiveEditing]
    fileprivate let state = OSAllocatedUnfairLock(initialState: State())

    init(
        search: FakeSearchClient, extensions: [String] = ["zip", "jar", "aar", "apk", "cbz"], entries: [Entry] = [], summary: ArchiveSummary? = nil,
        nested: [String: [Entry]] = [:], broken: Set<String> = [], passwords: [String: String] = [:], locked: Set<String> = [],
        editing: [String: ArchiveEditing] = [:]
    ) {
        self.search = search
        self.editing = editing
        self.extensions = extensions
        self.entries = entries
        self.nested = nested
        self.broken = broken
        self.passwords = passwords
        self.locked = locked
        self.summary = summary ?? ArchiveSummary(
            path: "", format: "zip", items: UInt64(entries.count), bytes: UInt64(entries.map(\.size).reduce(0, +)),
            encrypted: entries.contains { locked.contains($0.path) }, skipped: 0, problem: nil
        )
    }

    var opened: [Opened] { state.withLock { $0.opened } }
    var lastSession: SearchSessionID { SearchSessionID(rawValue: state.withLock { $0.lastSession }) }
    func session(_ id: SearchSessionID) -> Record? { state.withLock { $0.sessions[id] } }

    var extracts: [Extract] { state.withLock { $0.extracts } }
    var expands: [Expand] { state.withLock { $0.expands } }
    var cancels: [ArchiveJobID] { state.withLock { $0.cancels } }
    var closeOrder: [String] { state.withLock { $0.closeOrder } }
    var running: [ArchiveJobID] { state.withLock { $0.jobs.filter { !$0.value.finished }.keys.sorted().map(ArchiveJobID.init) } }

    static func bytes(_ path: String) -> Data { Data("bytes of \(path)".utf8) }

    static let saved = Data("the saved archive".utf8)

    func failWrites(with problem: ArchiveProblem?) { state.withLock { $0.writeProblem = problem } }

    var created: [String] { state.withLock { $0.created } }

    func hold() { state.withLock { $0.holds = true } }

    var waitingBrowses: Int { state.withLock { $0.waiting.count } }

    var laterSummary: ArchiveSummary? { state.withLock { $0.later } }

    func holdBrowse(_ folder: String) { state.withLock { _ = $0.heldFolders.insert(folder) } }

    func report(_ summary: ArchiveSummary) { state.withLock { $0.later = summary } }

    func expands(_ outcome: Expanded) { state.withLock { $0.expanded = outcome } }

    func progress(_ done: UInt64, of total: UInt64) {
        state.withLock { state in
            for id in state.jobs.keys where state.jobs[id]?.expanded != nil { state.jobs[id]?.bytes = (done, total) }
        }
    }

    func releaseBrowse(empty: Bool = false) {
        let ready = state.withLock { state in
            defer { state.waiting = [:] }
            state.heldFolders = []
            return Array(state.waiting.values)
        }
        for item in ready { search.send(.resultsReady(item.generation, count: empty ? 0 : item.count)) }
    }

    fileprivate func holds(_ id: SearchSessionID, folder: String, generation: SearchGeneration, count: Int) -> Bool {
        state.withLock { state in
            state.waiting[id] = nil
            guard state.heldFolders.contains(folder) else { return false }
            state.waiting[id] = (generation, count)
            return true
        }
    }

    func staleNext(_ reads: Int) { state.withLock { $0.stale = reads } }

    func fail(_ path: String, with problem: ArchiveProblem) { state.withLock { $0.problems[path] = problem } }

    func release() {
        state.withLockUnchecked { state in
            state.holds = false
            for id in state.jobs.keys where state.jobs[id]?.finished == false {
                if state.jobs[id]?.expanded != nil {
                    finish(&state.jobs[id]!, id: ArchiveJobID(rawValue: id))
                } else if state.jobs[id]?.out != nil {
                    state.jobs[id]?.finished = true
                } else {
                    perform(&state.jobs[id]!, problems: state.problems)
                }
            }
        }
    }

    func archiveExtensions() throws -> [String] { extensions }

    func openArchive(path: String, shownAs: String) throws -> any ArchiveSessionClient {
        let name = (shownAs as NSString).lastPathComponent
        let (id, stale) = state.withLock { state in
            state.opened.append(Opened(path: path, shownAs: shownAs))
            state.lastSession += 1
            let id = SearchSessionID(rawValue: state.lastSession)
            state.sessions[id] = Record()
            defer { state.stale = 0 }
            return (id, state.stale)
        }
        if broken.contains(name) { throw WhereverError.io }
        return FakeArchiveSession(id: id, client: self, shownAs: shownAs, entries: nested[name] ?? entries, stale: stale)
    }

    fileprivate func nextGeneration(_ id: SearchSessionID, _ record: (inout Record) -> Void) -> SearchGeneration {
        state.withLockUnchecked { state in
            state.generation += 1
            record(&state.sessions[id, default: Record()])
            return SearchGeneration(rawValue: state.generation)
        }
    }

    fileprivate func record(_ id: SearchSessionID, _ change: (inout Record) -> Void) {
        state.withLockUnchecked { change(&$0.sessions[id, default: Record()]) }
    }

    fileprivate func start(_ extract: Extract, entries: [Entry], unlocked: Bool) -> ArchiveJobID {
        state.withLockUnchecked { state in
            state.generation += 1
            state.extracts.append(extract)
            var job = Job(extract: extract, entries: entries, locked: unlocked ? [] : locked)
            if !state.holds { perform(&job, problems: state.problems) }
            state.jobs[state.generation] = job
            return ArchiveJobID(rawValue: state.generation)
        }
    }

    fileprivate func expand(_ expand: Expand) -> ArchiveJobID {
        state.withLockUnchecked { state in
            state.generation += 1
            state.expands.append(expand)
            let id = ArchiveJobID(rawValue: state.generation)
            try? FileManager.default.createDirectory(at: Self.staging(id, in: expand.folder), withIntermediateDirectories: false)
            var job = Job(extract: Extract(entries: expand.entries, folder: expand.folder, readOnly: false), entries: [], locked: [], expanded: state.expanded)
            if !state.holds { finish(&job, id: id) }
            state.jobs[id.rawValue] = job
            return id
        }
    }

    fileprivate func write(_ out: String, needsPassword: Bool) throws -> ArchiveJobID {
        guard !FileManager.default.fileExists(atPath: out) else { throw WhereverError.io }
        return state.withLockUnchecked { state in
            state.generation += 1
            var job = Job(extract: Extract(entries: [], folder: out, readOnly: false), entries: [], locked: [], out: out)
            if needsPassword {
                job.finished = true
                job.problem = .passwordNeeded
            } else {
                if FileManager.default.createFile(atPath: out, contents: Self.saved, attributes: [.posixPermissions: 0o600]) { state.created.append(out) }
                job.problem = state.writeProblem
                job.finished = !state.holds
            }
            state.jobs[state.generation] = job
            return ArchiveJobID(rawValue: state.generation)
        }
    }

    private func finish(_ job: inout Job, id: ArchiveJobID) {
        job.finished = true
        let staging = Self.staging(id, in: job.extract.folder)
        try? FileManager.default.removeItem(at: staging)
        guard !job.stopped, job.expanded?.problem == nil else { return }
        for name in job.expanded?.written ?? [] {
            try? Data().write(to: URL(filePath: job.extract.folder, directoryHint: .isDirectory).appending(path: name), options: .withoutOverwriting)
        }
    }

    fileprivate func job(_ id: ArchiveJobID) throws -> ArchiveJob {
        guard let job = state.withLock({ $0.jobs[id.rawValue] }) else { throw WhereverError.staleGeneration }
        if job.failed { throw WhereverError.io }
        if let expanded = job.expanded {
            let done = job.finished && !job.stopped
            let folder = URL(filePath: job.extract.folder, directoryHint: .isDirectory)
            return ArchiveJob(
                doneBytes: job.bytes.done, totalBytes: job.bytes.total, doneItems: done ? expanded.items : 0, totalItems: expanded.items,
                finished: job.finished, problem: done ? expanded.problem : nil,
                written: done && expanded.problem == nil ? expanded.written.map { folder.appending(path: $0).path(percentEncoded: false) } : [],
                skipped: done ? expanded.skipped : 0
            )
        }
        return ArchiveJob(
            doneBytes: 0, totalBytes: 0, doneItems: UInt64(job.done), totalItems: UInt64(job.extract.entries.count), finished: job.finished,
            problem: job.problem, written: [], skipped: 0
        )
    }

    fileprivate func closed(_ id: SearchSessionID, shownAs: String) {
        state.withLock { state in
            state.sessions[id, default: Record()].closes += 1
            state.closeOrder.append(shownAs)
        }
    }

    fileprivate func cancel(_ id: ArchiveJobID) {
        state.withLockUnchecked { state in
            state.cancels.append(id)
            guard state.jobs[id.rawValue]?.expanded != nil else {
                state.jobs[id.rawValue]?.finished = true
                state.jobs[id.rawValue]?.stopped = true
                return
            }
            guard state.jobs[id.rawValue]?.finished == false else { return }
            state.jobs[id.rawValue]?.stopped = true
            finish(&state.jobs[id.rawValue]!, id: id)
        }
    }

    private func perform(_ job: inout Job, problems: [String: ArchiveProblem]) {
        job.finished = true
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: job.extract.folder, isDirectory: &isFolder), isFolder.boolValue else {
            job.failed = true
            return
        }
        var paths: [String] = []
        for selected in job.extract.entries {
            for path in [selected] + job.entries.map(\.path).filter({ $0.hasPrefix(selected + "/") }) where !paths.contains(path) { paths.append(path) }
        }
        for path in paths {
            if let problem = problems[path] {
                job.problem = problem
                return
            }
            if job.locked.contains(path) || job.locked.contains(where: { $0.hasPrefix(path + "/") }) {
                job.problem = .passwordNeeded
                return
            }
            guard let entry = job.entries.first(where: { $0.path == path })
                ?? (job.entries.contains { $0.path.hasPrefix(path + "/") } ? Entry(path, kind: .folder) : nil) else {
                job.problem = .gone(name: path)
                return
            }
            let url = URL(filePath: job.extract.folder, directoryHint: .isDirectory).appending(path: path)
            do {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch entry.kind {
                case .folder:
                    try manager.createDirectory(at: url, withIntermediateDirectories: true)
                case .link:
                    guard let target = entry.target, Self.inside(target, from: path) else {
                        job.problem = .pointsOutside(name: path)
                        return
                    }
                    try manager.createSymbolicLink(atPath: url.path(percentEncoded: false), withDestinationPath: target)
                case .file:
                    try (entry.source.map { try Data(contentsOf: URL(filePath: $0)) } ?? Self.bytes(path)).write(to: url, options: .withoutOverwriting)
                    if job.extract.readOnly { try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path(percentEncoded: false)) }
                }
            } catch {
                job.failed = true
                return
            }
            job.done += 1
        }
    }

    private static func inside(_ target: String, from path: String) -> Bool {
        guard !target.hasPrefix("/") else { return false }
        var depth = path.split(separator: "/").count - 1
        for part in target.split(separator: "/") where part != "." {
            depth += part == ".." ? -1 : 1
            if depth < 0 { return false }
        }
        return true
    }
}

nonisolated final class FakeArchiveSession: ArchiveSessionClient {
    private struct Listing {
        var folder = ""
        var text = ""
        var sort = SearchSort.bestMatch
        var hidesHidden = false
        var current: UInt64 = 0
        var rows: [UInt64: [SearchHit]] = [:]
        var stale = 0
        var deleted: [String] = []
        var added: [(source: String, path: String)] = []
    }

    let id: SearchSessionID
    private let client: FakeArchiveClient
    private let shownAs: String
    private let entries: [FakeArchiveClient.Entry]
    private let listing = OSAllocatedUnfairLock(initialState: Listing())
    private let unlocked = OSAllocatedUnfairLock(initialState: false)

    fileprivate init(id: SearchSessionID, client: FakeArchiveClient, shownAs: String, entries: [FakeArchiveClient.Entry], stale: Int) {
        self.id = id
        self.client = client
        self.shownAs = shownAs
        self.entries = entries
        listing.withLock { $0.stale = stale }
    }

    func browse(_ folder: String) throws -> SearchGeneration {
        list({
            $0.folder = folder
            $0.text = ""
        }, record: { $0.browses.append(folder) })
    }

    func search(_ query: String, sort: SearchSort) throws -> SearchGeneration {
        list({
            $0.sort = sort
            $0.hidesHidden = query.contains("hidden:no")
            $0.text = query.split(separator: " ").filter { !$0.contains(":") }.joined(separator: " ")
        }, record: { $0.searches.append(query) })
    }

    func refresh(_ query: String, sort: SearchSort) throws -> SearchGeneration {
        client.record(id) { $0.refreshes += 1 }
        return SearchGeneration(rawValue: listing.withLock { $0.current })
    }

    func sort(_ sort: SearchSort) throws -> SearchGeneration {
        list({ $0.sort = sort }, record: { $0.sorts.append(sort) })
    }

    func rows(_ generation: SearchGeneration, in range: Range<Int>) throws -> [SearchHit] {
        let stale = listing.withLock { listing in
            defer { listing.stale = max(0, listing.stale - 1) }
            return listing.stale > 0
        }
        if stale {
            client.record(id) { $0.staleReads += 1 }
            throw WhereverError.staleGeneration
        }
        return try listing.withLock { listing in
            guard let rows = listing.rows[generation.rawValue] else { throw WhereverError.staleGeneration }
            return Array(rows[range.clamped(to: 0..<rows.count)])
        }
    }

    func summary() throws -> ArchiveSummary {
        let read = client.laterSummary ?? (client.nested[(shownAs as NSString).lastPathComponent] == nil ? client.summary : ArchiveSummary(
            path: "", format: "zip", items: UInt64(entries.count), bytes: UInt64(entries.map(\.size).reduce(0, +)),
            encrypted: entries.contains { client.locked.contains($0.path) }, skipped: 0, problem: nil
        ))
        let problem = read.problem == .passwordNeeded && unlocked.withLock({ $0 }) ? nil : read.problem
        let editing = client.editing[(shownAs as NSString).lastPathComponent]
        guard editing != nil || problem != read.problem else { return read }
        return ArchiveSummary(
            path: read.path, format: read.format, items: read.items, bytes: read.bytes, encrypted: read.encrypted, skipped: read.skipped,
            problem: problem, editing: editing ?? read.editing
        )
    }

    func unlock(_ password: String) throws -> Bool {
        let onMain = Thread.isMainThread
        client.record(id) {
            $0.unlocks += 1
            if onMain { $0.unlocksOnMain += 1 }
        }
        guard client.passwords[(shownAs as NSString).lastPathComponent] == password else { return false }
        unlocked.withLock { $0 = true }
        return true
    }

    func encrypted(_ entry: String) throws -> Bool {
        client.locked.contains(entry) || client.locked.contains { $0.hasPrefix(entry + "/") }
    }

    func extract(entries: [String], folder: String, readOnly: Bool) throws -> ArchiveJobID {
        let (deleted, added) = listing.withLock { ($0.deleted, $0.added) }
        return client.start(
            FakeArchiveClient.Extract(entries: entries, folder: folder, readOnly: readOnly), entries: view(deleted: deleted, added: added),
            unlocked: unlocked.withLock { $0 }
        )
    }

    func expand(entries: [String], folder: String, whole: Bool) throws -> ArchiveJobID {
        client.expand(FakeArchiveClient.Expand(entries: entries, folder: folder, whole: whole))
    }

    func job(_ id: ArchiveJobID) throws -> ArchiveJob { try client.job(id) }

    func cancel(_ id: ArchiveJobID) throws { client.cancel(id) }

    func setChanges(_ changes: [ArchiveChange]) throws -> SearchGeneration {
        list({ listing in
            listing.deleted = changes.compactMap { change in
                guard case let .delete(path) = change else { return nil }
                return path
            }
            listing.added = changes.compactMap { change in
                guard case let .add(source, folder, name) = change else { return nil }
                return (source, folder.isEmpty ? name : folder + "/" + name)
            }
        }, record: { $0.changes.append(changes) })
    }

    func clashes(folder: String, names: [String]) throws -> [ArchiveClash] {
        let (deleted, added) = listing.withLock { ($0.deleted, $0.added) }
        let children = view(deleted: deleted, added: added).filter { ($0.path as NSString).deletingLastPathComponent == folder }
        let folded = { (name: String) in name.precomposedStringWithCanonicalMapping.lowercased() }
        var taken = Set(children.map { folded(($0.path as NSString).lastPathComponent) } + names.map(folded))
        var dropped: [String: String] = [:]
        return names.compactMap { name in
            let existing: (path: String, folder: Bool)
            if let child = children.first(where: { folded(($0.path as NSString).lastPathComponent) == folded(name) }) {
                existing = (child.path, child.kind == .folder)
            } else if let earlier = dropped[folded(name)] {
                existing = (earlier, false)
            } else {
                dropped[folded(name)] = folder.isEmpty ? name : folder + "/" + name
                return nil
            }
            let isFolder = existing.folder
            let stem = isFolder ? name : (name as NSString).deletingPathExtension
            let suffix = isFolder || (name as NSString).pathExtension.isEmpty ? "" : "." + (name as NSString).pathExtension
            var number = 2
            while !taken.insert(folded("\(stem) \(number)\(suffix)")).inserted { number += 1 }
            return ArchiveClash(name: name, existing: existing.path, folder: isFolder, freeName: "\(stem) \(number)\(suffix)")
        }
    }

    func writeEdited(to out: String) throws -> ArchiveJobID {
        client.record(id) { $0.writes.append(out) }
        let adds = listing.withLock { !$0.added.isEmpty }
        return try client.write(out, needsPassword: client.summary.encrypted && adds && !unlocked.withLock { $0 })
    }

    func close() throws { client.closed(id, shownAs: shownAs) }

    private func list(_ change: (inout Listing) -> Void, record: (inout FakeArchiveClient.Record) -> Void) -> SearchGeneration {
        let generation = client.nextGeneration(id, record)
        let (count, folder) = listing.withLockUnchecked { listing in
            change(&listing)
            let found = rows(of: listing)
            listing.current = generation.rawValue
            listing.rows = [generation.rawValue: found]
            return (found.count, listing.folder)
        }
        if !client.holds(id, folder: folder, generation: generation, count: count) { client.search.send(.resultsReady(generation, count: count)) }
        return generation
    }

    private func view(deleted: [String], added: [(source: String, path: String)]) -> [FakeArchiveClient.Entry] {
        let manager = FileManager.default
        let gone = Set(deleted)
        let kept = entries.filter { entry in
            var path = Substring(entry.path)
            while !gone.contains(String(path)) {
                guard let slash = path.lastIndex(of: "/") else { return true }
                path = path[..<slash]
            }
            return false
        }
        return kept + added.flatMap { source, path in
            var folder: ObjCBool = false
            guard manager.fileExists(atPath: source, isDirectory: &folder) else { return [FakeArchiveClient.Entry]() }
            return ([""] + (folder.boolValue ? manager.subpaths(atPath: source) ?? [] : [])).map { sub in
                var inner: ObjCBool = false
                manager.fileExists(atPath: sub.isEmpty ? source : source + "/" + sub, isDirectory: &inner)
                return FakeArchiveClient.Entry(
                    sub.isEmpty ? path : path + "/" + sub, kind: inner.boolValue ? .folder : .file, source: sub.isEmpty ? source : source + "/" + sub
                )
            }
        }
    }

    private func rows(of listing: Listing) -> [SearchHit] {
        if client.summary.problem == .passwordNeeded, !unlocked.withLock({ $0 }) { return [] }
        let text = listing.text
        let hits = view(deleted: listing.deleted, added: listing.added).filter { entry in
            (text.isEmpty ? (entry.path as NSString).deletingLastPathComponent == listing.folder
                : (entry.path as NSString).lastPathComponent.localizedCaseInsensitiveContains(text))
                && !(listing.hidesHidden && entry.path.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "__MACOSX" })
        }.map { entry in
            let folder = (entry.path as NSString).deletingLastPathComponent
            return SearchHit(
                name: (entry.path as NSString).lastPathComponent, folder: folder.isEmpty ? shownAs : shownAs + "/" + folder, size: entry.size,
                modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: entry.kind
            )
        }
        let sort = listing.sort
        return hits.sorted { left, right in
            if sort.foldersFirst, (left.kind == .folder) != (right.kind == .folder) { return left.kind == .folder }
            let order = left.name.localizedStandardCompare(right.name)
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}
