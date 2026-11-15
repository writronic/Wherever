import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface
import os

private let photos: [FakeArchiveClient.Entry] = [
    .init("Trip", kind: .folder), .init("Family", kind: .folder), .init("notes.txt", size: 2_048), .init("cover.jpg", size: 1_200_000),
    .init("inner.zip", size: 64), .init("Trip/IMG_0001.HEIC", size: 10), .init("Trip/Day 2", kind: .folder),
    .init("Trip/Day 2/IMG_0003.HEIC", size: 10), .init("Family/mom.jpg", size: 10),
]

private let topLevel = ["Family", "Trip", "cover.jpg", "inner.zip", "notes.txt"]

private let tripRows = ["Day 2", "IMG_0001.HEIC"]

private func addStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.archive-add"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
}

private func key(_ window: NSWindow, _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
    ))
    window.sendEvent(event)
    #expect(window.undoManager?.groupingLevel == 0)
}

private func deleteKey(_ window: NSWindow) throws { try key(window, "\u{7f}", code: 51) }

private func returnKey(_ window: NSWindow) throws { try key(window, "\r", code: 36) }

private func undo(_ table: ThemedTable) throws { try #require(table.tryToPerform(NSSelectorFromString("undo:"), with: nil)) }

private func redo(_ table: ThemedTable) throws { try #require(table.tryToPerform(NSSelectorFromString("redo:"), with: nil)) }

private func real(_ url: URL?) -> String? {
    url.map { ($0.resolvingSymlinksInPath().path(percentEncoded: false) as NSString).standardizingPath }
}

private func views<T: NSView>(_ type: T.Type, in root: NSView?) -> [T] {
    guard let root else { return [] }
    return [root].compactMap { $0 as? T } + root.subviews.flatMap { views(type, in: $0) }
}

private func holdingMenu(_ title: String, in menu: NSMenu? = NSApp.mainMenu) -> NSMenu? {
    guard let menu else { return nil }
    menu.delegate?.menuNeedsUpdate?(menu)
    if menu.items.contains(where: { $0.title == title }) { return menu }
    return menu.items.lazy.compactMap { holdingMenu(title, in: $0.submenu) }.first
}

private final class Drop: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingSource: Any?
    var numberOfValidItemsForDrop = 0
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 0 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(_ items: [any NSPasteboardWriting], from source: Any? = nil) {
        draggingSource = source
        super.init()
        _ = draggingPasteboard.clearContents()
        _ = draggingPasteboard.writeObjects(items)
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

private nonisolated final class AccessSwitch: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: ArchiveAccess())

    var value: ArchiveAccess {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

@MainActor
private final class Rig {
    let search = FakeSearchClient(hits: [])
    let archive: FakeArchiveClient
    let index: IndexModel
    let recorder = ActionRecorder()
    let defaults = addStore()
    let windows: ArchiveWindows
    let folder: URL
    let drops: URL
    let access = AccessSwitch()
    var hosts: [SearchHost] = []
    var pasteboards: [NSPasteboard] = []
    var panels: [NSOpenPanel] = []
    var chosen: [URL] = []

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-add-\(UUID().uuidString)", directoryHint: .isDirectory)
        drops = folder.appending(path: "Drops", directoryHint: .isDirectory)
        let manager = FileManager.default
        for sub in ["Drops/Trip", "Drops/Scans", "Upper", "Again"] {
            try manager.createDirectory(at: folder.appending(path: sub, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        for name in ["Photos 2024.zip", "Other.zip", "Old.zip", "Library.jar"] { try Data().write(to: folder.appending(path: name)) }
        for name in [
            "Drops/report.pdf", "Drops/summary.txt", "Drops/notes.txt", "Drops/cover.jpg", "Drops/inner.zip", "Drops/twin.txt", "Drops/Trip/new.jpg",
            "Drops/Scans/a.jpg", "Drops/Scans/b.jpg", "Upper/NOTES.txt", "Again/report.pdf",
        ] {
            try Data(name.utf8).write(to: folder.appending(path: name))
        }
        archive = FakeArchiveClient(
            search: search, extensions: ["zip", "jar"], entries: photos,
            editing: ["Photos 2024.zip": .all, "Other.zip": .all, "Old.zip": .oldEncryption]
        )
        index = IndexModel(client: search)
        let preferences = ColumnPreferences(defaults: defaults)
        preferences.foldersFirst = true
        let access = access
        windows = ArchiveWindows(
            client: archive, index: index, actions: recorder.actions, defaults: defaults, columnPreferences: preferences,
            cache: folder.appending(path: "Cache", directoryHint: .isDirectory), access: { _ in access.value }
        )
    }

    func hit(_ name: String) -> SearchHit {
        SearchHit(
            name: name, folder: folder.path(percentEncoded: false), size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast,
            opened: .distantPast, kind: .file
        )
    }

    func file(_ name: String) -> URL { drops.appending(path: name) }

    func source(_ url: URL) -> String { url.path(percentEncoded: false) }

    func close() {
        ArchiveWindows.all.forEach { $0.window?.close() }
        hosts.forEach { $0.close() }
        pasteboards.forEach { $0.releaseGlobally() }
        try? FileManager.default.removeItem(at: folder)
    }

    func open(_ name: String = "Photos 2024.zip") async throws -> (NSWindow, ThemedTable, ArchiveWindowModel, SearchSessionID) {
        windows.open(hit(name))
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let model = controller.model
        model.pick = { [self] panel, done in
            panels.append(panel)
            done(chosen)
        }
        let table = try await listed(window, model: model, names: topLevel, selected: nil)
        try await untilTrue(waitingFor: "the summary and access check of \(name)") { model.summary != nil && model.checked != nil }
        return (window, table, model, archive.lastSession)
    }

    func table(_ window: NSWindow, model: ArchiveWindowModel) -> ThemedTable? {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let table = window.contentView?.descendant(ThemedTable.self),
              (table.delegate as? ResultsTable.Coordinator)?.model === model.results else { return nil }
        return table
    }

    @discardableResult
    func listed(_ window: NSWindow, model: ArchiveWindowModel, names: [String], selected: Int? = 0) async throws -> ThemedTable {
        try await untilTrue(waitingFor: "\(names) with row \(selected.map { "\($0)" } ?? "any") selected; shown \(model.results.names)") {
            guard let table = table(window, model: model) else { return false }
            return !model.results.isPending && model.results.names == names && table.numberOfRows == names.count
                && selected.map { table.selectedRowIndexes == [$0] } != false
        }
        return try #require(table(window, model: model))
    }

    func idle(_ model: ArchiveWindowModel) async throws {
        try await untilTrue(waitingFor: "the add to be read; adding \(model.edits?.adding ?? "nothing")") {
            model.edits?.adding == nil && !model.clashing && !model.results.isPending
        }
        #expect(model.edits?.undoManager()?.groupingLevel == 0)
    }

    func changes(_ session: SearchSessionID) -> [[ArchiveChange]] { archive.session(session)?.changes ?? [] }

    func drop(_ items: [any NSPasteboardWriting], from source: Any? = nil) -> Drop {
        let drop = Drop(items, from: source)
        pasteboards.append(drop.draggingPasteboard)
        return drop
    }

    func drop(_ urls: [URL]) -> Drop { drop(urls.map { $0 as NSURL }) }

    func validate(_ drop: Drop, on table: NSTableView, row: Int = 0, operation: NSTableView.DropOperation = .above) -> NSDragOperation {
        table.dataSource?.tableView?(table, validateDrop: drop, proposedRow: row, proposedDropOperation: operation) ?? []
    }

    func accept(_ drop: Drop, on table: NSTableView, row: Int = -1, operation: NSTableView.DropOperation = .on) -> Bool {
        let accepted = table.dataSource?.tableView?(table, acceptDrop: drop, row: row, dropOperation: operation) ?? false
        #expect(table.window?.undoManager?.groupingLevel == 0)
        return accepted
    }

    func sheet(_ window: NSWindow) async throws -> NSWindow {
        try await untilTrue(waitingFor: "the clash question") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        #expect(sheet.identifier?.rawValue == ArchiveWindowModel.clashAlertID)
        return sheet
    }

    func button(_ title: String, in sheet: NSWindow) throws -> NSButton {
        try #require(views(NSButton.self, in: sheet.contentView).first { !$0.isHidden && $0.title == title }, "no \(title) button in the sheet")
    }

    func press(_ title: String, in window: NSWindow) async throws {
        let sheet = try await sheet(window)
        try button(title, in: sheet).performClick(nil)
        try await untilTrue(waitingFor: "the \(title) answer to close the question") { window.attachedSheet !== sheet }
        #expect(window.undoManager?.groupingLevel == 0)
    }

    func element(_ id: String, in window: NSWindow) async throws -> NSObject {
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "\(id) among \(AXTree.nodeCount(in: content)) accessibility nodes") {
            content.layoutSubtreeIfNeeded()
            return AXTree.element(id, in: content) != nil
        }
        return try #require(AXTree.element(id, in: content))
    }

    func gone(_ id: String, in window: NSWindow) async throws {
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "\(id) to leave the window") {
            content.layoutSubtreeIfNeeded()
            return AXTree.element(id, in: content) == nil
        }
    }

    func addsATwin(_ table: ThemedTable, in window: NSWindow, model: ArchiveWindowModel, session: SearchSessionID) async throws {
        let before = changes(session).last ?? []
        let twin = drop([file("twin.txt")])
        #expect(validate(twin, on: table) == .copy)
        #expect(accept(twin, on: table))
        try await idle(model)
        #expect(changes(session).last == before + [.add(source: source(file("twin.txt")), folder: model.folder, name: "twin.txt")])
        #expect(model.results.names.contains("twin.txt"))
        #expect(window.isDocumentEdited)
    }
}

private let addTitle = String(localized: "Add", table: "Archive")
private let replaceTitle = String(localized: "Replace", table: "Archive")
private let keepBothTitle = String(localized: "Keep Both", table: "Archive")
private let stopTitle = String(localized: "Stop", table: "Archive")
private let applyToAllTitle = String(localized: "Apply to All", table: "Archive")

@Suite(.serialized) struct ArchiveAddTests {
    @Test func dropOfFinderFilesAddsToTheFolderShown() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        model.browse("Trip", selecting: nil)
        try await rig.listed(window, model: model, names: tripRows, selected: nil)

        let files = [rig.file("report.pdf"), rig.file("summary.txt")]
        let drop = rig.drop(files)
        #expect(rig.validate(drop, on: table) == .copy)
        #expect(rig.accept(drop, on: table))
        #expect(rig.changes(session) == [files.map { .add(source: rig.source($0), folder: "Trip", name: $0.lastPathComponent) }])
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: tripRows + ["report.pdf", "summary.txt"], selected: nil)
        #expect(window.isDocumentEdited)
        #expect(window.subtitle == String(localized: "Edited", table: "Archive"))
        #expect(window.undoManager?.undoActionName == addTitle)
        #expect(rig.recorder.refused == 0)

        try undo(table)
        try await rig.listed(window, model: model, names: tripRows, selected: nil)
        #expect(rig.changes(session).last == [])
        #expect(!window.isDocumentEdited)
    }

    @Test func dropTargetsTheWholeTableNeverARow() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        let drop = rig.drop([rig.file("report.pdf")])
        for (row, operation) in [(0, NSTableView.DropOperation.on), (1, .on), (2, .above), (5, .above)] {
            #expect(rig.validate(drop, on: table, row: row, operation: operation) == .copy, "row \(row) \(operation)")
        }
        #expect(!rig.accept(drop, on: table, row: 1, operation: .on))
        #expect(!rig.accept(drop, on: table, row: 2, operation: .above))
        #expect(rig.changes(session).isEmpty)

        #expect(rig.accept(drop, on: table))
        #expect(rig.changes(session) == [[.add(source: rig.source(rig.file("report.pdf")), folder: "", name: "report.pdf")]])
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "cover.jpg", "inner.zip", "notes.txt", "report.pdf"], selected: nil)
    }

    @Test func dragFromTheSameTableIsRefused() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        try await rig.addsATwin(table, in: window, model: model, session: session)
        let count = rig.changes(session).count

        let row = try #require(model.results.names.firstIndex(of: "cover.jpg"))
        let promise = try #require(table.dataSource?.tableView?(table, pasteboardWriterForRow: row) as? NSFilePromiseProvider)
        for drop in [rig.drop([promise], from: table), rig.drop([rig.file("report.pdf") as NSURL], from: table)] {
            #expect(rig.validate(drop, on: table, row: row, operation: .on) == [])
            #expect(!rig.accept(drop, on: table))
        }
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.changes(session).count == count)
        #expect(!model.results.names.contains("report.pdf"))
        #expect(rig.recorder.refused == 0)
    }

    @Test func filePromiseFromAnArchiveWindowIsRefused() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        try await rig.addsATwin(table, in: window, model: model, session: session)
        let count = rig.changes(session).count

        let (_, otherTable, otherModel, otherSession) = try await rig.open("Other.zip")
        let row = try #require(otherModel.results.names.firstIndex(of: "notes.txt"))
        let promise = try #require(otherTable.dataSource?.tableView?(otherTable, pasteboardWriterForRow: row) as? NSFilePromiseProvider)
        let drop = rig.drop([promise], from: otherTable)
        #expect(rig.validate(drop, on: table) == [])
        #expect(!rig.accept(drop, on: table))
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.changes(session).count == count)
        #expect(rig.changes(otherSession).isEmpty)
        #expect(rig.recorder.refused == 0)
    }

    @Test func dropOnAReadOnlyArchiveIsRefused() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        try await rig.addsATwin(table, in: window, model: model, session: session)
        window.close()

        let cases: [(String, ArchiveAccess)] = [
            ("Other.zip", ArchiveAccess(locked: true)), ("Other.zip", ArchiveAccess(folderWritable: false)), ("Old.zip", ArchiveAccess()),
            ("Library.jar", ArchiveAccess()),
        ]
        for (name, access) in cases {
            rig.access.value = access
            let (shut, shutTable, shutModel, shutSession) = try await rig.open(name)
            _ = try await rig.element(ArchiveStatusBar.readOnlyID, in: shut)
            try await pumpEvents(for: .milliseconds(50))
            #expect(shutTable.actions.accept == nil, "\(name)")
            #expect(!shutTable.registeredDraggedTypes.contains(.fileURL), "\(name)")
            let drop = rig.drop([rig.file("report.pdf")])
            #expect(rig.validate(drop, on: shutTable) == [], "\(name)")
            #expect(!rig.accept(drop, on: shutTable), "\(name)")
            shutModel.add([rig.file("report.pdf")])
            #expect(rig.changes(shutSession).isEmpty, "\(name)")
            #expect(shut.attachedSheet == nil)
            shut.close()
        }
        #expect(rig.recorder.refused == cases.count)
    }

    @Test func mainWindowTableAcceptsNoDrop() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        try await rig.addsATwin(table, in: window, model: model, session: session)

        let host = SearchHost(root: AnyView(SearchView(model: rig.index.makeModel())), actions: rig.recorder.actions)
        rig.hosts.append(host)
        try await host.until("the main results table") { host.list() is ThemedTable }
        let main = try #require(host.list() as? ThemedTable)
        try await pumpEvents(for: .milliseconds(50))
        #expect(main.actions.accept == nil)
        #expect(main.registeredDraggedTypes.isEmpty)
        let drop = rig.drop([rig.file("report.pdf")])
        #expect(rig.validate(drop, on: main) == [])
        #expect(!rig.accept(drop, on: main))
        #expect(rig.recorder.nothingHappened)
    }

    @Test func clashAsksWithKeepBothAsTheDefault() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        let drop = rig.drop([rig.file("notes.txt")])
        #expect(rig.validate(drop, on: table) == .copy)
        #expect(rig.accept(drop, on: table))
        let sheet = try await rig.sheet(window)
        #expect(rig.changes(session).isEmpty)
        let texts = views(NSTextField.self, in: sheet.contentView).map(\.stringValue)
        let shown = Bidi.name("notes.txt")
        #expect(texts.contains(String(
            localized: "An item named “\(shown)” already exists in this location. Do you want to replace it with the one you’re copying?", table: "Archive"
        )))
        let keep = try rig.button(keepBothTitle, in: sheet)
        let replace = try rig.button(replaceTitle, in: sheet)
        let stop = try rig.button(stopTitle, in: sheet)
        #expect(sheet.defaultButtonCell === keep.cell)
        #expect(stop.keyEquivalent == "\u{1b}")
        #expect(replace.keyEquivalent.isEmpty)
        #expect(keep.accessibilityIdentifier() == ArchiveWindowModel.keepBothID)
        #expect(replace.accessibilityIdentifier() == ArchiveWindowModel.replaceID)
        #expect(stop.accessibilityIdentifier() == ArchiveWindowModel.clashStopID)
        #expect(keep.frame.maxX > replace.frame.maxX || keep.frame.minY != replace.frame.minY)
        #expect(!views(NSButton.self, in: sheet.contentView).contains { !$0.isHidden && $0.title == applyToAllTitle })

        try #require(sheet.defaultButtonCell?.controlView as? NSButton).performClick(nil)
        try await untilTrue(waitingFor: "the question to close") { window.attachedSheet == nil }
        #expect(rig.changes(session) == [[.add(source: rig.source(rig.file("notes.txt")), folder: "", name: "notes 2.txt")]])
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "cover.jpg", "inner.zip", "notes 2.txt", "notes.txt"], selected: nil)
        #expect(window.undoManager?.undoActionName == addTitle)
        #expect(window.isDocumentEdited)
    }

    @Test func replaceSwapsTheEntryAndListsItOnce() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        #expect(rig.accept(rig.drop([rig.file("notes.txt")]), on: table))
        try await rig.press(replaceTitle, in: window)
        let notes = ArchiveChange.add(source: rig.source(rig.file("notes.txt")), folder: "", name: "notes.txt")
        #expect(rig.changes(session) == [[.delete(path: "notes.txt"), notes]])
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        #expect(window.undoManager?.undoActionName == replaceTitle)
        #expect(window.isDocumentEdited)

        #expect(rig.accept(rig.drop([rig.file("report.pdf")]), on: table))
        try await rig.idle(model)
        let again = rig.folder.appending(path: "Again/report.pdf")
        #expect(rig.accept(rig.drop([again]), on: table))
        try await rig.press(replaceTitle, in: window)
        #expect(rig.changes(session).last == [.delete(path: "notes.txt"), notes, .add(source: rig.source(again), folder: "", name: "report.pdf")])
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: topLevel + ["report.pdf"], selected: nil)
    }

    @Test func stopAddsNothingFromThatDrop() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        try await rig.addsATwin(table, in: window, model: model, session: session)
        let count = rig.changes(session).count
        let names = model.results.names

        let files = [rig.file("report.pdf"), rig.file("notes.txt")]
        #expect(rig.accept(rig.drop(files), on: table))
        let sheet = try await rig.sheet(window)
        let stop = try rig.button(stopTitle, in: sheet)
        #expect(stop.keyEquivalent == "\u{1b}")
        stop.performClick(nil)
        try await untilTrue(waitingFor: "the question to close") { window.attachedSheet == nil }
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.changes(session).count == count)
        #expect(model.results.names == names)
        #expect(!model.clashing)
        #expect(rig.recorder.refused == 0)

        #expect(rig.accept(rig.drop(files), on: table))
        try await rig.press(keepBothTitle, in: window)
        #expect(rig.changes(session).count == count + 1)
        #expect(rig.changes(session).last?.suffix(2) == [
            .add(source: rig.source(files[0]), folder: "", name: "report.pdf"), .add(source: rig.source(files[1]), folder: "", name: "notes 2.txt"),
        ])
    }

    @Test func applyToAllShowsOnlyForTwoOrMoreClashesAndAnswersTheRest() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        #expect(rig.accept(rig.drop([rig.file("notes.txt")]), on: table))
        let single = try await rig.sheet(window)
        #expect(!views(NSButton.self, in: single.contentView).contains { !$0.isHidden && $0.title == applyToAllTitle })
        try await rig.press(stopTitle, in: window)
        #expect(rig.changes(session).isEmpty)

        let files = ["notes.txt", "cover.jpg", "inner.zip"].map(rig.file)
        #expect(rig.accept(rig.drop(files), on: table))
        let sheet = try await rig.sheet(window)
        let all = try rig.button(applyToAllTitle, in: sheet)
        #expect(all.accessibilityIdentifier() == ArchiveWindowModel.applyToAllID)
        all.performClick(nil)
        #expect(all.state == .on)
        try rig.button(replaceTitle, in: sheet).performClick(nil)
        try await untilTrue(waitingFor: "the one question to close") { window.attachedSheet == nil }
        try await pumpEvents(for: .milliseconds(100))
        #expect(window.attachedSheet == nil)
        #expect(rig.changes(session) == [[
            .delete(path: "notes.txt"), .delete(path: "cover.jpg"), .delete(path: "inner.zip"),
        ] + files.map { .add(source: rig.source($0), folder: "", name: $0.lastPathComponent) }])
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        #expect(window.undoManager?.undoActionName == replaceTitle)

        try undo(table)
        try await rig.idle(model)
        #expect(rig.changes(session).last == [])
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        #expect(!window.isDocumentEdited)
    }

    @Test func folderClashUsesTheFolderQuestion() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        #expect(rig.accept(rig.drop([rig.file("Trip")]), on: table))
        let sheet = try await rig.sheet(window)
        let texts = views(NSTextField.self, in: sheet.contentView).map(\.stringValue)
        let shown = Bidi.name("Trip")
        #expect(texts.contains(String(
            localized: "A folder named “\(shown)” already exists in this location. Do you want to replace it with the one you’re copying?", table: "Archive"
        )))
        try await rig.press(keepBothTitle, in: window)
        #expect(rig.changes(session) == [[.add(source: rig.source(rig.file("Trip")), folder: "", name: "Trip 2")]])
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "Trip 2", "cover.jpg", "inner.zip", "notes.txt"], selected: nil)
        model.browse("Trip 2", selecting: nil)
        try await rig.listed(window, model: model, names: ["new.jpg"], selected: nil)
    }

    @Test func caseOnlyClashAsks() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        let upper = rig.folder.appending(path: "Upper/NOTES.txt")
        #expect(rig.accept(rig.drop([upper]), on: table))
        let sheet = try await rig.sheet(window)
        let texts = views(NSTextField.self, in: sheet.contentView).map(\.stringValue)
        let shown = Bidi.name("NOTES.txt")
        #expect(texts.contains(String(
            localized: "An item named “\(shown)” already exists in this location. Do you want to replace it with the one you’re copying?", table: "Archive"
        )))
        try await rig.press(replaceTitle, in: window)
        #expect(rig.changes(session) == [[.delete(path: "notes.txt"), .add(source: rig.source(upper), folder: "", name: "NOTES.txt")]])
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "cover.jpg", "inner.zip", "NOTES.txt"], selected: nil)
    }

    @Test func twoDroppedItemsWithOneNameAskOnceAndKeepBothNumbersTheLaterOne() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        let first = rig.file("report.pdf")
        let again = rig.folder.appending(path: "Again/report.pdf")
        #expect(rig.accept(rig.drop([first, again]), on: table))
        let sheet = try await rig.sheet(window)
        #expect(!views(NSButton.self, in: sheet.contentView).contains { !$0.isHidden && $0.title == applyToAllTitle })
        try await rig.press(keepBothTitle, in: window)
        try await pumpEvents(for: .milliseconds(50))
        #expect(window.attachedSheet == nil)
        #expect(rig.changes(session) == [[
            .add(source: rig.source(first), folder: "", name: "report.pdf"), .add(source: rig.source(again), folder: "", name: "report 2.pdf"),
        ]])
        try await rig.idle(model)
        try await untilTrue(waitingFor: "the added rows; shown \(model.results.names)") {
            !model.results.isPending && Set(model.results.names) == Set(topLevel + ["report 2.pdf", "report.pdf"])
        }
    }

    @Test func replaceOnASecondCopyInOneDropKeepsOnlyTheLaterOne() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        let upper = rig.folder.appending(path: "Upper/REPORT.pdf")
        try Data("upper".utf8).write(to: upper)
        let files = [rig.file("report.pdf"), rig.folder.appending(path: "Again/report.pdf"), upper]
        #expect(rig.accept(rig.drop(files), on: table))
        let sheet = try await rig.sheet(window)
        let texts = views(NSTextField.self, in: sheet.contentView).map(\.stringValue)
        #expect(texts.contains(String(
            localized: "An item named “\(Bidi.name("report.pdf"))” already exists in this location. Do you want to replace it with the one you’re copying?",
            table: "Archive"
        )))
        try await rig.press(replaceTitle, in: window)
        try await rig.press(replaceTitle, in: window)
        #expect(rig.changes(session) == [[.add(source: rig.source(upper), folder: "", name: "REPORT.pdf")]])
        #expect(window.undoManager?.undoActionName == addTitle)
        try await rig.idle(model)
        try await untilTrue(waitingFor: "the added rows; shown \(model.results.names)") {
            !model.results.isPending && Set(model.results.names) == Set(["Family", "Trip", "cover.jpg", "inner.zip", "notes.txt", "REPORT.pdf"])
        }

        try undo(table)
        try await rig.idle(model)
        #expect(rig.changes(session).last == [])
        #expect(rig.accept(rig.drop(files), on: table))
        try await rig.press(keepBothTitle, in: window)
        try await rig.press(replaceTitle, in: window)
        #expect(rig.changes(session).last == [
            .add(source: rig.source(files[1]), folder: "", name: "report 2.pdf"), .add(source: rig.source(upper), folder: "", name: "REPORT.pdf"),
        ])
    }

    @Test func twoCopiesOfAnArchiveItemsNameAnswerEachAndNeverAddTwice() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        let files = [rig.file("notes.txt"), rig.folder.appending(path: "Upper/NOTES.txt")]
        #expect(rig.accept(rig.drop(files), on: table))
        try await rig.press(keepBothTitle, in: window)
        try await rig.press(replaceTitle, in: window)
        #expect(rig.changes(session) == [[
            .delete(path: "notes.txt"), .add(source: rig.source(files[0]), folder: "", name: "notes 2.txt"),
            .add(source: rig.source(files[1]), folder: "", name: "NOTES.txt"),
        ]])
        try await rig.idle(model)
        try await untilTrue(waitingFor: "the added rows; shown \(model.results.names)") {
            !model.results.isPending && Set(model.results.names) == Set(["Family", "Trip", "cover.jpg", "inner.zip", "notes 2.txt", "NOTES.txt"])
        }

        try undo(table)
        try await rig.idle(model)
        #expect(rig.accept(rig.drop(files), on: table))
        let sheet = try await rig.sheet(window)
        let all = try rig.button(applyToAllTitle, in: sheet)
        all.performClick(nil)
        try rig.button(replaceTitle, in: sheet).performClick(nil)
        try await untilTrue(waitingFor: "the one question to close") { window.attachedSheet == nil }
        try await pumpEvents(for: .milliseconds(100))
        #expect(window.attachedSheet == nil)
        #expect(rig.changes(session).last == [.delete(path: "notes.txt"), .add(source: rig.source(files[1]), folder: "", name: "NOTES.txt")])
        try await rig.idle(model)
        try await untilTrue(waitingFor: "the added rows; shown \(model.results.names)") {
            !model.results.isPending && Set(model.results.names) == Set(["Family", "Trip", "cover.jpg", "inner.zip", "NOTES.txt"])
        }
    }

    @Test func fiveThousandDroppedNamesWithFiftyClashesPairAsBefore() {
        let names = (0..<5_000).map { "item-\($0 % 4_980).txt" }
        let firsts = (0..<30).map { ArchiveClash(name: "item-\($0).txt", existing: "item-\($0).txt", folder: false, freeName: "item-\($0) 2.txt") }
        let seconds = (0..<20).map { ArchiveClash(name: "item-\($0).txt", existing: "ITEM-\($0).txt", folder: false, freeName: "item-\($0) 3.txt") }
        let clashes = firsts + seconds
        var before: [Int: ArchiveClash] = [:]
        for name in Set(names) {
            let asked = clashes.filter { $0.name == name }
            for (index, clash) in zip(names.indices.filter { names[$0] == name }.suffix(asked.count), asked) { before[index] = clash }
        }
        let owners = ArchiveWindowModel.owners(names: names, clashes: clashes)
        #expect(owners == before)
        #expect(owners.count == 50)
        #expect(owners[0] == firsts[0] && owners[4_980] == seconds[0])
        #expect(owners[19] == firsts[19] && owners[4_999] == seconds[19])
        #expect(owners[29] == firsts[29] && owners[30] == nil)
    }

    @Test func firstAddedSkipsEveryAddAlreadyMadeAmongThousands() {
        let earlier = (0..<5_000).map { ArchiveChange.add(source: "/Drops/\($0).txt", folder: "", name: "\($0).txt") }
        let fresh = ArchiveChange.add(source: "/Drops/new.txt", folder: "Trip", name: "new.txt")
        #expect(ArchiveEdits.firstAdded(earlier, after: earlier) == nil)
        var list = earlier
        list.insert(fresh, at: 2_500)
        list.insert(.delete(path: "notes.txt"), at: 0)
        #expect(ArchiveEdits.firstAdded(list, after: earlier) == "new.txt")
        #expect(ArchiveEdits.firstAdded(earlier, after: []) == "0.txt")
        #expect(ArchiveEdits.firstAdded([.add(source: "/Drops/0.txt", folder: "Trip", name: "0.txt")], after: earlier) == "0.txt")
    }

    @Test func addPanelOpensInTheGivenFolderWhateverItRemembered() throws {
        let remembered = try scratchFolder("add-remembered")
        let wanted = try scratchFolder("add-wanted")
        defer { try? FileManager.default.removeItem(at: remembered); try? FileManager.default.removeItem(at: wanted) }
        let panel = try withRememberedFolder(remembered, as: ArchiveWindowModel.addPanelID) {
            ArchiveWindowModel.addPanel(name: "Photos 2024.zip", in: wanted)
        }
        #expect(panel.directoryURL?.resolvingSymlinksInPath().path(percentEncoded: false) == wanted.resolvingSymlinksInPath().path(percentEncoded: false))
    }

    @Test func addFilesPanelAddsTheChosenItems() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        rig.chosen = [rig.file("Scans"), rig.file("report.pdf")]
        var beeps = 0
        ArchiveWindows.addFiles(in: window) { beeps += 1 }
        #expect(beeps == 0)
        let panel = try #require(rig.panels.first)
        #expect(rig.panels.count == 1)
        #expect(panel.identifier?.rawValue == ArchiveWindowModel.addPanelID)
        #expect(panel.prompt == addTitle)
        #expect(panel.message == String(localized: "Choose the items to add to “\(Bidi.name("Photos 2024.zip"))”.", table: "Archive"))
        #expect(panel.canChooseFiles && panel.canChooseDirectories && panel.allowsMultipleSelection)
        #expect(real(panel.directoryURL) == real(rig.folder))
        #expect(rig.changes(session) == [rig.chosen.map { .add(source: rig.source($0), folder: "", name: $0.lastPathComponent) }])
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: ["Family", "Scans", "Trip", "cover.jpg", "inner.zip", "notes.txt", "report.pdf"], selected: nil)
        #expect(window.undoManager?.undoActionName == addTitle)

        table.selectRowIndexes([1], byExtendingSelection: false)
        window.makeFirstResponder(table)
        try returnKey(window)
        try await rig.listed(window, model: model, names: ["a.jpg", "b.jpg"], selected: nil)
        #expect(model.folder == "Scans")

        let bare = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        bare.isReleasedWhenClosed = false
        defer { bare.close() }
        ArchiveWindows.addFiles(in: bare) { beeps += 1 }
        ArchiveWindows.addFiles(in: nil) { beeps += 1 }
        #expect(beeps == 2)
        #expect(rig.panels.count == 1)

        let expand = String(localized: "Expand Archive…", table: "Archive")
        let title = String(localized: "Add Files…", table: "Archive")
        let file = try #require(holdingMenu(expand), "the main menu holds no \(expand) item")
        let index = try #require(file.items.firstIndex { $0.title == title }, "the File menu holds no \(title) item")
        try #require(index > 0)
        #expect(file.items[index - 1].title == expand)
        #expect(file.items[index].keyEquivalent.isEmpty)
        #expect(file.items[index].isEnabled)
    }

    @Test func addingShowsTheActivityLineAndSaveWaits() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        rig.archive.holdBrowse("")
        #expect(rig.accept(rig.drop([rig.file("report.pdf")]), on: table))
        #expect(model.edits?.adding == "report.pdf")
        #expect(model.busy)
        let line = try await rig.element(ArchiveStatusBar.addingID, in: window)
        #expect(AXTree.names(of: line).contains(String(localized: "Adding “\(Bidi.name("report.pdf"))”…", table: "Archive")))
        _ = try await rig.element(ArchiveStatusBar.addingStopID, in: window)
        #expect(window.isDocumentEdited)

        #expect(rig.accept(rig.drop([rig.file("summary.txt")]), on: table))
        rig.chosen = [rig.file("summary.txt")]
        ArchiveWindows.addFiles(in: window)
        table.selectRowIndexes([2], byExtendingSelection: false)
        try deleteKey(window)
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.changes(session).count == 1)
        #expect(rig.panels.isEmpty)
        #expect(rig.recorder.refused == 3)
        #expect(model.edits?.adding == "report.pdf")

        rig.archive.releaseBrowse()
        try await rig.idle(model)
        try await rig.gone(ArchiveStatusBar.addingID, in: window)
        #expect(model.edits?.adding == nil)
        #expect(!model.busy)
        try await rig.listed(window, model: model, names: topLevel + ["report.pdf"], selected: nil)

        rig.archive.holdBrowse("")
        #expect(rig.accept(rig.drop([rig.file("summary.txt")]), on: table))
        #expect(model.edits?.adding == "summary.txt")
        let stop = try await rig.element(ArchiveStatusBar.addingStopID, in: window)
        #expect(AXTree.press(stop))
        try await untilTrue(waitingFor: "Stop to drop the add") { model.edits?.adding == nil }
        rig.archive.releaseBrowse()
        try await rig.idle(model)
        #expect(rig.changes(session).last == [.add(source: rig.source(rig.file("report.pdf")), folder: "", name: "report.pdf")])
        try await rig.listed(window, model: model, names: topLevel + ["report.pdf"], selected: nil)
        #expect(window.undoManager?.undoActionName == addTitle)
        #expect(window.undoManager?.canRedo == true)
    }

    @Test func dropWhileASaveRunsIsRefusedWithNoHighlightAndAcceptedAfter() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        try await rig.addsATwin(table, in: window, model: model, session: session)

        rig.archive.hold()
        model.save()
        try await untilTrue(waitingFor: "the save to run") { model.saving != nil }
        try await untilTrue(waitingFor: "the table to stop taking file drops") { !table.registeredDraggedTypes.contains(.fileURL) }
        #expect(table.actions.accept == nil)
        let refused = rig.drop([rig.file("summary.txt")])
        #expect(rig.validate(refused, on: table) == [])
        #expect(!rig.accept(refused, on: table))
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.recorder.refused == 0)
        #expect(rig.changes(session).count == 1)
        #expect(window.attachedSheet == nil)

        rig.archive.release()
        try await untilTrue(waitingFor: "the save to end and the archive to reopen") {
            model.saving == nil && model.saveJob == nil && rig.archive.opened.count == 2 && !model.results.isPending
        }
        #expect(!window.isDocumentEdited)
        let fresh = try await rig.listed(window, model: model, names: topLevel, selected: nil)
        try await untilTrue(waitingFor: "the saved table to take file drops") { fresh.registeredDraggedTypes.contains(.fileURL) }
        let after = rig.drop([rig.file("summary.txt")])
        #expect(rig.validate(after, on: fresh) == .copy)
        #expect(rig.accept(after, on: fresh))
        try await rig.idle(model)
        #expect(model.results.names.contains("summary.txt"))
        #expect(window.isDocumentEdited)
        #expect(rig.recorder.refused == 0)
    }

    @Test func saveInTheQuestionWaitsForTheAddThenSavesAndCloses() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        ArchiveWindows.all.last?.activate = {}
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        try await rig.addsATwin(table, in: window, model: model, session: session)
        rig.archive.holdBrowse("")
        #expect(rig.accept(rig.drop([rig.file("report.pdf")]), on: table))
        #expect(model.edits?.adding == "report.pdf")

        window.performClose(nil)
        try await untilTrue(waitingFor: "the unsaved question") { window.attachedSheet?.identifier?.rawValue == ArchiveWindows.unsavedAlertID }
        let save = views(NSButton.self, in: window.attachedSheet?.contentView).first { $0.accessibilityIdentifier() == ArchiveWindows.unsavedSaveID }
        try #require(save).performClick(nil)
        try await untilTrue(waitingFor: "the question to close") { window.attachedSheet == nil }
        try await pumpEvents(for: .milliseconds(100))
        #expect(rig.recorder.refused == 0)
        #expect(window.isVisible && window.isDocumentEdited)
        #expect(model.saving == nil && model.waitingSave != nil)
        #expect(model.edits?.adding == "report.pdf")
        #expect(rig.archive.session(session)?.writes.isEmpty == true)

        rig.archive.releaseBrowse()
        try await untilTrue(waitingFor: "the add, the save, then the close") { ArchiveWindows.all.isEmpty && !window.isVisible }
        #expect(rig.archive.session(session)?.writes.count == 1)
        #expect(rig.changes(session).last?.contains(.add(source: rig.source(rig.file("report.pdf")), folder: "", name: "report.pdf")) == true)
        #expect(try Data(contentsOf: rig.folder.appending(path: "Photos 2024.zip")) == FakeArchiveClient.saved)
        #expect(rig.recorder.refused == 0)
        #expect(!ArchiveEdits.unsaved)
    }

    @Test func undoAddRemovesTheItemsAndUndoReplaceBringsTheOldOneBack() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        let added = [rig.file("report.pdf"), rig.file("summary.txt")].map { ArchiveChange.add(source: rig.source($0), folder: "", name: $0.lastPathComponent) }
        #expect(rig.accept(rig.drop([rig.file("report.pdf"), rig.file("summary.txt")]), on: table))
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: topLevel + ["report.pdf", "summary.txt"], selected: nil)

        try undo(table)
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        #expect(rig.changes(session).last == [])
        #expect(!window.isDocumentEdited)

        try redo(table)
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: topLevel + ["report.pdf", "summary.txt"], selected: nil)
        #expect(rig.changes(session).last == added)

        #expect(rig.accept(rig.drop([rig.file("notes.txt")]), on: table))
        try await rig.press(replaceTitle, in: window)
        try await rig.idle(model)
        #expect(rig.changes(session).last == added + [.delete(path: "notes.txt"), .add(source: rig.source(rig.file("notes.txt")), folder: "", name: "notes.txt")])
        #expect(window.undoManager?.undoActionName == replaceTitle)

        try undo(table)
        try await rig.idle(model)
        #expect(rig.changes(session).last == added)
        try await rig.listed(window, model: model, names: topLevel + ["report.pdf", "summary.txt"], selected: nil)
        #expect(window.undoManager?.undoActionName == addTitle)
        #expect(window.isDocumentEdited)
    }

    @Test func deletingAnAddedItemDropsItsAddAndADeletedFolderTakesItsAdds() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        #expect(rig.accept(rig.drop([rig.file("report.pdf")]), on: table))
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: topLevel + ["report.pdf"], selected: nil)
        table.selectRowIndexes([5], byExtendingSelection: false)
        try deleteKey(window)
        try await rig.idle(model)
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        #expect(rig.changes(session).last == [])
        #expect(window.undoManager?.undoActionName == String(localized: "Delete", table: "Archive"))

        model.browse("Trip", selecting: nil)
        try await rig.listed(window, model: model, names: tripRows, selected: nil)
        #expect(rig.accept(rig.drop([rig.file("summary.txt")]), on: table))
        try await rig.idle(model)
        model.goEnclosing()
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        table.selectRowIndexes([1], byExtendingSelection: false)
        try deleteKey(window)
        try await rig.idle(model)
        #expect(rig.changes(session).last == [.delete(path: "Trip")])
        try await rig.listed(window, model: model, names: ["Family", "cover.jpg", "inner.zip", "notes.txt"], selected: nil)
    }

    @Test func deleteInsideAnAddedFolderIsRefused() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await untilTrue(waitingFor: "the table to take file drops") { table.registeredDraggedTypes.contains(.fileURL) }
        #expect(rig.accept(rig.drop([rig.file("Scans")]), on: table))
        try await rig.idle(model)
        model.browse("Scans", selecting: nil)
        try await rig.listed(window, model: model, names: ["a.jpg", "b.jpg"], selected: nil)
        table.selectRowIndexes([0], byExtendingSelection: false)
        try deleteKey(window)
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.recorder.refused == 1)
        #expect(rig.changes(session) == [[.add(source: rig.source(rig.file("Scans")), folder: "", name: "Scans")]])
        #expect(model.results.names == ["a.jpg", "b.jpg"])
    }
}
