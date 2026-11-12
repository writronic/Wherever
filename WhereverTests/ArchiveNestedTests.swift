import AppKit
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private let outerEntries: [FakeArchiveClient.Entry] = [
    .init("Trip", kind: .folder), .init("Trip/Day 1", kind: .folder), .init("Trip/inner.zip", size: 64), .init("Trip/notes.txt"),
    .init("cover.jpg"), .init("report.docx"),
]

private let innerEntries: [FakeArchiveClient.Entry] = [
    .init("docs", kind: .folder), .init("docs/a.txt"), .init("deepest.zip", size: 32), .init("readme.txt"),
]

private let deepestEntries: [FakeArchiveClient.Entry] = [.init("bottom.txt")]

private let tripRows = ["Day 1", "inner.zip", "notes.txt"]
private let innerRows = ["docs", "deepest.zip", "readme.txt"]

private func nestedStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.archive-nested"
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

private func contextMenu(_ table: ThemedTable, row: Int, in window: NSWindow) throws -> NSMenu {
    let rect = table.rect(ofRow: row)
    let click = try #require(NSEvent.mouseEvent(
        with: .rightMouseDown, location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
    ))
    return try #require(table.menu(for: click))
}

private func write(_ provider: NSFilePromiseProvider, to url: URL) async throws -> (any Error)? {
    let extractor = try #require(provider.delegate as? ArchiveExtractor)
    let queue = extractor.operationQueue(for: provider)
    nonisolated(unsafe) let promise = provider
    return await withCheckedContinuation { (done: CheckedContinuation<(any Error)?, Never>) in
        queue.addOperation { extractor.filePromiseProvider(promise, writePromiseTo: url) { done.resume(returning: $0) } }
    }
}

@MainActor
private final class Rig {
    let search = FakeSearchClient(hits: [])
    let archive: FakeArchiveClient
    let index: IndexModel
    let recorder = ActionRecorder()
    let defaults = nestedStore()
    let windows: ArchiveWindows
    let folder: URL
    let cache: URL

    init(broken: Set<String> = []) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-nested-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = folder.appending(path: "Cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "Photos 2024.zip"))
        archive = FakeArchiveClient(
            search: search, entries: outerEntries, nested: ["inner.zip": innerEntries, "deepest.zip": deepestEntries], broken: broken
        )
        index = IndexModel(client: search)
        let preferences = ColumnPreferences(defaults: defaults)
        preferences.foldersFirst = true
        windows = ArchiveWindows(client: archive, index: index, actions: recorder.actions, defaults: defaults, columnPreferences: preferences, cache: cache)
    }

    var zip: SearchHit {
        SearchHit(
            name: "Photos 2024.zip", folder: folder.path(percentEncoded: false), size: 0, modified: Date(timeIntervalSince1970: 0),
            created: .distantPast, opened: .distantPast, kind: .file
        )
    }

    var zipPath: String { zip.path }
    var innerShown: String { zipPath + "/Trip/inner.zip" }
    var deepestShown: String { innerShown + "/deepest.zip" }

    var root: URL {
        get throws { cache.appending(path: try #require(ArchiveWindows.cacheKey(ArchiveWindows.resolved(zipPath))), directoryHint: .isDirectory) }
    }

    var innerCopy: URL { get throws { try copy(root, "open", "Trip/inner.zip") } }

    var innerRoot: URL {
        get throws { cache.appending(path: try #require(ArchiveWindows.cacheKey(try innerCopy.path(percentEncoded: false))), directoryHint: .isDirectory) }
    }

    func folderPath(_ root: URL, _ place: String, _ inner: String) -> String { ArchiveWindowModel.place(inner, in: root, folder: place).path(percentEncoded: false) }

    func copy(_ root: URL, _ place: String, _ inner: String) -> URL { ArchiveWindowModel.place(inner, in: root, folder: place).appending(path: inner) }

    func close() {
        ArchiveWindows.all.forEach { $0.window?.close() }
        try? FileManager.default.removeItem(at: folder)
    }

    func open() async throws -> (NSWindow, ArchiveWindowModel) {
        windows.open(zip)
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        _ = try await listed(window, model: controller.model, count: 3)
        return (window, controller.model)
    }

    func table(_ window: NSWindow, model: ArchiveWindowModel) -> ThemedTable? {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let table = window.contentView?.descendant(ThemedTable.self),
              (table.delegate as? ResultsTable.Coordinator)?.model === model.results else { return nil }
        return table
    }

    @discardableResult
    func listed(_ window: NSWindow, model: ArchiveWindowModel, count: Int, selected: Int = 0) async throws -> ThemedTable {
        try await untilTrue(waitingFor: "\(count) rows with row \(selected) selected at depth \(model.depth); shown \(model.results.names)") {
            guard let table = table(window, model: model) else { return false }
            return !model.results.isPending && model.selection == nil && table.numberOfRows == count && table.selectedRowIndexes == [selected]
                && window.firstResponder === table
        }
        return try #require(table(window, model: model))
    }

    func select(_ name: String, in window: NSWindow, model: ArchiveWindowModel) throws -> ThemedTable {
        let table = try #require(table(window, model: model))
        let row = try #require(model.results.names.firstIndex(of: name), "\(name) among \(model.results.names)")
        table.selectRowIndexes([row], byExtendingSelection: false)
        return table
    }

    func intoTrip(_ window: NSWindow, model: ArchiveWindowModel) async throws {
        _ = try select("Trip", in: window, model: model)
        try returnKey(window)
        try await listed(window, model: model, count: tripRows.count)
    }

    func enterInner(_ window: NSWindow, model: ArchiveWindowModel) async throws {
        try await intoTrip(window, model: model)
        _ = try select("inner.zip", in: window, model: model)
        try returnKey(window)
        try await listed(window, model: model, count: innerRows.count)
    }

    func element(_ id: String, in window: NSWindow) async throws -> NSObject {
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "\(id) among \(AXTree.nodeCount(in: content)) accessibility nodes") {
            content.layoutSubtreeIfNeeded()
            return AXTree.element(id, in: content) != nil
        }
        return try #require(AXTree.element(id, in: content))
    }
}

@Suite(.serialized) struct ArchiveNestedTests {
    @Test func returnOnANestedZipEntersIt() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.intoTrip(window, model: model)
        _ = try rig.select("inner.zip", in: window, model: model)
        rig.archive.hold()
        try returnKey(window)
        try await untilTrue(waitingFor: "Opening the inner archive") { model.opening == "inner.zip" }
        let status = try await rig.element(ArchiveStatusBar.openingID, in: window)
        #expect(AXTree.names(of: status).contains(String(localized: "Opening “\(Bidi.name("inner.zip"))”…", table: "Archive")))
        let stop = try await rig.element(ArchiveStatusBar.openingStopID, in: window)
        #expect(AXTree.names(of: stop).contains(String(localized: "Stop", table: "Normal")))
        #expect(model.depth == 0)

        rig.archive.release()
        try await rig.listed(window, model: model, count: innerRows.count)
        #expect(model.depth == 1)
        #expect(model.results.names == innerRows)
        #expect(model.shownAs == rig.innerShown)
        #expect(model.folder.isEmpty)
        #expect(model.opening == nil)
        #expect(rig.archive.extracts == [FakeArchiveClient.Extract(entries: ["Trip/inner.zip"], folder: rig.folderPath(try rig.root, "open", "Trip/inner.zip"), readOnly: true)])
        #expect(rig.archive.opened.last == FakeArchiveClient.Opened(path: try rig.innerCopy.path(percentEncoded: false), shownAs: rig.innerShown))
        #expect(rig.archive.opened.count == 2)
        #expect(rig.recorder.opened.isEmpty)
        #expect(rig.recorder.refused == 0)
        #expect(window.title == "Photos 2024.zip")
        let items = try await rig.element(ArchiveStatusBar.itemsID, in: window)
        #expect(AXTree.names(of: items).contains(String(localized: "Items: \(innerEntries.count.formatted())", table: "Archive")))

        _ = try rig.select("docs", in: window, model: model)
        try returnKey(window)
        try await rig.listed(window, model: model, count: 1)
        #expect(model.folder == "docs")
        #expect(rig.archive.session(rig.archive.lastSession)?.browses == ["docs"])
    }

    @Test func contextMenuOnANestedZipShowsShowArchiveContentsAfterOpen() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.intoTrip(window, model: model)
        let open = String(localized: "Open", table: "Results")
        let show = String(localized: "Show Archive Contents", table: "Results")
        let table = try #require(rig.table(window, model: model))
        for name in ["Day 1", "notes.txt"] {
            let row = try #require(model.results.names.firstIndex(of: name))
            let menu = try contextMenu(table, row: row, in: window)
            #expect(!menu.items.contains { $0.title == show || $0.action == #selector(ThemedTable.showInside(_:)) }, "\(name): \(menu.items.map(\.title))")
        }
        let row = try #require(model.results.names.firstIndex(of: "inner.zip"))
        let menu = try contextMenu(table, row: row, in: window)
        #expect(Array(menu.items.prefix(2).map(\.title)) == [open, show], "\(menu.items.map(\.title))")
        let item = menu.items[1]
        #expect(item.action == #selector(ThemedTable.showInside(_:)))
        #expect(item.keyEquivalent == String(Character(NSEvent.SpecialKey.downArrow.unicodeScalar)))
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(menu.items.filter { $0.action == #selector(ThemedTable.showInside(_:)) }.count == 1)
        #expect(table.selectedRowIndexes == [row])
        menu.performActionForItem(at: 1)
        try await rig.listed(window, model: model, count: innerRows.count)
        #expect(model.depth == 1)
        #expect(model.results.names == innerRows)
        let inner = try #require(rig.table(window, model: model))
        let deeper = try contextMenu(inner, row: try #require(model.results.names.firstIndex(of: "deepest.zip")), in: window)
        #expect(deeper.items.filter { $0.action == #selector(ThemedTable.showInside(_:)) }.count == 1, "\(deeper.items.map(\.title))")
        #expect(rig.recorder.opened.isEmpty)
        #expect(rig.recorder.refused == 0)
    }

    @Test func stopWhileOpeningStaysInTheOuterArchive() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.intoTrip(window, model: model)
        _ = try rig.select("inner.zip", in: window, model: model)
        rig.archive.hold()
        try returnKey(window)
        try await untilTrue(waitingFor: "the held job") { model.opening == "inner.zip" && rig.archive.running.count == 1 }
        let held = rig.archive.running
        #expect(AXTree.press(try await rig.element(ArchiveStatusBar.openingStopID, in: window)))
        try await untilTrue(waitingFor: "the open to stop") { model.opening == nil && model.running.isEmpty }
        #expect(rig.archive.cancels == held)
        #expect(model.depth == 0)
        #expect(rig.archive.opened.count == 1)
        #expect(window.isVisible)
        #expect(model.notice == nil)
    }

    @Test func pathBarShowsBothLevelsAndTheOuterSegmentPops() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.enterInner(window, model: model)
        _ = try rig.select("docs", in: window, model: model)
        try returnKey(window)
        try await rig.listed(window, model: model, count: 1)
        #expect(model.segments == ["Photos 2024.zip", "Trip", "inner.zip", "docs"])
        for (index, name) in model.segments.enumerated() {
            #expect(AXTree.names(of: try await rig.element(ArchivePathBar.segmentID(index), in: window)).contains(name))
        }

        #expect(AXTree.press(try await rig.element(ArchivePathBar.segmentID(2), in: window)))
        try await rig.listed(window, model: model, count: innerRows.count)
        #expect(model.depth == 1)
        #expect(model.folder.isEmpty)
        #expect(model.segments == ["Photos 2024.zip", "Trip", "inner.zip"])
        #expect(AXTree.isEnabled(try await rig.element(ArchivePathBar.enclosingID, in: window)) == true)

        #expect(AXTree.press(try await rig.element(ArchivePathBar.segmentID(1), in: window)))
        try await rig.listed(window, model: model, count: tripRows.count, selected: 1)
        #expect(model.depth == 0)
        #expect(model.folder == "Trip")
        #expect(model.segments == ["Photos 2024.zip", "Trip"])
        #expect(rig.archive.closeOrder == [rig.innerShown])
        #expect(model.results.names == tripRows)

        _ = try rig.select("inner.zip", in: window, model: model)
        try returnKey(window)
        try await rig.listed(window, model: model, count: innerRows.count)
        #expect(AXTree.press(try await rig.element(ArchivePathBar.segmentID(0), in: window)))
        try await rig.listed(window, model: model, count: 3)
        #expect(model.depth == 0)
        #expect(model.folder.isEmpty)
        #expect(rig.archive.closeOrder == [rig.innerShown, rig.innerShown])
        #expect(AXTree.isEnabled(try await rig.element(ArchivePathBar.enclosingID, in: window)) == false)
    }

    @Test func commandUpAtTheInnerRootReturnsAndSelectsTheInnerRow() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.intoTrip(window, model: model)
        _ = try rig.select("inner.zip", in: window, model: model)
        try arrow(window, .downArrow, flags: .command)
        try await rig.listed(window, model: model, count: innerRows.count)
        #expect(model.depth == 1)
        #expect(model.shownAs == rig.innerShown)

        try arrow(window, .upArrow, flags: .command)
        try await rig.listed(window, model: model, count: tripRows.count, selected: 1)
        #expect(model.depth == 0)
        #expect(model.folder == "Trip")
        #expect(rig.archive.closeOrder == [rig.innerShown])
        #expect(rig.recorder.refused == 0)

        try arrow(window, .upArrow, flags: .command)
        try await rig.listed(window, model: model, count: 3, selected: 0)
        #expect(model.folder.isEmpty)
        try arrow(window, .upArrow, flags: .command)
        try await pumpEvents(for: .milliseconds(50))
        #expect(model.depth == 0)
        #expect(rig.archive.closeOrder == [rig.innerShown])
    }

    @Test func copyPathGivesTheWholeChain() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.enterInner(window, model: model)
        var table = try rig.select("readme.txt", in: window, model: model)
        table.copy(nil)
        #expect(rig.recorder.copied == ["\(rig.innerShown)/readme.txt"])

        _ = try rig.select("docs", in: window, model: model)
        try returnKey(window)
        table = try await rig.listed(window, model: model, count: 1)
        try returnKey(window, flags: .command)
        #expect(rig.recorder.revealed == [URL(filePath: rig.zipPath)])
        #expect(rig.recorder.reveals == 1)
        table.copy(nil)
        #expect(rig.recorder.copied.last == "\(rig.innerShown)/docs/a.txt")
        #expect(rig.recorder.opened.isEmpty)
        #expect(rig.archive.extracts.count == 1)
    }

    @Test func closeClosesSessionsInnermostFirst() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.enterInner(window, model: model)
        _ = try rig.select("deepest.zip", in: window, model: model)
        try returnKey(window)
        try await rig.listed(window, model: model, count: deepestEntries.count)
        #expect(model.depth == 2)
        #expect(rig.archive.closeOrder.isEmpty)

        window.close()
        #expect(rig.archive.closeOrder == [rig.deepestShown, rig.innerShown, rig.zipPath])
        #expect(ArchiveWindows.all.isEmpty)
    }

    @Test func damagedInnerShowsTheLineAndCommandUpReturns() async throws {
        let rig = try Rig(broken: ["inner.zip"])
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.intoTrip(window, model: model)
        _ = try rig.select("inner.zip", in: window, model: model)
        try returnKey(window)
        try await untilTrue(waitingFor: "the damaged inner archive") { model.depth == 1 && model.problem == .damaged }
        let line = try await rig.element(ArchiveView.problemID, in: window)
        #expect(AXTree.names(of: line).contains(ArchiveWindowModel.line(.damaged, name: "inner.zip")))
        #expect(model.segments == ["Photos 2024.zip", "Trip", "inner.zip"])
        #expect(AXTree.isEnabled(try await rig.element(ArchivePathBar.enclosingID, in: window)) == true)
        #expect(AXTree.press(try await rig.element(ArchiveView.problemRevealID, in: window)))
        #expect(rig.recorder.revealed == [URL(filePath: rig.zipPath)])

        try arrow(window, .upArrow, flags: .command)
        try await rig.listed(window, model: model, count: tripRows.count, selected: 1)
        #expect(model.depth == 0)
        #expect(model.problem == nil)
        #expect(model.folder == "Trip")
        #expect(rig.archive.opened.count == 2)
        #expect(rig.archive.closeOrder.isEmpty)
    }

    @Test func threeLevelsDeep() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.enterInner(window, model: model)
        _ = try rig.select("deepest.zip", in: window, model: model)
        try returnKey(window)
        let table = try await rig.listed(window, model: model, count: deepestEntries.count)
        #expect(model.depth == 2)
        #expect(model.shownAs == rig.deepestShown)
        #expect(model.segments == ["Photos 2024.zip", "Trip", "inner.zip", "deepest.zip"])
        #expect(rig.archive.extracts.last == FakeArchiveClient.Extract(entries: ["deepest.zip"], folder: rig.folderPath(try rig.innerRoot, "open", "deepest.zip"), readOnly: true))
        table.copy(nil)
        #expect(rig.recorder.copied == ["\(rig.deepestShown)/bottom.txt"])

        try arrow(window, .upArrow, flags: .command)
        try await rig.listed(window, model: model, count: innerRows.count, selected: 1)
        #expect(model.depth == 1)
        #expect(rig.archive.closeOrder == [rig.deepestShown])
        try arrow(window, .upArrow, flags: .command)
        try await rig.listed(window, model: model, count: tripRows.count, selected: 1)
        #expect(model.depth == 0)
        #expect(rig.archive.closeOrder == [rig.deepestShown, rig.innerShown])
        #expect(rig.archive.extracts.count == 2)
    }

    @Test func docxOpensWithItsAppAndIsNotEntered() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        _ = try rig.select("report.docx", in: window, model: model)
        try returnKey(window)
        let copy = rig.copy(try rig.root, "open", "report.docx")
        try await untilTrue(waitingFor: "the document to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [copy] }
        #expect(model.depth == 0)
        #expect(model.opening == nil)
        #expect(rig.archive.opened.count == 1)
        #expect(rig.archive.extracts.map(\.entries) == [["report.docx"]])

        _ = try rig.select("report.docx", in: window, model: model)
        try arrow(window, .downArrow, flags: .command)
        try await untilTrue(waitingFor: "the second open; opened \(rig.recorder.opened)") { rig.recorder.opened == [copy, copy] }
        #expect(model.depth == 0)
        #expect(rig.archive.opened.count == 1)
    }

    @Test func reenteringReusesTheCachedCopy() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.enterInner(window, model: model)
        try arrow(window, .upArrow, flags: .command)
        try await rig.listed(window, model: model, count: tripRows.count, selected: 1)

        try returnKey(window)
        try await rig.listed(window, model: model, count: innerRows.count)
        #expect(model.depth == 1)
        #expect(rig.archive.extracts.count == 1)
        #expect(rig.archive.opened.count == 3)
        #expect(rig.archive.opened.last == FakeArchiveClient.Opened(path: try rig.innerCopy.path(percentEncoded: false), shownAs: rig.innerShown))

        _ = try rig.select("readme.txt", in: window, model: model)
        try space(window)
        #expect(rig.recorder.shown == [nil])
        let preview = rig.copy(try rig.innerRoot, "preview", "readme.txt")
        try await untilTrue(waitingFor: "the inner entry's preview; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed == [preview] }
        #expect(try Data(contentsOf: preview) == FakeArchiveClient.bytes("readme.txt"))
        #expect(rig.archive.extracts.last == FakeArchiveClient.Extract(entries: ["readme.txt"], folder: rig.folderPath(try rig.innerRoot, "preview", "readme.txt"), readOnly: false))
        #expect(rig.archive.extracts.count == 2)
    }

    @Test func spaceOnANestedZipPreviewsTheFileThenReturnEntersIt() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.intoTrip(window, model: model)
        _ = try rig.select("inner.zip", in: window, model: model)
        try space(window)
        let preview = rig.copy(try rig.root, "preview", "Trip/inner.zip")
        try await untilTrue(waitingFor: "the archive file's preview; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed == [preview] }
        #expect(try Data(contentsOf: preview) == FakeArchiveClient.bytes("Trip/inner.zip"))
        #expect(model.depth == 0)
        #expect(model.opening == nil)
        #expect(rig.archive.opened.count == 1)

        try returnKey(window)
        try await rig.listed(window, model: model, count: innerRows.count)
        #expect(model.depth == 1)
        #expect(rig.archive.extracts.map(\.readOnly) == [false, true])
    }

    @Test func dragOfANestedZipWritesTheArchiveBytes() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.open()
        try await rig.intoTrip(window, model: model)
        let table = try rig.select("inner.zip", in: window, model: model)
        let row = try #require(model.results.names.firstIndex(of: "inner.zip"))
        let provider = try #require(table.dataSource?.tableView?(table, pasteboardWriterForRow: row) as? NSFilePromiseProvider)
        let desktop = rig.folder.appending(path: "Desktop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let destination = desktop.appending(path: "inner.zip")
        #expect(try await write(provider, to: destination) == nil)
        #expect(try Data(contentsOf: destination) == FakeArchiveClient.bytes("Trip/inner.zip"))
        #expect(model.depth == 0)
        #expect(rig.archive.opened.count == 1)
        #expect(rig.recorder.opened.isEmpty)
    }
}
