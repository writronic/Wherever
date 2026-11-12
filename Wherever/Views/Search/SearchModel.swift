import AppKit
import Combine
import Foundation
import SwiftUI
import WhereverInterface

final class SearchModel: ObservableObject {
    static let pageSize = 128
    static let pageLimit = 8
    static let readPause = Duration.milliseconds(400)

    struct Results: Equatable {
        var generation: SearchGeneration?
        var count = 0
        var live = false
    }

    private struct Asked {
        var folder: String?
        var name: String
        var pills: String
    }

    struct ContentProgress: Equatable {
        var read = 0
        var total = 0
        var notDownloaded = 0
        var unreadable = 0
        var done = false
    }

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            queryChanges.send(query)
            search(live: false)
        }
    }
    let queryChanges = PassthroughSubject<String, Never>()
    @Published var filters = SearchFilters() {
        didSet {
            if folderMissing, filters.folder != oldValue.folder { folderMissing = false }
            guard !dropping, filters != oldValue else { return }
            search(live: false)
        }
    }
    @Published var content = ContentTerms() {
        didSet { termsChanged() }
    }
    var contentDraft = "" {
        didSet { termsChanged() }
    }
    @Published private(set) var hasTerms = false
    @Published private(set) var folderMissing = false
    private(set) var press: SearchGeneration? {
        didSet { if press == nil, folderMissing { folderMissing = false } }
    }
    private var pressFolder: String?
    private var pressed: Asked?
    private var readWait: Task<Void, Never>?
    private var folderWait: Task<Void, Never>?
    var readDelay: @MainActor () async -> Void = { try? await Task.sleep(for: SearchModel.readPause) }
    var checkFolder: @Sendable (String) -> (path: String, isFolder: Bool) = SearchModel.lookUpFolder
    @Published private(set) var progress: ContentProgress?
    @Published var sort = SearchSort.bestMatch {
        didSet { if sort != oldValue { resort() } }
    }
    var shownSort: SearchSort {
        listsAll && sort.column == .relevance && !sort.ascending && filters.nameText(query).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SearchSort(column: .name, ascending: true, foldersFirst: sort.foldersFirst) : sort
    }
    @Published private(set) var results = Results()
    @Published private(set) var failed = false
    private var pending = false
    var isPending: Bool { pending || readWait != nil }
    private(set) var lastSearchTime: Duration?
    private(set) var searchRevision = 0
    private var started: ContinuousClock.Instant?
    private var waiting: (generation: SearchGeneration, action: () -> Void)?

    var count: Int { results.count }

    private let session: (any ResultsSessionClient)?
    private var contentSession: (any SearchSessionClient)? { session as? any SearchSessionClient }
    private var columnsWatch: AnyCancellable?
    private var openedWatch: AnyCancellable?
    private var unmountWatch: AnyCancellable?
    private var openedStale = false
    private var changed = false
    var visible = true {
        didSet { catchUp() }
    }
    let columnPreferences: ColumnPreferences
    private let listsAll: Bool
    private var current: SearchGeneration?
    private var pages: [(index: Int, rows: [SearchHit])] = []

    init(
        session: (any ResultsSessionClient)?, listsAll: Bool = false, hidesHidden: Bool = false, query: String = "", columnPreferences: ColumnPreferences = .shared,
        mounts: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.columnPreferences = columnPreferences
        self.session = session
        self.listsAll = listsAll
        self._filters = Published(initialValue: SearchFilters(hidesHidden: hidesHidden))
        self.query = query
        _sort = Published(initialValue: SearchSort(column: .relevance, ascending: false, foldersFirst: columnPreferences.foldersFirst))
        columnsWatch = columnPreferences.$foldersFirst.dropFirst().sink { [weak self] first in
            guard let self else { return }
            sort = SearchSort(column: sort.column, ascending: sort.ascending, foldersFirst: first)
        }
        openedWatch = columnPreferences.$shown.map { $0.contains(.opened) }.removeDuplicates().dropFirst().sink { [weak self] shown in
            guard let self, listsAll, shown, openedStale, press == nil else { return }
            changed = true
            catchUp()
        }
        let unmount = mounts.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
            guard let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path(percentEncoded: false) else { return }
            MainActor.assumeIsolated { self?.unmounting(Self.trimmed(volume)) }
        }
        unmountWatch = AnyCancellable { mounts.removeObserver(unmount) }
        if searchable { search(live: false) }
    }

    private nonisolated static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func unmounting(_ volume: String) {
        guard reading, volume != "/", let folder = pressFolder, folder == volume || folder.hasPrefix(volume + "/") else { return }
        try? contentSession?.stopContent()
    }

    func rows(in range: Range<Int>) -> [SearchHit] {
        let range = range.clamped(to: 0..<count)
        return range.compactMap { row in
            let rows = page(row / Self.pageSize)
            let offset = row % Self.pageSize
            return offset < rows.count ? rows[offset] : nil
        }
    }

    func hits(at rows: IndexSet) -> [SearchHit] {
        guard let generation = results.generation, let session else { return [] }
        var hits: [SearchHit] = []
        do {
            for run in rows.rangeView {
                let run = run.clamped(to: 0..<count)
                for start in stride(from: run.lowerBound, to: run.upperBound, by: Self.pageSize) {
                    hits += try session.rows(generation, in: start..<min(start + Self.pageSize, run.upperBound))
                }
            }
        } catch {}
        return hits
    }

    func readHits(at rows: IndexSet) -> Task<[SearchHit], any Error> {
        let session = session, generation = results.generation, first = rows.first ?? 0
        let span = first..<max(first, min((rows.last ?? first) + 1, count))
        return Task.detached {
            guard let session, let generation, !span.isEmpty else { return [] }
            let all = try session.rows(generation, in: span)
            guard all.count == span.count else { throw WhereverError.staleGeneration }
            return rows.compactMap { span.contains($0) ? all[$0 - span.lowerBound] : nil }
        }
    }

    private func page(_ index: Int) -> [SearchHit] {
        if let found = pages.firstIndex(where: { $0.index == index }) {
            let page = pages.remove(at: found)
            pages.append(page)
            return page.rows
        }
        guard let generation = results.generation else { return [] }
        let start = index * Self.pageSize
        let rows = (try? session?.rows(generation, in: start..<min(start + Self.pageSize, count))) ?? []
        pages.append((index, rows))
        if pages.count > Self.pageLimit { pages.removeFirst() }
        return rows
    }

    static func holdsWord(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var searchable: Bool { listsAll || Self.holdsWord(filters.nameText(query)) || filters.narrowsResults }

    var reading: Bool { press != nil && progress?.done == false }

    func searchContent() {
        guard !reading else {
            dropReadWait()
            try? contentSession?.stopContent()
            return
        }
        read()
    }

    private func read() {
        dropReadWait()
        let words = content.words(draft: contentDraft)
        guard !words.isEmpty else { return }
        let generation = askContent { try $0.searchContent(searchText, terms: words, matchAll: content.match == .all, sort: shownSort) }
        press = generation
        pressed = asked
        progress = generation == nil ? nil : ContentProgress()
        checkPressFolder(generation)
        begin(generation, live: false)
    }

    private func checkPressFolder(_ generation: SearchGeneration?) {
        folderWait?.cancel()
        let folder = generation == nil ? nil : filters.folder
        pressFolder = folder.map { Self.trimmed(($0 as NSString).expandingTildeInPath) }
        guard let folder else {
            folderWait = nil
            if folderMissing { folderMissing = false }
            return
        }
        let check = checkFolder
        folderWait = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { check(folder) }.value
            guard let self, !Task.isCancelled, press == generation, filters.folder == folder else { return }
            pressFolder = found.path
            if folderMissing == found.isFolder { folderMissing = !found.isFolder }
        }
    }

    private nonisolated static func lookUpFolder(_ text: String) -> (path: String, isFolder: Bool) {
        let path = (text as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let isFolder = path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        return (trimmed(URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)), isFolder)
    }

    private var asked: Asked {
        Asked(folder: filters.folder, name: filters.nameText(query).trimmingCharacters(in: .whitespacesAndNewlines), pills: filters.pills)
    }

    private var keptSetAnswers: Bool {
        guard let pressed else { return false }
        let now = asked
        return pressed.folder == now.folder && (pressed.name.isEmpty || pressed.name == now.name) && (pressed.pills.isEmpty || pressed.pills == now.pills)
    }

    private func dropReadWait() {
        readWait?.cancel()
        readWait = nil
    }

    private func readAfterThePause() {
        dropReadWait()
        readWait = Task { [weak self] in
            await self?.readDelay()
            guard !Task.isCancelled else { return }
            self?.read()
        }
    }

    func whenReady(_ action: @escaping () -> Void) { waiting = reading || readWait != nil ? nil : current.map { ($0, action) } }

    func dropWaiting() { waiting = nil }

    private func termsChanged() {
        let holds = !content.words(draft: contentDraft).isEmpty
        if hasTerms != holds { hasTerms = holds }
        dropEmptyPress()
    }

    private func dropEmptyPress() {
        guard press != nil, content.words(draft: contentDraft).isEmpty else { return }
        dropReadWait()
        press = nil
        progress = nil
        try? contentSession?.stopContent()
        search(live: false)
    }

    private var searchText: String {
        let text = filters.typedText(query)
        let tokens = filters.tokens
        guard !tokens.isEmpty else { return text }
        let closed = text.filter { $0 == "\"" }.count.isMultiple(of: 2) ? text : text + "\""
        return closed.isEmpty ? tokens : closed + " " + tokens
    }

    private var dropping = false

    func dropNormalControls() {
        let before = searchable ? searchText : nil
        let order = shownSort
        let held = press != nil
        if held {
            dropReadWait()
            press = nil
            progress = nil
            try? contentSession?.stopContent()
        }
        dropping = true
        content = ContentTerms()
        contentDraft = ""
        filters = SearchFilters(hidesHidden: filters.hidesHidden)
        dropping = false
        if held || (searchable ? searchText : nil) != before || shownSort != order { search(live: false) }
    }

    private func show(_ new: Results) {
        pages = []
        results = new
    }

    private func search(live: Bool) {
        if !live { searchRevision += 1 }
        changed = false
        if press != nil {
            guard keptSetAnswers else { return readAfterThePause() }
            dropReadWait()
            return begin(askContent { try $0.narrow(searchText, sort: shownSort) }, live: live)
        }
        guard searchable else {
            current = nil
            pending = false
            setFailed(false)
            show(Results())
            return
        }
        let generation = ask { try live ? $0.refresh(searchText, sort: shownSort) : $0.search(searchText, sort: shownSort) }
        if generation != nil { openedStale = false }
        begin(generation, live: live)
    }

    private func resort() {
        guard searchable || press != nil else { return }
        if press == nil, changed || (openedStale && shownSort.column == .opened) { return search(live: false) }
        guard current != nil else { return search(live: false) }
        guard let generation = ask({ try $0.sort(shownSort) }) else { return }
        begin(generation, live: false)
    }

    func reload() {
        searchRevision += 1
        changed = false
        begin(ask { try $0.refresh(searchText, sort: shownSort) }, live: false)
    }

    private func askContent(_ call: (any SearchSessionClient) throws -> SearchGeneration) -> SearchGeneration? {
        ask { session in
            guard let session = session as? any SearchSessionClient else { throw WhereverError.unknown }
            return try call(session)
        }
    }

    private func ask(_ call: (any ResultsSessionClient) throws -> SearchGeneration) -> SearchGeneration? {
        do {
            guard let session else { throw WhereverError.unknown }
            let generation = try call(session)
            setFailed(false)
            return generation
        } catch {
            setFailed(error as? WhereverError != .staleGeneration)
            return nil
        }
    }

    private func setFailed(_ value: Bool) {
        if failed != value { failed = value }
    }

    private func begin(_ generation: SearchGeneration?, live: Bool) {
        current = generation
        started = generation == nil || live ? nil : .now
        if current == nil {
            pending = false
            show(Results())
        } else if !live {
            pending = true
        }
    }

    private func catchUp() {
        guard changed, visible, press == nil, searchable, current == nil || current == results.generation else { return }
        search(live: true)
    }

    func handle(_ event: SearchEvent) {
        switch event {
        case .resultsChanged, .openedChanged:
            guard searchable, press == nil else { return }
            if event == .openedChanged {
                openedStale = true
                guard shownSort.column == .opened || (listsAll && columnPreferences.shown.contains(.opened)) else { return }
            }
            changed = true
            catchUp()
        case let .resultsReady(generation, count):
            guard generation == current else { return }
            lastSearchTime = started.map { $0.duration(to: .now) } ?? lastSearchTime
            show(Results(generation: generation, count: count, live: !pending))
            pending = false
            let ready = waiting?.generation == generation ? waiting?.action : nil
            waiting = nil
            if count > 0 { ready?() }
            catchUp()
        case let .searchFailed(generation):
            guard generation == current || generation == press else { return }
            if generation == press {
                dropReadWait()
                press = nil
                progress = nil
                try? contentSession?.stopContent()
            }
            if generation == current {
                current = nil
                pending = false
            }
            setFailed(true)
            catchUp()
        case let .contentProgress(generation, read, total, notDownloaded, unreadable, done):
            guard generation == press else { return }
            progress = ContentProgress(read: read, total: total, notDownloaded: notDownloaded, unreadable: unreadable, done: done)
        case .stateChanged, .volumesChanged:
            break
        }
    }
}
