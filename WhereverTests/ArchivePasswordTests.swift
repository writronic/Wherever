import AppKit
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private let archiveName = "Photos 2024.zip"

private func passwordStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.archive-password"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
}

private func event(_ window: NSWindow, _ characters: String, code: UInt16) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
    ))
}

private func key(_ window: NSWindow, _ characters: String, code: UInt16) throws { window.sendEvent(try event(window, characters, code: code)) }

private func press(_ sheet: NSWindow, _ characters: String, code: UInt16) throws {
    let event = try event(sheet, characters, code: code)
    if sheet.performKeyEquivalent(with: event) { return }
    sheet.sendEvent(event)
}

private func returnKey(_ window: NSWindow) throws { try key(window, "\r", code: 36) }

private func space(_ window: NSWindow) throws { try key(window, " ", code: 49) }

private func submit(_ sheet: NSWindow) throws { try press(sheet, "\r", code: 36) }

private func escape(_ sheet: NSWindow) throws { try press(sheet, "\u{1b}", code: 53) }

private func drainMain() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
}

private func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil }

private func write(_ provider: NSFilePromiseProvider, to url: URL) async throws -> (any Error)? {
    let extractor = try #require(provider.delegate as? ArchiveExtractor)
    let queue = extractor.operationQueue(for: provider)
    nonisolated(unsafe) let promise = provider
    return await withCheckedContinuation { (done: CheckedContinuation<(any Error)?, Never>) in
        queue.addOperation { extractor.filePromiseProvider(promise, writePromiseTo: url) { done.resume(returning: $0) } }
    }
}

private func holds(_ value: Any, _ text: String) -> Bool {
    switch value {
    case let string as String: string.contains(text)
    case let data as Data: String(decoding: data, as: UTF8.self).contains(text)
    case let list as [Any]: list.contains { holds($0, text) }
    case let map as [String: Any]: map.keys.contains { $0.contains(text) } || map.values.contains { holds($0, text) }
    default: String(describing: value).contains(text)
    }
}

@MainActor
private final class Rig {
    let search = FakeSearchClient(hits: [])
    let archive: FakeArchiveClient
    let index: IndexModel
    let recorder = ActionRecorder()
    let defaults = passwordStore()
    let windows: ArchiveWindows
    let folder: URL
    let cache: URL

    init(
        entries: [FakeArchiveClient.Entry], locked: Set<String>, password: String, nested: [String: [FakeArchiveClient.Entry]] = [:],
        passwords: [String: String] = [:], summary: ArchiveSummary? = nil, editing: [String: ArchiveEditing] = [:]
    ) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-password-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = folder.appending(path: "Cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: archiveName))
        archive = FakeArchiveClient(
            search: search, entries: entries, summary: summary, nested: nested, passwords: passwords.merging([archiveName: password]) { $1 },
            locked: locked, editing: editing
        )
        index = IndexModel(client: search)
        windows = ArchiveWindows(
            client: archive, index: index, actions: recorder.actions, defaults: defaults, columnPreferences: ColumnPreferences(defaults: defaults),
            cache: cache
        )
    }

    var zipPath: String { folder.appending(path: archiveName).path(percentEncoded: false) }

    var zip: SearchHit {
        SearchHit(
            name: archiveName, folder: folder.path(percentEncoded: false), size: 0, modified: Date(timeIntervalSince1970: 0),
            created: .distantPast, opened: .distantPast, kind: .file
        )
    }

    var root: URL {
        get throws { cache.appending(path: try #require(ArchiveWindows.cacheKey(ArchiveWindows.resolved(zipPath))), directoryHint: .isDirectory) }
    }

    func copy(_ place: String, _ inner: String) throws -> URL { ArchiveWindowModel.place(inner, in: try root, folder: place).appending(path: inner) }

    var unlocks: Int { archive.session(archive.lastSession)?.unlocks ?? 0 }

    var unlocksOnMain: Int { archive.session(archive.lastSession)?.unlocksOnMain ?? 0 }

    func close() {
        ArchiveWindows.all.forEach { $0.window?.close() }
        try? FileManager.default.removeItem(at: folder)
    }

    func open(count: Int) async throws -> (NSWindow, ThemedTable, ArchiveWindowModel) {
        windows.open(zip)
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let table = try await listed(window, model: controller.model, count: count)
        try await untilTrue(waitingFor: "the summary and the access check") { controller.model.summary != nil && controller.model.checked != nil }
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

    func select(_ name: String, in table: ThemedTable, model: ArchiveWindowModel) throws {
        let all = model.results.names
        table.selectRowIndexes([try #require(all.firstIndex(of: name), "\(name) among \(all)")], byExtendingSelection: false)
    }

    func drag(_ name: String, in table: ThemedTable, model: ArchiveWindowModel) throws -> (any NSPasteboardWriting)? {
        let row = try #require(model.results.names.firstIndex(of: name))
        return table.dataSource?.tableView?(table, pasteboardWriterForRow: row)
    }

    func sheet(on window: NSWindow) async throws -> NSWindow {
        try await untilTrue(waitingFor: "the password sheet") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        try await untilTrue(waitingFor: "the password field") {
            sheet.contentView?.layoutSubtreeIfNeeded()
            return Self.field(in: sheet) != nil
        }
        return sheet
    }

    func closed(_ window: NSWindow, model: ArchiveWindowModel) async throws {
        try await untilTrue(waitingFor: "the sheet to close; asking \(model.asking ?? "nothing")") {
            window.attachedSheet == nil && model.asking == nil
        }
    }

    static func field(in sheet: NSWindow) -> NSTextField? {
        sheet.contentView?.descendant(NSSecureTextField.self) ?? sheet.contentView?.descendant(NSTextField.self)
    }

    func type(_ text: String, in sheet: NSWindow) throws {
        let field = try #require(Self.field(in: sheet))
        if field.currentEditor() == nil { sheet.makeFirstResponder(field) }
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func element(_ id: String, in sheet: NSWindow) -> NSObject? {
        guard let content = sheet.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        return AXTree.element(id, in: content)
    }

    func names(in sheet: NSWindow) -> [String] {
        guard let content = sheet.contentView else { return [] }
        return AXTree.elements(in: content).flatMap { AXTree.names(of: $0) }
    }
}

@Suite(.serialized) struct ArchivePasswordTests {
    private static let entries: [FakeArchiveClient.Entry] = [.init("cover.jpg"), .init("notes.txt"), .init("readme.txt"), .init("secret.txt")]
    private static let rows = entries.count
    private static let mixed: [FakeArchiveClient.Entry] = [
        .init("docs", kind: .folder), .init("docs/plain.txt"), .init("readme.txt"), .init("secret.txt"), .init("vault", kind: .folder),
        .init("vault/key.txt"),
    ]
    private static let mixedLocked: Set<String> = ["secret.txt", "vault/key.txt"]
    private static let mixedRows = 4

    @Test func previewOfAnEncryptedEntryAsksThenShows() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try Rig(entries: Self.entries, locked: ["cover.jpg"], password: password)
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: Self.rows)
        #expect(model.summary?.encrypted == true)
        try rig.select("cover.jpg", in: table, model: model)
        try space(window)
        #expect(rig.recorder.shown == [nil])
        let sheet = try await rig.sheet(on: window)
        #expect(model.asking == archiveName)
        #expect(rig.recorder.hides == 1)
        #expect(!rig.recorder.quickLookOpen)
        #expect(model.notice == nil)
        #expect(model.problem == nil)
        let title = String(localized: "Enter the password for “\(Bidi.name(archiveName))”.", table: "Archive")
        #expect(rig.names(in: sheet).contains(title))
        for id in [ArchivePasswordSheet.sheetID, ArchivePasswordSheet.fieldID, ArchivePasswordSheet.okID, ArchivePasswordSheet.cancelID] {
            #expect(rig.element(id, in: sheet) != nil, "\(id) in the sheet")
        }
        #expect(rig.element(ArchivePasswordSheet.wrongID, in: sheet) == nil)
        let preview = try rig.copy("preview", "cover.jpg")
        #expect(!exists(preview))

        try rig.type(password, in: sheet)
        try submit(sheet)
        try await untilTrue(waitingFor: "the preview; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed == [preview] }
        try await rig.closed(window, model: model)
        #expect(rig.recorder.shown == [nil, nil])
        #expect(try Data(contentsOf: preview) == FakeArchiveClient.bytes("cover.jpg"))
        #expect(rig.unlocks == 1)
        #expect(rig.unlocksOnMain == 0)
        #expect(model.notice == nil)
        #expect(rig.recorder.refused == 0)
    }

    @Test func wrongPasswordShowsTheLineClearsTheFieldAndKeepsTheSheet() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try Rig(entries: Self.entries, locked: ["cover.jpg"], password: password)
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: Self.rows)
        try rig.select("cover.jpg", in: table, model: model)
        try space(window)
        let sheet = try await rig.sheet(on: window)

        try rig.type("not it", in: sheet)
        try submit(sheet)
        try await untilTrue(waitingFor: "the wrong-password line; misses \(model.misses)") { model.misses == 1 && !model.unlocking }
        let field = try #require(Rig.field(in: sheet))
        try await untilTrue(waitingFor: "an empty, focused field; holds \(field.stringValue.count) characters") {
            field.stringValue.isEmpty && field.currentEditor() != nil && sheet.firstResponder === field.currentEditor()
        }
        #expect(window.attachedSheet === sheet)
        #expect(model.asking == archiveName)
        let wrong = try #require(rig.element(ArchivePasswordSheet.wrongID, in: sheet))
        #expect(AXTree.names(of: wrong).contains(String(localized: "The password is incorrect. Try again.", table: "Archive")))
        #expect(rig.recorder.refreshed.isEmpty)
        #expect(rig.archive.extracts.count == 1)

        try rig.type(password, in: sheet)
        try submit(sheet)
        let preview = try rig.copy("preview", "cover.jpg")
        try await untilTrue(waitingFor: "the preview; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed == [preview] }
        try await rig.closed(window, model: model)
        #expect(rig.unlocks == 2)
        #expect(model.notice == nil)
    }

    @Test func cancelEndsTheActionAndShowsNothing() async throws {
        let rig = try Rig(entries: Self.entries, locked: ["cover.jpg"], password: "pw-\(UUID().uuidString)")
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: Self.rows)
        try rig.select("cover.jpg", in: table, model: model)
        try space(window)
        let sheet = try await rig.sheet(on: window)
        try rig.type("half typed", in: sheet)

        try escape(sheet)
        try await rig.closed(window, model: model)
        #expect(rig.unlocks == 0)
        #expect(model.notice == nil)
        #expect(model.problem == nil)
        #expect(rig.recorder.refreshed.isEmpty)
        #expect(rig.recorder.opened.isEmpty)
        #expect(rig.recorder.refused == 0)
        #expect(!rig.recorder.quickLookOpen)
        #expect(rig.archive.extracts.count == 1)
        #expect(!exists(try rig.copy("preview", "cover.jpg")))

        try space(window)
        #expect(rig.recorder.shown == [nil, nil])
        let again = try await rig.sheet(on: window)
        let field = try #require(Rig.field(in: again))
        #expect(field.stringValue.isEmpty)
        #expect(rig.element(ArchivePasswordSheet.wrongID, in: again) == nil)
        #expect(rig.archive.extracts.count == 2)
    }

    @Test func cancelledPasswordForASaveAnswersFalseOnlyWhenTheSheetCloses() async throws {
        let rig = try Rig(entries: Self.entries, locked: ["cover.jpg"], password: "pw-\(UUID().uuidString)", editing: [archiveName: .all])
        defer { rig.close() }
        let (window, _, model) = try await rig.open(count: Self.rows)
        let file = rig.folder.appending(path: "report.pdf")
        try Data("a dropped file".utf8).write(to: file)
        model.add([file])
        try await untilTrue(waitingFor: "the add; shown \(model.results.names)") {
            model.edits?.adding == nil && !model.busy && !model.results.isPending && model.results.count == Self.rows + 1
        }
        #expect(window.isDocumentEdited)

        var replies: [Bool] = []
        model.save { replies.append($0) }
        let sheet = try await rig.sheet(on: window)
        #expect(model.asking == archiveName)
        try await pumpEvents(for: .milliseconds(50))
        #expect(replies.isEmpty)
        #expect(model.waitingSave != nil)
        #expect(model.saving == nil)

        try escape(sheet)
        try await rig.closed(window, model: model)
        try await untilTrue(waitingFor: "the answer; got \(replies)") { !replies.isEmpty }
        try await pumpEvents(for: .milliseconds(50))
        #expect(replies == [false])
        #expect(model.waitingSave == nil)
        #expect(model.saveJob == nil)
        #expect(window.isDocumentEdited)
        #expect(rig.unlocks == 0)
        #expect(try Data(contentsOf: URL(filePath: rig.zipPath)).isEmpty)
    }

    @Test func secondWrongPasswordClearsAgainAndEscapeAfterAMissCancels() async throws {
        let rig = try Rig(entries: Self.entries, locked: ["cover.jpg"], password: "pw-\(UUID().uuidString)")
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: Self.rows)
        try rig.select("cover.jpg", in: table, model: model)
        try space(window)
        let sheet = try await rig.sheet(on: window)
        let field = try #require(Rig.field(in: sheet))

        for miss in 1...2 {
            try rig.type("wrong \(miss)", in: sheet)
            try submit(sheet)
            try await untilTrue(waitingFor: "miss \(miss); misses \(model.misses)") { model.misses == miss && !model.unlocking }
            try await untilTrue(waitingFor: "an empty, focused field; holds \(field.stringValue.count) characters") {
                field.stringValue.isEmpty && sheet.firstResponder === field.currentEditor()
            }
        }
        #expect(window.attachedSheet === sheet)

        try escape(sheet)
        try await rig.closed(window, model: model)
        #expect(rig.unlocks == 2)
        #expect(model.notice == nil)
        #expect(rig.recorder.refreshed.isEmpty)
    }

    @Test func returnSubmitsAndEscapeCancels() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try Rig(entries: Self.entries, locked: ["notes.txt"], password: password)
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: Self.rows)
        try rig.select("notes.txt", in: table, model: model)
        try returnKey(window)
        let first = try await rig.sheet(on: window)
        try escape(first)
        try await rig.closed(window, model: model)
        #expect(rig.recorder.opened.isEmpty)
        #expect(rig.unlocks == 0)

        try returnKey(window)
        let sheet = try await rig.sheet(on: window)
        try rig.type(password, in: sheet)
        try submit(sheet)
        let copy = try rig.copy("open", "notes.txt")
        try await untilTrue(waitingFor: "the read-only copy to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [copy] }
        try await rig.closed(window, model: model)
        #expect(rig.unlocks == 1)
        #expect(try Data(contentsOf: copy) == FakeArchiveClient.bytes("notes.txt"))
        #expect(model.notice == nil)
    }

    @Test func oneUnlockCoversTheSession() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try Rig(entries: Self.entries, locked: ["cover.jpg", "notes.txt", "secret.txt"], password: password)
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: Self.rows)
        try rig.select("cover.jpg", in: table, model: model)
        try returnKey(window)
        let sheet = try await rig.sheet(on: window)
        try rig.type(password, in: sheet)
        try submit(sheet)
        let cover = try rig.copy("open", "cover.jpg")
        try await untilTrue(waitingFor: "the cover to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [cover] }
        try await rig.closed(window, model: model)

        try rig.select("notes.txt", in: table, model: model)
        try returnKey(window)
        let notes = try rig.copy("open", "notes.txt")
        try await untilTrue(waitingFor: "the notes to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [cover, notes] }
        #expect(window.attachedSheet == nil)
        #expect(model.asking == nil)
        #expect(rig.unlocks == 1)

        window.close()
        let (reopened, again, fresh) = try await rig.open(count: Self.rows)
        #expect(fresh !== model)
        #expect(fresh.asking == nil)
        try rig.select("secret.txt", in: again, model: fresh)
        try returnKey(reopened)
        let asked = try await rig.sheet(on: reopened)
        #expect(fresh.asking == archiveName)
        #expect(rig.unlocks == 0)
        try escape(asked)
        try await rig.closed(reopened, model: fresh)
        #expect(rig.recorder.opened == [cover, notes])
    }

    @Test func afterASaveAPreviewNeedsNoPasswordAgain() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try Rig(entries: Self.entries, locked: ["cover.jpg"], password: password, editing: [archiveName: .all])
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: Self.rows)
        try rig.select("cover.jpg", in: table, model: model)
        try space(window)
        let sheet = try await rig.sheet(on: window)
        try rig.type(password, in: sheet)
        try submit(sheet)
        let first = try rig.copy("preview", "cover.jpg")
        try await untilTrue(waitingFor: "the first preview; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed == [first] }
        try await rig.closed(window, model: model)
        try space(window)
        try #require(!rig.recorder.quickLookOpen)
        let opened = rig.archive.lastSession

        model.edits?.delete(["notes.txt"])
        try await untilTrue(waitingFor: "the delete; shown \(model.results.names)") {
            window.isDocumentEdited && !model.results.isPending && model.results.count == Self.rows - 1
        }
        model.save()
        try await untilTrue(waitingFor: "the save, the reopen and the unlock; locked \(model.locked)") {
            model.saving == nil && model.saveJob == nil && rig.archive.lastSession != opened && !model.results.isPending
                && model.summary != nil && !model.locked
        }
        #expect(rig.unlocks == 1)
        #expect(rig.unlocksOnMain == 0)
        #expect(!window.isDocumentEdited)

        var reopened: ThemedTable?
        try await untilTrue(waitingFor: "the reopened table") {
            window.contentView?.layoutSubtreeIfNeeded()
            reopened = window.contentView?.descendant(ThemedTable.self)
            return (reopened?.delegate as? ResultsTable.Coordinator)?.model === model.results && reopened?.numberOfRows == Self.rows
        }
        try rig.select("cover.jpg", in: try #require(reopened), model: model)
        try space(window)
        let second = try rig.copy("preview", "cover.jpg")
        try await untilTrue(waitingFor: "the second preview; refreshed \(rig.recorder.refreshed)") { rig.recorder.refreshed.count == 2 }
        #expect(rig.recorder.refreshed.last == second)
        #expect(window.attachedSheet == nil)
        #expect(model.asking == nil)
        #expect(rig.unlocks == 1)
        #expect(rig.recorder.refused == 0)
    }

    @Test func nestedArchiveAsksItsOwnPassword() async throws {
        let outer = "pw-outer-\(UUID().uuidString)"
        let inner = "pw-inner-\(UUID().uuidString)"
        let rig = try Rig(
            entries: [.init("inner.zip"), .init("outer.txt")], locked: ["outer.txt", "deep.txt"], password: outer,
            nested: ["inner.zip": [.init("deep.txt"), .init("plain.txt")]], passwords: ["inner.zip": inner]
        )
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: 2)
        try rig.select("outer.txt", in: table, model: model)
        try returnKey(window)
        let first = try await rig.sheet(on: window)
        try rig.type(outer, in: first)
        try submit(first)
        let outerCopy = try rig.copy("open", "outer.txt")
        try await untilTrue(waitingFor: "the outer entry to open; opened \(rig.recorder.opened)") { rig.recorder.opened == [outerCopy] }
        try await rig.closed(window, model: model)

        try rig.select("inner.zip", in: table, model: model)
        try returnKey(window)
        try await untilTrue(waitingFor: "the inner archive; depth \(model.depth)") { model.depth == 1 }
        let innerTable = try await rig.listed(window, model: model, count: 2)
        try await untilTrue(waitingFor: "the inner summary") { model.summary != nil }
        #expect(model.summary?.encrypted == true)
        #expect(model.locked)
        #expect(rig.unlocks == 0)

        try rig.select("deep.txt", in: innerTable, model: model)
        try returnKey(window)
        let second = try await rig.sheet(on: window)
        #expect(model.asking == "inner.zip")
        let title = String(localized: "Enter the password for “\(Bidi.name("inner.zip"))”.", table: "Archive")
        #expect(rig.names(in: second).contains(title))
        try rig.type(outer, in: second)
        try submit(second)
        try await untilTrue(waitingFor: "the outer password to fail inside; misses \(model.misses)") { model.misses == 1 && !model.unlocking }
        #expect(window.attachedSheet === second)

        try rig.type(inner, in: second)
        try submit(second)
        try await untilTrue(waitingFor: "the inner entry to open; opened \(rig.recorder.opened.count)") { rig.recorder.opened.count == 2 }
        try await rig.closed(window, model: model)
        #expect(rig.recorder.opened.last?.lastPathComponent == "deep.txt")
        #expect(rig.unlocks == 2)
        #expect(!model.locked)
    }

    @Test func dragOnALockedEntryOpensTheSheet() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try Rig(entries: Self.entries, locked: ["notes.txt"], password: password)
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: Self.rows)
        #expect(model.locked)
        #expect(try rig.drag("notes.txt", in: table, model: model) == nil)
        let sheet = try await rig.sheet(on: window)
        #expect(rig.archive.extracts.isEmpty)
        try rig.type(password, in: sheet)
        try submit(sheet)
        try await rig.closed(window, model: model)
        #expect(!model.locked)
        #expect(rig.archive.extracts.isEmpty)
        #expect(rig.recorder.opened.isEmpty)

        let provider = try #require(try rig.drag("notes.txt", in: table, model: model) as? NSFilePromiseProvider)
        let desktop = rig.folder.appending(path: "Desktop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let dropped = desktop.appending(path: "notes.txt")
        #expect(try await write(provider, to: dropped) == nil)
        #expect(try Data(contentsOf: dropped) == FakeArchiveClient.bytes("notes.txt"))
        #expect(window.attachedSheet == nil)
        #expect(model.notice == nil)
    }

    @Test func dragOnAPlainEntryInAMixedZipAsksNothing() async throws {
        let rig = try Rig(entries: Self.mixed, locked: Self.mixedLocked, password: "pw-\(UUID().uuidString)")
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: Self.mixedRows)
        #expect(model.locked)
        let desktop = rig.folder.appending(path: "Desktop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        for name in ["readme.txt", "docs"] {
            let provider = try #require(try rig.drag(name, in: table, model: model) as? NSFilePromiseProvider, "the \(name) drag")
            await drainMain()
            #expect(model.asking == nil, "after the \(name) drag")
            #expect(try await write(provider, to: desktop.appending(path: name)) == nil, "the \(name) drop")
        }
        for file in ["readme.txt", "docs/plain.txt"] {
            #expect(try Data(contentsOf: desktop.appending(path: file)) == FakeArchiveClient.bytes(file), "\(file)")
        }
        #expect(Set(rig.archive.extracts.flatMap(\.entries)) == ["readme.txt", "docs"])
        #expect(window.attachedSheet == nil)
        #expect(model.asking == nil)
        #expect(model.locked)
        #expect(model.notice == nil)
    }

    @Test func dragOnALockedEntryStillAsks() async throws {
        let rig = try Rig(entries: Self.mixed, locked: Self.mixedLocked, password: "pw-\(UUID().uuidString)")
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: Self.mixedRows)
        let session = rig.archive.lastSession
        _ = try #require(try rig.drag("readme.txt", in: table, model: model) as? NSFilePromiseProvider)
        await drainMain()
        #expect(model.asking == nil)

        #expect(try rig.drag("secret.txt", in: table, model: model) == nil)
        let sheet = try await rig.sheet(on: window)
        #expect(model.asking == archiveName)
        #expect(try rig.drag("vault", in: table, model: model) == nil)
        await drainMain()
        #expect(window.attachedSheet === sheet)
        #expect(rig.archive.extracts.isEmpty)
        try escape(sheet)
        try await rig.closed(window, model: model)
        #expect(model.locked)
        #expect(rig.archive.session(session)?.unlocks == 0)

        let again = try #require(try rig.drag("readme.txt", in: table, model: model) as? NSFilePromiseProvider)
        await drainMain()
        #expect(model.asking == nil)
        #expect(window.attachedSheet == nil)
        let desktop = rig.folder.appending(path: "Desktop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let dropped = desktop.appending(path: "readme.txt")
        #expect(try await write(again, to: dropped) == nil)
        #expect(try Data(contentsOf: dropped) == FakeArchiveClient.bytes("readme.txt"))

        #expect(try rig.drag("vault", in: table, model: model) == nil)
        let folderSheet = try await rig.sheet(on: window)
        #expect(model.asking == archiveName)
        try escape(folderSheet)
        try await rig.closed(window, model: model)
        #expect(rig.archive.extracts.map(\.entries) == [["readme.txt"]])
        #expect(model.notice == nil)
    }

    @Test func noNewDefaultsKeyAfterASession() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try Rig(entries: Self.entries, locked: ["notes.txt"], password: password)
        defer { rig.close() }
        let (window, table, model) = try await rig.open(count: Self.rows)
        let before = Set(rig.defaults.dictionaryRepresentation().keys)
        try rig.select("notes.txt", in: table, model: model)
        try returnKey(window)
        let sheet = try await rig.sheet(on: window)
        try rig.type("wrong-\(password)", in: sheet)
        try submit(sheet)
        try await untilTrue(waitingFor: "the wrong-password line") { model.misses == 1 && !model.unlocking }
        try rig.type(password, in: sheet)
        try submit(sheet)
        try await untilTrue(waitingFor: "the copy to open") { rig.recorder.opened.count == 1 }
        try await rig.closed(window, model: model)
        #expect(Set(rig.defaults.dictionaryRepresentation().keys) == before)
        window.close()

        for store in [rig.defaults, UserDefaults.standard] {
            let leaks = store.dictionaryRepresentation().filter { holds($0.key, password) || holds($0.value, password) }.map(\.key)
            #expect(leaks.isEmpty, "defaults keys holding the password: \(leaks)")
        }
        #expect(!holds(model.notice ?? "", password))
    }

    private static func image() -> ArchiveSummary {
        ArchiveSummary(path: "", format: "dmg", items: UInt64(rows), bytes: 0, encrypted: true, skipped: 0, problem: .passwordNeeded)
    }

    private func openImage(_ rig: Rig) async throws -> (NSWindow, ArchiveWindowModel, NSWindow) {
        rig.windows.open(rig.zip)
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let sheet = try await rig.sheet(on: window)
        #expect(controller.model.asking == archiveName)
        #expect(controller.model.problem == .passwordNeeded)
        #expect(controller.model.results.count == 0)
        let title = String(localized: "Enter the password for “\(Bidi.name(archiveName))”.", table: "Archive")
        #expect(rig.names(in: sheet).contains(title))
        return (window, controller.model, sheet)
    }

    @Test func encryptedDiskImageAsksAtOpenThenLists() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try Rig(entries: Self.entries, locked: [], password: password, summary: Self.image())
        defer { rig.close() }
        let (window, model, sheet) = try await openImage(rig)

        try rig.type("not it", in: sheet)
        try submit(sheet)
        try await untilTrue(waitingFor: "the wrong-password line; misses \(model.misses)") { model.misses == 1 && !model.unlocking }
        #expect(window.attachedSheet === sheet)
        #expect(model.asking == archiveName)
        #expect(rig.element(ArchivePasswordSheet.wrongID, in: sheet) != nil)
        #expect(model.results.count == 0)

        try rig.type(password, in: sheet)
        try submit(sheet)
        try await rig.closed(window, model: model)
        _ = try await rig.listed(window, model: model, count: Self.rows)
        try await untilTrue(waitingFor: "the unlocked summary") { model.summary != nil }
        #expect(model.summary?.problem == nil)
        #expect(model.problem == nil)
        #expect(Set(model.results.names) == Set(Self.entries.map(\.path)))
        #expect(rig.unlocks == 2)
        #expect(rig.unlocksOnMain == 0)
        #expect(model.notice == nil)
        #expect(rig.recorder.refused == 0)
        #expect(rig.element(ArchiveView.problemID, in: window) == nil)
    }

    @Test func cancelOnAnEncryptedDiskImageKeepsTheEncryptedMessage() async throws {
        let rig = try Rig(entries: Self.entries, locked: [], password: "pw-\(UUID().uuidString)", summary: Self.image())
        defer { rig.close() }
        let (window, model, sheet) = try await openImage(rig)

        try escape(sheet)
        try await rig.closed(window, model: model)
        #expect(model.problem == .passwordNeeded)
        #expect(model.results.count == 0)
        #expect(rig.unlocks == 0)
        try await untilTrue(waitingFor: "the encrypted message") { rig.element(ArchiveView.problemID, in: window) != nil }
        let shown = try #require(rig.element(ArchiveView.problemID, in: window))
        #expect(AXTree.names(of: shown).contains(ArchiveWindowModel.line(.passwordNeeded, name: archiveName)))
        try await pumpEvents(for: .milliseconds(100))
        #expect(window.attachedSheet == nil)
    }
}
