import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Wherever
import WhereverInterface

private let entries: [FakeArchiveClient.Entry] = [
    .init("Trip", kind: .folder), .init("Trip/IMG_0001.HEIC"), .init("Trip/IMG_0002.HEIC"), .init("Trip/Day 2", kind: .folder),
    .init("Trip/Day 2/IMG_0003.HEIC"), .init("Trip/Beach", kind: .folder), .init("cover.jpg"),
    .init("latest", kind: .link, target: "Trip/IMG_0001.HEIC"), .init("notes.txt"), .init("outside", kind: .link, target: "../secret"),
    .init("shortcut", kind: .link, target: "Trip"),
]

private let topLevel = ["Trip", "cover.jpg", "latest", "notes.txt", "outside", "shortcut"]

private func actionsStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.archive-actions"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
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

private func returnKey(_ window: NSWindow, flags: NSEvent.ModifierFlags = []) throws { try key(window, "\r", code: 36, flags: flags) }

private func space(_ window: NSWindow) throws { try key(window, " ", code: 49) }

private func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.posixPermissions] as? Int
}

private func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil }

private func write(_ provider: NSFilePromiseProvider, to url: URL) async throws -> (any Error)? {
    let extractor = try #require(provider.delegate as? ArchiveExtractor)
    let queue = extractor.operationQueue(for: provider)
    nonisolated(unsafe) let promise = provider
    let (error, onMain) = await withCheckedContinuation { (done: CheckedContinuation<((any Error)?, Bool), Never>) in
        queue.addOperation {
            let onMain = Thread.isMainThread
            extractor.filePromiseProvider(promise, writePromiseTo: url) { done.resume(returning: ($0, onMain)) }
        }
    }
    try #require(!onMain, "the write ran on the main thread")
    return error
}

@MainActor
private final class Rig {
    let search = FakeSearchClient(hits: [])
    let archive: FakeArchiveClient
    let index: IndexModel
    let recorder = ActionRecorder()
    let defaults = actionsStore()
    let windows: ArchiveWindows
    let folder: URL
    let cache: URL

    init(entries list: [FakeArchiveClient.Entry] = entries) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = folder.appending(path: "Cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "Photos 2024.zip"))
        archive = FakeArchiveClient(search: search, entries: list)
        index = IndexModel(client: search)
        let preferences = ColumnPreferences(defaults: defaults)
        preferences.foldersFirst = true
        windows = ArchiveWindows(client: archive, index: index, actions: recorder.actions, defaults: defaults, columnPreferences: preferences, cache: cache)
    }

    var zipPath: String { folder.appending(path: "Photos 2024.zip").path(percentEncoded: false) }

    var zip: SearchHit {
        SearchHit(
            name: "Photos 2024.zip", folder: folder.path(percentEncoded: false), size: 0, modified: Date(timeIntervalSince1970: 0),
            created: .distantPast, opened: .distantPast, kind: .file
        )
    }

    var root: URL {
        get throws { cache.appending(path: try #require(ArchiveWindows.cacheKey(ArchiveWindows.resolved(zipPath))), directoryHint: .isDirectory) }
    }

    func copy(_ place: String, _ inner: String) throws -> URL { ArchiveWindowModel.place(inner, in: try root, folder: place).appending(path: inner) }

    func close() {
        ArchiveWindows.all.forEach { $0.window?.close() }
        try? FileManager.default.removeItem(at: folder)
    }

    func open(count: Int = topLevel.count) async throws -> (NSWindow, ThemedTable, ArchiveWindowModel) {
        windows.open(zip)
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let table = try await listed(window, model: controller.model, count: count)
        return (window, table, controller.model)
    }

    func listed(_ window: NSWindow, model: ArchiveWindowModel, count: Int) async throws -> ThemedTable {
        try await untilTrue(waitingFor: "\(count) rows; shown \(model.results.names)") {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let table = window.contentView?.descendant(ThemedTable.self) else { return false }
            return !model.results.isPending && table.numberOfRows == count && table.selectedRowIndexes == [0]
        }
        return try #require(window.contentView?.descendant(ThemedTable.self))
    }

    func select(_ names: String..., in table: ThemedTable, model: ArchiveWindowModel) throws {
        let all = model.results.names
        let rows = try names.map { name in try #require(all.firstIndex(of: name), "\(name) among \(all)") }
        table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    func element(_ id: String, in window: NSWindow) async throws -> NSObject {
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "\(id) among \(AXTree.nodeCount(in: content)) accessibility nodes") {
            content.layoutSubtreeIfNeeded()
            return AXTree.element(id, in: content) != nil
        }
        return try #require(AXTree.element(id, in: content))
    }

    func promise(_ name: String, in table: ThemedTable, model: ArchiveWindowModel) throws -> NSFilePromiseProvider {
        let row = try #require(model.results.names.firstIndex(of: name))
        return try #require(table.dataSource?.tableView?(table, pasteboardWriterForRow: row) as? NSFilePromiseProvider)
    }

    func drop(_ name: String) throws -> URL {
        let drop = folder.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        return drop
    }

    var dragLeftovers: [String] {
        get throws {
            let drag = try root.appending(path: "drag").path(percentEncoded: false)
            return (try? FileManager.default.contentsOfDirectory(atPath: drag)) ?? []
        }
    }

    func hit(_ name: String, in model: ArchiveWindowModel) throws -> SearchHit {
        try #require(model.results.rows(in: 0..<model.results.count).first { $0.name == name })
    }
}

@Suite(.serialized) struct ArchiveActionsTests {
    @Test func returnOnAFileOpensAReadOnlyCopyFromTheOpenFolder() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try rig.select("notes.txt", in: table, model: model)
        try returnKey(window)
        let copy = try rig.copy("open", "notes.txt")
        try await untilTrue(waitingFor: "the read-only copy to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [copy] }
        #expect(try Data(contentsOf: copy) == FakeArchiveClient.bytes("notes.txt"))
        #expect(mode(copy) == 0o444)
        let place = ArchiveWindowModel.place("notes.txt", in: try rig.root, folder: "open").path(percentEncoded: false)
        #expect(rig.archive.extracts == [FakeArchiveClient.Extract(entries: ["notes.txt"], folder: place, readOnly: true)])
        #expect(rig.recorder.recorded.isEmpty)
        #expect(rig.recorder.refused == 0)
        try await untilTrue(waitingFor: "the activity to end") { model.preparing == nil }
        #expect(model.notice == nil)

        try returnKey(window)
        try await untilTrue(waitingFor: "the second open; opened \(rig.recorder.opened)") { rig.recorder.opened == [copy, copy] }
        #expect(rig.archive.extracts.count == 1)
    }

    @Test func returnOnManyRowsAsksThenOpensEveryCopy() async throws {
        let names = (1...ResultActions.askLimit).map { "file-\($0).txt" }
        let rig = try Rig(entries: names.map { FakeArchiveClient.Entry($0) })
        defer { rig.close() }
        let (window, table, _) = try await rig.open(count: names.count)
        table.selectAll(nil)
        try returnKey(window)
        #expect(rig.recorder.asked == ["open \(names.count)"])
        let copies = try Set(names.map { try rig.copy("open", $0) })
        try await untilTrue(waitingFor: "every copy to open; opened \(rig.recorder.opened.count)") { Set(rig.recorder.opened) == copies }
        #expect(rig.recorder.opened.count == names.count)
        #expect(rig.archive.extracts.count == names.count)
        #expect(rig.archive.extracts.allSatisfy { $0.readOnly })

        try returnKey(window, flags: .command)
        #expect(rig.recorder.asked == ["open \(names.count)"])
        #expect(rig.recorder.revealed == [URL(filePath: rig.zipPath)])
    }

    @Test func spaceShowsThePanelThenRefreshesWithTheCachedFile() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        rig.archive.hold()
        try rig.select("cover.jpg", in: table, model: model)
        try space(window)
        #expect(rig.recorder.shown == [nil])
        try await untilTrue(waitingFor: "Preparing to show") { model.preparing == "cover.jpg" }
        let status = try await rig.element(ArchiveStatusBar.preparingID, in: window)
        #expect(AXTree.names(of: status).contains(String(localized: "Preparing “\(Bidi.name("cover.jpg"))”…", table: "Archive")))
        #expect(table.previewPanel(nil, previewItemAt: 0) == nil)
        #expect(rig.recorder.refreshed.isEmpty)

        rig.archive.release()
        let copy = try rig.copy("preview", "cover.jpg")
        try await untilTrue(waitingFor: "the refresh; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed == [copy] }
        #expect((table.previewPanel(nil, previewItemAt: 0) as? NSURL) as URL? == copy)
        #expect(try Data(contentsOf: copy) == FakeArchiveClient.bytes("cover.jpg"))
        #expect(rig.archive.extracts.map(\.readOnly) == [false])
        try await untilTrue(waitingFor: "the activity to end") { model.preparing == nil }
        #expect(rig.recorder.shown == [nil])
        #expect(rig.archive.extracts.count == 1)
    }

    @Test func caseOnlyNamesShowAndOpenTheirOwnFile() async throws {
        let rig = try Rig(entries: [.init("Notes.txt"), .init("notes.txt")])
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: 2)
        try rig.select("Notes.txt", in: table, model: model)
        try space(window)
        let upper = try rig.copy("preview", "Notes.txt")
        try await untilTrue(waitingFor: "the Notes.txt preview; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed == [upper] }
        #expect(try Data(contentsOf: upper) == FakeArchiveClient.bytes("Notes.txt"))

        try rig.select("notes.txt", in: table, model: model)
        table.showQuickLook(nil)
        let lower = try rig.copy("preview", "notes.txt")
        #expect(lower.deletingLastPathComponent() != upper.deletingLastPathComponent())
        try await untilTrue(waitingFor: "the notes.txt preview; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed.last == lower }
        #expect(try Data(contentsOf: lower) == FakeArchiveClient.bytes("notes.txt"))
        #expect(try Data(contentsOf: upper) == FakeArchiveClient.bytes("Notes.txt"))

        try rig.select("Notes.txt", in: table, model: model)
        table.showQuickLook(nil)
        #expect(rig.recorder.refreshed.last == upper)
        #expect(rig.archive.extracts.map(\.entries) == [["Notes.txt"], ["notes.txt"]])

        try returnKey(window)
        let opened = try rig.copy("open", "Notes.txt")
        try await untilTrue(waitingFor: "the Notes.txt copy to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [opened] }
        try rig.select("notes.txt", in: table, model: model)
        try returnKey(window)
        let other = try rig.copy("open", "notes.txt")
        try await untilTrue(waitingFor: "the notes.txt copy to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [opened, other] }
        #expect(try Data(contentsOf: opened) == FakeArchiveClient.bytes("Notes.txt"))
        #expect(try Data(contentsOf: other) == FakeArchiveClient.bytes("notes.txt"))
        #expect(rig.recorder.refused == 0)
        #expect(model.notice == nil)
    }

    @Test func aReplacedItemShowsItsNewBytesAndUndoShowsTheOldOnes() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try rig.select("notes.txt", in: table, model: model)
        try space(window)
        let old = try rig.copy("preview", "notes.txt")
        try await untilTrue(waitingFor: "the first preview; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed == [old] }

        let newer = rig.folder.appending(path: "notes.txt")
        try Data("newer notes".utf8).write(to: newer)
        let edits = try #require(model.edits)
        edits.add([.add(source: newer.path(percentEncoded: false), folder: "", name: "notes.txt")], replacing: ["notes.txt"])
        try await untilTrue(waitingFor: "the replace to list") {
            window.contentView?.layoutSubtreeIfNeeded()
            return !model.results.isPending && edits.adding == nil && table.selectedRowIndexes.isEmpty
        }
        try rig.select("notes.txt", in: table, model: model)
        table.showQuickLook(nil)
        try await untilTrue(waitingFor: "the replaced preview; refreshed \(rig.recorder.refreshed)") {
            (rig.recorder.refreshed.last ?? nil).map { $0 != old } == true
        }
        let replaced = try #require(rig.recorder.refreshed.last ?? nil)
        #expect(replaced.lastPathComponent == "notes.txt")
        #expect(try Data(contentsOf: replaced) == Data("newer notes".utf8))
        #expect(try Data(contentsOf: old) == FakeArchiveClient.bytes("notes.txt"))
        #expect(rig.archive.extracts.map(\.entries) == [["notes.txt"], ["notes.txt"]])

        try returnKey(window)
        try await untilTrue(waitingFor: "the replaced copy to open; opened \(rig.recorder.opened)") { rig.recorder.opened.count == 1 }
        #expect(try Data(contentsOf: try #require(rig.recorder.opened.first)) == Data("newer notes".utf8))

        #expect(table.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        try await untilTrue(waitingFor: "the undo to list") {
            !model.results.isPending && edits.changes.isEmpty && table.selectedRowIndexes.isEmpty
        }
        try rig.select("notes.txt", in: table, model: model)
        table.showQuickLook(nil)
        #expect(rig.recorder.refreshed.last == old)
        try returnKey(window)
        let original = try rig.copy("open", "notes.txt")
        try await untilTrue(waitingFor: "the archive's own copy to open; opened \(rig.recorder.opened)") { rig.recorder.opened.count == 2 }
        #expect(rig.recorder.opened.last == original)
        #expect(try Data(contentsOf: original) == FakeArchiveClient.bytes("notes.txt"))
        #expect(rig.archive.extracts.count == 4)
        #expect(rig.recorder.refused == 0)
    }

    @Test func spaceAgainClosesThePanel() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try rig.select("notes.txt", in: table, model: model)
        try space(window)
        let preview = try rig.copy("preview", "notes.txt")
        try await untilTrue(waitingFor: "the refresh") { rig.recorder.refreshed == [preview] }
        try space(window)
        #expect(rig.recorder.hides == 1)
        #expect(!rig.recorder.quickLookOpen)
        #expect(rig.recorder.shown == [nil])

        try returnKey(window)
        let copy = try rig.copy("open", "notes.txt")
        try await untilTrue(waitingFor: "the read-only copy to open") { rig.recorder.opened == [copy] }
        #expect(mode(copy) == 0o444)
    }

    @Test func downArrowWithThePanelOpenPreviewsTheNextEntry() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try space(window)
        let trip = try rig.root.appending(path: "preview/Trip", directoryHint: .isDirectory)
        #expect(rig.recorder.shown == [trip])
        #expect(try trip.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(rig.archive.extracts.isEmpty)

        rig.archive.hold()
        try arrow(window, .downArrow)
        #expect(table.selectedRowIndexes == [1])
        #expect(rig.recorder.refreshed == [nil])
        try await untilTrue(waitingFor: "Preparing the next entry") { model.preparing == "cover.jpg" }
        rig.archive.release()
        let cover = try rig.copy("preview", "cover.jpg")
        try await untilTrue(waitingFor: "the next entry; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed == [nil, cover] }
        #expect((table.previewPanel(nil, previewItemAt: 0) as? NSURL) as URL? == cover)
        #expect(rig.recorder.hides == 0)
    }

    @Test func commandUpWithThePanelOpenFollowsTheFolderYouLeft() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try returnKey(window)
        _ = try await rig.listed(window, model: model, count: 4)
        try rig.select("IMG_0001.HEIC", in: table, model: model)
        try space(window)
        let image = try rig.copy("preview", "Trip/IMG_0001.HEIC")
        try await untilTrue(waitingFor: "the image preview") { rig.recorder.refreshed == [image] }

        try arrow(window, .upArrow, flags: .command)
        _ = try await rig.listed(window, model: model, count: topLevel.count)
        #expect(model.folder.isEmpty)
        let trip = try rig.root.appending(path: "preview/Trip", directoryHint: .isDirectory)
        try await untilTrue(waitingFor: "the folder you left; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed.last == trip }
        try space(window)
        #expect(rig.recorder.hides == 1)
        #expect(rig.recorder.shown == [nil])
    }

    @Test func copyPathCopiesVirtualPathsOnePerLine() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try rig.select("cover.jpg", "notes.txt", in: table, model: model)
        table.copy(nil)
        #expect(rig.recorder.copied == ["\(rig.zipPath)/cover.jpg\n\(rig.zipPath)/notes.txt"])
        try rig.select("Trip", in: table, model: model)
        try returnKey(window)
        _ = try await rig.listed(window, model: model, count: 4)
        try rig.select("Day 2", "IMG_0002.HEIC", in: table, model: model)
        table.copy(nil)
        #expect(rig.recorder.copied.last == "\(rig.zipPath)/Trip/Day 2\n\(rig.zipPath)/Trip/IMG_0002.HEIC")
        #expect(rig.archive.extracts.isEmpty)
        #expect(rig.recorder.opened.isEmpty)
    }

    @Test func commandReturnRevealsTheArchiveFile() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try returnKey(window)
        _ = try await rig.listed(window, model: model, count: 4)
        try rig.select("IMG_0001.HEIC", "IMG_0002.HEIC", in: table, model: model)
        try returnKey(window, flags: .command)
        #expect(rig.recorder.revealed == [URL(filePath: rig.zipPath)])
        #expect(rig.recorder.reveals == 1)
        #expect(rig.recorder.opened.isEmpty)
        #expect(rig.archive.extracts.isEmpty)
    }

    @Test func filePromiseWritesTheEntryBytesIntoTheDestination() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (_, table, model) = try await rig.open()
        let provider = try rig.promise("cover.jpg", in: table, model: model)
        #expect(provider.fileType == UTType.jpeg.identifier)
        let extractor = try #require(provider.delegate as? ArchiveExtractor)
        #expect(extractor.filePromiseProvider(provider, fileNameForType: provider.fileType) == "cover.jpg")
        #expect(extractor.operationQueue(for: provider).maxConcurrentOperationCount == 1)
        let desktop = try rig.drop("Desktop").appending(path: "cover.jpg")
        let other = try rig.drop("Other").appending(path: "cover.jpg")
        let first = Task { try await write(provider, to: desktop) }
        let second = Task { try await write(provider, to: other) }
        #expect(try await first.value == nil)
        #expect(try await second.value == nil)
        #expect(try Data(contentsOf: desktop) == FakeArchiveClient.bytes("cover.jpg"))
        #expect(try Data(contentsOf: other) == FakeArchiveClient.bytes("cover.jpg"))
        #expect(rig.archive.extracts.map(\.entries) == [["cover.jpg"], ["cover.jpg"]])
        #expect(rig.archive.extracts.allSatisfy { !$0.readOnly })
        #expect(Set(rig.archive.extracts.map(\.folder)).count == 2)
        #expect(try rig.dragLeftovers.isEmpty)
        #expect(rig.archive.opened.count == 1)
        try await untilTrue(waitingFor: "the activity to end") { model.preparing == nil }
        #expect(model.notice == nil)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func folderPromiseWritesTheTree() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (_, table, model) = try await rig.open()
        let window = rig.archive.lastSession
        let provider = try rig.promise("Trip", in: table, model: model)
        #expect(provider.fileType == UTType.folder.identifier)
        let extractor = try #require(provider.delegate as? ArchiveExtractor)
        #expect(extractor.filePromiseProvider(provider, fileNameForType: provider.fileType) == "Trip")
        let desktop = try rig.drop("Desktop")
        #expect(try await write(provider, to: desktop.appending(path: "Trip")) == nil)
        for file in ["Trip/IMG_0001.HEIC", "Trip/IMG_0002.HEIC", "Trip/Day 2/IMG_0003.HEIC"] {
            #expect(try Data(contentsOf: desktop.appending(path: file)) == FakeArchiveClient.bytes(file), "\(file)")
        }
        #expect(try desktop.appending(path: "Trip/Beach").resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(rig.archive.extracts.map(\.entries) == [["Trip"]])
        #expect(rig.archive.opened.count == 1)
        #expect(rig.archive.lastSession == window)
        #expect(rig.archive.session(window)?.browses == [])
        #expect(model.folder.isEmpty)
        #expect(try rig.dragLeftovers.isEmpty)

        for name in ["cover.jpg", "notes.txt"] {
            #expect(try await write(rig.promise(name, in: table, model: model), to: desktop.appending(path: name)) == nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: desktop.path(percentEncoded: false)).sorted() == ["Trip", "cover.jpg", "notes.txt"])
        try rig.select("Trip", "cover.jpg", "notes.txt", in: table, model: model)
        table.copy(nil)
        #expect(rig.recorder.copied == ["\(rig.zipPath)/Trip\n\(rig.zipPath)/cover.jpg\n\(rig.zipPath)/notes.txt"])
    }

    @Test func folderPromiseWritesPendingEditsFromTheOpenSession() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (_, table, model) = try await rig.open()
        let session = rig.archive.lastSession
        let added = rig.folder.appending(path: "added.txt")
        try Data("added on disk".utf8).write(to: added)
        let edits = try #require(model.edits)
        edits.add([.add(source: added.path(percentEncoded: false), folder: "Trip", name: "added.txt")], replacing: [])
        edits.delete(["Trip/IMG_0002.HEIC"])
        #expect(rig.archive.session(session)?.changes.last == [
            .add(source: added.path(percentEncoded: false), folder: "Trip", name: "added.txt"), .delete(path: "Trip/IMG_0002.HEIC"),
        ])
        try await untilTrue(waitingFor: "the edits to list") { !model.results.isPending }

        let desktop = try rig.drop("Desktop")
        #expect(try await write(rig.promise("Trip", in: table, model: model), to: desktop.appending(path: "Trip")) == nil)
        #expect(try Data(contentsOf: desktop.appending(path: "Trip/added.txt")) == Data("added on disk".utf8))
        #expect(!exists(desktop.appending(path: "Trip/IMG_0002.HEIC")))
        for file in ["Trip/IMG_0001.HEIC", "Trip/Day 2/IMG_0003.HEIC"] {
            #expect(try Data(contentsOf: desktop.appending(path: file)) == FakeArchiveClient.bytes(file), "\(file)")
        }
        #expect(rig.archive.extracts.map(\.entries) == [["Trip"]])
        #expect(rig.archive.opened.count == 1)
        #expect(rig.archive.lastSession == session)
        #expect(try rig.dragLeftovers.isEmpty)

        let day = desktop.appending(path: "Day 2")
        model.browse("Trip", selecting: nil)
        try await untilTrue(waitingFor: "the Trip rows; shown \(model.results.names)") {
            !model.results.isPending && model.results.names.contains("added.txt")
        }
        #expect(try await write(rig.promise("Day 2", in: table, model: model), to: day) == nil)
        #expect(try Data(contentsOf: day.appending(path: "IMG_0003.HEIC")) == FakeArchiveClient.bytes("Trip/Day 2/IMG_0003.HEIC"))
        #expect(rig.archive.extracts.map(\.entries) == [["Trip"], ["Trip/Day 2"]])
        #expect(rig.archive.opened.count == 1)
    }

    @Test func returnOnALinkToAFolderBrowsesWithoutExtracting() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try rig.select("shortcut", in: table, model: model)
        try returnKey(window)
        _ = try await rig.listed(window, model: model, count: 4)
        #expect(model.folder == "Trip")
        #expect(rig.archive.extracts.map(\.entries) == [["shortcut"]])
        #expect(!exists(try rig.copy("open", "Trip/IMG_0001.HEIC")))
        #expect(rig.recorder.opened.isEmpty)
        #expect(rig.recorder.refused == 0)
    }

    @Test func failedDragShowsTheLine() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        let missing = rig.folder.appending(path: "Missing/notes.txt")
        let refused = try #require(try await write(rig.promise("notes.txt", in: table, model: model), to: missing) as? CocoaError)
        #expect(refused.code == .fileWriteUnknown)
        #expect(!exists(missing))
        let line = String(localized: "Wherever can’t copy “\(Bidi.name("notes.txt"))”.", table: "Archive")
        try await untilTrue(waitingFor: "the copy line; notice \(model.notice ?? "none")") { model.notice == line }
        let notice = try await rig.element(ArchiveStatusBar.noticeID, in: window)
        #expect(AXTree.names(of: notice).contains(line))
        #expect(model.problem == nil)
        #expect(try rig.dragLeftovers.isEmpty)

        let desktop = try rig.drop("Desktop")
        let taken = desktop.appending(path: "notes.txt")
        try Data("mine".utf8).write(to: taken)
        #expect(try await write(rig.promise("notes.txt", in: table, model: model), to: taken) != nil)
        #expect(try Data(contentsOf: taken) == Data("mine".utf8))

        rig.archive.fail("cover.jpg", with: .damaged)
        let damaged = desktop.appending(path: "cover.jpg")
        #expect(try await write(rig.promise("cover.jpg", in: table, model: model), to: damaged) != nil)
        #expect(!exists(damaged))
        let damagedLine = ArchiveWindowModel.line(.damaged, name: model.name)
        try await untilTrue(waitingFor: "the damaged line; notice \(model.notice ?? "none")") { model.notice == damagedLine }
        #expect(rig.recorder.refused == 0)
    }

    @Test func noSpaceShowsTheLineAndOpensNothing() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        let problem = ArchiveProblem.noSpace(needed: 3_200_000_000, volume: "Macintosh HD")
        rig.archive.fail("notes.txt", with: problem)
        try rig.select("notes.txt", in: table, model: model)
        try returnKey(window)
        let line = ArchiveWindowModel.line(problem, name: model.name)
        try await untilTrue(waitingFor: "the no-space line; notice \(model.notice ?? "none")") { model.notice == line }
        let notice = try await rig.element(ArchiveStatusBar.noticeID, in: window)
        #expect(AXTree.names(of: notice).contains(line))
        #expect(rig.recorder.opened.isEmpty)
        #expect(!exists(try rig.copy("open", "notes.txt")))
        #expect(model.problem == nil)
        #expect(table.numberOfRows == topLevel.count)

        try space(window)
        #expect(model.notice == nil)
        try await untilTrue(waitingFor: "the second try; notice \(model.notice ?? "none")") { rig.archive.extracts.count == 2 && model.notice == line }
        #expect(rig.recorder.shown == [nil])
        #expect(rig.recorder.refreshed.isEmpty)
    }

    @Test func linkOutsideShowsTheLine() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try rig.select("outside", in: table, model: model)
        try returnKey(window)
        let line = ArchiveWindowModel.line(.pointsOutside(name: "outside"), name: model.name)
        try await untilTrue(waitingFor: "the outside line; notice \(model.notice ?? "none")") { model.notice == line }
        #expect(line == String(localized: "“\(Bidi.name("outside"))” points outside the archive.", table: "Archive"))
        #expect(rig.recorder.opened.isEmpty)

        try rig.select("latest", in: table, model: model)
        try returnKey(window)
        let target = try rig.copy("open", "Trip/IMG_0001.HEIC")
        try await untilTrue(waitingFor: "the link target to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [target] }
        #expect(try Data(contentsOf: target) == FakeArchiveClient.bytes("Trip/IMG_0001.HEIC"))
        #expect(rig.archive.extracts.map(\.entries) == [["outside"], ["latest"], ["Trip/IMG_0001.HEIC"]])
        #expect(model.notice == nil)
        #expect(model.folder.isEmpty)
    }

    @Test func closeRemovesPreviewKeepsOpenAndCancelsJobs() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        let session = rig.archive.lastSession
        try rig.select("notes.txt", in: table, model: model)
        try returnKey(window)
        let opened = try rig.copy("open", "notes.txt")
        try await untilTrue(waitingFor: "the read-only copy") { rig.recorder.opened == [opened] }
        try rig.select("cover.jpg", in: table, model: model)
        try space(window)
        let previewed = try rig.copy("preview", "cover.jpg")
        try await untilTrue(waitingFor: "the preview copy") { rig.recorder.refreshed == [previewed] }
        rig.archive.hold()
        try arrow(window, .downArrow)
        try await untilTrue(waitingFor: "the held job") { model.preparing == "latest" && rig.archive.running.count == 1 }
        let held = rig.archive.running
        #expect(held.count == 1)

        window.close()
        let preview = try rig.root.appending(path: "preview", directoryHint: .isDirectory)
        try await untilTrue(waitingFor: "preview/ to go") { !exists(preview) }
        #expect(rig.archive.cancels == held)
        #expect(rig.archive.session(session)?.closes == 1)
        #expect(exists(opened))
        #expect(mode(opened) == 0o444)
        #expect(ArchiveWindows.all.isEmpty)

        rig.archive.release()
        let (again, reopened, reopenedModel) = try await rig.open()
        let openFolder = try rig.root.appending(path: "open", directoryHint: .isDirectory).path(percentEncoded: false)
        let intoOpen = { rig.archive.extracts.filter { $0.folder.hasPrefix(openFolder) }.count }
        let extracts = intoOpen()
        try rig.select("notes.txt", in: reopened, model: reopenedModel)
        try returnKey(again)
        try await untilTrue(waitingFor: "the kept copy to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [opened, opened] }
        #expect(intoOpen() == extracts)
    }

    @Test func stopCancelsTheJob() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        rig.archive.hold()
        try rig.select("cover.jpg", in: table, model: model)
        try space(window)
        try await untilTrue(waitingFor: "the held job") { model.preparing == "cover.jpg" && rig.archive.running.count == 1 }
        let held = rig.archive.running
        let stop = try await rig.element(ArchiveStatusBar.preparingStopID, in: window)
        #expect(AXTree.names(of: stop).contains(String(localized: "Stop", table: "Normal")))
        #expect(AXTree.press(stop))
        try await untilTrue(waitingFor: "the job to stop") { model.preparing == nil && model.running.isEmpty }
        #expect(rig.archive.cancels == held)
        #expect(rig.recorder.refreshed.isEmpty)
        #expect(model.notice == nil)
        #expect(window.isVisible)
        #expect(!exists(try rig.copy("preview", "cover.jpg")))

        try space(window)
        #expect(rig.recorder.hides == 1)
        try space(window)
        #expect(rig.recorder.shown == [nil, nil])
        try await untilTrue(waitingFor: "the second job to start; extracts \(rig.archive.extracts.count)") { rig.archive.extracts.count == 2 }
        rig.archive.release()
        let copy = try rig.copy("preview", "cover.jpg")
        try await untilTrue(waitingFor: "the new job's refresh; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed == [copy] }

        rig.archive.hold()
        let destination = try rig.drop("Desktop").appending(path: "notes.txt")
        let provider = try rig.promise("notes.txt", in: table, model: model)
        let dropped = Task { try await write(provider, to: destination) }
        try await untilTrue(waitingFor: "the held drag") { model.preparing == "notes.txt" && rig.archive.running.count == 1 }
        let dragged = rig.archive.running
        model.stopPreparing()
        let error = try await dropped.value
        #expect((error as? CocoaError)?.code == .userCancelled)
        #expect(rig.archive.cancels == held + dragged)
        #expect(!exists(destination))
        #expect(try rig.dragLeftovers.isEmpty)
        try await untilTrue(waitingFor: "the drag's activity to end") { model.preparing == nil }
        #expect(model.notice == nil)
    }

    @Test func commandDownOnAnEntryActsAsReturn() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try rig.select("notes.txt", in: table, model: model)
        try arrow(window, .downArrow, flags: .command)
        let copy = try rig.copy("open", "notes.txt")
        try await untilTrue(waitingFor: "the file to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [copy] }
        #expect(table.selectedRowIndexes == [try #require(topLevel.firstIndex(of: "notes.txt"))])

        try rig.select("shortcut", in: table, model: model)
        try arrow(window, .downArrow, flags: .command)
        _ = try await rig.listed(window, model: model, count: 4)
        #expect(model.folder == "Trip")
        #expect(rig.archive.extracts.map(\.entries) == [["notes.txt"], ["shortcut"]])
        #expect(!exists(try rig.copy("open", "Trip")))

        try arrow(window, .upArrow, flags: .command)
        _ = try await rig.listed(window, model: model, count: topLevel.count)
        try rig.select("Trip", in: table, model: model)
        try arrow(window, .downArrow, flags: .command)
        _ = try await rig.listed(window, model: model, count: 4)
        #expect(model.folder == "Trip")
        #expect(rig.archive.session(rig.archive.lastSession)?.browses == ["Trip", "", "Trip"])
        #expect(rig.recorder.opened == [copy])
        #expect(rig.recorder.refused == 0)

        let rect = table.rect(ofRow: 0)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let menu = try #require(table.menu(for: click))
        #expect(menu.items.map(\.title) == [
            String(localized: "Open", table: "Results"), String(localized: "Show in Finder", table: "Results"),
            String(localized: "Quick Look", table: "Results"), String(localized: "Copy Path", table: "Results"), "",
            String(localized: "Expand Selected Items…", table: "Archive"), String(localized: "Expand Archive…", table: "Archive"),
        ])
    }
}
