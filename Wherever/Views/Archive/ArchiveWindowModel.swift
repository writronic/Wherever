import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WhereverInterface

final class ArchiveWindowModel: ObservableObject {
    enum Selection: Equatable {
        case first
        case named(String)
        case row(Int)
    }

    struct Level {
        let shownAs: String
        let session: (any ArchiveSessionClient)?
        let results: SearchModel
        let root: URL?
        var extractor: ArchiveExtractor?
        var folder = ""
        var summary: ArchiveSummary?
        var problem: ArchiveProblem?
        var unlocked = false
        var password: String?
        var expanded = false
        var leaving: String?

        var name: String { (shownAs as NSString).lastPathComponent }
    }

    @Published private(set) var levels: [Level] = []
    @Published var preparing: String?
    @Published var opening: String?
    @Published var notice: String?
    @Published private(set) var asking: String?
    @Published private(set) var misses = 0
    @Published private(set) var unlocking = false
    @Published var expansion: Expansion?
    @Published var saving: Saving?
    var expandJob: ExpandJob?
    var saveJob: SaveJob?
    var waitingSave: ((Bool) -> Void)?
    var jobsWatch: AnyCancellable?
    var choose: (NSOpenPanel, @escaping (URL?) -> Void) -> Void = { _, done in done(nil) }
    var pick: (NSOpenPanel, @escaping ([URL]) -> Void) -> Void = { _, done in done([]) }
    var place: (NSSavePanel, @escaping (URL?) -> Void) -> Void = { _, done in done(nil) }
    @Published var clashing = false
    weak var controller: ArchiveWindowController?
    private var retries: [() -> Void] = []
    private var asker: SearchModel?
    private(set) var selection: Selection? = .first
    var stop: () -> Void = {}
    var running: Set<String> = []
    let base: ResultActions
    let readAccess: @Sendable (String) -> ArchiveAccess
    @Published private(set) var checked: (path: String, access: ArchiveAccess)?
    private(set) var checkingAccess = false
    private var accessChecks = 0
    private(set) var edits: ArchiveEdits?
    private let index: IndexModel
    private let defaults: UserDefaults
    private let columnPreferences: ColumnPreferences
    private let client: (any ArchiveClient)?
    private let extensions: [String]
    private var watch: AnyCancellable?

    init(
        shownAs: String, session: (any ArchiveSessionClient)?, index: IndexModel, actions: ResultActions,
        defaults: UserDefaults = .standard, columnPreferences: ColumnPreferences = .shared, root: URL? = nil,
        client: (any ArchiveClient)? = nil, extensions: [String] = [],
        access: @escaping @Sendable (String) -> ArchiveAccess = ArchiveAccess.read
    ) {
        base = actions
        readAccess = access
        self.index = index
        self.defaults = defaults
        self.columnPreferences = columnPreferences
        self.client = client
        self.extensions = extensions
        push(shownAs: shownAs, session: session, root: root)
        makeEdits()
        checkAccess()
    }

    func checkAccess() {
        accessChecks += 1
        let ticket = accessChecks
        let shown = outermost
        let read = readAccess
        checkingAccess = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let path = ArchiveWindows.resolved(shown)
            let access = read(path)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.accessChecked(ticket, path: path, access) } }
        }
    }

    private func accessChecked(_ ticket: Int, path: String, _ access: ArchiveAccess) {
        guard ticket == accessChecks else { return }
        checkingAccess = false
        checked = (path, access)
    }

    private func makeEdits() {
        edits = levels[0].session.map { ArchiveEdits(session: $0, results: levels[0].results, refuse: base.refuse) }
        edits?.busy = { [weak self] in self?.objectWillChange.send() }
        edits?.frozen = { [weak self] in self?.saving != nil }
    }

    private var level: Level {
        get { levels[levels.count - 1] }
        set { levels[levels.count - 1] = newValue }
    }

    var shownAs: String { level.shownAs }
    var results: SearchModel { level.results }
    var session: (any ArchiveSessionClient)? { level.session }
    var root: URL? { level.root }
    var extractor: ArchiveExtractor? { level.extractor }
    var folder: String { level.folder }
    var summary: ArchiveSummary? { level.summary }
    var problem: ArchiveProblem? { level.problem }
    var blocked: ArchiveProblem? {
        switch problem {
        case .damaged?, .pointsOutside?: (summary?.items ?? 0) > 0 ? nil : problem
        default: problem
        }
    }
    var depth: Int { levels.count - 1 }
    var locked: Bool { summary?.format == "zip" && summary?.encrypted == true && !level.unlocked }

    var outermost: String { levels[0].shownAs }

    var name: String { level.name }

    var location: String { ((outermost as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }

    var reading: Bool { summary == nil && problem == nil || level.leaving != nil }

    var canGoUp: Bool { !folder.isEmpty || depth > 0 }

    var searching: Bool { SearchModel.holdsWord(results.query) }

    func clearSearch() { results.query = "" }

    var segments: [String] { levels.flatMap { [$0.name] + Self.parts($0.folder) } }

    private static func parts(_ folder: String) -> [String] { folder.isEmpty ? [] : folder.components(separatedBy: "/") }

    func go(toSegment index: Int) {
        var start = 0
        for (depth, item) in levels.enumerated() {
            let parts = Self.parts(item.folder)
            defer { start += parts.count + 1 }
            guard index >= start, index <= start + parts.count else { continue }
            let local = index - start
            if depth == self.depth {
                guard parts.indices.contains(local) else { return }
                return browse(parts.prefix(local).joined(separator: "/"), selecting: parts[local])
            }
            let left = local < parts.count ? parts[local] : levels[depth + 1].name
            pop(to: depth)
            return browse(parts.prefix(local).joined(separator: "/"), selecting: left)
        }
    }

    func goEnclosing() {
        if let back = level.leaving { return browse(back, selecting: nil) }
        go(toSegment: segments.count - 2)
    }

    func stopReading() {
        level.leaving != nil || depth > 0 ? goEnclosing() : stop()
    }

    func showInFinder() {
        base.reveal([URL(filePath: outermost)])
    }

    func takeSelection() -> Int? {
        guard let selection, !results.isPending else { return nil }
        self.selection = nil
        guard !results.failed, let generation = results.results.generation, results.count > 0 else { return nil }
        switch selection {
        case .first:
            return 0
        case let .row(row):
            return min(row, results.count - 1)
        case let .named(name):
            find(name, generation: generation)
            return nil
        }
    }

    private func find(_ name: String, generation: SearchGeneration) {
        guard let session else { return }
        let asked = results
        let count = results.count
        let size = SearchModel.pageSize
        Task { [weak self] in
            let row = await Task.detached(priority: .userInitiated) { Self.position(of: name, in: session, generation: generation, count: count, size: size) }.value
            guard let self, results === asked, asked.results.generation == generation, selection == nil else { return }
            objectWillChange.send()
            selection = .row(row ?? 0)
        }
    }

    private nonisolated static func position(
        of name: String, in session: any ArchiveSessionClient, generation: SearchGeneration, count: Int, size: Int
    ) -> Int? {
        for start in stride(from: 0, to: count, by: size) {
            guard let rows = try? session.rows(generation, in: start..<min(start + size, count)) else { return nil }
            if let row = rows.firstIndex(where: { $0.name == name }) { return start + row }
        }
        return nil
    }

    func close() {
        let waiting = waitingSave
        waitingSave = nil
        jobsWatch = nil
        stopExpanding()
        stopSaving()
        for item in levels.reversed() { Self.close(item) }
        levels[0].password = nil
        waiting?(false)
    }

    func leaveNested() {
        if depth > 0 { pop(to: 0) }
    }

    func reopen(path: String, shownAs: String) {
        let folder = levels[0].folder
        let row = depth == 0 ? controller?.window?.contentView?.descendant(ThemedTable.self)?.selectedRow ?? -1 : -1
        let kept = row >= 0 ? results.rows(in: row..<row + 1).first?.name : nil
        let query = depth == 0 ? results.query : ""
        let cache = levels[0].root?.deletingLastPathComponent()
        let password = levels[0].password
        for item in levels.reversed() { Self.close(item) }
        levels.removeAll()
        let session = try? client?.openArchive(path: path, shownAs: shownAs)
        push(shownAs: shownAs, session: session, root: ArchiveWindows.cacheKey(path).flatMap { cache?.appending(path: $0, directoryHint: .isDirectory) })
        levels[0].password = password
        makeEdits()
        checkAccess()
        controller?.window?.undoManager?.removeAllActions()
        controller?.rekey(path: path)
        if !folder.isEmpty {
            browse(folder, selecting: kept)
        } else if let kept {
            selection = .named(kept)
        }
        guard !query.isEmpty else { return }
        results.query = query
        selection = kept.map(Selection.named) ?? .first
    }

    func heldElsewhere(_ url: URL) -> Bool {
        let path = ArchiveWindows.resolved(url.path(percentEncoded: false))
        let identity = ArchiveWindows.identity(path)
        return ArchiveWindows.all.contains { $0 !== controller && $0.holds(identity, path: path) }
    }

    func askPassword(then retry: @escaping () -> Void = {}) {
        retries.append(retry)
        guard asking == nil else { return }
        misses = 0
        asker = results
        asking = name
    }

    func submitPassword(_ password: String) {
        guard asking != nil, !unlocking, let session, let asker, asker === results else { return }
        unlocking = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let answer = Result { try session.unlock(password) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.answered(answer, password: password, for: asker) } }
        }
    }

    func cancelPassword() {
        guard asking != nil, !unlocking else { return }
        endAsking()
    }

    private func answered(_ answer: Result<Bool, any Error>, password: String, for asked: SearchModel) {
        unlocking = false
        guard asking != nil, asked === asker else { return }
        switch answer {
        case .success(false):
            misses += 1
        case .success(true):
            if let at = levels.firstIndex(where: { $0.results === asked }) {
                levels[at].unlocked = true
                if at == 0 { levels[at].password = password }
            }
            let waiting = asked === results ? retries : []
            endAsking()
            for retry in waiting { retry() }
        case .failure:
            endAsking()
            base.refuse()
        }
    }

    private func endAsking() {
        asking = nil
        asker = nil
        retries = []
    }

    func inner(_ path: String) -> String? {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let prefix = shownAs + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    func inner(_ hit: SearchHit) -> String? { Self.inner(hit, in: shownAs) }

    static func inner(_ hit: SearchHit, in shownAs: String) -> String? {
        var folder = hit.folder
        var shownAs = shownAs
        return folder.withUTF8 { folder in
            shownAs.withUTF8 { shown -> String? in
                guard folder.count >= shown.count, memcmp(folder.baseAddress, shown.baseAddress, shown.count) == 0 else { return nil }
                if folder.count == shown.count { return hit.name }
                guard folder[shown.count] == UInt8(ascii: "/") else { return nil }
                return String(decoding: UnsafeBufferPointer(rebasing: folder[(shown.count + 1)...]), as: UTF8.self) + "/" + hit.name
            }
        }
    }

    func browse(_ target: String, selecting name: String?) {
        guard let session, (try? session.browse(target)) != nil else { return base.refuse() }
        notice = nil
        if case .done = expansion { expansion = nil }
        level.leaving = expands(target) ? (level.leaving ?? level.folder) : nil
        level.folder = target
        selection = name.map(Selection.named) ?? .first
        clearSearch()
        results.reload()
    }

    private func expands(_ target: String) -> Bool {
        guard summary?.format == "pkg", !level.expanded else { return false }
        let parts = Self.parts(target)
        let leaf = parts.first?.hasSuffix(".pkg") == true && parts.count > 1 ? 1 : 0
        return parts.count > leaf && ["Payload", "Scripts"].contains(parts[leaf])
    }

    func enters(_ inner: String) -> Bool {
        ArchiveWindows.allows(name: (inner as NSString).lastPathComponent, extensions: extensions)
    }

    func enter(_ url: URL, inner: String) {
        guard let client else { return base.open(url) }
        let path = url.path(percentEncoded: false)
        let shown = shownAs + "/" + inner
        let cache = root?.deletingLastPathComponent()
        let key = ArchiveWindows.cacheKey(path)
        push(shownAs: shown, session: try? client.openArchive(path: path, shownAs: shown), root: key.flatMap { cache?.appending(path: $0, directoryHint: .isDirectory) })
    }

    private func push(shownAs: String, session: (any ArchiveSessionClient)?, root: URL?) {
        let results = index.makeArchiveModel(session: session, defaults: defaults, columnPreferences: columnPreferences)
        var item = Level(shownAs: shownAs, session: session, results: results, root: root, problem: session == nil ? .damaged : nil)
        item.extractor = makeExtractor(session: session, root: root)
        levels.append(item)
        selection = .first
        notice = nil
        if case .done = expansion { expansion = nil }
        follow(results)
    }

    private func pop(to depth: Int) {
        if let job = expandJob, job.depth > depth { stopExpanding() }
        while self.depth > depth { Self.close(levels.removeLast()) }
        notice = nil
        preparing = extractor?.current
        let hides = defaults.bool(forKey: SearchFilters.hidesHiddenKey)
        if results.filters.hidesHidden != hides { results.filters.hidesHidden = hides }
        follow(results)
    }

    private static func close(_ item: Level) {
        item.extractor?.close()
        try? item.session?.close()
    }

    private func follow(_ results: SearchModel) {
        watch = results.$results.sink { [weak self] in
            guard let self else { return }
            if $0.generation != nil { readSummary() } else { level.leaving = nil }
        }
    }

    private func makeExtractor(session: (any ArchiveSessionClient)?, root: URL?) -> ArchiveExtractor? {
        guard let session, let root else { return nil }
        return ArchiveExtractor(session: session, root: root) { [weak self] report in
            let model = self
            DispatchQueue.main.async { MainActor.assumeIsolated { model?.received(report) } }
        }
    }

    private func readSummary() {
        guard blocked == nil, let session else { return }
        let leaving = level.leaving
        level.leaving = nil
        guard let earlier = summary else {
            do {
                let read = try session.summary()
                level.summary = read
                level.problem = read.problem
                if let password = level.password, !level.unlocked, read.encrypted || read.problem == .passwordNeeded {
                    unlockAgain(with: password)
                } else if read.problem == .passwordNeeded, read.format == "dmg" {
                    askToUnlock()
                }
            } catch {
                level.problem = .damaged
            }
            return
        }
        guard let read = try? session.summary() else { return }
        level.summary = read
        if let later = read.problem, leaving != nil || later != earlier.problem {
            notice = Self.line(later, name: name)
        } else if leaving != nil, read.problem == nil {
            level.expanded = true
        }
    }

    private func unlockAgain(with password: String) {
        guard let session else { return }
        let asked = results
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let opened = (try? session.unlock(password)) == true
            DispatchQueue.main.async { MainActor.assumeIsolated { self.unlockedAgain(opened, for: asked) } }
        }
    }

    private func unlockedAgain(_ opened: Bool, for asked: SearchModel) {
        guard let at = levels.firstIndex(where: { $0.results === asked }) else { return }
        guard opened else {
            levels[at].password = nil
            if asked === results, problem == .passwordNeeded, summary?.format == "dmg" { askToUnlock() }
            return
        }
        levels[at].unlocked = true
        guard asked === results, problem == .passwordNeeded else { return }
        level.summary = nil
        level.problem = nil
        browse(folder, selecting: nil)
    }

    private func askToUnlock() {
        let asked = results
        askPassword { [weak self] in
            guard let self, results === asked else { return }
            level.summary = nil
            level.problem = nil
            browse(folder, selecting: nil)
        }
    }
}

extension ArchiveWindowModel {
    static func formatName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["rar", "cbr"].contains(ext), UTType(filenameExtension: ext).map(\.isDynamic) ?? true {
            return String(localized: "RAR archive", table: "Archive")
        }
        let file = SearchHit(name: name, folder: "", size: 0, modified: .distantPast, created: .distantPast, opened: .distantPast, kind: .file)
        return ResultType.of(file).kind
    }

    static func line(_ problem: ArchiveProblem, name: String, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        let shown = Bidi.name(name)
        return switch problem {
        case .damaged:
            String(localized: "Wherever can’t read “\(shown)”. The archive may be damaged.", table: "Archive", bundle: bundle, locale: locale)
        case .unsupported:
            String(localized: "Wherever can’t read “\(shown)”. It is in an unsupported format.", table: "Archive", bundle: bundle, locale: locale)
        case .encrypted, .passwordNeeded, .wrongPassword:
            String(localized: "Wherever can’t read “\(shown)” because it is encrypted.", table: "Archive", bundle: bundle, locale: locale)
        case .empty:
            String(localized: "The archive “\(shown)” is empty.", table: "Archive", bundle: bundle, locale: locale)
        case .changed:
            String(localized: "“\(shown)” changed on disk. Close this window and open it again.", table: "Archive", bundle: bundle, locale: locale)
        case .gone:
            String(localized: "Wherever can’t find “\(shown)”.", table: "Archive", bundle: bundle, locale: locale)
        case let .noSpace(needed, volume):
            String(
                localized: "There isn’t enough space on “\(Bidi.name(volume))”. This needs \(ByteCountFormatter.string(fromByteCount: Int64(clamping: needed), countStyle: .file)) more.",
                table: "Archive", bundle: bundle, locale: locale
            )
        case let .pointsOutside(entry):
            String(localized: "“\(Bidi.name((entry as NSString).lastPathComponent))” points outside the archive.", table: "Archive", bundle: bundle, locale: locale)
        case let .linkedItem(entry):
            String(
                localized: "“\(Bidi.name((entry as NSString).lastPathComponent))” can’t be deleted because another item in the archive links to it.",
                table: "Archive", bundle: bundle, locale: locale
            )
        case .oldEncryption:
            String(localized: "This archive uses an old kind of encryption, so Wherever can’t edit it.", table: "Archive", bundle: bundle, locale: locale)
        case let .duplicate(entry):
            String(localized: "The archive would hold two items named “\(Bidi.name((entry as NSString).lastPathComponent))”.", table: "Archive", bundle: bundle, locale: locale)
        }
    }

    static func revealsArchive(_ problem: ArchiveProblem) -> Bool { problem != .empty }
}
