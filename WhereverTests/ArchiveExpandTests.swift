import AppKit
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private let archiveName = "Photos 2024.zip"

private let photos: [FakeArchiveClient.Entry] = [
    .init("Trip", kind: .folder), .init("Family", kind: .folder), .init("notes.txt", size: 2_048), .init("cover.jpg", size: 1_200_000),
    .init("Trip/IMG_0001.HEIC", size: 10),
]

private let topLevel = ["Family", "Trip", "cover.jpg", "notes.txt"]

private func expandStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.archive-expand"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
}

private func real(_ url: URL?) -> String? {
    url.map { ($0.resolvingSymlinksInPath().path(percentEncoded: false) as NSString).standardizingPath }
}

func withRememberedFolder<T>(_ folder: URL, as identifier: String, _ body: () throws -> T) throws -> T {
    let key = "\(identifier) - NSOSPLastRootDirectory"
    let previous = UserDefaults.standard.object(forKey: key)
    defer {
        if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
    UserDefaults.standard.set(try folder.bookmarkData(), forKey: key)
    return try body()
}

func scratchFolder(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
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

@MainActor
private final class Rig {
    let search = FakeSearchClient(hits: [])
    let archive: FakeArchiveClient
    let index: IndexModel
    let recorder = ActionRecorder()
    let defaults = expandStore()
    let center = NotificationCenter()
    let windows: ArchiveWindows
    let folder: URL
    let destination: URL
    var panels: [NSOpenPanel] = []
    var answer: URL?

    init(entries: [FakeArchiveClient.Entry] = photos, nested: [String: [FakeArchiveClient.Entry]] = [:], passwords: [String: String] = [:]) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-expand-\(UUID().uuidString)", directoryHint: .isDirectory)
        destination = folder.appending(path: "Expanded", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: archiveName))
        archive = FakeArchiveClient(search: search, entries: entries, nested: nested, passwords: passwords)
        index = IndexModel(client: search)
        let preferences = ColumnPreferences(defaults: defaults)
        preferences.foldersFirst = true
        windows = ArchiveWindows(
            client: archive, index: index, actions: recorder.actions, defaults: defaults, columnPreferences: preferences,
            cache: folder.appending(path: "Cache", directoryHint: .isDirectory), center: center, activate: {}
        )
        answer = destination
    }

    var zip: SearchHit {
        SearchHit(
            name: archiveName, folder: folder.path(percentEncoded: false), size: 0, modified: Date(timeIntervalSince1970: 0),
            created: .distantPast, opened: .distantPast, kind: .file
        )
    }

    var leftovers: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false))) ?? []).sorted() }

    func close() {
        ArchiveWindows.all.forEach { $0.window?.close() }
        try? FileManager.default.removeItem(at: folder)
    }

    func table(_ window: NSWindow) -> ThemedTable? {
        window.contentView?.layoutSubtreeIfNeeded()
        return window.contentView?.descendant(ThemedTable.self)
    }

    func open(rows: Int = topLevel.count) async throws -> (NSWindow, ThemedTable, ArchiveWindowModel) {
        windows.open(zip)
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let model = controller.model
        model.choose = { [self] panel, done in
            panels.append(panel)
            done(answer)
        }
        try await untilTrue(waitingFor: "\(rows) rows and the summary; shown \(model.results.names)") {
            !model.results.isPending && table(window)?.numberOfRows == rows && model.canExpand
        }
        return (window, try #require(table(window)), model)
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

    func pressExpand(in window: NSWindow) async throws {
        #expect(AXTree.press(try await element(ArchivePathBar.expandID, in: window)))
    }

    func expanding(_ model: ArchiveWindowModel) async throws -> ArchiveJobID {
        try await untilTrue(waitingFor: "a running Expand job; running \(archive.running)") {
            if case .running? = model.expansion { return archive.running.count == 1 }
            return false
        }
        return try #require(archive.running.first)
    }

    func menu(_ table: ThemedTable, row: Int, in window: NSWindow) throws -> NSMenu {
        let rect = table.rect(ofRow: row)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        return try #require(table.menu(for: click))
    }
}

@Suite(.serialized) struct ArchiveExpandTests {
    @Test func contextMenuHasBothExpandItemsAfterCopyPath() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        let controller = try #require(ArchiveWindows.all.first)
        table.selectRowIndexes([2, 3], byExtendingSelection: false)
        let menu = try rig.menu(table, row: 3, in: window)
        #expect(table.selectedRowIndexes == [2, 3])
        #expect(menu.items.map(\.title) == [
            String(localized: "Open", table: "Results"), String(localized: "Show in Finder", table: "Results"),
            String(localized: "Quick Look", table: "Results"), String(localized: "Copy Path", table: "Results"), "",
            String(localized: "Expand Selected Items…", table: "Archive"), String(localized: "Expand Archive…", table: "Archive"),
        ])
        #expect(menu.items[4].isSeparatorItem)
        let selected = menu.items[5]
        let whole = menu.items[6]
        #expect(selected.identifier?.rawValue == ArchiveWindowModel.expandSelectedID)
        #expect(whole.identifier?.rawValue == ArchiveWindowModel.expandArchiveID)
        #expect(selected.action == #selector(ArchiveWindowController.expandSelected(_:)))
        #expect(whole.action == #selector(ArchiveWindowController.expandArchive(_:)))
        #expect(selected.target === controller && whole.target === controller)
        #expect(selected.keyEquivalent.isEmpty && whole.keyEquivalent.isEmpty)
        #expect(controller.validateMenuItem(selected) && controller.validateMenuItem(whole))

        #expect(NSApp.sendAction(try #require(selected.action), to: selected.target, from: selected))
        #expect(rig.panels.count == 1)
        #expect(rig.archive.expands == [
            FakeArchiveClient.Expand(entries: ["cover.jpg", "notes.txt"], folder: rig.destination.path(percentEncoded: false), whole: false),
        ])
        try await untilTrue(waitingFor: "the job to end") { model.expansion != nil && !model.expansion.isRunning }

        rig.archive.hold()
        #expect(NSApp.sendAction(try #require(whole.action), to: whole.target, from: whole))
        _ = try await rig.expanding(model)
        #expect(rig.archive.expands.last == FakeArchiveClient.Expand(entries: [], folder: rig.destination.path(percentEncoded: false), whole: true))
        #expect(!controller.validateMenuItem(selected) && !controller.validateMenuItem(whole))
        rig.archive.release()
    }

    @Test func panelStartsInTheArchivesFolderWithTheExpandButton() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        rig.answer = nil
        try await rig.pressExpand(in: window)
        try await untilTrue(waitingFor: "the Expand panel") { rig.panels.count == 1 }
        let panel = try #require(rig.panels.first)
        #expect(real(panel.directoryURL) == real(rig.folder))
        #expect(panel.prompt == String(localized: "Expand", table: "Archive"))
        #expect(panel.message == String(localized: "Choose where to expand “\(Bidi.name(archiveName))”.", table: "Archive"))
        #expect(panel.canChooseDirectories && !panel.canChooseFiles && panel.canCreateDirectories && !panel.allowsMultipleSelection)
        #expect(panel.identifier?.rawValue == ArchiveWindowModel.panelID)

        try await pumpEvents(for: .milliseconds(50))
        #expect(rig.archive.expands.isEmpty)
        #expect(model.expansion == nil)
        #expect(rig.recorder.refused == 0)
        try await rig.pressExpand(in: window)
        try await untilTrue(waitingFor: "the panel to open again") { rig.panels.count == 2 }
        #expect(rig.archive.expands.isEmpty)
    }

    @Test func expandPanelOpensInTheGivenFolderWhateverItRemembered() throws {
        let remembered = try scratchFolder("expand-remembered")
        let wanted = try scratchFolder("expand-wanted")
        defer { try? FileManager.default.removeItem(at: remembered); try? FileManager.default.removeItem(at: wanted) }
        let panel = try withRememberedFolder(remembered, as: ArchiveWindowModel.panelID) {
            ArchiveWindowModel.expandPanel(name: archiveName, in: wanted)
        }
        #expect(real(panel.directoryURL) == real(wanted))
    }

    @Test func progressShowsAndStopCancels() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        rig.archive.hold()
        try await rig.pressExpand(in: window)
        let job = try await rig.expanding(model)
        #expect(model.expansion == .running(name: archiveName, fraction: nil))
        #expect(rig.leftovers == [".Wherever-fake-\(job.rawValue)"])
        let text = try await rig.element(ArchiveStatusBar.expandingID, in: window)
        #expect(AXTree.names(of: text).contains(String(localized: "Expanding “\(Bidi.name(archiveName))”…", table: "Archive")))
        _ = try await rig.element(ArchiveStatusBar.progressID, in: window)
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "the Expand button to turn off") {
            AXTree.element(ArchivePathBar.expandID, in: content).flatMap(AXTree.isEnabled) == false
        }

        rig.archive.progress(50, of: 200)
        try await untilTrue(waitingFor: "a determinate bar; shown \(String(describing: model.expansion))") {
            model.expansion == .running(name: archiveName, fraction: 0.25)
        }

        #expect(AXTree.press(try await rig.element(ArchiveStatusBar.expandingStopID, in: window)))
        try await untilTrue(waitingFor: "the job to stop") { rig.archive.cancels == [job] && model.expansion == nil }
        #expect(rig.leftovers.isEmpty)
        try await rig.gone(ArchiveStatusBar.expandingID, in: window)
        _ = try await rig.element(ArchiveStatusBar.itemsID, in: window)
        try await pumpEvents(for: .milliseconds(100))
        #expect(model.expansion == nil)
        #expect(rig.recorder.refused == 0)

        try await rig.pressExpand(in: window)
        let again = try await rig.expanding(model)
        #expect(again != job)
        #expect(rig.archive.expands.count == 2)
        rig.archive.release()
    }

    @Test func doneShowsTheCountAndShowInFinderRevealsTheWrittenItems() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        rig.archive.expands(FakeArchiveClient.Expanded(written: ["Photos 2024"], items: 120, skipped: 3))
        try await rig.pressExpand(in: window)
        let done = try await rig.element(ArchiveStatusBar.expandedID, in: window)
        #expect(AXTree.names(of: done).contains(String(localized: "Expanded \(120) items", table: "Archive")))
        #expect(String(localized: "Expanded \(1) items", table: "Archive") != String(localized: "Expanded \(120) items", table: "Archive"))
        let skipped = try await rig.element(ArchiveStatusBar.expandedSkippedID, in: window)
        #expect(AXTree.names(of: skipped).contains(String(localized: "\(3) items skipped", table: "Archive")))
        let help: String? = AXTree.value("accessibilityHelp", of: skipped)
        #expect(help == String(localized: "Items whose names or links point outside the archive, device files, and items Wherever couldn’t expand.", table: "Archive"))
        #expect(rig.leftovers == ["Photos 2024"])

        #expect(AXTree.press(try await rig.element(ArchiveStatusBar.expandedRevealID, in: window)))
        try await untilTrue(waitingFor: "the reveal") { rig.recorder.reveals == 1 }
        #expect(rig.recorder.revealed.map { real($0) } == [real(rig.destination.appending(path: "Photos 2024"))])

        table.selectRowIndexes([1], byExtendingSelection: false)
        table.openSelected(nil)
        try await untilTrue(waitingFor: "the Trip folder") { model.folder == "Trip" && !model.results.isPending }
        try await rig.gone(ArchiveStatusBar.expandedID, in: window)
        #expect(model.expansion == nil)
    }

    @Test func closeWhileExpandingAsksAndContinueKeepsTheWindow() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        rig.archive.hold()
        try await rig.pressExpand(in: window)
        let job = try await rig.expanding(model)
        window.performClose(nil)
        try await untilTrue(waitingFor: "the stop expanding alert") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        #expect(sheet.identifier?.rawValue == ArchiveWindows.stopAlertID)
        let texts = views(NSTextField.self, in: sheet.contentView).map(\.stringValue)
        #expect(texts.contains(String(localized: "Stop expanding “\(Bidi.name(archiveName))”?", table: "Archive")))
        #expect(texts.contains(String(localized: "The items expanded so far will be removed.", table: "Archive")))
        let buttons = views(NSButton.self, in: sheet.contentView).filter { !$0.isHidden && !$0.title.isEmpty }
        #expect(Set(buttons.map(\.title)) == [String(localized: "Continue", table: "Archive"), String(localized: "Stop Expanding", table: "Archive")])
        let keep = try #require(buttons.first { $0.title == String(localized: "Continue", table: "Archive") })
        let stop = try #require(buttons.first { $0.title == String(localized: "Stop Expanding", table: "Archive") })
        #expect(sheet.defaultButtonCell === keep.cell)
        #expect(sheet.defaultButtonCell !== stop.cell)

        try #require(sheet.defaultButtonCell?.controlView as? NSButton).performClick(nil)
        try await untilTrue(waitingFor: "the alert to close") { window.attachedSheet == nil }
        try await pumpEvents(for: .milliseconds(50))
        #expect(window.isVisible)
        #expect(ArchiveWindows.all.count == 1)
        #expect(rig.archive.cancels.isEmpty)
        #expect(rig.archive.running == [job])
        #expect(model.expansion == .running(name: archiveName, fraction: nil))
        #expect(rig.archive.session(rig.archive.lastSession)?.closes == 0)
        rig.archive.release()
        try await untilTrue(waitingFor: "the job to end") { model.expansion != nil && !model.expansion.isRunning }
        window.performClose(nil)
        #expect(!window.isVisible)
    }

    @Test func escapeInTheStopExpandingAlertPressesContinueAndBothButtonsCarryIDs() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        rig.archive.hold()
        try await rig.pressExpand(in: window)
        let job = try await rig.expanding(model)
        window.performClose(nil)
        try await untilTrue(waitingFor: "the stop expanding alert") { window.attachedSheet?.identifier?.rawValue == ArchiveWindows.stopAlertID }
        let sheet = try #require(window.attachedSheet)
        let buttons = views(NSButton.self, in: sheet.contentView).filter { !$0.isHidden && !$0.title.isEmpty }
        let keep = try #require(buttons.first { $0.accessibilityIdentifier() == ArchiveWindows.stopContinueID })
        let stop = try #require(buttons.first { $0.accessibilityIdentifier() == ArchiveWindows.stopStopID })
        #expect(keep.title == String(localized: "Continue", table: "Archive"))
        #expect(stop.title == String(localized: "Stop Expanding", table: "Archive"))
        #expect(sheet.defaultButtonCell === keep.cell)
        #expect(keep.keyEquivalent == "\r")

        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        #expect(sheet.performKeyEquivalent(with: escape))
        try await untilTrue(waitingFor: "the alert to close") { window.attachedSheet == nil }
        try await pumpEvents(for: .milliseconds(50))
        #expect(window.isVisible)
        #expect(rig.archive.cancels.isEmpty)
        #expect(rig.archive.running == [job])
        #expect(model.expansion == .running(name: archiveName, fraction: nil))
        rig.archive.release()
        try await untilTrue(waitingFor: "the job to end") { model.expansion != nil && !model.expansion.isRunning }
        window.performClose(nil)
        #expect(!window.isVisible)
    }

    @Test func closeWhileExpandingStopCancels() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        let session = rig.archive.lastSession
        rig.archive.hold()
        try await rig.pressExpand(in: window)
        let job = try await rig.expanding(model)
        window.performClose(nil)
        try await untilTrue(waitingFor: "the stop expanding alert") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let stop = try #require(views(NSButton.self, in: sheet.contentView).first { $0.title == String(localized: "Stop Expanding", table: "Archive") })
        stop.performClick(nil)
        try await untilTrue(waitingFor: "the window to close") { !window.isVisible && ArchiveWindows.all.isEmpty }
        #expect(rig.archive.cancels == [job])
        #expect(rig.archive.running.isEmpty)
        #expect(rig.leftovers.isEmpty)
        #expect(rig.archive.session(session)?.closes == 1)
        #expect(model.expansion == nil)
    }
    @Test func unsavedQuestionComesBeforeStopExpanding() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        model.edits?.delete(["notes.txt"])
        try await untilTrue(waitingFor: "the delete to list; shown \(model.results.names)") {
            window.isDocumentEdited && !model.results.isPending && model.results.count == topLevel.count - 1 && model.canExpand
        }
        rig.archive.hold()
        try await rig.pressExpand(in: window)
        let job = try await rig.expanding(model)

        func button(_ id: String) -> NSButton? { views(NSButton.self, in: window.attachedSheet?.contentView).first { $0.accessibilityIdentifier() == id } }
        window.performClose(nil)
        try await untilTrue(waitingFor: "a question") { window.attachedSheet != nil }
        #expect(window.attachedSheet?.identifier?.rawValue == ArchiveWindows.unsavedAlertID)
        try #require(button(ArchiveWindows.unsavedCancelID)).performClick(nil)
        try await untilTrue(waitingFor: "the question to close") { window.attachedSheet == nil }
        try await pumpEvents(for: .milliseconds(50))
        #expect(window.attachedSheet == nil)
        #expect(window.isVisible && window.isDocumentEdited)
        #expect(rig.archive.cancels.isEmpty)
        #expect(model.expansion == .running(name: archiveName, fraction: nil))

        window.performClose(nil)
        try await untilTrue(waitingFor: "the unsaved question") { window.attachedSheet?.identifier?.rawValue == ArchiveWindows.unsavedAlertID }
        try #require(button(ArchiveWindows.unsavedDontSaveID)).performClick(nil)
        try await untilTrue(waitingFor: "the stop expanding alert next") { window.attachedSheet?.identifier?.rawValue == ArchiveWindows.stopAlertID }
        #expect(window.isVisible)
        #expect(rig.archive.cancels.isEmpty)
        let stop = try #require(views(NSButton.self, in: window.attachedSheet?.contentView).first { $0.title == String(localized: "Stop Expanding", table: "Archive") })
        stop.performClick(nil)
        try await untilTrue(waitingFor: "the window to close") { !window.isVisible && ArchiveWindows.all.isEmpty }
        #expect(rig.archive.cancels == [job])
        #expect(rig.leftovers.isEmpty)
        #expect(!ArchiveEdits.unsaved)
    }

    private func editedAndExpanding(_ rig: Rig) async throws -> (NSWindow, ArchiveWindowModel, ArchiveJobID) {
        let (window, _, model) = try await rig.open()
        model.edits?.delete(["notes.txt"])
        try await untilTrue(waitingFor: "the delete to list; shown \(model.results.names)") {
            window.isDocumentEdited && !model.results.isPending && model.results.count == topLevel.count - 1 && model.canExpand
        }
        rig.archive.hold()
        try await rig.pressExpand(in: window)
        return (window, model, try await rig.expanding(model))
    }

    private func saveInTheQuestion(_ window: NSWindow) async throws {
        try await untilTrue(waitingFor: "the unsaved question") { window.attachedSheet?.identifier?.rawValue == ArchiveWindows.unsavedAlertID }
        let save = views(NSButton.self, in: window.attachedSheet?.contentView).first { $0.accessibilityIdentifier() == ArchiveWindows.unsavedSaveID }
        try #require(save).performClick(nil)
        try await untilTrue(waitingFor: "the question to close") { window.attachedSheet == nil }
    }

    @Test func saveInTheQuestionWaitsForTheExpandThenSavesAndCloses() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model, _) = try await editedAndExpanding(rig)
        let archive = rig.folder.appending(path: archiveName)

        window.performClose(nil)
        try await saveInTheQuestion(window)
        try await pumpEvents(for: .milliseconds(100))
        #expect(rig.recorder.refused == 0)
        #expect(window.isVisible && window.isDocumentEdited)
        #expect(model.saving == nil && model.waitingSave != nil)
        #expect(model.expansion == .running(name: archiveName, fraction: nil))
        #expect(rig.archive.cancels.isEmpty)
        #expect(try Data(contentsOf: archive).isEmpty)
        #expect(ArchiveEdits.unsaved)

        window.performClose(nil)
        try await pumpEvents(for: .milliseconds(100))
        #expect(window.attachedSheet == nil)
        #expect(window.isVisible)
        #expect(rig.recorder.refused == 0)

        rig.archive.release()
        try await untilTrue(waitingFor: "the expand, the save, then the close") { ArchiveWindows.all.isEmpty && !window.isVisible }
        #expect(rig.archive.cancels.isEmpty)
        #expect(try Data(contentsOf: archive) == FakeArchiveClient.saved)
        #expect(rig.archive.opened.count == 2)
        #expect(rig.recorder.refused == 0)
        #expect(!ArchiveEdits.unsaved)
    }

    @Test func stopExpandingWhileSaveWaitsSavesAndCloses() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model, job) = try await editedAndExpanding(rig)
        let archive = rig.folder.appending(path: archiveName)

        window.performClose(nil)
        try await saveInTheQuestion(window)
        try await pumpEvents(for: .milliseconds(50))
        #expect(model.waitingSave != nil)
        #expect(window.isVisible)

        let stop = try await rig.element(ArchiveStatusBar.expandingStopID, in: window)
        #expect(AXTree.press(stop))
        try await untilTrue(waitingFor: "the save to start after the stop") { model.saving != nil && model.waitingSave == nil }
        #expect(rig.archive.cancels == [job])
        #expect(window.isVisible)
        rig.archive.release()
        try await untilTrue(waitingFor: "the save, then the close") { ArchiveWindows.all.isEmpty && !window.isVisible }
        #expect(rig.archive.cancels == [job])
        #expect(try Data(contentsOf: archive) == FakeArchiveClient.saved)
        #expect(rig.recorder.refused == 0)
        #expect(!ArchiveEdits.unsaved)
    }

    @Test func undoWhileTheSaveWaitsClosesWithNothingToSave() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model, _) = try await editedAndExpanding(rig)
        let archive = rig.folder.appending(path: archiveName)

        window.performClose(nil)
        try await saveInTheQuestion(window)
        try await pumpEvents(for: .milliseconds(50))
        #expect(model.waitingSave != nil)
        let undo = try #require(window.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        try await untilTrue(waitingFor: "the undo to list every row") {
            !window.isDocumentEdited && !model.results.isPending && model.results.count == topLevel.count
        }
        #expect(window.isVisible)

        rig.archive.release()
        try await untilTrue(waitingFor: "the close with nothing to save") { ArchiveWindows.all.isEmpty && !window.isVisible }
        #expect(try Data(contentsOf: archive).isEmpty)
        #expect(rig.archive.opened.count == 1)
        #expect(rig.recorder.refused == 0)
        #expect(!ArchiveEdits.unsaved)
    }

    @Test func quitWhileTheSaveWaitsAnswersOnceTheSaveEnds() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model, _) = try await editedAndExpanding(rig)
        var answers: [Bool] = []
        ArchiveEdits.resolve { answers.append($0) }
        try await saveInTheQuestion(window)
        try await pumpEvents(for: .milliseconds(100))
        #expect(answers.isEmpty)
        #expect(model.waitingSave != nil)
        #expect(window.isVisible)
        #expect(rig.recorder.refused == 0)

        rig.archive.release()
        try await untilTrue(waitingFor: "one answer after the save") { answers == [true] }
        try await untilTrue(waitingFor: "the window to close") { !window.isVisible }
        #expect(try Data(contentsOf: rig.folder.appending(path: archiveName)) == FakeArchiveClient.saved)
        try await pumpEvents(for: .milliseconds(50))
        #expect(answers == [true])
        #expect(!ArchiveEdits.unsaved)
    }

    @Test func fileMenuItemExpandsTheKeyArchiveWindowAndBeepsElsewhere() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        rig.answer = nil
        var beeps = 0
        ArchiveWindows.expandArchive(in: window) { beeps += 1 }
        #expect(beeps == 0)
        #expect(rig.panels.count == 1)

        let bare = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        bare.isReleasedWhenClosed = false
        defer { bare.close() }
        ArchiveWindows.expandArchive(in: bare) { beeps += 1 }
        #expect(beeps == 1)
        ArchiveWindows.expandArchive(in: nil) { beeps += 1 }
        #expect(beeps == 2)
        #expect(rig.panels.count == 1)

        rig.answer = rig.destination
        rig.archive.hold()
        ArchiveWindows.expandArchive(in: window) { beeps += 1 }
        _ = try await rig.expanding(model)
        #expect(rig.archive.expands == [FakeArchiveClient.Expand(entries: [], folder: rig.destination.path(percentEncoded: false), whole: true)])
        ArchiveWindows.expandArchive(in: window) { beeps += 1 }
        #expect(rig.recorder.refused == 1)
        #expect(rig.panels.count == 2)
        #expect(beeps == 2)
        rig.archive.release()

        let showContents = String(localized: "Show Archive Contents", table: "Results")
        let title = String(localized: "Expand Archive…", table: "Archive")
        let file = try #require(holdingMenu(showContents), "the main menu holds no \(showContents) item")
        let index = try #require(file.items.firstIndex { $0.title == title }, "the File menu holds no \(title) item")
        try #require(index > 0)
        #expect(file.items[index - 1].title == showContents)
        #expect(file.items[index].keyEquivalent.isEmpty)
        #expect(file.items[index].isEnabled)
    }

    @Test func quitCancelsWithoutAnAlert() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        rig.archive.hold()
        try await rig.pressExpand(in: window)
        let job = try await rig.expanding(model)
        #expect(!rig.leftovers.isEmpty)
        rig.center.post(name: NSApplication.willTerminateNotification, object: NSApp)
        try await untilTrue(waitingFor: "the quit to cancel the job") { rig.archive.cancels == [job] }
        #expect(rig.leftovers.isEmpty)
        #expect(rig.archive.running.isEmpty)
        #expect(model.expansion == nil)
        try await pumpEvents(for: .milliseconds(50))
        #expect(window.attachedSheet == nil)
        #expect(window.isVisible)
    }

    @Test func closeAllWhileExpandingCancelsWithoutAnAlert() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        let session = rig.archive.lastSession
        rig.archive.hold()
        try await rig.pressExpand(in: window)
        let job = try await rig.expanding(model)
        window.close()
        #expect(window.attachedSheet == nil)
        #expect(!window.isVisible)
        #expect(ArchiveWindows.all.isEmpty)
        #expect(rig.archive.cancels == [job])
        #expect(rig.leftovers.isEmpty)
        #expect(rig.archive.session(session)?.closes == 1)

        let (again, _, reopened) = try await rig.open()
        #expect(again !== window)
        #expect(rig.archive.opened.count == 2)
        #expect(reopened.expansion == nil)
        #expect(reopened.canExpand)
    }

    @Test func aPasswordQuestionRunsTheSameExpandAgain() async throws {
        let password = "pw-\(UUID().uuidString)"
        let rig = try Rig(passwords: [archiveName: password])
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        rig.archive.expands(FakeArchiveClient.Expanded(problem: .passwordNeeded))
        try await rig.pressExpand(in: window)
        try await untilTrue(waitingFor: "the password question") { model.asking == archiveName }
        #expect(model.expansion == nil)
        rig.archive.expands(FakeArchiveClient.Expanded(written: ["Photos 2024"], items: 8))
        model.submitPassword(password)
        try await untilTrue(waitingFor: "the second Expand to end") { model.expansion != nil && !model.expansion.isRunning }
        #expect(model.asking == nil)
        #expect(rig.panels.count == 1)
        let expand = FakeArchiveClient.Expand(entries: [], folder: rig.destination.path(percentEncoded: false), whole: true)
        #expect(rig.archive.expands == [expand, expand])
        #expect(model.expansion == .done(items: 8, written: [rig.destination.appending(path: "Photos 2024").path(percentEncoded: false)], skipped: 0))
    }
    @Test func leavingANestedArchiveWhileItExpandsStopsItsJob() async throws {
        let rig = try Rig(
            entries: [.init("inner.zip", size: 32), .init("notes.txt")], nested: ["inner.zip": [.init("a.txt"), .init("b.txt"), .init("c.txt")]]
        )
        defer { rig.close() }
        let (window, table, model) = try await rig.open(rows: 2)
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.openSelected(nil)
        try await untilTrue(waitingFor: "the inner archive; depth \(model.depth), shown \(model.results.names)") {
            model.depth == 1 && !model.results.isPending && model.results.count == 3 && model.canExpand
        }
        rig.archive.hold()
        try await rig.pressExpand(in: window)
        let job = try await rig.expanding(model)
        #expect(model.expansion == .running(name: "inner.zip", fraction: nil))
        #expect(real(rig.panels.last?.directoryURL) == real(rig.folder))

        model.goEnclosing()
        try await untilTrue(waitingFor: "the outer archive") { model.depth == 0 && !model.results.isPending && model.results.count == 2 }
        #expect(rig.archive.cancels == [job])
        #expect(model.expansion == nil)
        #expect(rig.leftovers.isEmpty)
        try await pumpEvents(for: .milliseconds(100))
        #expect(model.expansion == nil)
        #expect(rig.recorder.refused == 0)
    }
}

private extension Optional where Wrapped == ArchiveWindowModel.Expansion {
    var isRunning: Bool {
        if case .running? = self { return true }
        return false
    }
}
