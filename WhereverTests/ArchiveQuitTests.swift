import AppKit
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private let entries: [FakeArchiveClient.Entry] = [.init("Trip", kind: .folder), .init("notes.txt", size: 2_048), .init("cover.jpg", size: 1_200)]

private func quitStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.archive-quit"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
}

private func views<T: NSView>(_ type: T.Type, in root: NSView?) -> [T] {
    guard let root else { return [] }
    return [root].compactMap { $0 as? T } + root.subviews.flatMap { views(type, in: $0) }
}

@MainActor
final class UnsavedArchives {
    final class Tally {
        var count = 0
    }

    static let first = "Photos 2024.zip"
    static let second = "Drafts.zip"
    static let original = Data("the original archive".utf8)

    let search = FakeSearchClient(hits: [])
    let archive: FakeArchiveClient
    let recorder = ActionRecorder()
    let windows: ArchiveWindows
    let folder: URL
    let real: String
    let activations: Tally

    init(passwords: [String: String] = [:], locked: Set<String> = []) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-quit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        real = ArchiveWindows.resolved(folder.path(percentEncoded: false))
        for name in [Self.first, Self.second] { try Self.original.write(to: folder.appending(path: name)) }
        archive = FakeArchiveClient(
            search: search, extensions: ["zip"], entries: entries, passwords: passwords, locked: locked, editing: [Self.first: .all, Self.second: .all]
        )
        let tally = Tally()
        activations = tally
        let defaults = quitStore()
        windows = ArchiveWindows(
            client: archive, index: IndexModel(client: search), actions: recorder.actions, defaults: defaults,
            columnPreferences: ColumnPreferences(defaults: defaults), cache: folder.appending(path: "Cache", directoryHint: .isDirectory),
            center: NotificationCenter(), access: { _ in ArchiveAccess() }, activate: { tally.count += 1 }
        )
    }

    func path(_ name: String) -> String { real + "/" + name }

    func bytes(_ name: String = first) -> Data? { try? Data(contentsOf: URL(filePath: path(name))) }

    func open(_ name: String = first) async throws -> ArchiveWindowController {
        windows.open(SearchHit(
            name: name, folder: folder.path(percentEncoded: false), size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast,
            opened: .distantPast, kind: .file
        ))
        let controller = try #require(ArchiveWindows.all.last)
        let model = controller.model
        try await untilTrue(waitingFor: "\(name) to list; shown \(model.results.names)") {
            !model.results.isPending && model.results.count == 3 && model.summary != nil && model.checked != nil
        }
        return controller
    }

    func edited(_ name: String = first) async throws -> (ArchiveWindowController, NSWindow) {
        let controller = try await open(name)
        let window = try #require(controller.window)
        let model = controller.model
        model.edits?.delete(["notes.txt"])
        #expect(window.undoManager?.groupingLevel == 0)
        try await untilTrue(waitingFor: "the delete in \(name); shown \(model.results.names)") {
            window.isDocumentEdited && !model.results.isPending && model.results.count == 2
        }
        return (controller, window)
    }

    func added(_ name: String = first) async throws -> (ArchiveWindowController, NSWindow) {
        let controller = try await open(name)
        let window = try #require(controller.window)
        let model = controller.model
        let file = URL(filePath: path("report.pdf"))
        try Data("a dropped file".utf8).write(to: file)
        model.add([file])
        try await untilTrue(waitingFor: "the add in \(name); shown \(model.results.names)") {
            window.isDocumentEdited && model.edits?.adding == nil && !model.busy && !model.results.isPending && model.results.count == 4
        }
        return (controller, window)
    }

    func password(_ password: String, on controller: ArchiveWindowController) async throws {
        let model = controller.model
        try await untilTrue(waitingFor: "the password sheet; asking \(model.asking ?? "nothing")") {
            model.asking != nil && controller.window?.attachedSheet != nil
        }
        model.submitPassword(password)
    }

    func question(on window: NSWindow) async throws -> NSWindow {
        try await untilTrue(waitingFor: "the unsaved question on \(window.title); sheet \(window.attachedSheet?.identifier?.rawValue ?? "none")") {
            window.attachedSheet?.identifier?.rawValue == ArchiveWindows.unsavedAlertID
        }
        return try #require(window.attachedSheet)
    }

    func button(_ id: String, in sheet: NSWindow) -> NSButton? {
        views(NSButton.self, in: sheet.contentView).first { $0.accessibilityIdentifier() == id }
    }

    func press(_ id: String, on window: NSWindow) async throws {
        let sheet = try await question(on: window)
        try #require(button(id, in: sheet), "no \(id) in the question").performClick(nil)
    }

    func type(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], on window: NSWindow) async throws {
        let sheet = try await question(on: window)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
        try #require(sheet.performKeyEquivalent(with: event), "no button in the question took \(characters.debugDescription)")
    }

    func pressReturn(on window: NSWindow) async throws {
        let sheet = try await question(on: window)
        let save = try #require(sheet.defaultButtonCell?.controlView as? NSButton, "the question has no default button")
        try #require(save.accessibilityIdentifier() == ArchiveWindows.unsavedSaveID, "Return's default button is not Save")
        save.performClick(nil)
    }

    func answered(_ window: NSWindow) async throws {
        try await untilTrue(waitingFor: "the question on \(window.title) to close") { window.attachedSheet?.identifier?.rawValue != ArchiveWindows.unsavedAlertID }
    }

    func closed(_ window: NSWindow) async throws {
        try await untilTrue(waitingFor: "\(window.title) to close") { !window.isVisible && !ArchiveWindows.all.contains { $0.window === window } }
    }

    func close() {
        for controller in ArchiveWindows.all {
            guard let window = controller.window else { continue }
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            window.close()
        }
        try? FileManager.default.removeItem(atPath: real)
    }
}

@MainActor
final class QuitProbe {
    let delegate = AppDelegate()
    var replies: [Bool] = []
    var terminations: [NSApplication.TerminateReply] = []

    init() {
        delegate.reply = { [weak self] in self?.replies.append($0) }
        delegate.terminate = { [weak self] in
            guard let self else { return }
            terminations.append(delegate.applicationShouldTerminate(NSApp))
        }
    }

    func replied(_ expected: [Bool]) async throws {
        try await untilTrue(waitingFor: "the replies \(expected); got \(replies)") { replies == expected }
    }
}

@Suite(.serialized) struct ArchiveQuitTests {
    private let save = String(localized: "Save", table: "Archive")
    private let cancel = String(localized: "Cancel", table: "Normal")
    private let dontSave = String(localized: "Don’t Save", table: "Archive")

    @Test func closeButtonOnAnEditedWindowAsks() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        window.performClose(nil)
        let sheet = try await rig.question(on: window)
        #expect(window.isVisible)
        #expect(rig.activations.count == 1)
        let texts = views(NSTextField.self, in: sheet.contentView).map(\.stringValue)
        #expect(texts.contains(String(localized: "Do you want to save the changes made to the archive “\(Bidi.name(UnsavedArchives.first))”?", table: "Archive")))
        #expect(texts.contains(String(localized: "Your changes will be lost if you don’t save them.", table: "Archive")))
        let saveButton = try #require(rig.button(ArchiveWindows.unsavedSaveID, in: sheet))
        let cancelButton = try #require(rig.button(ArchiveWindows.unsavedCancelID, in: sheet))
        let dontSaveButton = try #require(rig.button(ArchiveWindows.unsavedDontSaveID, in: sheet))
        #expect([saveButton.title, cancelButton.title, dontSaveButton.title] == [save, cancel, dontSave])
        #expect(sheet.defaultButtonCell === saveButton.cell)
        #expect(cancelButton.keyEquivalent == "\u{1b}" && cancelButton.keyEquivalentModifierMask.isEmpty)
        #expect(dontSaveButton.keyEquivalent == "d" && dontSaveButton.keyEquivalentModifierMask == .command)

        cancelButton.performClick(nil)
        try await rig.answered(window)
        #expect(window.isVisible && window.isDocumentEdited)
        #expect(rig.bytes() == UnsavedArchives.original)
    }

    @Test func saveInTheQuestionSavesThenCloses() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (controller, window) = try await rig.edited()
        let session = rig.archive.lastSession
        window.performClose(nil)
        try await rig.press(ArchiveWindows.unsavedSaveID, on: window)
        try await rig.closed(window)
        #expect(rig.bytes() == FakeArchiveClient.saved)
        #expect(rig.archive.session(session)?.writes.count == 1)
        #expect(rig.archive.created.count == 1)
        #expect(controller.model.saveJob == nil)
        #expect(!ArchiveEdits.unsaved)
    }

    @Test func saveInTheQuestionClosesOnceThePasswordIsGiven() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try UnsavedArchives(passwords: [UnsavedArchives.first: password], locked: ["cover.jpg"])
        defer { rig.close() }
        let (controller, window) = try await rig.added()
        let session = rig.archive.lastSession
        window.performClose(nil)
        try await rig.press(ArchiveWindows.unsavedSaveID, on: window)
        try await rig.password(password, on: controller)
        try await rig.closed(window)
        #expect(rig.bytes() == FakeArchiveClient.saved)
        #expect(rig.archive.session(session)?.writes.count == 2)
        #expect(rig.archive.session(session)?.unlocks == 1)
        #expect(!ArchiveEdits.unsaved)
    }

    @Test func dontSaveClosesAndDropsTheChanges() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        let session = rig.archive.lastSession
        window.performClose(nil)
        try await rig.type("d", code: 2, flags: .command, on: window)
        try await rig.closed(window)
        #expect(rig.bytes() == UnsavedArchives.original)
        #expect(rig.archive.session(session)?.writes.isEmpty == true)
        #expect(rig.archive.session(session)?.closes == 1)
        #expect(!ArchiveEdits.unsaved)
    }

    @Test func cancelKeepsTheWindowAndItsChanges() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (controller, window) = try await rig.edited()
        let session = rig.archive.lastSession
        window.performClose(nil)
        try await rig.type("\u{1b}", code: 53, on: window)
        try await rig.answered(window)
        try await pumpEvents(for: .milliseconds(50))
        #expect(window.isVisible && window.isDocumentEdited)
        #expect(controller.model.edits?.changes == [.delete(path: "notes.txt")])
        #expect(rig.archive.session(session)?.writes.isEmpty == true)
        #expect(rig.archive.session(session)?.closes == 0)
        #expect(rig.bytes() == UnsavedArchives.original)
        window.performClose(nil)
        _ = try await rig.question(on: window)
    }

    @Test func failedSaveInTheQuestionKeepsTheWindow() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (controller, window) = try await rig.edited()
        rig.archive.failWrites(with: .changed)
        window.performClose(nil)
        try await rig.press(ArchiveWindows.unsavedSaveID, on: window)
        try await untilTrue(waitingFor: "the save failure sheet") { window.attachedSheet?.identifier?.rawValue == ArchiveWindowModel.saveFailedID }
        try await pumpEvents(for: .milliseconds(50))
        #expect(window.isVisible && window.isDocumentEdited)
        #expect(controller.model.edits?.changes == [.delete(path: "notes.txt")])
        #expect(rig.bytes() == UnsavedArchives.original)
        #expect(ArchiveWindows.all.count == 1)
    }

    @Test func commandQThatQuitsAsksThenReplies() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        let probe = QuitProbe()
        #expect(probe.delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        _ = try await rig.question(on: window)
        #expect(probe.delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
        try await pumpEvents(for: .milliseconds(50))
        #expect(probe.replies.isEmpty)
        #expect(rig.activations.count == 1)
        try await rig.pressReturn(on: window)
        try await probe.replied([true])
        #expect(rig.bytes() == FakeArchiveClient.saved)
        #expect(ArchiveWindows.all.isEmpty)
    }

    @Test func quitThenSaveEndsTheAppOnceThePasswordIsGiven() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try UnsavedArchives(passwords: [UnsavedArchives.first: password], locked: ["cover.jpg"])
        defer { rig.close() }
        let (controller, window) = try await rig.added()
        let probe = QuitProbe()
        probe.delegate.terminate()
        #expect(probe.terminations == [.terminateLater])
        try await rig.pressReturn(on: window)
        try await rig.password(password, on: controller)
        try await probe.replied([true])
        #expect(rig.bytes() == FakeArchiveClient.saved)
        #expect(ArchiveWindows.all.isEmpty)
        #expect(!ArchiveEdits.unsaved)
    }

    @Test func aQuitCancelledAtTheQuestionKeepsWhereverAndTheNextQuitAsksAgain() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        let probe = QuitProbe()
        probe.delegate.terminate()
        #expect(probe.terminations == [.terminateLater])
        try await rig.type("\u{1b}", code: 53, on: window)
        try await probe.replied([false])
        #expect(window.isVisible && window.isDocumentEdited)

        probe.delegate.terminate()
        #expect(probe.terminations == [.terminateLater, .terminateLater])
        try await rig.press(ArchiveWindows.unsavedDontSaveID, on: window)
        try await probe.replied([false, true])
        #expect(rig.bytes() == UnsavedArchives.original)
    }

    @Test func twoEditedWindowsAskInTurnAndOneCancelStopsTheWalk() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, first) = try await rig.edited(UnsavedArchives.first)
        let (_, second) = try await rig.edited(UnsavedArchives.second)
        let probe = QuitProbe()
        probe.delegate.terminate()
        _ = try await rig.question(on: first)
        #expect(second.attachedSheet == nil)
        try await rig.press(ArchiveWindows.unsavedSaveID, on: first)
        try await rig.closed(first)
        _ = try await rig.question(on: second)
        #expect(rig.bytes(UnsavedArchives.first) == FakeArchiveClient.saved)
        try await rig.press(ArchiveWindows.unsavedCancelID, on: second)
        try await rig.answered(second)
        try await probe.replied([false])
        #expect(second.isVisible && second.isDocumentEdited)
        #expect(rig.bytes(UnsavedArchives.second) == UnsavedArchives.original)
        #expect(rig.activations.count == 2)
    }

    @Test func quitWithTwoEditedWindowsAsksForBothInWindowOrder() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, first) = try await rig.edited(UnsavedArchives.first)
        let (_, second) = try await rig.edited(UnsavedArchives.second)
        #expect(ArchiveWindows.all.compactMap(\.window) == [first, second])
        #expect(NSApp.orderedWindows.firstIndex(of: second) ?? .max < NSApp.orderedWindows.firstIndex(of: first) ?? .max)
        let probe = QuitProbe()
        probe.delegate.terminate()
        #expect(probe.terminations == [.terminateLater])
        _ = try await rig.question(on: first)
        #expect(second.attachedSheet == nil)
        try await rig.press(ArchiveWindows.unsavedSaveID, on: first)
        try await rig.closed(first)
        _ = try await rig.question(on: second)
        #expect(probe.replies.isEmpty)
        try await rig.press(ArchiveWindows.unsavedDontSaveID, on: second)
        try await rig.closed(second)
        try await probe.replied([true])
        #expect(rig.bytes(UnsavedArchives.first) == FakeArchiveClient.saved)
        #expect(rig.bytes(UnsavedArchives.second) == UnsavedArchives.original)
        #expect(ArchiveWindows.all.isEmpty)
        #expect(rig.activations.count == 2)
        #expect(!ArchiveEdits.unsaved)
    }

    @Test func quitBringsAnEditedWindowWithAnOpenSheetForwardBeforeItRefuses() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        let blocker = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        blocker.isReleasedWhenClosed = false
        window.beginSheet(blocker) { _ in }
        try await untilTrue(waitingFor: "the sheet on \(window.title)") { window.attachedSheet === blocker }
        let cover = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        defer { cover.close() }
        cover.orderFront(nil)
        #expect(NSApp.orderedWindows.firstIndex(of: cover) ?? .max < NSApp.orderedWindows.firstIndex(of: window) ?? .max)
        let before = rig.activations.count

        let probe = QuitProbe()
        probe.delegate.terminate()
        #expect(probe.terminations == [.terminateLater])
        try await probe.replied([false])
        #expect(rig.activations.count == before + 1)
        #expect(NSApp.orderedWindows.firstIndex(of: window) ?? .max < NSApp.orderedWindows.firstIndex(of: cover) ?? .max)
        #expect(window.isVisible && window.isDocumentEdited)
        #expect(window.attachedSheet === blocker)
        #expect(rig.recorder.refused == 1)
        window.endSheet(blocker)
    }

    @Test func windowsWithoutChangesCloseWithoutAQuestion() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        window.performClose(nil)
        try await rig.press(ArchiveWindows.unsavedCancelID, on: window)
        try await rig.answered(window)
        #expect(ArchiveEdits.unsaved)

        try #require(window.undoManager).undo()
        try await untilTrue(waitingFor: "the undo to clear Edited") { !window.isDocumentEdited }
        #expect(!ArchiveEdits.unsaved)
        #expect(QuitProbe().delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        window.performClose(nil)
        try await rig.closed(window)
        #expect(rig.activations.count == 1)
        #expect(rig.bytes() == UnsavedArchives.original)
    }
}
