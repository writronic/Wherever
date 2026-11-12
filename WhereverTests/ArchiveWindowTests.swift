import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Wherever
import WhereverInterface
import os

private let photos: [FakeArchiveClient.Entry] = [
    .init("Trip", kind: .folder), .init("Family", kind: .folder), .init("notes.txt", size: 2_048), .init("cover.jpg", size: 1_200_000),
    .init("Trip/IMG_0001.HEIC", size: 10), .init("Trip/IMG_0002.HEIC", size: 10), .init("Trip/Day 2", kind: .folder), .init("Trip/Beach", kind: .folder),
    .init("Trip/Day 2/IMG_0003.HEIC", size: 10),
]

private let topLevel = ["Family", "Trip", "cover.jpg", "notes.txt"]

private func archiveStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.archive"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
}

private func summary(items: UInt64 = 8, bytes: UInt64 = 1_202_078, encrypted: Bool = false, skipped: UInt64 = 0, problem: ArchiveProblem? = nil) -> ArchiveSummary {
    ArchiveSummary(path: "", format: "zip", items: items, bytes: bytes, encrypted: encrypted, skipped: skipped, problem: problem)
}

private func file(_ name: String, in folder: URL, kind: SearchHit.Kind = .file) -> SearchHit {
    SearchHit(
        name: name, folder: folder.path(percentEncoded: false), size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast,
        opened: .distantPast, kind: kind
    )
}

private func key(_ window: NSWindow, _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
    ))
    if flags.contains(.command), window.performKeyEquivalent(with: event) { return }
    window.sendEvent(event)
}

private func arrow(_ window: NSWindow, _ arrow: NSEvent.SpecialKey, flags: NSEvent.ModifierFlags = []) throws {
    let codes: [NSEvent.SpecialKey: UInt16] = [.upArrow: 126, .downArrow: 125]
    try key(window, String(Character(arrow.unicodeScalar)), code: try #require(codes[arrow]), flags: flags.union([.numericPad, .function]))
}

private func returnKey(_ window: NSWindow) throws { try key(window, "\r", code: 36) }

private func texts(in view: NSView?) -> [String] {
    guard let view else { return [] }
    return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { texts(in: $0) }
}

private func holdingMenu(_ title: String, in menu: NSMenu? = NSApp.mainMenu) -> NSMenu? {
    guard let menu else { return nil }
    menu.delegate?.menuNeedsUpdate?(menu)
    if menu.items.contains(where: { $0.title == title }) { return menu }
    return menu.items.lazy.compactMap { holdingMenu(title, in: $0.submenu) }.first
}

private nonisolated final class RowWatch: ArchiveClient {
    struct Read: Sendable {
        let start: Int
        let onMain: Bool
    }

    let inner: FakeArchiveClient
    private let log = OSAllocatedUnfairLock(initialState: [Read]())

    init(_ inner: FakeArchiveClient) { self.inner = inner }

    var reads: [Read] { log.withLock { $0 } }

    func clear() { log.withLock { $0 = [] } }

    func record(_ start: Int) {
        let onMain = Thread.isMainThread
        log.withLock { $0.append(Read(start: start, onMain: onMain)) }
    }

    func archiveExtensions() throws -> [String] { try inner.archiveExtensions() }

    func openArchive(path: String, shownAs: String) throws -> any ArchiveSessionClient {
        WatchedSession(inner: try inner.openArchive(path: path, shownAs: shownAs), watch: self)
    }
}

private nonisolated final class WatchedSession: ArchiveSessionClient {
    let inner: any ArchiveSessionClient
    let watch: RowWatch

    init(inner: any ArchiveSessionClient, watch: RowWatch) {
        self.inner = inner
        self.watch = watch
    }

    var id: SearchSessionID { inner.id }
    func search(_ query: String, sort: SearchSort) throws -> SearchGeneration { try inner.search(query, sort: sort) }
    func refresh(_ query: String, sort: SearchSort) throws -> SearchGeneration { try inner.refresh(query, sort: sort) }
    func sort(_ sort: SearchSort) throws -> SearchGeneration { try inner.sort(sort) }

    func rows(_ generation: SearchGeneration, in range: Range<Int>) throws -> [SearchHit] {
        watch.record(range.lowerBound)
        return try inner.rows(generation, in: range)
    }

    func browse(_ folder: String) throws -> SearchGeneration { try inner.browse(folder) }
    func summary() throws -> ArchiveSummary { try inner.summary() }
    func unlock(_ password: String) throws -> Bool { try inner.unlock(password) }
    func encrypted(_ entry: String) throws -> Bool { try inner.encrypted(entry) }
    func extract(entries: [String], folder: String, readOnly: Bool) throws -> ArchiveJobID { try inner.extract(entries: entries, folder: folder, readOnly: readOnly) }
    func expand(entries: [String], folder: String, whole: Bool) throws -> ArchiveJobID { try inner.expand(entries: entries, folder: folder, whole: whole) }
    func job(_ id: ArchiveJobID) throws -> ArchiveJob { try inner.job(id) }
    func cancel(_ id: ArchiveJobID) throws { try inner.cancel(id) }
    func setChanges(_ changes: [ArchiveChange]) throws -> SearchGeneration { try inner.setChanges(changes) }
    func clashes(folder: String, names: [String]) throws -> [ArchiveClash] { try inner.clashes(folder: folder, names: names) }
    func writeEdited(to out: String) throws -> ArchiveJobID { try inner.writeEdited(to: out) }
    func close() throws { try inner.close() }
}

@MainActor
private final class Rig {
    let search: FakeSearchClient
    let archive: FakeArchiveClient
    let index: IndexModel
    let recorder = ActionRecorder()
    let main = ActionRecorder()
    let defaults: UserDefaults
    let windows: ArchiveWindows
    let folder: URL
    let cache: URL
    let mainCount: Int
    private var hosts: [SearchHost] = []

    init(
        entries: [FakeArchiveClient.Entry] = photos, summary: ArchiveSummary? = nil, extensions: [String] = ["zip", "jar", "aar", "apk", "cbz"],
        hidesHidden: Bool = false, mainHits: [String] = []
    ) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-window-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = folder.appending(path: "Cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Photos 2024.zip", "Other.zip", "notes.txt"] {
            try Data().write(to: folder.appending(path: name))
        }
        search = FakeSearchClient(hits: [])
        archive = FakeArchiveClient(search: search, extensions: extensions, entries: entries, summary: summary)
        index = IndexModel(client: search)
        defaults = archiveStore()
        defaults.set(hidesHidden, forKey: SearchFilters.hidesHiddenKey)
        let preferences = ColumnPreferences(defaults: defaults)
        preferences.foldersFirst = true
        windows = ArchiveWindows(client: archive, index: index, actions: recorder.actions, defaults: defaults, columnPreferences: preferences, cache: cache)
        mainCount = mainHits.count
        let folder = folder
        search.setHits(mainHits.map { file($0, in: folder) })
    }

    var zip: SearchHit { file("Photos 2024.zip", in: folder) }

    var other: SearchHit { file("Other.zip", in: folder) }

    var zipPath: String { zip.path }

    func close() {
        let open = ArchiveWindows.all
        open.forEach { $0.window?.close() }
        hosts.forEach { $0.close() }
        try? FileManager.default.removeItem(at: folder)
    }

    func open(_ hit: SearchHit? = nil, count: Int = topLevel.count) async throws -> (NSWindow, ThemedTable, ArchiveWindowModel) {
        windows.open(hit ?? zip)
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let table = try await listed(window, model: controller.model, count: count)
        return (window, table, controller.model)
    }

    func table(_ window: NSWindow) -> ThemedTable? {
        window.contentView?.layoutSubtreeIfNeeded()
        return window.contentView?.descendant(ThemedTable.self)
    }

    func listed(_ window: NSWindow, model: ArchiveWindowModel, count: Int, selected: Int? = 0) async throws -> ThemedTable {
        try await untilTrue(waitingFor: "\(count) rows with row \(selected.map { "\($0)" } ?? "none") selected; shown \(model.results.names)") {
            guard let table = table(window) else { return false }
            return !model.results.isPending && table.numberOfRows == count && selected.map { table.selectedRowIndexes == [$0] } != false
        }
        return try #require(table(window))
    }

    func element(_ id: String, in window: NSWindow) async throws -> NSObject {
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "\(id) among \(AXTree.nodeCount(in: content)) accessibility nodes") {
            content.layoutSubtreeIfNeeded()
            return AXTree.element(id, in: content) != nil
        }
        return try #require(AXTree.element(id, in: content))
    }

    func mainWindow() async throws -> (SearchHost, SearchModel) {
        let model = index.makeModel()
        var actions = main.actions
        actions.inside = windows.inside
        let host = SearchHost(root: AnyView(SearchView(model: model)), actions: actions)
        hosts.append(host)
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        try await host.type("ph")
        search.send(.resultsReady(search.latest, count: mainCount))
        try await host.until("\(mainCount) main rows") { !model.isPending && host.list()?.numberOfRows == mainCount }
        return (host, model)
    }
}

@Suite(.serialized) struct ArchiveWindowTests {
    @Test func opensOneWindowPerArchiveAndFocusesItAgain() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (first, _, model) = try await rig.open()
        let firstSession = rig.archive.lastSession
        #expect(first.title == "Photos 2024.zip")
        #expect(first.subtitle == ((rig.zipPath as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
        let unplaced = ArchiveWindowController(
            model: ArchiveWindowModel(shownAs: rig.zipPath, session: nil, index: rig.index, actions: rig.recorder.actions, defaults: rig.defaults),
            identity: nil, path: rig.zipPath, defaults: rig.defaults
        )
        #expect(unplaced.window?.frame.size == ArchiveWindows.defaultSize)
        #expect(unplaced.window?.contentMinSize == NSSize(width: SearchMetrics.windowMinWidth, height: SearchMetrics.windowMinHeight))
        #expect(first.identifier?.rawValue == ArchiveWindows.windowID)
        #expect(model.name == "Photos 2024.zip")
        let (second, _, _) = try await rig.open(rig.other)
        #expect(ArchiveWindows.all.count == 2)
        #expect(NSApp.orderedWindows.firstIndex(of: second) ?? .max < NSApp.orderedWindows.firstIndex(of: first) ?? .max)

        rig.windows.open(rig.zip)
        #expect(ArchiveWindows.all.count == 2)
        #expect(rig.archive.opened.count == 2)
        #expect(NSApp.orderedWindows.firstIndex(of: first) ?? .max < NSApp.orderedWindows.firstIndex(of: second) ?? .max)

        first.performClose(nil)
        #expect(!first.isVisible)
        #expect(rig.archive.session(firstSession)?.closes == 1)
        #expect(ArchiveWindows.all.compactMap(\.window) == [second])
        rig.windows.open(rig.zip)
        #expect(rig.archive.opened.count == 3)
        #expect(ArchiveWindows.all.count == 2)
    }

    @Test func listsTheTopLevelSortedFoldersFirst() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        #expect(model.results.names == topLevel)
        #expect(table.selectedRowIndexes == [0])
        #expect(window.firstResponder === table)
        let record = try #require(rig.archive.session(rig.archive.lastSession))
        #expect(record.searches == [""])
        #expect(record.browses.isEmpty)
        #expect(rig.archive.opened == [FakeArchiveClient.Opened(path: ArchiveWindows.resolved(rig.zipPath), shownAs: rig.zipPath)])
        #expect(model.results.rows(in: 0..<1).first?.folder == rig.zipPath)
        #expect(model.segments == ["Photos 2024.zip"])
        #expect(model.folder.isEmpty)
    }

    @Test func returnOnAFolderEntersIt() async throws {
        let rig = try Rig(mainHits: ["Photos 2024.zip"])
        defer { rig.close() }
        let (host, _) = try await rig.mainWindow()
        try await host.focusList()
        try #require(host.list()).selectRowIndexes([0], byExtendingSelection: false)
        try host.press(.downArrow, flags: .command)
        #expect(rig.main.opened.isEmpty)
        let controller = try #require(ArchiveWindows.all.first)
        let window = try #require(controller.window)
        let model = controller.model
        let table = try await rig.listed(window, model: model, count: topLevel.count)
        try arrow(window, .downArrow)
        #expect(table.selectedRowIndexes == [1])
        try returnKey(window)
        _ = try await rig.listed(window, model: model, count: 4)
        #expect(model.results.names == ["Beach", "Day 2", "IMG_0001.HEIC", "IMG_0002.HEIC"])
        #expect(rig.archive.session(rig.archive.lastSession)?.browses == ["Trip"])
        #expect(model.folder == "Trip")
        #expect(model.segments == ["Photos 2024.zip", "Trip"])
        #expect(window.firstResponder === table)
        #expect(rig.recorder.refused == 0)
        #expect(rig.recorder.opened.isEmpty)
        try arrow(window, .downArrow)
        try returnKey(window)
        _ = try await rig.listed(window, model: model, count: 1)
        #expect(model.results.names == ["IMG_0003.HEIC"])
        #expect(model.folder == "Trip/Day 2")
    }

    @Test func commandUpGoesToTheEnclosingFolderAndSelectsTheFolderYouLeft() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        table.selectRowIndexes([1], byExtendingSelection: false)
        try returnKey(window)
        _ = try await rig.listed(window, model: model, count: 4)
        table.selectRowIndexes([1], byExtendingSelection: false)
        try returnKey(window)
        _ = try await rig.listed(window, model: model, count: 1)
        try arrow(window, .upArrow, flags: .command)
        _ = try await rig.listed(window, model: model, count: 4, selected: 1)
        #expect(model.folder == "Trip")
        #expect(model.results.names[1] == "Day 2")
        try arrow(window, .upArrow, flags: .command)
        _ = try await rig.listed(window, model: model, count: topLevel.count, selected: 1)
        #expect(model.folder.isEmpty)
        #expect(model.results.names[1] == "Trip")
        #expect(rig.archive.session(rig.archive.lastSession)?.browses == ["Trip", "Trip/Day 2", "Trip", ""])
        #expect(rig.recorder.refused == 0)
        #expect(window.firstResponder === table)
    }

    @Test func commandUpAtTheRootDoesNothing() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        table.selectRowIndexes([2], byExtendingSelection: false)
        try arrow(window, .upArrow, flags: .command)
        try arrow(window, .upArrow, flags: .command)
        try await pumpEvents(for: .milliseconds(50))
        #expect(table.selectedRowIndexes == [2])
        #expect(rig.archive.session(rig.archive.lastSession)?.browses == [])
        #expect(rig.archive.session(rig.archive.lastSession)?.refreshes == 0)
        #expect(model.folder.isEmpty)
        #expect(rig.recorder.nothingHappened)
        #expect(ArchiveWindows.all.count == 1)
        #expect(window.isVisible)
        try arrow(window, .downArrow)
        #expect(table.selectedRowIndexes == [3])
    }

    @Test func goingUpOutOfAFolderAmong20000SelectsItWithThePageReadsOffTheMainThread() async throws {
        let names = (0..<20_000).map { String(format: "d%05d", $0) }
        let rig = try Rig(entries: names.map { FakeArchiveClient.Entry($0, kind: .folder) } + [.init("d19990/inside.txt")])
        defer { rig.close() }
        let watch = RowWatch(rig.archive)
        let windows = ArchiveWindows(
            client: watch, index: rig.index, actions: rig.recorder.actions, defaults: rig.defaults, columnPreferences: ColumnPreferences(defaults: rig.defaults),
            cache: rig.cache
        )
        defer { ArchiveWindows.all.forEach { $0.window?.close() } }
        windows.open(rig.zip)
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let model = controller.model
        _ = try await rig.listed(window, model: model, count: names.count)
        model.browse("d19990", selecting: nil)
        _ = try await rig.listed(window, model: model, count: 1)
        watch.clear()

        model.goEnclosing()
        _ = try await rig.listed(window, model: model, count: names.count, selected: 19_990)
        let reads = watch.reads
        let size = SearchModel.pageSize
        #expect(reads.contains { !$0.onMain && $0.start == 19_990 / size * size })
        let middle = size..<(19_990 / size - 1) * size
        #expect(!reads.contains { $0.onMain && middle.contains($0.start) }, "main-thread page reads at \(reads.filter(\.onMain).map(\.start))")
        #expect(model.folder.isEmpty)
        #expect(model.results.rows(in: 19_990..<19_991).first?.name == "d19990")
        #expect(rig.recorder.refused == 0)
    }

    @Test func pathSegmentClickBrowses() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        let enclosing = try await rig.element(ArchivePathBar.enclosingID, in: window)
        #expect(AXTree.isEnabled(enclosing) == false)
        #expect(AXTree.names(of: enclosing).contains(String(localized: "Enclosing Folder", table: "Archive")))
        table.selectRowIndexes([1], byExtendingSelection: false)
        try returnKey(window)
        _ = try await rig.listed(window, model: model, count: 4)
        table.selectRowIndexes([1], byExtendingSelection: false)
        try returnKey(window)
        _ = try await rig.listed(window, model: model, count: 1)
        let segment = try await rig.element(ArchivePathBar.segmentID(2), in: window)
        #expect(AXTree.names(of: segment).contains("Day 2"))
        #expect(AXTree.press(segment))
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.archive.session(rig.archive.lastSession)?.browses == ["Trip", "Trip/Day 2"])

        #expect(AXTree.press(try await rig.element(ArchivePathBar.segmentID(1), in: window)))
        _ = try await rig.listed(window, model: model, count: 4, selected: 1)
        #expect(model.folder == "Trip")
        #expect(AXTree.press(try await rig.element(ArchivePathBar.segmentID(0), in: window)))
        _ = try await rig.listed(window, model: model, count: topLevel.count, selected: 1)
        #expect(model.folder.isEmpty)
        #expect(rig.archive.session(rig.archive.lastSession)?.browses == ["Trip", "Trip/Day 2", "Trip", ""])

        table.selectRowIndexes([2], byExtendingSelection: false)
        try returnKey(window)
        let key = try #require(ArchiveWindows.cacheKey(ArchiveWindows.resolved(rig.zipPath)))
        let copy = ArchiveWindowModel.place("cover.jpg", in: rig.cache.appending(path: key), folder: "open").appending(path: "cover.jpg")
        try await untilTrue(waitingFor: "the read-only copy to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [copy] }
        #expect(rig.recorder.refused == 0)
        #expect(rig.recorder.recorded.isEmpty)
        #expect(rig.archive.session(rig.archive.lastSession)?.browses.count == 4)
        #expect(table.selectedRowIndexes == [2])
    }

    @Test func statusShowsFormatItemsSizeAndLock() async throws {
        let plain = try Rig(summary: summary(items: 1_284, bytes: 245_600_000))
        defer { plain.close() }
        let (quiet, _, quietModel) = try await plain.open()
        try await untilTrue(waitingFor: "the summary") { quietModel.summary != nil }
        _ = try await plain.element(ArchiveStatusBar.itemsID, in: quiet)
        #expect(AXTree.element(ArchiveStatusBar.lockID, in: try #require(quiet.contentView)) == nil)
        #expect(AXTree.element(ArchiveStatusBar.skippedID, in: try #require(quiet.contentView)) == nil)
        quiet.close()

        let rig = try Rig(summary: summary(items: 1_284, bytes: 245_600_000, encrypted: true))
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        let format = try await rig.element(ArchiveStatusBar.formatID, in: window)
        let zipKind = ResultType.of(file("Photos 2024.zip", in: rig.folder)).kind
        #expect(AXTree.names(of: format).contains(zipKind))
        #expect(ArchiveWindowModel.formatName("Photos 2024.zip") == zipKind)
        let items = try await rig.element(ArchiveStatusBar.itemsID, in: window)
        let count = UInt64(1_284).formatted(.number.locale(.autoupdatingCurrent))
        #expect(AXTree.names(of: items).contains(String(localized: "Items: \(count)", table: "Archive")))
        let size = try await rig.element(ArchiveStatusBar.sizeID, in: window)
        #expect(AXTree.names(of: size).contains(ByteCountFormatter.string(fromByteCount: 245_600_000, countStyle: .file)))
        let lock = try await rig.element(ArchiveStatusBar.lockID, in: window)
        #expect(AXTree.names(of: lock).contains(String(localized: "Encrypted", table: "Archive")))
        #expect(model.summary?.items == 1_284)
        #expect(!model.reading)
        #expect(AXTree.element(ArchiveStatusBar.activityID, in: try #require(window.contentView)) == nil)

        let rar = UTType(filenameExtension: "rar")
        let rarName = rar.map(\.isDynamic) == false
            ? ResultType.of(file("Music.rar", in: rig.folder)).kind : String(localized: "RAR archive", table: "Archive")
        #expect(ArchiveWindowModel.formatName("Music.rar") == rarName)
        #expect(ArchiveWindowModel.formatName("Photos.cbz") == ResultType.of(file("Photos.cbz", in: rig.folder)).kind)
    }

    @Test func damagedShowsTheLineAndShowInFinderRevealsTheArchive() async throws {
        let problems: [ArchiveProblem] = [.damaged, .unsupported, .encrypted, .gone(name: "/elsewhere/Photos 2024.zip")]
        for problem in problems {
            let rig = try Rig(summary: summary(items: 0, bytes: 0, problem: problem))
            defer { rig.close() }
            rig.windows.open(rig.zip)
            let controller = try #require(ArchiveWindows.all.first)
            let window = try #require(controller.window)
            let line = try await rig.element(ArchiveView.problemID, in: window)
            let expected = ArchiveWindowModel.line(problem, name: "Photos 2024.zip")
            #expect(AXTree.names(of: line).contains(expected), "\(problem)")
            #expect(expected.contains("Photos 2024.zip"))
            #expect(controller.model.problem == problem)
            #expect(rig.table(window) == nil)
            let reveal = try await rig.element(ArchiveView.problemRevealID, in: window)
            #expect(rig.recorder.revealed.isEmpty)
            #expect(AXTree.press(reveal))
            try await untilTrue(waitingFor: "the reveal of \(problem)") { !rig.recorder.revealed.isEmpty }
            #expect(rig.recorder.revealed == [URL(filePath: rig.zipPath)])
            #expect(rig.recorder.refused == 0)
        }
        #expect(ArchiveWindowModel.line(.damaged, name: "Report.zip") == String(
            localized: "Wherever can’t read “\(Bidi.name("Report.zip"))”. The archive may be damaged.", table: "Archive"
        ))
    }

    @Test func emptyArchiveShowsTheEmptyLine() async throws {
        let rig = try Rig(entries: [], summary: summary(items: 0, bytes: 0, problem: .empty))
        defer { rig.close() }
        rig.windows.open(file("Empty.zip", in: rig.folder))
        let window = try #require(ArchiveWindows.all.first?.window)
        let line = try await rig.element(ArchiveView.problemID, in: window)
        #expect(AXTree.names(of: line).contains(String(localized: "The archive “\(Bidi.name("Empty.zip"))” is empty.", table: "Archive")))
        #expect(AXTree.element(ArchiveView.problemRevealID, in: try #require(window.contentView)) == nil)
        #expect(rig.table(window) == nil)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func aListingWithAProblemShowsItsRowsWithTheLine() async throws {
        let problems: [ArchiveProblem] = [.pointsOutside(name: "Applications"), .damaged]
        for problem in problems {
            let rig = try Rig(summary: summary(skipped: 1, problem: problem))
            defer { rig.close() }
            let (window, table, model) = try await rig.open()
            #expect(model.problem == problem)
            #expect(model.blocked == nil)
            #expect(model.results.names == topLevel, "\(problem)")
            let line = try await rig.element(ArchiveView.problemID, in: window)
            #expect(AXTree.names(of: line).contains(ArchiveWindowModel.line(problem, name: "Photos 2024.zip")), "\(problem)")
            #expect(AXTree.element(ArchiveView.problemRevealID, in: try #require(window.contentView)) == nil, "\(problem)")
            let items = try await rig.element(ArchiveStatusBar.itemsID, in: window)
            let count = UInt64(8).formatted(.number.locale(.autoupdatingCurrent))
            #expect(AXTree.names(of: items).contains(String(localized: "Items: \(count)", table: "Archive")))
            _ = try await rig.element(ArchiveStatusBar.skippedID, in: window)
            #expect(model.canExpand, "\(problem)")

            table.selectRowIndexes([1], byExtendingSelection: false)
            try returnKey(window)
            _ = try await rig.listed(window, model: model, count: 4)
            #expect(model.folder == "Trip")
            _ = try await rig.element(ArchiveView.problemID, in: window)
            try arrow(window, .upArrow, flags: .command)
            _ = try await rig.listed(window, model: model, count: topLevel.count, selected: 1)
            #expect(model.folder.isEmpty)
            _ = try await rig.element(ArchiveView.problemID, in: window)
            #expect(rig.recorder.refused == 0, "\(problem)")
        }
    }

    @Test func aProblemThatListedNothingKeepsTheSentenceAndShowInFinder() async throws {
        let problems: [ArchiveProblem] = [.pointsOutside(name: "Applications"), .damaged]
        for problem in problems {
            let rig = try Rig(summary: summary(items: 0, bytes: 0, skipped: 1, problem: problem))
            defer { rig.close() }
            rig.windows.open(rig.zip)
            let controller = try #require(ArchiveWindows.all.first)
            let window = try #require(controller.window)
            let line = try await rig.element(ArchiveView.problemID, in: window)
            #expect(AXTree.names(of: line).contains(ArchiveWindowModel.line(problem, name: "Photos 2024.zip")), "\(problem)")
            _ = try await rig.element(ArchiveView.problemRevealID, in: window)
            #expect(controller.model.blocked == problem)
            #expect(rig.table(window) == nil)
            #expect(!controller.model.canExpand)
            #expect(AXTree.element(ArchiveStatusBar.itemsID, in: try #require(window.contentView)) == nil)
        }
    }

    @Test func skippedCountShowsWithItsTooltip() async throws {
        let rig = try Rig(summary: summary(skipped: 3))
        defer { rig.close() }
        let (window, _, _) = try await rig.open()
        let skipped = try await rig.element(ArchiveStatusBar.skippedID, in: window)
        #expect(AXTree.names(of: skipped).contains(String(localized: "\(3) items skipped", table: "Archive")))
        let help: String? = AXTree.value("accessibilityHelp", of: skipped)
        #expect(help == String(localized: "Items whose names or links point outside the archive, and device files.", table: "Archive"))
        #expect(String(localized: "\(1) items skipped", table: "Archive") != String(localized: "\(3) items skipped", table: "Archive"))
    }

    @Test func closeAllClosesArchiveWindows() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (first, _, _) = try await rig.open()
        let firstSession = rig.archive.lastSession
        let (second, _, _) = try await rig.open(rig.other)
        let secondSession = rig.archive.lastSession
        #expect(first.canBecomeKey && second.canBecomeKey)
        [first, second].forEach { $0.close() }
        #expect(!first.isVisible && !second.isVisible)
        #expect(ArchiveWindows.all.isEmpty)
        #expect(rig.archive.session(firstSession)?.closes == 1)
        #expect(rig.archive.session(secondSession)?.closes == 1)
        rig.search.send(.resultsReady(SearchGeneration(rawValue: (1 << 40) + 1), count: 4))
        try await pumpEvents(for: .milliseconds(50))
        #expect(ArchiveWindows.all.isEmpty)
    }

    @Test func saveAsOntoAnArchiveAnotherWindowHoldsIsRefusedUntilThatWindowCloses() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (held, _, _) = try await rig.open(rig.other)
        let (window, _, model) = try await rig.open()
        let session = rig.archive.lastSession
        try await untilTrue(waitingFor: "Save As to be possible") { model.canSaveAs }
        let target = URL(filePath: rig.other.path)
        let before = try Data(contentsOf: target)
        var placed = 0
        model.place = { _, done in
            placed += 1
            done(target)
        }

        model.saveAs()
        try await untilTrue(waitingFor: "the save-failed sheet; sheet \(window.attachedSheet?.identifier?.rawValue ?? "none")") {
            window.attachedSheet?.identifier?.rawValue == ArchiveWindowModel.saveFailedID
        }
        let sheet = try #require(window.attachedSheet)
        let name = Bidi.name("Other.zip")
        let reason = String(localized: "“\(name)” is open in another window. Close it first.", table: "Archive")
        #expect(texts(in: sheet.contentView).contains(String(localized: "The archive “\(name)” could not be saved. \(reason)", table: "Archive")))
        #expect(placed == 1)
        #expect(model.saving == nil && model.saveJob == nil)
        let writes = rig.archive.session(session)?.writes ?? []
        #expect(writes.isEmpty)
        #expect(try Data(contentsOf: target) == before)
        #expect(held.isVisible)
        #expect(model.name == "Photos 2024.zip")
        window.endSheet(sheet)
        try await untilTrue(waitingFor: "the sheet to close") { window.attachedSheet == nil }

        held.close()
        model.saveAs()
        try await untilTrue(waitingFor: "the copy to be written and shown; name \(model.name)") {
            model.saving == nil && model.saveJob == nil && model.name == "Other.zip"
        }
        #expect(placed == 2)
        #expect(rig.archive.session(session)?.writes.count == 1)
        #expect(window.attachedSheet == nil)
    }

    @Test func fileMenuItemOpensTheKeyTablesArchiveRow() async throws {
        let rig = try Rig(mainHits: ["Photos 2024.zip", "notes.txt"])
        defer { rig.close() }
        let (host, model) = try await rig.mainWindow()
        try await host.focusList()
        let row = try #require(model.names.firstIndex(of: "Photos 2024.zip"))
        try #require(host.list()).selectRowIndexes([row], byExtendingSelection: false)
        var beeps = 0
        ArchiveWindows.showContents(in: host.window) { beeps += 1 }
        #expect(beeps == 0)
        #expect(rig.main.refused == 0)
        #expect(ArchiveWindows.all.count == 1)
        #expect(rig.archive.opened.map(\.shownAs) == [rig.zipPath])
        let controller = try #require(ArchiveWindows.all.first)
        _ = try await rig.listed(try #require(controller.window), model: controller.model, count: topLevel.count)
        ArchiveWindows.showContents(in: host.window) { beeps += 1 }
        #expect(ArchiveWindows.all.count == 1)
        #expect(rig.archive.opened.count == 1)

        let newWindow = String(localized: "New Window", table: "MenuBar")
        let title = String(localized: "Show Archive Contents", table: "Results")
        let file = try #require(holdingMenu(newWindow), "the main menu holds no New Window item")
        let index = try #require(file.items.firstIndex { $0.title == title }, "the File menu holds no \(title) item")
        try #require(index > 0)
        #expect(file.items[index - 1].title == newWindow)
        #expect(file.items[index].keyEquivalent.isEmpty)
        #expect(file.items[index].isEnabled)
    }

    @Test func fileMenuItemBeepsWithAPlainRowOrNoTable() async throws {
        let rig = try Rig(mainHits: ["Photos 2024.zip", "notes.txt"])
        defer { rig.close() }
        let (host, model) = try await rig.mainWindow()
        try await host.focusList()
        let row = try #require(model.names.firstIndex(of: "notes.txt"))
        try #require(host.list()).selectRowIndexes([row], byExtendingSelection: false)
        var beeps = 0
        ArchiveWindows.showContents(in: host.window) { beeps += 1 }
        #expect(rig.main.refused == 1)
        #expect(beeps == 0)
        #expect(ArchiveWindows.all.isEmpty)
        #expect(rig.archive.opened.isEmpty)

        let bare = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        bare.isReleasedWhenClosed = false
        defer { bare.close() }
        ArchiveWindows.showContents(in: bare) { beeps += 1 }
        #expect(beeps == 1)
        ArchiveWindows.showContents(in: nil) { beeps += 1 }
        #expect(beeps == 2)
        #expect(rig.main.refused == 1)
        #expect(ArchiveWindows.all.isEmpty)
    }

    @Test func hiddenFilesSettingHidesMacosxEntries() async throws {
        let entries = photos + [.init("__MACOSX", kind: .folder), .init("__MACOSX/._cover.jpg"), .init(".DS_Store")]
        let shown = try Rig(entries: entries)
        defer { shown.close() }
        let (shownWindow, _, shownModel) = try await shown.open(count: topLevel.count + 2)
        #expect(shownModel.results.names.contains("__MACOSX"))
        #expect(shownModel.results.names.contains(".DS_Store"))
        #expect(shown.archive.session(shown.archive.lastSession)?.searches == [""])
        shown.defaults.set(true, forKey: SearchFilters.hidesHiddenKey)
        _ = try await shown.listed(shownWindow, model: shownModel, count: topLevel.count, selected: nil)
        #expect(shownModel.results.names == topLevel)
        #expect(shown.archive.session(shown.archive.lastSession)?.searches == ["", "hidden:no"])
        shownWindow.close()

        let rig = try Rig(entries: entries, hidesHidden: true)
        defer { rig.close() }
        let (_, _, model) = try await rig.open()
        #expect(model.results.names == topLevel)
        #expect(rig.archive.session(rig.archive.lastSession)?.searches == ["hidden:no"])
    }

    @Test func diskChangeLeavesTheArchiveWindowAlone() async throws {
        let rig = try Rig(mainHits: ["Photos 2024.zip"])
        defer { rig.close() }
        let main = rig.index.makeModel(listsAll: true)
        rig.search.send(.resultsReady(rig.search.latest, count: 1))
        let (window, table, model) = try await rig.open()
        try await untilTrue(waitingFor: "the main list") { main.count == 1 && model.summary != nil }
        table.selectRowIndexes([2], byExtendingSelection: false)
        let session = rig.archive.lastSession
        let before = try #require(rig.archive.session(session))
        let results = model.results.results
        let refreshed = rig.search.refreshes.count
        rig.search.send(.openedChanged)
        rig.search.send(.resultsChanged)
        try await untilTrue(waitingFor: "the main window's refresh") { rig.search.refreshes.count > refreshed }
        try await pumpEvents(for: .milliseconds(50))
        let after = try #require(rig.archive.session(session))
        #expect(after.refreshes == before.refreshes)
        #expect(after.searches == before.searches)
        #expect(after.browses == before.browses)
        #expect(model.results.results == results)
        #expect(!model.results.isPending)
        #expect(table.selectedRowIndexes == [2])
        #expect(model.results.names == topLevel)
        try arrow(window, .downArrow)
        #expect(table.selectedRowIndexes == [3])
    }

    @Test func symlinkRowOpensItsTargetAndKeysTheWindowByTheTarget() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let fm = FileManager.default
        let link = rig.folder.appending(path: "Link.zip")
        try fm.createSymbolicLink(at: link, withDestinationURL: rig.folder.appending(path: "Photos 2024.zip"))
        let broken = rig.folder.appending(path: "Broken.zip")
        try fm.createSymbolicLink(at: broken, withDestinationURL: rig.folder.appending(path: "Gone.zip"))
        let target = ArchiveWindows.resolved(rig.zipPath)
        #expect(target.hasPrefix("/private/"))
        #expect(target != URL(filePath: rig.zipPath).resolvingSymlinksInPath().path(percentEncoded: false))

        let linkHit = file("Link.zip", in: rig.folder, kind: .link)
        let (window, _, model) = try await rig.open(linkHit)
        #expect(rig.archive.opened == [FakeArchiveClient.Opened(path: target, shownAs: linkHit.path)])
        #expect(window.title == "Link.zip")
        #expect(model.results.rows(in: 0..<1).first?.folder == linkHit.path)

        rig.windows.open(rig.zip)
        #expect(ArchiveWindows.all.count == 1)
        #expect(rig.archive.opened.count == 1)

        let brokenHit = file("Broken.zip", in: rig.folder, kind: .link)
        rig.windows.open(brokenHit)
        #expect(ArchiveWindows.all.count == 2)
        #expect(rig.archive.opened.last == FakeArchiveClient.Opened(path: brokenHit.path, shownAs: brokenHit.path))
        rig.windows.open(brokenHit)
        #expect(ArchiveWindows.all.count == 2)
        #expect(rig.archive.opened.count == 2)
    }

    @Test func allowsMatchesCompoundSuffixesOnly() throws {
        let rig = try Rig(extensions: ["zip", "TAR.GZ"])
        defer { rig.close() }
        let folder = rig.folder
        let allowed = [file("a.TAR.GZ", in: folder), file("b.zip", in: folder), file("Photos.Zip", in: folder), file("c.zip", in: folder, kind: .link)]
        let refused = [
            file("notes.gz", in: folder), file("photos.zip.001", in: folder), file("x.zip", in: folder, kind: .folder), file(".zip", in: folder),
            file("tar.gz", in: folder), file("zip", in: folder), file("a.tgz", in: folder),
        ]
        let inside = rig.windows.inside
        for hit in allowed {
            #expect(ArchiveWindows.allows(hit, extensions: ["zip", "tar.gz"]), "\(hit.name)")
            #expect(inside.allows(hit), "\(hit.name)")
        }
        for hit in refused {
            #expect(!ArchiveWindows.allows(hit, extensions: ["zip", "tar.gz"]), "\(hit.name)")
            #expect(!inside.allows(hit), "\(hit.name)")
        }
        #expect(inside.enclosing == nil)
    }

    @Test func fileMenuItemBeepsWhileTheSearchFieldIsFirstResponder() async throws {
        let rig = try Rig(mainHits: ["Photos 2024.zip"])
        defer { rig.close() }
        let (host, model) = try await rig.mainWindow()
        try #require(host.list()).selectRowIndexes([0], byExtendingSelection: false)
        #expect(host.fieldHasFocus)
        var beeps = 0
        ArchiveWindows.showContents(in: host.window) { beeps += 1 }
        #expect(beeps == 1)
        #expect(rig.main.refused == 0)
        #expect(ArchiveWindows.all.isEmpty)

        let editor = try #require(host.field()?.currentEditor() as? NSTextView)
        editor.selectedRange = NSRange(location: 0, length: 0)
        try host.press(.downArrow, flags: .command)
        #expect(editor.selectedRange == NSRange(location: 2, length: 0))
        #expect(ArchiveWindows.all.isEmpty)
        #expect(rig.archive.opened.isEmpty)
        try host.sendKeys("o")
        #expect(model.query == "pho")
        #expect(host.fieldHasFocus)
    }
}
