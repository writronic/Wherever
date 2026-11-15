import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
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

private let archiveName = "Photos 2024.zip"

private let original = Data("the original archive".utf8)

private let safari: [UInt8] = Array("0081;5f000000;Safari;".utf8)

private let tagsKey = "com.apple.metadata:_kMDItemUserTags"

private let saveTitle = String(localized: "Save", table: "Archive")

private let saveAsTitle = String(localized: "Save As…", table: "Archive")

private func saveStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.archive-save"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
}

private func key(_ window: NSWindow, _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
    ))
    if !flags.contains(.command) || !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    #expect(window.undoManager?.groupingLevel == 0)
}

private func deleteKey(_ window: NSWindow) throws { try key(window, "\u{7f}", code: 51) }

private func returnKey(_ window: NSWindow) throws { try key(window, "\r", code: 36) }

private func space(_ window: NSWindow) throws { try key(window, " ", code: 49) }

private func undo(_ table: ThemedTable) -> Bool { table.tryToPerform(NSSelectorFromString("undo:"), with: nil) }

private func commandS(_ table: ThemedTable) throws {
    try #require(table.tryToPerform(#selector(ArchiveWindowController.saveArchive(_:)), with: nil), "no responder took saveArchive:")
}

private func shiftCommandS(_ table: ThemedTable) throws {
    try #require(table.tryToPerform(#selector(ArchiveWindowController.saveArchiveAs(_:)), with: nil), "no responder took saveArchiveAs:")
}

private func views<T: NSView>(_ type: T.Type, in root: NSView?) -> [T] {
    guard let root else { return [] }
    return [root].compactMap { $0 as? T } + root.subviews.flatMap { views(type, in: $0) }
}

private func fileMenu(in menu: NSMenu? = NSApp.mainMenu) -> NSMenu? {
    guard let menu else { return nil }
    menu.delegate?.menuNeedsUpdate?(menu)
    if menu.items.contains(where: { $0.title == String(localized: "Show Archive Contents", table: "Results") }) {
        menu.update()
        return menu
    }
    return menu.items.lazy.compactMap { fileMenu(in: $0.submenu) }.first
}

private func fileItem(_ title: String) -> NSMenuItem? { fileMenu()?.items.first { $0.title == title } }

private func info(_ path: String) throws -> stat {
    var value = stat()
    try #require(lstat(path, &value) == 0, "lstat \(path): \(errno)")
    return value
}

private func xattr(_ name: String, of path: String) -> [UInt8]? {
    let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
    guard size >= 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    let read = getxattr(path, name, &bytes, size, 0, XATTR_NOFOLLOW)
    return read >= 0 ? Array(bytes.prefix(read)) : nil
}

private func setXattr(_ name: String, _ bytes: [UInt8], on path: String) throws {
    try #require(setxattr(path, name, bytes, bytes.count, 0, 0) == 0, "setxattr \(name): \(errno)")
}

private func aclText(_ path: String) -> String? {
    guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return nil }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard let text = acl_to_text(acl, nil) else { return nil }
    defer { acl_free(UnsafeMutableRawPointer(text)) }
    return String(cString: text)
}

private func chmod(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/chmod")
    process.arguments = arguments
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

private func tag(_ path: String, _ names: [String]) throws {
    try (URL(filePath: path) as NSURL).setResourceValue(names, forKey: .tagNamesKey)
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
    let defaults = saveStore()
    let windows: ArchiveWindows
    let folder: URL
    let real: String
    let access = AccessSwitch()
    let name: String
    var panels: [NSSavePanel] = []
    var saveTo: URL?

    init(name: String = archiveName, passwords: [String: String] = [:], locked: Set<String> = [], summary: ArchiveSummary? = nil) throws {
        self.name = name
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-save-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        real = ArchiveWindows.resolved(folder.path(percentEncoded: false))
        try original.write(to: folder.appending(path: name))
        try Data("a dropped file".utf8).write(to: folder.appending(path: "report.pdf"))
        archive = FakeArchiveClient(
            search: search, extensions: ["zip", "jar", "tar", "tgz", "tar.gz", "tar.bz2", "tar.xz"], entries: photos, summary: summary,
            nested: ["inner.zip": innerEntries],
            passwords: passwords, locked: locked, editing: [name: .all, "Copy.zip": .all, "inner.zip": .all]
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

    var path: String { real + "/" + name }

    func path(_ name: String) -> String { real + "/" + name }

    func hit(_ name: String? = nil) -> SearchHit {
        SearchHit(
            name: name ?? self.name, folder: folder.path(percentEncoded: false), size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast,
            opened: .distantPast, kind: .file
        )
    }

    func close() {
        ArchiveWindows.all.forEach { $0.window?.close() }
        for item in (try? FileManager.default.contentsOfDirectory(atPath: real)) ?? [] {
            let path = real + "/" + item
            _ = lchflags(path, 0)
            _ = chmod(["-N", path])
        }
        try? FileManager.default.removeItem(atPath: real)
    }

    func open() async throws -> (NSWindow, ThemedTable, ArchiveWindowModel, SearchSessionID) {
        windows.open(hit())
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let model = controller.model
        model.place = { [self] panel, done in
            panels.append(panel)
            done(saveTo)
        }
        let table = try await listed(window, model: model, names: topLevel)
        try await untilTrue(waitingFor: "the summary and the access check") { model.summary != nil && model.checked != nil }
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

    func select(_ names: [String], in table: ThemedTable, model: ArchiveWindowModel) throws {
        var rows = IndexSet()
        for name in names { rows.insert(try #require(model.results.names.firstIndex(of: name), "\(name) among \(model.results.names)")) }
        table.selectRowIndexes(rows, byExtendingSelection: false)
    }

    func deletes(_ name: String, in table: ThemedTable, window: NSWindow, model: ArchiveWindowModel) async throws {
        let names = model.results.names
        try select([name], in: table, model: model)
        try deleteKey(window)
        try await listed(window, model: model, names: names.filter { $0 != name }, selected: nil)
        #expect(window.isDocumentEdited)
    }

    func saved(_ model: ArchiveWindowModel, sessions: Int) async throws {
        try await untilTrue(waitingFor: "the save to end and the archive to reopen; opened \(archive.opened.count)") {
            model.saving == nil && model.saveJob == nil && archive.opened.count >= sessions && !model.results.isPending
        }
    }

    func writes(_ session: SearchSessionID) -> [String] { archive.session(session)?.writes ?? [] }

    func hiddenCopies() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: real)) ?? []).filter { $0.contains(".wherever-") }.sorted()
    }

    func isHiddenCopy(_ out: String, of name: String) -> Bool {
        let item = (out as NSString).lastPathComponent
        let prefix = "." + name + ".wherever-"
        return ArchiveWindows.resolved((out as NSString).deletingLastPathComponent) == real && item.hasPrefix(prefix)
            && UUID(uuidString: String(item.dropFirst(prefix.count))) != nil
    }

    func sheet(_ window: NSWindow, id: String) async throws -> NSWindow {
        try await untilTrue(waitingFor: "the \(id) sheet") { window.attachedSheet?.identifier?.rawValue == id }
        return try #require(window.attachedSheet)
    }

    func button(_ id: String, in sheet: NSWindow) -> NSButton? {
        views(NSButton.self, in: sheet.contentView).first { $0.accessibilityIdentifier() == id }
    }

    func texts(in sheet: NSWindow) -> [String] { views(NSTextField.self, in: sheet.contentView).map(\.stringValue) }

    func element(_ id: String, in window: NSWindow) async throws -> NSObject {
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "\(id) among \(AXTree.nodeCount(in: content)) accessibility nodes") {
            content.layoutSubtreeIfNeeded()
            return AXTree.element(id, in: content) != nil
        }
        return try #require(AXTree.element(id, in: content))
    }
}

@Suite(.serialized) struct ArchiveSaveTests {
    @Test func commandSWritesTheHiddenCopyBesideTheArchiveThenSwaps() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        let before = try info(rig.path)
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        try commandS(table)
        try await rig.saved(model, sessions: 2)

        let writes = rig.writes(session)
        #expect(writes.count == 1)
        let out = try #require(writes.first)
        #expect(rig.isHiddenCopy(out, of: archiveName), "\(out)")
        #expect(rig.archive.created == [out])
        #expect(!FileManager.default.fileExists(atPath: out))
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == FakeArchiveClient.saved)
        #expect(try info(rig.path).st_ino != before.st_ino)
        #expect(rig.hiddenCopies().isEmpty)
        #expect(rig.archive.opened.map(\.shownAs) == [rig.hit().path, rig.hit().path])
        #expect(rig.archive.session(session)?.closes == 1)
        #expect(!window.isDocumentEdited)
        #expect(window.subtitle == model.location)
        #expect(window.title == archiveName)
        #expect(rig.recorder.refused == 0)
    }

    @Test func saveKeepsModeQuarantineTagsAndHiddenFlag() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let path = rig.path
        #expect(Darwin.chmod(path, 0o640) == 0)
        try setXattr(ArchiveWindowModel.quarantine, safari, on: path)
        try tag(path, ["Work"])
        #expect(chmod(["+a", "group:everyone allow read", path]) == 0)
        #expect(chflags(path, UInt32(UF_HIDDEN)) == 0)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 978_307_200)], ofItemAtPath: path)
        let tags = try #require(xattr(tagsKey, of: path))
        let acl = try #require(aclText(path))
        let before = try info(path)

        let (window, table, model, _) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        try commandS(table)
        try await rig.saved(model, sessions: 2)

        let after = try info(path)
        #expect(try Data(contentsOf: URL(filePath: path)) == FakeArchiveClient.saved)
        #expect(after.st_ino != before.st_ino)
        #expect(after.st_mode & 0o7777 == 0o640)
        #expect(after.st_flags & UInt32(UF_HIDDEN) != 0)
        #expect(xattr(ArchiveWindowModel.quarantine, of: path) == safari)
        #expect(xattr(tagsKey, of: path) == tags)
        #expect(aclText(path) == acl)
        #expect(Double(after.st_mtimespec.tv_sec) >= start.timeIntervalSince1970)
        #expect(rig.hiddenCopies().isEmpty)
    }

    @Test func saveFailureDeletesTheCopyKeepsTheOriginalAndTheList() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        #expect(chmod(["+a", "group:everyone deny delete", rig.path]) == 0)
        let before = try info(rig.path)
        try commandS(table)

        let sheet = try await rig.sheet(window, id: ArchiveWindowModel.saveFailedID)
        #expect(rig.archive.created.count == 1)
        #expect(rig.archive.created == rig.writes(session))
        #expect(rig.hiddenCopies().isEmpty, "\(rig.hiddenCopies())")
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == original)
        #expect(try info(rig.path).st_ino == before.st_ino)
        #expect(model.edits?.changes == [.delete(path: "notes.txt")])
        #expect(window.isDocumentEdited)
        #expect(model.saving == nil)
        #expect(rig.archive.opened.count == 1)
        let text = rig.texts(in: sheet).joined(separator: " ")
        #expect(text.contains(String(localized: "The archive “\(Bidi.name(archiveName))” could not be saved. ", table: "Archive")), "\(text)")
        #expect(rig.button(ArchiveWindowModel.saveFailedSaveAsID, in: sheet) != nil)
        try #require(rig.button(ArchiveWindowModel.saveFailedOKID, in: sheet)).performClick(nil)
        try await untilTrue(waitingFor: "the failure sheet to close") { window.attachedSheet == nil }
        #expect(rig.panels.isEmpty)
        #expect(model.canSave)
    }

    @Test func escapeInTheSaveFailedAlertPressesOKAndReturnStaysOnOK() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        for (offersSaveAs, buttons) in [(false, 1), (true, 2)] {
            let alert = ArchiveWindowModel.saveFailedAlert(name: archiveName, reason: "reason", offersSaveAs: offersSaveAs)
            var answers: [NSApplication.ModalResponse] = []
            alert.beginSheetModal(for: window) { answers.append($0) }
            try await untilTrue(waitingFor: "the save-failed sheet") { window.attachedSheet?.identifier?.rawValue == ArchiveWindowModel.saveFailedID }
            let sheet = try #require(window.attachedSheet)
            let ok = try #require(views(NSButton.self, in: sheet.contentView).first { $0.accessibilityIdentifier() == ArchiveWindowModel.saveFailedOKID })
            #expect(alert.buttons.count == buttons)
            #expect(ok.keyEquivalent == "\r")
            #expect(sheet.defaultButtonCell === ok.cell)
            let escape = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
            ))
            #expect(sheet.performKeyEquivalent(with: escape), "offers Save As: \(offersSaveAs)")
            try await untilTrue(waitingFor: "the sheet to close with OK; answers \(answers)") { window.attachedSheet == nil && !answers.isEmpty }
            #expect(answers == [.alertFirstButtonReturn], "offers Save As: \(offersSaveAs)")
        }
    }

    @Test func permissionDeniedOffersSaveAs() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, _) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        #expect(chflags(rig.path, UInt32(UF_IMMUTABLE)) == 0)
        try commandS(table)

        let sheet = try await rig.sheet(window, id: ArchiveWindowModel.saveFailedID)
        #expect(rig.archive.created.count == 1)
        #expect(rig.hiddenCopies().isEmpty)
        #expect(window.isDocumentEdited)
        rig.saveTo = rig.folder.appending(path: "Copy.zip")
        try #require(rig.button(ArchiveWindowModel.saveFailedSaveAsID, in: sheet)).performClick(nil)
        try await untilTrue(waitingFor: "the Save As panel") { rig.panels.count == 1 }
        let panel = try #require(rig.panels.first)
        #expect(panel.identifier?.rawValue == ArchiveWindowModel.savePanelID)
        #expect(panel.nameFieldStringValue == archiveName)
        #expect(panel.directoryURL.map { ArchiveWindows.resolved($0.path(percentEncoded: false)) } == rig.real)
        try await rig.saved(model, sessions: 2)

        let copy = rig.path("Copy.zip")
        #expect(try Data(contentsOf: URL(filePath: copy)) == FakeArchiveClient.saved)
        #expect(try info(copy).st_flags == 0)
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == original)
        #expect(window.title == "Copy.zip")
        #expect(!window.isDocumentEdited)
    }

    @Test func changedOnDiskShowsItsReasonAndKeepsTheList() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        rig.archive.failWrites(with: .changed)
        try commandS(table)

        let sheet = try await rig.sheet(window, id: ArchiveWindowModel.saveFailedID)
        #expect(rig.archive.created.count == 1)
        #expect(rig.archive.created == rig.writes(session))
        #expect(rig.hiddenCopies().isEmpty, "\(rig.hiddenCopies())")
        let reason = ArchiveWindowModel.line(.changed, name: archiveName)
        let text = rig.texts(in: sheet).joined(separator: " ")
        #expect(text.contains(String(localized: "The archive “\(Bidi.name(archiveName))” could not be saved. \(reason)", table: "Archive")), "\(text)")
        #expect(rig.button(ArchiveWindowModel.saveFailedSaveAsID, in: sheet) == nil)
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == original)
        #expect(model.edits?.changes == [.delete(path: "notes.txt")])
        #expect(window.isDocumentEdited)
        #expect(rig.archive.opened.count == 1)
        try #require(rig.button(ArchiveWindowModel.saveFailedOKID, in: sheet)).performClick(nil)
        try await untilTrue(waitingFor: "the failure sheet to close") { window.attachedSheet == nil }
    }

    @Test(arguments: [
        (ArchiveProblem.gone(name: "/Volumes/USB/photo.jpg"), "photo.jpg"),
        (ArchiveProblem.gone(name: "/Volumes/USB/Holiday/"), "Holiday"),
        (ArchiveProblem.gone(name: "photo.jpg"), "photo.jpg"),
        (ArchiveProblem.gone(name: "/archives/Photos 2024.zip"), "Photos 2024.zip"),
        (ArchiveProblem.damaged, "Photos 2024.zip"),
    ])
    func failedSaveNamesTheItemItCouldNotRead(problem: ArchiveProblem, named: String) async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, _) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        rig.archive.failWrites(with: problem)
        try commandS(table)

        let sheet = try await rig.sheet(window, id: ArchiveWindowModel.saveFailedID)
        let reason = ArchiveWindowModel.line(problem, name: named)
        let text = rig.texts(in: sheet).joined(separator: " ")
        #expect(text.contains(String(localized: "The archive “\(Bidi.name(archiveName))” could not be saved. \(reason)", table: "Archive")), "\(text)")
        if named != archiveName {
            #expect(!text.contains(ArchiveWindowModel.line(problem, name: archiveName)), "\(text)")
        }
        #expect(rig.hiddenCopies().isEmpty, "\(rig.hiddenCopies())")
        #expect(model.edits?.changes == [.delete(path: "notes.txt")])
        #expect(window.isDocumentEdited)
        try #require(rig.button(ArchiveWindowModel.saveFailedOKID, in: sheet)).performClick(nil)
        try await untilTrue(waitingFor: "the failure sheet to close") { window.attachedSheet == nil }
        #expect(model.canSave)
    }

    @Test func stopDuringSaveDeletesTheCopy() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        rig.archive.hold()
        try commandS(table)
        try await untilTrue(waitingFor: "the write to start") { model.saveJob?.id != nil }

        let line = try await rig.element(ArchiveStatusBar.savingID, in: window)
        #expect(AXTree.names(of: line).contains(String(localized: "Saving “\(Bidi.name(archiveName))”…", table: "Archive")))
        let out = try #require(rig.archive.created.first)
        #expect(rig.writes(session) == [out])
        #expect(FileManager.default.fileExists(atPath: out))
        #expect(model.saving != nil)
        let job = try #require(rig.archive.running.first)
        try #require(AXTree.press(try await rig.element(ArchiveStatusBar.savingStopID, in: window)))
        try await untilTrue(waitingFor: "the stop") { model.saving == nil && rig.archive.cancels == [job] }
        #expect(!FileManager.default.fileExists(atPath: out))
        #expect(rig.hiddenCopies().isEmpty)
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == original)
        #expect(window.isDocumentEdited)
        #expect(model.edits?.changes == [.delete(path: "notes.txt")])
        try await pumpEvents(for: .milliseconds(100))
        #expect(window.attachedSheet == nil)
        #expect(rig.archive.opened.count == 1)

        rig.archive.release()
        try commandS(table)
        try await rig.saved(model, sessions: 2)
        #expect(rig.writes(session).count == 2)
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == FakeArchiveClient.saved)
        #expect(!window.isDocumentEdited)
        #expect(rig.hiddenCopies().isEmpty)
    }

    @Test func afterSaveTheWindowReopensInTheSameFolderAndEditedClears() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try rig.select(["Trip"], in: table, model: model)
        try returnKey(window)
        let trip = try await rig.listed(window, model: model, names: tripRows)
        try await rig.deletes("IMG_0001.HEIC", in: trip, window: window, model: model)
        #expect(window.undoManager?.canUndo == true)
        try commandS(trip)
        try await rig.saved(model, sessions: 2)

        #expect(model.folder == "Trip")
        let fresh = try await rig.listed(window, model: model, names: tripRows)
        let reopened = rig.archive.lastSession
        #expect(reopened != session)
        #expect(rig.archive.session(reopened)?.browses.last == "Trip")
        #expect(!window.isDocumentEdited)
        #expect(window.subtitle == model.location)
        #expect(model.edits?.changes == [])
        #expect(window.undoManager?.canUndo == false)
        _ = undo(fresh)
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.archive.session(reopened)?.changes == [])
        #expect(model.edits?.changes == [])
        #expect(model.results.names == tripRows)
        #expect(rig.archive.session(session)?.changes.count == 1)

        try rig.select(["IMG_0001.HEIC"], in: fresh, model: model)
        try space(window)
        #expect(rig.recorder.quickLookOpen)
        try await untilTrue(waitingFor: "a preview of the row; extracts \(rig.archive.extracts.map(\.entries))") {
            rig.archive.extracts.contains { $0.entries == ["Trip/IMG_0001.HEIC"] }
        }
        #expect(rig.recorder.refused == 0)
    }

    @Test func afterSaveTheNextDeleteUndoesOnItsOwn() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, _) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        try commandS(table)
        try await rig.saved(model, sessions: 2)
        let reopened = rig.archive.lastSession
        let fresh = try await rig.listed(window, model: model, names: topLevel, selected: nil)
        try await rig.deletes("cover.jpg", in: fresh, window: window, model: model)
        let manager = try #require(window.undoManager)
        #expect(manager.undoActionName == String(localized: "Delete", table: "Archive"))

        let edited = try #require(rig.table(window, model: model))
        #expect(undo(edited))
        try await rig.listed(window, model: model, names: topLevel, selected: nil)
        #expect(rig.archive.session(reopened)?.changes == [[.delete(path: "cover.jpg")], []])
        #expect(!window.isDocumentEdited)
        #expect(!manager.canUndo)
        #expect(manager.canRedo)
    }

    @Test func afterSaveShowArchiveContentsFocusesTheSameWindow() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, _) = try await rig.open()
        let before = try info(rig.path)
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        try commandS(table)
        try await rig.saved(model, sessions: 2)
        #expect(try info(rig.path).st_ino != before.st_ino)

        rig.windows.open(rig.hit())
        #expect(ArchiveWindows.all.count == 1)
        #expect(rig.archive.opened.count == 2)
        #expect(ArchiveWindows.all.first?.window === window)
    }

    @Test func saveAsWritesANewFileAndTheWindowShowsIt() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        rig.saveTo = rig.folder.appending(path: "Copy.zip")
        try shiftCommandS(table)
        try await rig.saved(model, sessions: 2)

        let panel = try #require(rig.panels.first)
        #expect(rig.panels.count == 1)
        #expect(panel.identifier?.rawValue == ArchiveWindowModel.savePanelID)
        #expect(panel.nameFieldStringValue == archiveName)
        #expect(panel.allowedContentTypes == [UTType.zip])
        #expect(!panel.isExtensionHidden)
        let out = try #require(rig.writes(session).first)
        #expect(rig.writes(session).count == 1)
        #expect(rig.isHiddenCopy(out, of: "Copy.zip"), "\(out)")
        let copy = rig.path("Copy.zip")
        #expect(try Data(contentsOf: URL(filePath: copy)) == FakeArchiveClient.saved)
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == original)
        #expect(rig.hiddenCopies().isEmpty)
        #expect(window.title == "Copy.zip")
        #expect(window.subtitle == model.location)
        #expect(ArchiveWindows.resolved(model.outermost) == copy)
        #expect(rig.archive.opened.last.map { ArchiveWindows.resolved($0.path) } == copy)
        #expect(!window.isDocumentEdited)

        let copyHit = SearchHit(
            name: "Copy.zip", folder: rig.folder.path(percentEncoded: false), size: 0, modified: .distantPast, created: .distantPast,
            opened: .distantPast, kind: .file
        )
        rig.windows.open(copyHit)
        #expect(ArchiveWindows.all.count == 1)
        rig.windows.open(rig.hit())
        #expect(ArchiveWindows.all.count == 2)
    }

    @Test(arguments: [("project.tar.gz", "backup.tar.gz"), ("project.tar.bz2", "backup.tar.bz2"), ("project.tar.xz", "backup.tar.xz"), ("PROJECT.TAR.GZ", "backup.TAR.GZ")])
    func saveAsKeepsTheTarballSuffixOnATypedName(_ name: String, _ saved: String) async throws {
        let rig = try Rig(name: name)
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        rig.saveTo = rig.folder.appending(path: "backup")
        try shiftCommandS(table)
        try await rig.saved(model, sessions: 2)

        let panel = try #require(rig.panels.first)
        #expect(panel.nameFieldStringValue == name)
        #expect(panel.allowedContentTypes.isEmpty)
        let out = try #require(rig.writes(session).first)
        #expect(rig.isHiddenCopy(out, of: saved), "\(out)")
        let copy = rig.path(saved)
        #expect(try Data(contentsOf: URL(filePath: copy)) == FakeArchiveClient.saved)
        for wrong in ["backup", "backup.gz", "backup.bz2", "backup.xz"] { #expect(!FileManager.default.fileExists(atPath: rig.path(wrong)), "\(wrong)") }
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == original)
        #expect(window.title == saved)
        #expect(rig.archive.opened.last.map { ArchiveWindows.resolved($0.path) } == copy)
        #expect(ArchiveWindows.allows(name: saved, extensions: try rig.archive.archiveExtensions()))
        #expect(model.blocked == nil)
        #expect(!window.isDocumentEdited)
    }

    @Test(arguments: [
        ("backup", "backup.tar.gz"), ("backup.tar.gz", "backup.tar.gz"), ("Backup.TAR.GZ", "Backup.TAR.GZ"), ("backup.gz", "backup.tar.gz"),
        ("backup.tar", "backup.tar.gz"), ("backup.tgz", "backup.tgz.tar.gz"), ("backup.zip", "backup.zip.tar.gz"),
    ])
    func aTypedNameGetsTheTarballSuffixOnce(_ typed: String, _ saved: String) {
        let folder = URL(filePath: "/Users/someone/Desktop", directoryHint: .isDirectory)
        let named = ArchiveWindowModel.named(folder.appending(path: typed), like: URL(filePath: "/Users/someone/project.tar.gz"))
        #expect(named == folder.appending(path: saved))
    }

    @Test func saveAsPanelOpensBesideTheArchiveWhateverItRemembered() throws {
        let remembered = try scratchFolder("save-remembered")
        let wanted = try scratchFolder("save-wanted")
        defer { try? FileManager.default.removeItem(at: remembered); try? FileManager.default.removeItem(at: wanted) }
        let panel = try withRememberedFolder(remembered, as: ArchiveWindowModel.savePanelID) {
            ArchiveWindowModel.saveAsPanel(for: wanted.appending(path: "Photos 2024.zip"))
        }
        #expect(panel.directoryURL?.resolvingSymlinksInPath().path(percentEncoded: false) == wanted.resolvingSymlinksInPath().path(percentEncoded: false))
    }

    @Test func otherFormatsKeepTheirTypeAndName() {
        for (name, type) in [("a.zip", UTType.zip), ("a.tar", UTType(filenameExtension: "tar")), ("a.tgz", UTType(filenameExtension: "tgz")), ("a.gz", UTType.gzip)] {
            let archive = URL(filePath: "/Users/someone/" + name)
            #expect(ArchiveWindowModel.saveAsPanel(for: archive).allowedContentTypes == [type].compactMap { $0 }, "\(name)")
            let typed = URL(filePath: "/Users/someone/Desktop/backup")
            #expect(ArchiveWindowModel.named(typed, like: archive) == typed, "\(name)")
        }
        #expect(ArchiveWindowModel.saveAsPanel(for: URL(filePath: "/Users/someone/a.tar.xz")).allowedContentTypes.isEmpty)
    }

    @Test func saveAsRefusesASuffixedNameThatIsTakenAndKeepsIt() async throws {
        let rig = try Rig(name: "project.tar.gz")
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        let taken = rig.folder.appending(path: "backup.tar.gz")
        try Data("mine".utf8).write(to: taken)
        rig.saveTo = rig.folder.appending(path: "backup")
        try shiftCommandS(table)

        let sheet = try await rig.sheet(window, id: ArchiveWindowModel.saveFailedID)
        let error = CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: rig.path("backup.tar.gz")]) as NSError
        let reason = error.localizedFailureReason ?? error.localizedDescription
        let text = rig.texts(in: sheet).joined(separator: " ")
        #expect(text.contains(String(localized: "The archive “\(Bidi.name("backup.tar.gz"))” could not be saved. \(reason)", table: "Archive")), "\(text)")
        #expect(try Data(contentsOf: taken) == Data("mine".utf8))
        #expect(rig.writes(session).isEmpty)
        #expect(rig.archive.created.isEmpty)
        #expect(rig.archive.opened.count == 1)
        #expect(model.edits?.changes == [.delete(path: "notes.txt")])
        #expect(window.isDocumentEdited)

        rig.saveTo = rig.folder.appending(path: "fresh")
        try #require(rig.button(ArchiveWindowModel.saveFailedSaveAsID, in: sheet)).performClick(nil)
        try await untilTrue(waitingFor: "the second Save As panel") { rig.panels.count == 2 }
        try await rig.saved(model, sessions: 2)
        #expect(try Data(contentsOf: URL(filePath: rig.path("fresh.tar.gz"))) == FakeArchiveClient.saved)
        #expect(try Data(contentsOf: taken) == Data("mine".utf8))
        #expect(window.title == "fresh.tar.gz")
    }

    @Test func saveAsOntoItsOwnPathTakesTheSaveRoute() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        let before = try info(rig.path)
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        rig.saveTo = URL(filePath: rig.path)
        try shiftCommandS(table)
        try await rig.saved(model, sessions: 2)

        let out = try #require(rig.writes(session).first)
        #expect(rig.isHiddenCopy(out, of: archiveName), "\(out)")
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == FakeArchiveClient.saved)
        let swapped = try info(rig.path)
        #expect(swapped.st_ino != before.st_ino)
        #expect(window.title == archiveName)
        #expect(ArchiveWindows.all.count == 1)
        #expect(!window.isDocumentEdited)

        let fresh = try await rig.listed(window, model: model, names: topLevel)
        let reopened = rig.archive.lastSession
        try await rig.deletes("cover.jpg", in: fresh, window: window, model: model)
        rig.saveTo = rig.folder.appending(path: archiveName.lowercased())
        try shiftCommandS(fresh)
        try await rig.saved(model, sessions: 3)
        let second = try #require(rig.writes(reopened).first)
        #expect(rig.isHiddenCopy(second, of: archiveName), "\(second)")
        #expect(try info(rig.path).st_ino != swapped.st_ino)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.real)) ?? []).filter { $0.lowercased() == archiveName.lowercased() } == [archiveName])
        #expect(window.title == archiveName)
    }

    @Test func saveAsWorksOnALockedArchiveAndWithoutChanges() async throws {
        let rig = try Rig()
        defer { rig.close() }
        try setXattr(ArchiveWindowModel.quarantine, safari, on: rig.path)
        #expect(chflags(rig.path, UInt32(UF_IMMUTABLE | UF_HIDDEN)) == 0)
        rig.access.value.locked = true
        let (window, table, model, session) = try await rig.open()
        #expect(model.readOnly == String(localized: "“\(Bidi.name(archiveName))” is locked.", table: "Archive"))
        #expect(!model.canSave)
        #expect(model.canSaveAs)
        rig.saveTo = rig.folder.appending(path: "Copy.zip")
        try shiftCommandS(table)
        try await rig.saved(model, sessions: 2)

        let copy = rig.path("Copy.zip")
        #expect(rig.writes(session).count == 1)
        #expect(rig.archive.session(session)?.changes == [])
        #expect(try Data(contentsOf: URL(filePath: copy)) == FakeArchiveClient.saved)
        #expect(try info(copy).st_flags == 0)
        #expect(xattr(ArchiveWindowModel.quarantine, of: copy) == safari)
        #expect(try info(rig.path).st_flags & UInt32(UF_IMMUTABLE | UF_HIDDEN) == UInt32(UF_IMMUTABLE | UF_HIDDEN))
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == original)
        #expect(window.title == "Copy.zip")
        #expect(!window.isDocumentEdited)
    }

    @Test func saveIsDisabledWithoutChangesAndSaveAsIsEnabled() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        let menu = ArchiveSaveMenu.shared
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await untilTrue(waitingFor: "Save off and Save As on; save \(menu.canSave), save as \(menu.canSaveAs)") {
            !menu.canSave && menu.canSaveAs && fileItem(saveTitle)?.isEnabled == false && fileItem(saveAsTitle)?.isEnabled == true
        }
        #expect(!model.canSave)
        try commandS(table)
        #expect(rig.recorder.refused == 1)
        #expect(rig.writes(session).isEmpty)

        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        try await untilTrue(waitingFor: "Save on after a change") {
            menu.canSave && menu.canSaveAs && fileItem(saveTitle)?.isEnabled == true && fileItem(saveAsTitle)?.isEnabled == true
        }
        rig.archive.hold()
        try commandS(table)
        try await untilTrue(waitingFor: "both off while saving") {
            !menu.canSave && !menu.canSaveAs && fileItem(saveTitle)?.isEnabled == false && fileItem(saveAsTitle)?.isEnabled == false
        }
        rig.archive.release()
        try await rig.saved(model, sessions: 2)
        try await untilTrue(waitingFor: "Save off and Save As on after the save") {
            !menu.canSave && menu.canSaveAs && fileItem(saveTitle)?.isEnabled == false && fileItem(saveAsTitle)?.isEnabled == true
        }

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try await untilTrue(waitingFor: "both off with no archive window key") {
            !menu.canSave && !menu.canSaveAs && fileItem(saveTitle)?.isEnabled == false && fileItem(saveAsTitle)?.isEnabled == false
        }
    }

    @Test func addFilesIsOffForAReadOnlyArchiveAndTheAccessIsCheckedAgainWhenTheWindowBecomesKey() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model, _) = try await rig.open()
        let menu = ArchiveSaveMenu.shared
        let add = String(localized: "Add Files…", table: "Archive")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await untilTrue(waitingFor: "Add on in an editable archive window; add \(menu.canAdd), checking \(model.checkingAccess)") {
            menu.canAdd && fileItem(add)?.isEnabled == true && !model.checkingAccess
        }
        #expect(model.readOnly == nil)

        rig.access.value.locked = true
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await untilTrue(waitingFor: "Add off in a locked archive window; add \(menu.canAdd), read only \(model.readOnly ?? "nil")") {
            !menu.canAdd && fileItem(add)?.isEnabled == false && model.readOnly != nil
        }
        #expect(model.readOnly == String(localized: "“\(Bidi.name(archiveName))” is locked.", table: "Archive"))
        #expect(menu.canSaveAs)
        #expect(!model.editable)

        rig.access.value.locked = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await untilTrue(waitingFor: "Add on again once the lock is gone; add \(menu.canAdd)") { menu.canAdd && model.readOnly == nil }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    }

    @Test func expandAndAddFilesFollowTheKeyArchiveWindowAndShowContentsStays() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, _) = try await rig.open()
        let menu = ArchiveSaveMenu.shared
        let expand = String(localized: "Expand Archive…", table: "Archive")
        let add = String(localized: "Add Files…", table: "Archive")
        let show = String(localized: "Show Archive Contents", table: "Results")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try await untilTrue(waitingFor: "Expand and Add off with no archive window key; expand \(menu.canExpand), add \(menu.canAdd)") {
            !menu.canExpand && !menu.canAdd && fileItem(expand)?.isEnabled == false && fileItem(add)?.isEnabled == false
                && fileItem(show)?.isEnabled == true
        }

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await untilTrue(waitingFor: "Expand and Add on in an editable archive window; expand \(menu.canExpand), add \(menu.canAdd)") {
            menu.canExpand && menu.canAdd && fileItem(expand)?.isEnabled == true && fileItem(add)?.isEnabled == true
                && fileItem(show)?.isEnabled == true
        }

        try rig.select(["inner.zip"], in: table, model: model)
        try returnKey(window)
        try await rig.listed(window, model: model, names: ["docs", "readme.txt"])
        #expect(model.depth == 1)
        try await untilTrue(waitingFor: "Add off inside a nested archive; expand \(menu.canExpand), add \(menu.canAdd)") {
            menu.canExpand && !menu.canAdd && fileItem(expand)?.isEnabled == true && fileItem(add)?.isEnabled == false
        }

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try await untilTrue(waitingFor: "both off again with no archive window key") { !menu.canExpand && !menu.canAdd }
    }

    @Test func saveAsWaitsWhileTheArchiveIsRead() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.archive.holdBrowse("")
        rig.windows.open(rig.hit())
        let model = try #require(ArchiveWindows.all.last).model
        try await untilTrue(waitingFor: "the held first listing") { rig.archive.waitingBrowses == 1 }
        #expect(model.edits != nil)
        #expect(model.reading)
        #expect(!model.canSaveAs)
        model.saveAs(to: rig.folder.appending(path: "Copy.zip"))
        #expect(rig.recorder.refused == 1)
        #expect(rig.writes(rig.archive.lastSession).isEmpty)

        rig.archive.releaseBrowse()
        try await untilTrue(waitingFor: "the summary") { model.summary != nil }
        #expect(!model.reading)
        #expect(model.canSaveAs)
    }

    @Test func saveAsStaysOffAfterAFailedOpen() async throws {
        let rig = try Rig(summary: ArchiveSummary(path: "", format: "zip", items: 0, bytes: 0, encrypted: false, skipped: 0, problem: .damaged))
        defer { rig.close() }
        rig.windows.open(rig.hit())
        let model = try #require(ArchiveWindows.all.last).model
        try await untilTrue(waitingFor: "the failed read; problem \(String(describing: model.problem))") { model.problem == .damaged }
        #expect(model.blocked == .damaged)
        #expect(model.edits != nil)
        #expect(!model.canSaveAs)
        model.saveAs(to: rig.folder.appending(path: "Copy.zip"))
        #expect(rig.recorder.refused == 1)
        #expect(rig.writes(rig.archive.lastSession).isEmpty)
    }

    @Test func staleCopiesAreSweptOffTheMainThreadBeforeTheWriteStarts() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let stale = rig.path(".\(archiveName).wherever-\(UUID().uuidString)")
        try Data().write(to: URL(filePath: stale))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 978_307_200)], ofItemAtPath: stale)
        let (window, table, model, session) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)

        model.save()
        #expect(model.saving != nil)
        #expect(rig.writes(session).isEmpty)
        let deadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: stale), Date() < deadline { usleep(1_000) }
        #expect(!FileManager.default.fileExists(atPath: stale))
        #expect(rig.writes(session).isEmpty)

        try await rig.saved(model, sessions: 2)
        #expect(rig.writes(session).count == 1)
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == FakeArchiveClient.saved)
    }

    @Test func staleHiddenCopiesAreRemovedAndLookalikesStay() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let old = Date(timeIntervalSince1970: 978_307_200)
        let stale = ".\(archiveName).wherever-\(UUID().uuidString)"
        let lookalikes = [".\(archiveName).wherever-notes", ".Other.zip.wherever-\(UUID().uuidString)", ".\(archiveName).wherever-\(UUID().uuidString).bak"]
        for name in [stale] + lookalikes {
            try Data(name.utf8).write(to: URL(filePath: rig.path(name)))
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: rig.path(name))
        }
        #expect(chflags(rig.path(stale), UInt32(UF_IMMUTABLE)) == 0)
        let (window, table, model, _) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        try commandS(table)
        try await rig.saved(model, sessions: 2)

        #expect(!FileManager.default.fileExists(atPath: rig.path(stale)))
        #expect(rig.hiddenCopies() == lookalikes.sorted())
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == FakeArchiveClient.saved)
    }

    @Test func saveAsksForThePasswordBeforeAddingToAnEncryptedZip() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try Rig(passwords: [archiveName: password], locked: ["cover.jpg"])
        defer { rig.close() }
        let (window, _, model, session) = try await rig.open()
        #expect(model.summary?.encrypted == true)
        model.add([URL(filePath: rig.path("report.pdf"))])
        try await rig.listed(window, model: model, names: topLevel + ["report.pdf"], selected: nil)
        try await untilTrue(waitingFor: "the add to be read") { model.edits?.adding == nil && !model.busy }
        let table = try #require(rig.table(window, model: model))
        try commandS(table)

        try await untilTrue(waitingFor: "the password sheet") {
            window.attachedSheet?.contentView.map { views(NSSecureTextField.self, in: $0).isEmpty } == false
        }
        #expect(model.asking == archiveName)
        #expect(rig.writes(session).count == 1)
        #expect(rig.archive.created.isEmpty)
        #expect(rig.hiddenCopies().isEmpty)
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == original)
        #expect(window.isDocumentEdited)
        #expect(model.saving == nil)

        model.submitPassword(password)
        try await rig.saved(model, sessions: 2)
        #expect(rig.writes(session).count == 2)
        #expect(rig.archive.created.count == 1)
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == FakeArchiveClient.saved)
        #expect(!window.isDocumentEdited)
        try await untilTrue(waitingFor: "the sheet to close") { window.attachedSheet == nil && model.asking == nil }
    }

    @Test func fileMenuShowsSaveAndSaveAsAfterSwiftUIsSaveGroupAndCloseStays() throws {
        let file = try #require(fileMenu(), "the main menu holds no File menu")
        let items = file.items
        let close = try #require(items.firstIndex { $0.action == #selector(NSWindow.performClose(_:)) }, "\(items.map(\.title))")
        let save = try #require(items.firstIndex { $0.title == saveTitle }, "\(items.map(\.title))")
        try #require(save + 1 < items.count)
        #expect(save > close)
        #expect(items[(close + 1)..<save].allSatisfy { $0.action == NSSelectorFromString("closeAll:") }, "\(items.map(\.title))")
        #expect(items[save + 1].title == saveAsTitle)
        #expect(items[save].keyEquivalent == "s")
        #expect(items[save].keyEquivalentModifierMask == [.command])
        #expect(items[save + 1].keyEquivalent.lowercased() == "s")
        #expect(items[save + 1].keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [.command, .shift])
        #expect(items[close].keyEquivalent == "w")
    }

    @Test func whileSavingEditsAreFrozen() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        rig.archive.hold()
        try commandS(table)
        try await untilTrue(waitingFor: "the write to start") { model.saveJob?.id != nil }
        let out = try #require(rig.archive.created.first)
        let job = try #require(rig.archive.running.first)

        try rig.select(["cover.jpg"], in: table, model: model)
        try deleteKey(window)
        #expect(undo(table))
        model.expandArchive()
        try commandS(table)
        try shiftCommandS(table)
        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.recorder.refused == 5)
        #expect(rig.archive.session(session)?.changes == [[.delete(path: "notes.txt")]])
        #expect(model.edits?.changes == [.delete(path: "notes.txt")])
        #expect(!model.canExpand)
        #expect(rig.panels.isEmpty)
        #expect(rig.writes(session) == [out])
        #expect(rig.archive.cancels.isEmpty)
        #expect(rig.archive.running == [job])
        rig.archive.release()
        try await rig.saved(model, sessions: 2)
    }

    @Test func closeDuringSaveWaitsForTheSave() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        rig.archive.hold()
        try commandS(table)
        try await untilTrue(waitingFor: "the write to start") { model.saveJob?.id != nil }
        let out = try #require(rig.archive.created.first)
        let job = try #require(rig.archive.running.first)

        window.performClose(nil)
        try await pumpEvents(for: .milliseconds(50))
        #expect(window.attachedSheet == nil)
        #expect(window.isVisible)
        #expect(ArchiveWindows.all.count == 1)
        #expect(rig.archive.cancels.isEmpty)
        #expect(rig.archive.running == [job])
        #expect(FileManager.default.fileExists(atPath: out))

        rig.archive.release()
        try await untilTrue(waitingFor: "the save, then the close") { ArchiveWindows.all.isEmpty && !window.isVisible }
        #expect(window.attachedSheet == nil)
        #expect(rig.archive.cancels.isEmpty)
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == FakeArchiveClient.saved)
        #expect(rig.writes(session) == [out])
        #expect(rig.hiddenCopies().isEmpty)
        #expect(rig.archive.opened.count == 2)
        #expect(!ArchiveEdits.unsaved)
    }

    @Test func saveFromInsideANestedArchiveSavesTheOuterOne() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model, session) = try await rig.open()
        try await rig.deletes("notes.txt", in: table, window: window, model: model)
        try rig.select(["inner.zip"], in: table, model: model)
        try returnKey(window)
        let inner = try await rig.listed(window, model: model, names: ["docs", "readme.txt"])
        #expect(model.depth == 1)
        let nested = rig.archive.lastSession
        try commandS(inner)
        try await rig.saved(model, sessions: 3)

        #expect(model.depth == 0)
        #expect(model.folder == "")
        try await rig.listed(window, model: model, names: topLevel)
        #expect(rig.writes(session).count == 1)
        #expect(rig.writes(nested).isEmpty)
        #expect(rig.archive.session(nested)?.closes == 1)
        #expect(try Data(contentsOf: URL(filePath: rig.path)) == FakeArchiveClient.saved)
        #expect(!window.isDocumentEdited)
    }
}
