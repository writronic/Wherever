import AppKit
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private let entries: [FakeArchiveClient.Entry] = [
    .init("Docs", kind: .folder), .init("Docs/Old", kind: .folder), .init("Pictures", kind: .folder), .init("notes.txt", size: 10),
    .init("Docs/report.pdf", size: 10), .init("Docs/Old/report-2019.pdf", size: 10), .init("Pictures/beach.jpg", size: 10),
]

private let topLevel = ["Docs", "Pictures", "notes.txt"]
private let reports: Set<String> = ["report.pdf", "report-2019.pdf"]
private let letters: [Character: UInt16] = ["r": 15, "e": 14, "p": 35, "o": 31, "l": 37, "d": 2]

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

private func type(_ text: String, in window: NSWindow) throws {
    for character in text { try key(window, String(character), code: try #require(letters[character], "no key code for \(character)")) }
}

private func escape(_ window: NSWindow) throws { try key(window, "\u{1b}", code: 53) }

private func returnKey(_ window: NSWindow) throws { try key(window, "\r", code: 36) }

private func space(_ window: NSWindow) throws { try key(window, " ", code: 49) }

private func searchStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.archive-search"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
}

@MainActor
private final class Rig {
    let search = FakeSearchClient(hits: [])
    let archive: FakeArchiveClient
    let index: IndexModel
    let recorder = ActionRecorder()
    let defaults = searchStore()
    let windows: ArchiveWindows
    let folder: URL
    let cache: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-search-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = folder.appending(path: "Cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "Photos 2024.zip"))
        archive = FakeArchiveClient(search: search, entries: entries)
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

    var record: FakeArchiveClient.Record? { archive.session(archive.lastSession) }

    func copy(_ place: String, _ inner: String) throws -> URL {
        let root = cache.appending(path: try #require(ArchiveWindows.cacheKey(ArchiveWindows.resolved(zipPath))), directoryHint: .isDirectory)
        return ArchiveWindowModel.place(inner, in: root, folder: place).appending(path: inner)
    }

    func close() {
        ArchiveWindows.all.forEach { $0.window?.close() }
        try? FileManager.default.removeItem(at: folder)
    }

    func open() async throws -> (NSWindow, ThemedTable, ArchiveWindowModel) {
        windows.open(zip)
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let table = try await listed(window, model: controller.model, names: topLevel)
        return (window, table, controller.model)
    }

    func table(_ window: NSWindow) -> ThemedTable? {
        window.contentView?.layoutSubtreeIfNeeded()
        return window.contentView?.descendant(ThemedTable.self)
    }

    func field(_ window: NSWindow) throws -> NSSearchField {
        window.contentView?.layoutSubtreeIfNeeded()
        return try #require(window.searchField)
    }

    func editing(_ window: NSWindow) -> Bool {
        guard let editor = window.searchField?.currentEditor() else { return false }
        return window.firstResponder === editor
    }

    @discardableResult
    func listed(_ window: NSWindow, model: ArchiveWindowModel, names: [String], selected: Int? = 0) async throws -> ThemedTable {
        try await untilTrue(waitingFor: "\(names) with row \(selected.map { "\($0)" } ?? "none") selected; shown \(model.results.names)") {
            guard let table = table(window) else { return false }
            return !model.results.isPending && model.results.names == names && table.numberOfRows == names.count
                && selected.map { table.selectedRowIndexes == [$0] } != false
        }
        return try #require(table(window))
    }

    func searched(_ window: NSWindow, model: ArchiveWindowModel, names: Set<String>) async throws {
        try await untilTrue(waitingFor: "the hits \(names); shown \(model.results.names)") {
            guard let table = table(window) else { return false }
            return !model.results.isPending && Set(model.results.names) == names && table.numberOfRows == names.count
        }
    }

    func hit(_ name: String, in model: ArchiveWindowModel) throws -> SearchHit {
        try #require(model.results.rows(in: 0..<model.results.count).first { $0.name == name })
    }

    func element(_ id: String, in window: NSWindow) -> NSObject? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        return AXTree.element(id, in: content)
    }
}

@Suite(.serialized) struct ArchiveSearchTests {

    private func saved(_ model: ArchiveWindowModel, in window: NSWindow, rig: Rig, selecting name: String? = nil) async throws {
        let opened = rig.archive.opened.count
        model.edits?.delete(["notes.txt"])
        try await untilTrue(waitingFor: "the delete") { window.isDocumentEdited && !model.results.isPending }
        if let name {
            let table = try #require(rig.table(window))
            let row = try #require(model.results.names.firstIndex(of: name), "\(name) among \(model.results.names)")
            table.selectRowIndexes([row], byExtendingSelection: false)
            #expect(selectedName(window, model: model, rig: rig) == name)
        }
        model.save()
        try await untilTrue(waitingFor: "the save and the reopen; opened \(rig.archive.opened.count)") {
            model.saving == nil && model.saveJob == nil && rig.archive.opened.count == opened + 1 && !window.isDocumentEdited
        }
    }

    private func selectedName(_ window: NSWindow, model: ArchiveWindowModel, rig: Rig) -> String? {
        guard let table = rig.table(window), (table.delegate as? ResultsTable.Coordinator)?.model === model.results, table.selectedRow >= 0 else { return nil }
        return model.results.names[table.selectedRow]
    }

    @Test func aSaveKeepsTheSelectedNameAndTheSearch() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        model.results.query = "report"
        try await rig.searched(window, model: model, names: reports)
        try await saved(model, in: window, rig: rig)
        try await rig.searched(window, model: model, names: reports)
        #expect(model.results.query == "report")
        try await saved(model, in: window, rig: rig, selecting: "report-2019.pdf")

        try await rig.searched(window, model: model, names: reports)
        #expect(model.results.query == "report")
        try await untilTrue(waitingFor: "report-2019.pdf to stay selected; selected \(selectedName(window, model: model, rig: rig) ?? "none")") {
            selectedName(window, model: model, rig: rig) == "report-2019.pdf"
        }
        #expect(try rig.field(window).stringValue == "report")
        #expect(model.folder.isEmpty)
    }

    @Test func aSaveInsideAFolderKeepsTheFolderAndTheSelectedName() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        model.browse("Docs", selecting: "report.pdf")
        try await rig.listed(window, model: model, names: ["Old", "report.pdf"], selected: 1)
        try await saved(model, in: window, rig: rig, selecting: "report.pdf")
        try await rig.listed(window, model: model, names: ["Old", "report.pdf"], selected: 1)
        #expect(model.folder == "Docs")
        #expect(model.results.query.isEmpty)

        try await saved(model, in: window, rig: rig, selecting: "Old")
        try await rig.listed(window, model: model, names: ["Old", "report.pdf"], selected: 0)
        #expect(model.folder == "Docs")
    }
    @Test func typingInTheTableMovesToTheFieldAndSearches() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        #expect(window.firstResponder === table)
        #expect(try rig.field(window).stringValue.isEmpty)

        try type("rep", in: window)
        try await rig.searched(window, model: model, names: reports)
        #expect(try rig.field(window).stringValue == "rep")
        #expect(model.results.query == "rep")
        #expect(rig.editing(window))
        #expect(try rig.hit("report-2019.pdf", in: model).folder == rig.zipPath + "/Docs/Old")
        #expect(try rig.hit("report.pdf", in: model).folder == rig.zipPath + "/Docs")
        #expect(rig.record?.searches.last == "rep")
        #expect(rig.record?.browses.isEmpty == true)
        #expect(model.folder.isEmpty)

        try arrow(window, .downArrow)
        #expect(window.firstResponder === table)
        #expect(table.selectedRowIndexes == [0])
        let row = try #require(model.results.names.firstIndex(of: "report-2019.pdf"))
        table.selectRowIndexes([row], byExtendingSelection: false)
        try space(window)
        let preview = try rig.copy(ArchiveExtractor.previewFolder, "Docs/Old/report-2019.pdf")
        try await untilTrue(waitingFor: "the preview of the hit; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed == [preview] }
        try space(window)
        #expect(!rig.recorder.quickLookOpen)

        try returnKey(window)
        let copy = try rig.copy(ArchiveExtractor.openFolder, "Docs/Old/report-2019.pdf")
        try await untilTrue(waitingFor: "the hit to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [copy] }
        #expect(rig.recorder.refused == 0)
        #expect(try rig.field(window).stringValue == "rep")
        try await untilTrue(waitingFor: "the activity to end") { model.preparing == nil }
    }

    @Test func escapeClearsThenDoesNothing() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        try type("rep", in: window)
        try await rig.searched(window, model: model, names: reports)

        try escape(window)
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        #expect(try rig.field(window).stringValue.isEmpty)
        #expect(model.results.query.isEmpty)
        #expect(rig.editing(window))
        #expect(rig.record?.searches.last == "")
        let searches = rig.record?.searches.count

        try escape(window)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.record?.searches.count == searches)
        #expect(rig.record?.browses.isEmpty == true)
        #expect(model.results.names == topLevel)
        #expect(try rig.field(window).stringValue.isEmpty)
        #expect(rig.editing(window))
        #expect(window.isVisible)
        #expect(rig.recorder.refused == 0)
    }

    @Test func enteringAFolderClearsTheSearch() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try type("old", in: window)
        try await rig.searched(window, model: model, names: ["Old"])
        #expect(try rig.hit("Old", in: model).folder == rig.zipPath + "/Docs")

        try arrow(window, .downArrow)
        try returnKey(window)
        try await rig.listed(window, model: model, names: ["report-2019.pdf"])
        #expect(model.folder == "Docs/Old")
        #expect(model.segments == ["Photos 2024.zip", "Docs", "Old"])
        #expect(try rig.field(window).stringValue.isEmpty)
        #expect(model.results.query.isEmpty)
        #expect(rig.record?.browses == ["Docs/Old"])
        #expect(window.firstResponder === table)

        try type("rep", in: window)
        try await rig.searched(window, model: model, names: reports)
        #expect(try rig.field(window).stringValue == "rep")
        #expect(model.folder == "Docs/Old")

        model.go(toSegment: 0)
        try await rig.listed(window, model: model, names: topLevel)
        #expect(model.folder.isEmpty)
        #expect(try rig.field(window).stringValue.isEmpty)
        #expect(model.results.query.isEmpty)
    }

    @Test func upArrowOnTheFirstRowFocusesTheField() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        #expect(window.firstResponder === table)
        try arrow(window, .upArrow)
        #expect(rig.editing(window))
        #expect(table.selectedRowIndexes == [0])

        try type("rep", in: window)
        try await rig.searched(window, model: model, names: reports)
        try arrow(window, .downArrow)
        #expect(window.firstResponder === table)
        try arrow(window, .upArrow)
        #expect(rig.editing(window))
        try type("o", in: window)
        try await rig.searched(window, model: model, names: reports)
        #expect(try rig.field(window).stringValue == "repo")
        #expect(model.results.query == "repo")
        #expect(rig.record?.searches.last == "repo")
    }

    @Test func placeholderNamesTheArchive() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, _) = try await rig.open()
        let field = try rig.field(window)
        let format = Bundle.main.localizedString(forKey: "Search in “%@”", value: nil, table: "Archive")
        let expected = String(format: format, Bidi.name("Photos 2024.zip"))
        #expect(field.placeholderString == expected)
        #expect(field.placeholderString?.contains("Photos 2024.zip") == true)
        #expect(field.placeholderString != String(localized: "Search files"))
        #expect(rig.element(SearchView.fieldID, in: window) != nil)
    }

    @Test func statusShowsTheSearchTime() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        #expect(rig.element(ArchiveStatusBar.itemsID, in: window) != nil)
        #expect(rig.element(ArchiveStatusBar.searchID, in: window) == nil)

        try type("rep", in: window)
        try await rig.searched(window, model: model, names: reports)
        let time = try #require(model.results.lastSearchTime)
        let count = String(localized: "\(2) results", table: "Results")
        let milliseconds = time.formatted(.units(allowed: [.milliseconds], width: .abbreviated))
        let expected = String(localized: "Search: \(count) – \(milliseconds)")
        try await untilTrue(waitingFor: "the search time in the status bar") {
            rig.element(ArchiveStatusBar.searchID, in: window).map { AXTree.names(of: $0).contains(expected) } ?? false
        }

        try escape(window)
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        try await untilTrue(waitingFor: "the search time to leave the status bar") { rig.element(ArchiveStatusBar.searchID, in: window) == nil }
        #expect(rig.element(ArchiveStatusBar.itemsID, in: window) != nil)
    }

    @Test func commandUpWhileSearchingClearsTheSearch() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        try returnKey(window)
        try await rig.listed(window, model: model, names: ["Old", "report.pdf"])
        #expect(model.folder == "Docs")

        try type("rep", in: window)
        try await rig.searched(window, model: model, names: reports)
        #expect(rig.editing(window))
        try arrow(window, .upArrow, flags: .command)
        try await rig.listed(window, model: model, names: ["Old", "report.pdf"], selected: nil)
        #expect(model.folder == "Docs")
        #expect(try rig.field(window).stringValue.isEmpty)
        #expect(model.results.query.isEmpty)
        #expect(rig.record?.browses == ["Docs"])
        #expect(rig.editing(window))

        try arrow(window, .upArrow, flags: .command)
        try await rig.listed(window, model: model, names: topLevel)
        #expect(model.folder.isEmpty)
        #expect(rig.record?.browses == ["Docs", ""])
        #expect(window.firstResponder === table)

        try type("rep", in: window)
        try await rig.searched(window, model: model, names: reports)
        try arrow(window, .downArrow)
        #expect(window.firstResponder === table)
        try arrow(window, .upArrow, flags: .command)
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        #expect(try rig.field(window).stringValue.isEmpty)
        #expect(rig.record?.browses == ["Docs", ""])
        #expect(rig.recorder.refused == 0)
    }
}
