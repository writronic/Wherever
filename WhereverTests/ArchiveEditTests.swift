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

private let innerEntries: [FakeArchiveClient.Entry] = [.init("docs", kind: .folder), .init("docs/a.txt"), .init("readme.txt")]

private let topLevel = ["Family", "Trip", "cover.jpg", "inner.zip", "notes.txt"]

private let tripRows = ["Day 2", "IMG_0001.HEIC"]

private let innerRows = ["docs", "readme.txt"]

private let letters: [Character: UInt16] = ["n": 45, "o": 31]

private func editStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.archive-edit"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
}

private func send(_ window: NSWindow, _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
    ))
    if !flags.contains(.command) || !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
}

private func key(_ window: NSWindow, _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
    try send(window, characters, code: code, flags: flags)
    #expect(window.undoManager?.groupingLevel == 0)
}

private func deleteKey(_ window: NSWindow, flags: NSEvent.ModifierFlags = []) throws { try key(window, "\u{7f}", code: 51, flags: flags) }

private func forwardDelete(_ window: NSWindow) throws {
    try key(window, String(Character(NSEvent.SpecialKey.deleteForward.unicodeScalar)), code: 117, flags: [.function])
}

private func returnKey(_ window: NSWindow) throws { try key(window, "\r", code: 36) }

private func space(_ window: NSWindow) throws { try key(window, " ", code: 49) }

private func commandUp(_ window: NSWindow) throws {
    try key(window, String(Character(NSEvent.SpecialKey.upArrow.unicodeScalar)), code: 126, flags: [.command, .numericPad, .function])
}

private func undo(_ table: ThemedTable) throws { try #require(table.tryToPerform(NSSelectorFromString("undo:"), with: nil)) }

private func redo(_ table: ThemedTable) throws { try #require(table.tryToPerform(NSSelectorFromString("redo:"), with: nil)) }

private func editMenuDelete(in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
    guard let menu else { return nil }
    menu.delegate?.menuNeedsUpdate?(menu)
    if let item = menu.items.first(where: { $0.action == #selector(ThemedTable.delete(_:)) }) { return item }
    return menu.items.lazy.compactMap { editMenuDelete(in: $0.submenu) }.first
}

private func cellText(_ table: NSTableView, row: Int) -> String? {
    let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(ResultsTable.Column.name.rawValue))
    return (table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField?.stringValue
}

private func shownCells(_ table: NSTableView) -> [NSView] {
    var found: [NSView] = []
    table.enumerateAvailableRowViews { row, _ in found += row.subviews.filter { $0 is ResultCell } }
    return found
}

private func entry(_ name: String, in folder: String) -> SearchHit {
    SearchHit(name: name, folder: folder, size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .file)
}

private nonisolated final class AccessSwitch: Sendable {
    private nonisolated struct State {
        var value = ArchiveAccess()
        var calls = 0
        var onMain = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var value: ArchiveAccess {
        get { state.withLock { $0.value } }
        set { state.withLock { $0.value = newValue } }
    }

    var calls: Int { state.withLock { $0.calls } }
    var onMain: Int { state.withLock { $0.onMain } }

    func read(_ path: String) -> ArchiveAccess {
        let main = Thread.isMainThread
        return state.withLock {
            $0.calls += 1
            if main { $0.onMain += 1 }
            return $0.value
        }
    }
}

@MainActor
private final class Rig {
    let search = FakeSearchClient(hits: [])
    let archive: FakeArchiveClient
    let index: IndexModel
    let recorder = ActionRecorder()
    let defaults = editStore()
    let windows: ArchiveWindows
    let folder: URL
    let access = AccessSwitch()

    init(entries: [FakeArchiveClient.Entry] = photos) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-edit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Photos 2024.zip", "Other.zip", "Old.zip", "Library.jar", "Music.rar"] {
            try Data().write(to: folder.appending(path: name))
        }
        archive = FakeArchiveClient(
            search: search, extensions: ["zip", "jar", "rar"], entries: entries, nested: ["inner.zip": innerEntries],
            editing: ["Photos 2024.zip": .all, "Other.zip": .all, "Old.zip": .oldEncryption, "inner.zip": .all]
        )
        index = IndexModel(client: search)
        let preferences = ColumnPreferences(defaults: defaults)
        preferences.foldersFirst = true
        let access = access
        windows = ArchiveWindows(
            client: archive, index: index, actions: recorder.actions, defaults: defaults, columnPreferences: preferences,
            cache: folder.appending(path: "Cache", directoryHint: .isDirectory), access: { access.read($0) }
        )
    }

    func hit(_ name: String) -> SearchHit {
        SearchHit(
            name: name, folder: folder.path(percentEncoded: false), size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast,
            opened: .distantPast, kind: .file
        )
    }

    func close() {
        ArchiveWindows.all.forEach { $0.window?.close() }
        try? FileManager.default.removeItem(at: folder)
    }

    func open(_ name: String = "Photos 2024.zip", names: [String] = topLevel) async throws -> (NSWindow, ThemedTable, ArchiveWindowModel, SearchSessionID) {
        windows.open(hit(name))
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let table = try await listed(window, model: controller.model, names: names)
        try await untilTrue(waitingFor: "the access check of \(name)") { controller.model.checked != nil }
        return (window, table, controller.model, archive.lastSession)
    }

    func table(_ window: NSWindow, model: ArchiveWindowModel) -> ThemedTable? {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let table = window.contentView?.descendant(ThemedTable.self),
              (table.delegate as? ResultsTable.Coordinator)?.model === model.results else { return nil }
        return table
    }

    @discardableResult
    func listed(_ window: NSWindow, model: ArchiveWindowModel, names: [String], selected: Int? = 0) async throws -> ThemedTable {
        try await untilTrue(waitingFor: "\(names) with row \(selected.map { "\($0)" } ?? "none") selected; shown \(model.results.names)") {
            guard let table = table(window, model: model) else { return false }
            return !model.results.isPending && model.results.names == names && table.numberOfRows == names.count
                && selected.map { table.selectedRowIndexes == [$0] } != false
        }
        return try #require(table(window, model: model))
    }

    func select(_ names: [String], in table: ThemedTable, model: ArchiveWindowModel) throws {
        var rows = IndexSet()
        for name in names { rows.insert(try #require(model.results.names.firstIndex(of: name), "\(name) among \(model.results.names)")) }
        table.selectRowIndexes(rows, byExtendingSelection: false)
    }

    func changes(_ session: SearchSessionID) -> [[ArchiveChange]] { archive.session(session)?.changes ?? [] }

    func menu(_ table: ThemedTable, row: Int, in window: NSWindow) throws -> NSMenu {
        let rect = table.rect(ofRow: row)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        return try #require(table.menu(for: click))
    }

    func element(_ id: String, in window: NSWindow) async throws -> NSObject {
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "\(id) among \(AXTree.nodeCount(in: content)) accessibility nodes") {
            content.layoutSubtreeIfNeeded()
            return AXTree.element(id, in: content) != nil
        }
        return try #require(AXTree.element(id, in: content))
    }

    func shows(_ id: String, in window: NSWindow) throws -> Bool {
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        return AXTree.element(id, in: content) != nil
    }

    func deletesARow(_ table: ThemedTable, in window: NSWindow, model: ArchiveWindowModel, session: SearchSessionID) async throws {
        try select(["cover.jpg"], in: table, model: model)
        let menu = try menu(table, row: 2, in: window)
        #expect(menu.items.last?.identifier?.rawValue == ThemedTable.deleteItemID)
        #expect(table.validateUserInterfaceItem(try #require(editMenuDelete())))
        try deleteKey(window)
        try await listed(window, model: model, names: ["Family", "Trip", "inner.zip", "notes.txt"], selected: nil)
        #expect(changes(session).last == [.delete(path: "cover.jpg")])
        #expect(window.isDocumentEdited)
    }

    func refusesTheDelete(_ table: ThemedTable, in window: NSWindow, model: ArchiveWindowModel, session: SearchSessionID, reason: String) async throws {
        let status = try await element(ArchiveStatusBar.readOnlyID, in: window)
        #expect(AXTree.names(of: status).contains(String(localized: "Read only", table: "Archive")))
        let help: String? = AXTree.value("accessibilityHelp", of: status)
        #expect(help == reason)
        try select(["cover.jpg"], in: table, model: model)
        try deleteKey(window)
        try forwardDelete(window)
        try deleteKey(window, flags: .command)
        try await pumpEvents(for: .milliseconds(100))
        #expect(changes(session).isEmpty)
        #expect(recorder.refused == 0)
        #expect(model.results.names == topLevel)
        #expect(table.selectedRowIndexes == [2])
        #expect(!window.isDocumentEdited)
        let menu = try menu(table, row: 2, in: window)
        #expect(!menu.items.contains { $0.identifier?.rawValue == ThemedTable.deleteItemID })
        #expect(menu.items.last?.title == String(localized: "Expand Archive…", table: "Archive"))
        let item = try #require(editMenuDelete())
        #expect(!table.validateUserInterfaceItem(item))
    }
}

@Suite(.serialized) struct ArchiveEditTests {
    @Test func deleteKeyRemovesTheSelectedRowsAndMarksTheWindowEdited() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        let location = window.subtitle
        #expect(!window.isDocumentEdited)
        _ = try await rig.element(ArchiveStatusBar.itemsID, in: window)
        #expect(try rig.shows(ArchiveStatusBar.readOnlyID, in: window) == false)
        #expect(location == ((rig.hit("Photos 2024.zip").path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)

        try rig.select(["cover.jpg", "notes.txt"], in: table, model: model)
        try deleteKey(window)
        #expect(rig.changes(session) == [[.delete(path: "cover.jpg"), .delete(path: "notes.txt")]])
        #expect(table.selectedRowIndexes.isEmpty)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "inner.zip"], selected: nil)
        #expect(window.isDocumentEdited)
        #expect(window.subtitle == String(localized: "Edited", table: "Archive"))
        #expect(window.undoManager?.undoActionName == String(localized: "Delete", table: "Archive"))
        #expect(rig.recorder.refused == 0)
        #expect(window.firstResponder === table)
    }

    @Test func forwardDeleteAndCommandDeleteDoTheSame() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try rig.select(["cover.jpg"], in: table, model: model)
        try forwardDelete(window)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "inner.zip", "notes.txt"], selected: nil)
        #expect(rig.changes(session) == [[.delete(path: "cover.jpg")]])
        #expect(table.selectedRowIndexes.isEmpty)

        try rig.select(["notes.txt"], in: table, model: model)
        try deleteKey(window, flags: .command)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "inner.zip"], selected: nil)
        #expect(rig.changes(session).last == [.delete(path: "cover.jpg"), .delete(path: "notes.txt")])
        #expect(table.selectedRowIndexes.isEmpty)
        #expect(window.isDocumentEdited)

        try deleteKey(window, flags: .option)
        try deleteKey(window, flags: .shift)
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.changes(session).count == 2)
        #expect(rig.recorder.refused == 0)
    }

    @Test func contextMenuEndsWithDeleteShowingTheDeleteKey() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        let menu = try rig.menu(table, row: 2, in: window)
        #expect(table.selectedRowIndexes == [2])
        #expect(menu.items.map(\.title) == [
            String(localized: "Open", table: "Results"), String(localized: "Show in Finder", table: "Results"),
            String(localized: "Quick Look", table: "Results"), String(localized: "Copy Path", table: "Results"), "",
            String(localized: "Expand Selected Items…", table: "Archive"), String(localized: "Expand Archive…", table: "Archive"), "",
            String(localized: "Delete", table: "Archive"),
        ])
        #expect(menu.items[7].isSeparatorItem)
        let item = try #require(menu.items.last)
        #expect(item.identifier?.rawValue == ThemedTable.deleteItemID)
        #expect(item.keyEquivalent == "\u{8}")
        #expect(item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]).isEmpty)
        #expect(item.action == #selector(ThemedTable.delete(_:)))
        #expect(item.target === table)
        #expect(table.validateUserInterfaceItem(item))

        menu.performActionForItem(at: menu.items.count - 1)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "inner.zip", "notes.txt"], selected: nil)
        #expect(rig.changes(session) == [[.delete(path: "cover.jpg")]])
    }

    @Test func editMenuDeleteIsEnabledOnlyWithASelectionInAnEditableArchive() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let item = try #require(editMenuDelete())
        let (window, table, model, session) = try await rig.open()
        try rig.select(["notes.txt"], in: table, model: model)
        #expect(table.validateUserInterfaceItem(item))
        table.deselectAll(nil)
        #expect(!table.validateUserInterfaceItem(item))

        try rig.select(["notes.txt"], in: table, model: model)
        #expect(NSApp.sendAction(#selector(ThemedTable.delete(_:)), to: table, from: item))
        try await rig.listed(window, model: model, names: ["Family", "Trip", "cover.jpg", "inner.zip"], selected: nil)
        #expect(rig.changes(session) == [[.delete(path: "notes.txt")]])

        let (jarWindow, jarTable, jarModel, _) = try await rig.open("Library.jar")
        try rig.select(["notes.txt"], in: jarTable, model: jarModel)
        #expect(!jarTable.validateUserInterfaceItem(item))
        jarWindow.close()
    }

    @Test func deletingAFolderTakesItsSubtreeAndEmptiesTheSelection() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try rig.select(["Trip"], in: table, model: model)
        try returnKey(window)
        try await rig.listed(window, model: model, names: tripRows)
        #expect(model.folder == "Trip")

        try rig.select(["Day 2"], in: table, model: model)
        try deleteKey(window)
        #expect(rig.changes(session) == [[.delete(path: "Trip/Day 2")]])
        #expect(table.selectedRowIndexes.isEmpty)
        try await rig.listed(window, model: model, names: ["IMG_0001.HEIC"], selected: nil)

        try commandUp(window)
        try await rig.listed(window, model: model, names: topLevel, selected: 1)
        try returnKey(window)
        try await rig.listed(window, model: model, names: ["IMG_0001.HEIC"])
        #expect(model.folder == "Trip")
        #expect(window.isDocumentEdited)
    }

    @Test func undoBringsTheRowsBackAndTheLastUndoClearsEdited() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        let location = window.subtitle
        try rig.select(["cover.jpg", "notes.txt"], in: table, model: model)
        try deleteKey(window)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "inner.zip"], selected: nil)
        try rig.select(["Family"], in: table, model: model)
        try deleteKey(window)
        try await rig.listed(window, model: model, names: ["Trip", "inner.zip"], selected: nil)
        let manager = try #require(window.undoManager)
        #expect(manager.undoMenuItemTitle.contains(String(localized: "Delete", table: "Archive")))

        try undo(table)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "inner.zip"], selected: nil)
        #expect(rig.changes(session).last == [.delete(path: "cover.jpg"), .delete(path: "notes.txt")])
        #expect(window.isDocumentEdited)
        #expect(window.subtitle == String(localized: "Edited", table: "Archive"))

        try undo(table)
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        #expect(rig.changes(session).last == [])
        #expect(!window.isDocumentEdited)
        #expect(window.subtitle == location)
        #expect(!manager.canUndo)
        #expect(manager.canRedo)
    }

    @Test func deletingMoreThanTheActionLimitKeepsItsOwnUndoGroup() async throws {
        let names = (0..<ThemedTable.actionLimit + 3).map { String(format: "file-%05d.txt", $0) }
        let rig = try Rig(entries: names.map { .init($0) })
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open(names: names)
        let manager = try #require(window.undoManager)
        let bulk = names.prefix(ThemedTable.actionLimit + 1).map { ArchiveChange.delete(path: $0) }
        let rest = Array(names.suffix(2))
        table.selectRowIndexes(IndexSet(0...ThemedTable.actionLimit), byExtendingSelection: false)
        try deleteKey(window)
        try await rig.listed(window, model: model, names: rest, selected: nil)
        #expect(rig.changes(session).last == bulk)
        #expect(manager.groupingLevel == 0)
        try rig.select([rest[0]], in: table, model: model)
        try deleteKey(window)
        try await rig.listed(window, model: model, names: [rest[1]], selected: nil)
        #expect(rig.changes(session).last == bulk + [.delete(path: rest[0])])

        try undo(table)
        try await rig.listed(window, model: model, names: rest, selected: nil)
        #expect(rig.changes(session).last == bulk)
        #expect(manager.canUndo)

        try undo(table)
        try await untilTrue(waitingFor: "every row back; \(table.numberOfRows) shown") { table.numberOfRows == names.count }
        #expect(rig.changes(session).last == [])
        #expect(!manager.canUndo)
        #expect(!window.isDocumentEdited)
    }

    @Test func redoDeletesAgain() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try rig.select(["cover.jpg"], in: table, model: model)
        try deleteKey(window)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "inner.zip", "notes.txt"], selected: nil)
        try undo(table)
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        #expect(!window.isDocumentEdited)

        try redo(table)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "inner.zip", "notes.txt"], selected: nil)
        #expect(rig.changes(session).last == [.delete(path: "cover.jpg")])
        #expect(window.isDocumentEdited)
        #expect(window.undoManager?.undoActionName == String(localized: "Delete", table: "Archive"))

        try undo(table)
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        try rig.select(["notes.txt"], in: table, model: model)
        try deleteKey(window)
        try await rig.listed(window, model: model, names: ["Family", "Trip", "cover.jpg", "inner.zip"], selected: nil)
        #expect(rig.changes(session).last == [.delete(path: "notes.txt")])
        let manager = try #require(window.undoManager)
        #expect(!manager.canRedo)
        let sent = rig.changes(session).count
        try redo(table)
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.changes(session).count == sent)
        #expect(model.results.names == ["Family", "Trip", "cover.jpg", "inner.zip"])
    }

    @Test func statusUpdatesDuringASaveReadTheAccessCheckedOnceOffTheMainThread() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model, _) = try await rig.open()
        let content = try #require(window.contentView)
        let checks = rig.access.calls
        #expect(checks >= 1)
        _ = try await rig.element(ArchiveStatusBar.statusID, in: window)
        for step in 1...10 {
            model.saving = ArchiveWindowModel.Saving(name: "Photos 2024.zip", fraction: Double(step) / 10)
            try await pumpEvents(for: .milliseconds(20))
            content.layoutSubtreeIfNeeded()
            #expect(model.readOnly == nil)
        }
        model.saving = nil
        try await pumpEvents(for: .milliseconds(20))
        #expect(rig.access.calls == checks)
        #expect(rig.access.onMain == 0)
        #expect(model.editable)
    }

    @Test func lockedReadOnlyFolderAndReadOnlyVolumeShowReadOnlyWithTheReason() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletesARow(table, in: window, model: model, session: session)
        window.close()

        let path = ArchiveWindows.resolved(rig.hit("Other.zip").path)
        let folder = Bidi.name(((path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
        let other = Bidi.name("Other.zip")
        let cases: [(ArchiveAccess, String)] = [
            (ArchiveAccess(locked: true), String(localized: "“\(other)” is locked.", table: "Archive")),
            (ArchiveAccess(folderWritable: false), String(localized: "You don’t have permission to change “\(folder)”.", table: "Archive")),
            (ArchiveAccess(readOnlyVolume: true, writable: false), String(localized: "“\(other)” is on a read-only volume.", table: "Archive")),
            (ArchiveAccess(writable: false), String(localized: "You don’t have permission to change “\(other)”.", table: "Archive")),
        ]
        for (access, reason) in cases {
            rig.access.value = access
            let (lockedWindow, lockedTable, lockedModel, lockedSession) = try await rig.open("Other.zip")
            try await rig.refusesTheDelete(lockedTable, in: lockedWindow, model: lockedModel, session: lockedSession, reason: reason)
            lockedWindow.close()
        }
    }

    @Test func jarAndRarShowReadOnlyWithTheFormatReason() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletesARow(table, in: window, model: model, session: session)
        window.close()

        let reason = String(localized: "Only .zip files and tarballs can be edited.", table: "Archive")
        for name in ["Library.jar", "Music.rar"] {
            let (shut, shutTable, shutModel, shutSession) = try await rig.open(name)
            try await rig.refusesTheDelete(shutTable, in: shut, model: shutModel, session: shutSession, reason: reason)
            shut.close()
        }
    }

    @Test func zipCryptoZipShowsReadOnlyWithTheEncryptionReason() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open("Old.zip")
        try await rig.refusesTheDelete(
            table, in: window, model: model, session: session,
            reason: String(localized: "This archive uses an old kind of encryption, so Wherever can’t edit it.", table: "Archive")
        )
    }

    @Test func nestedArchiveHasNoDelete() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletesARow(table, in: window, model: model, session: session)

        try rig.select(["inner.zip"], in: table, model: model)
        try returnKey(window)
        let innerTable = try await rig.listed(window, model: model, names: innerRows)
        #expect(model.depth == 1)
        let innerSession = rig.archive.lastSession
        #expect(innerSession != session)
        let status = try await rig.element(ArchiveStatusBar.readOnlyID, in: window)
        let help: String? = AXTree.value("accessibilityHelp", of: status)
        #expect(help == String(localized: "Items in an archive inside another archive can’t be edited.", table: "Archive"))

        try rig.select(["readme.txt"], in: innerTable, model: model)
        try deleteKey(window)
        try forwardDelete(window)
        try deleteKey(window, flags: .command)
        try await pumpEvents(for: .milliseconds(100))
        #expect(rig.changes(innerSession).isEmpty)
        #expect(rig.changes(session).count == 1)
        #expect(model.results.names == innerRows)
        #expect(innerTable.selectedRowIndexes == [1])
        let menu = try rig.menu(innerTable, row: 1, in: window)
        #expect(!menu.items.contains { $0.identifier?.rawValue == ThemedTable.deleteItemID })
        #expect(!innerTable.validateUserInterfaceItem(try #require(editMenuDelete())))
        #expect(rig.recorder.refused == 0)
        #expect(window.isDocumentEdited)
    }

    @Test func deleteInTheSearchFieldEditsTheTextOnly() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletesARow(table, in: window, model: model, session: session)

        window.contentView?.layoutSubtreeIfNeeded()
        let field = try #require(window.searchField)
        #expect(window.makeFirstResponder(field))
        for character in "no" { try send(window, String(character), code: try #require(letters[character])) }
        try await untilTrue(waitingFor: "the field to read no; it reads \(field.stringValue)") { field.stringValue == "no" }
        try send(window, "\u{7f}", code: 51)
        try await untilTrue(waitingFor: "the field to read n; it reads \(field.stringValue)") { field.stringValue == "n" }
        #expect(rig.changes(session).count == 1)
        try send(window, "\u{7f}", code: 51)
        try await untilTrue(waitingFor: "an empty field; it reads \(field.stringValue)") { field.stringValue.isEmpty }
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.changes(session).count == 1)
        #expect(rig.recorder.refused == 0)
        #expect(window.firstResponder === field.currentEditor())
    }

    @Test func quickLookAndCopyAfterADeleteActOnTheRowSelectedNext() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletesARow(table, in: window, model: model, session: session)
        try rig.select(["notes.txt"], in: table, model: model)
        try space(window)
        #expect(rig.recorder.quickLookOpen)
        try await untilTrue(waitingFor: "a preview of notes.txt; extracts \(rig.archive.extracts.map(\.entries))") {
            rig.archive.extracts.contains { $0.entries == ["notes.txt"] }
        }
        #expect(!rig.archive.extracts.contains { $0.entries == ["cover.jpg"] })
        let notes = try #require(model.results.rows(in: 0..<model.results.count).first { $0.name == "notes.txt" })
        #expect(table.numberOfPreviewItems(in: nil) == 1)
        #expect(NSApp.sendAction(NSSelectorFromString("copy:"), to: table, from: nil))
        #expect(rig.recorder.copied == [notes.path])
        #expect(notes.path == rig.hit("Photos 2024.zip").path + "/notes.txt")
    }

    @Test func deletingEveryRowThenUndoAndRedoFillsAndEmptiesTheTable() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try rig.select(topLevel, in: table, model: model)
        try deleteKey(window)
        try await rig.listed(window, model: model, names: [], selected: nil)
        #expect(rig.changes(session).last == topLevel.map { ArchiveChange.delete(path: $0) })
        #expect(window.isDocumentEdited)

        try undo(table)
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        try await untilTrue(waitingFor: "Family in row 0's cell; it reads \(cellText(table, row: 0) ?? "nothing")") {
            window.contentView?.layoutSubtreeIfNeeded()
            return cellText(table, row: 0) == "Family" && cellText(table, row: 4) == "notes.txt"
        }
        #expect(rig.changes(session).last == [])
        #expect(!window.isDocumentEdited)

        try redo(table)
        try await rig.listed(window, model: model, names: [], selected: nil)
        #expect(rig.changes(session).last == topLevel.map { ArchiveChange.delete(path: $0) })
        #expect(window.isDocumentEdited)
    }

    @Test func undoAfterDeletingAThousandFoldersGrowsTheTableInPlace() async throws {
        let folders = (0..<1_000).map { String(format: "folder-%04d", $0) }
        let files = (0..<60).map { String(format: "file-%02d.txt", $0) }
        let rig = try Rig(entries: folders.map { .init($0, kind: .folder) } + files.map { .init($0) })
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open(names: folders + files)
        table.selectRowIndexes(IndexSet(integersIn: 0..<folders.count), byExtendingSelection: false)
        try deleteKey(window)
        try await rig.listed(window, model: model, names: files, selected: nil)
        #expect(rig.changes(session).last == folders.map { ArchiveChange.delete(path: $0) })
        window.displayIfNeeded()
        let before = shownCells(table)
        try #require(!before.isEmpty)

        try undo(table)
        try await rig.listed(window, model: model, names: folders + files, selected: nil)
        try await untilTrue(waitingFor: "folder-0000 in row 0's cell; it reads \(cellText(table, row: 0) ?? "nothing")") {
            window.contentView?.layoutSubtreeIfNeeded()
            return cellText(table, row: 0) == folders[0]
        }
        window.displayIfNeeded()
        let known = Set(before.map(ObjectIdentifier.init))
        #expect(shownCells(table).filter { !known.contains(ObjectIdentifier($0)) }.isEmpty, "the undo reuses the cells")
        #expect(table.selectedRowIndexes.isEmpty)

        try redo(table)
        try await rig.listed(window, model: model, names: files, selected: nil)
        try await untilTrue(waitingFor: "file-00.txt in row 0's cell; it reads \(cellText(table, row: 0) ?? "nothing")") {
            window.contentView?.layoutSubtreeIfNeeded()
            return cellText(table, row: 0) == files[0]
        }
        #expect(rig.changes(session).last == folders.map { ArchiveChange.delete(path: $0) })
    }

    @Test func deleteDuringASearchTakesEachHitFromItsOwnFolder() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        model.results.query = "jp"
        try await rig.listed(window, model: model, names: ["mom.jpg", "cover.jpg"], selected: nil)
        let hits = model.results.rows(in: 0..<model.results.count)
        #expect(hits.map(\.folder) == [model.shownAs + "/Family", model.shownAs])
        let before = hits.compactMap { model.inner($0.path) }
        #expect(before == ["Family/mom.jpg", "cover.jpg"])

        table.selectRowIndexes(IndexSet(integersIn: 0..<hits.count), byExtendingSelection: false)
        try deleteKey(window)
        try await rig.listed(window, model: model, names: [], selected: nil)
        #expect(rig.changes(session) == [before.map { ArchiveChange.delete(path: $0) }])
        #expect(window.isDocumentEdited)
    }

    @Test func innerPathOfAHitMatchesTheOldPathMappingByteForByte() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (_, _, model, _) = try await rig.open()
        let root = model.shownAs
        let same = [
            entry("notes.txt", in: root), entry("IMG_0003.HEIC", in: root + "/Trip/Day 2"),
            entry("Cafe\u{301}.txt", in: root), entry("Caf\u{e9}.txt", in: root + "/Trip"),
            entry("Cafe\u{301}.txt", in: root + "/Re\u{301}sume\u{301}"), entry("📷 shot 🇹🇷.jpg", in: root + "/My Photos"),
            entry("my file.txt", in: root), entry("\u{301}x.txt", in: root + "/Trip"),
            entry("notes.txt", in: "/elsewhere"), entry("notes.txt", in: root + "x"), entry("notes.txt", in: root + "x/Trip"),
        ]
        for hit in same {
            let old = model.inner(hit.path)
            let new = ArchiveWindowModel.inner(hit, in: root)
            #expect(new.map { Array($0.utf8) } == old.map { Array($0.utf8) }, "\(hit.folder) \(hit.name): \(new ?? "nil") against \(old ?? "nil")")
            #expect(model.inner(hit).map { Array($0.utf8) } == new.map { Array($0.utf8) })
        }
        #expect(ArchiveWindowModel.inner(entry("Cafe\u{301}.txt", in: root + "/Trip"), in: root).map { Array($0.utf8) } == Array("Trip/Cafe\u{301}.txt".utf8))
        #expect(ArchiveWindowModel.inner(entry("notes.txt", in: "/elsewhere"), in: root) == nil)
        #expect(ArchiveWindowModel.inner(entry("notes.txt", in: root + "x"), in: root) == nil)

        #expect(model.inner(entry("\u{301}x.txt", in: root).path) == nil)
        #expect(ArchiveWindowModel.inner(entry("\u{301}x.txt", in: root), in: root).map { Array($0.utf8) } == Array("\u{301}x.txt".utf8))
        #expect(ArchiveWindowModel.inner(entry("x.txt", in: root + "/\u{301}dir"), in: root).map { Array($0.utf8) } == Array("\u{301}dir/x.txt".utf8))
    }
}
