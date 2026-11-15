import AppKit
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private let archiveName = "Example.pkg"

private let entries: [FakeArchiveClient.Entry] = [
    .init("Distribution"), .init("Resources", kind: .folder), .init("Resources/en.lproj", kind: .folder), .init("tool.pkg", kind: .folder),
    .init("tool.pkg/Bom"), .init("tool.pkg/PackageInfo"), .init("tool.pkg/Payload", kind: .folder), .init("tool.pkg/Scripts", kind: .folder),
    .init("tool.pkg/Payload/Applications", kind: .folder), .init("tool.pkg/Payload/Applications/Tool.app", kind: .folder),
    .init("tool.pkg/Payload/readme.txt", size: 10), .init("tool.pkg/Scripts/postinstall", size: 10),
]

private let componentRows = ["Payload", "Scripts", "Bom", "PackageInfo"]

private func summary(items: UInt64 = 8, skipped: UInt64 = 0, problem: ArchiveProblem? = nil) -> ArchiveSummary {
    ArchiveSummary(path: "", format: "pkg", items: items, bytes: 20, encrypted: false, skipped: skipped, problem: problem)
}

private func pkgStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.archive-pkg"
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

private func returnKey(_ window: NSWindow) throws { try key(window, "\r", code: 36) }

private func commandUp(_ window: NSWindow) throws {
    try key(window, String(Character(NSEvent.SpecialKey.upArrow.unicodeScalar)), code: 126, flags: [.command, .numericPad, .function])
}

@MainActor
private final class Rig {
    let search = FakeSearchClient(hits: [])
    let archive: FakeArchiveClient
    let index: IndexModel
    let recorder = ActionRecorder()
    let defaults = pkgStore()
    let windows: ArchiveWindows
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-pkg-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: archiveName))
        archive = FakeArchiveClient(search: search, extensions: ["zip", "pkg"], entries: entries, summary: summary())
        index = IndexModel(client: search)
        let preferences = ColumnPreferences(defaults: defaults)
        preferences.foldersFirst = true
        windows = ArchiveWindows(
            client: archive, index: index, actions: recorder.actions, defaults: defaults, columnPreferences: preferences,
            cache: folder.appending(path: "Cache", directoryHint: .isDirectory)
        )
    }

    var pkg: SearchHit {
        SearchHit(
            name: archiveName, folder: folder.path(percentEncoded: false), size: 0, modified: Date(timeIntervalSince1970: 0),
            created: .distantPast, opened: .distantPast, kind: .file
        )
    }

    var browses: [String] { archive.session(archive.lastSession)?.browses ?? [] }

    func close() {
        ArchiveWindows.all.forEach { $0.window?.close() }
        try? FileManager.default.removeItem(at: folder)
    }

    func table(_ window: NSWindow) -> ThemedTable? {
        window.contentView?.layoutSubtreeIfNeeded()
        return window.contentView?.descendant(ThemedTable.self)
    }

    func listed(_ window: NSWindow, model: ArchiveWindowModel, count: Int) async throws -> ThemedTable {
        try await untilTrue(waitingFor: "\(count) rows with the first selected; shown \(model.results.names)") {
            guard let table = table(window) else { return false }
            return !model.results.isPending && model.selection == nil && table.numberOfRows == count && table.selectedRowIndexes == [0]
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

    func enter(_ name: String, in window: NSWindow, model: ArchiveWindowModel) throws {
        let table = try #require(table(window))
        let row = try #require(model.results.names.firstIndex(of: name), "\(name) among \(model.results.names)")
        table.selectRowIndexes([row], byExtendingSelection: false)
        try returnKey(window)
    }

    func component() async throws -> (NSWindow, ArchiveWindowModel) {
        windows.open(pkg)
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let model = controller.model
        _ = try await listed(window, model: model, count: 3)
        try await untilTrue(waitingFor: "the summary") { model.summary != nil }
        try enter("tool.pkg", in: window, model: model)
        _ = try await listed(window, model: model, count: componentRows.count)
        #expect(model.results.names == componentRows)
        #expect(!model.reading)
        return (window, model)
    }

    func expanding(_ name: String, in window: NSWindow, model: ArchiveWindowModel) async throws {
        archive.holdBrowse("tool.pkg/" + name)
        try enter(name, in: window, model: model)
        try await untilTrue(waitingFor: "the held expansion of \(name)") { model.reading && self.archive.waitingBrowses == 1 }
        #expect(model.folder == "tool.pkg/" + name)
        let activity = try await element(ArchiveStatusBar.activityID, in: window)
        #expect(AXTree.names(of: activity).contains(String(localized: "Reading “\(Bidi.name(archiveName))”…", table: "Archive")))
        #expect(AXTree.names(of: try await element(ArchiveStatusBar.stopID, in: window)).contains(String(localized: "Stop", table: "Normal")))
    }
}

@Suite(.serialized) struct ArchivePkgTests {
    @Test func stopWhileExpandingStaysAtThePkgLevel() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.component()
        try await rig.expanding("Scripts", in: window, model: model)

        #expect(AXTree.press(try await rig.element(ArchiveStatusBar.stopID, in: window)))
        let table = try await rig.listed(window, model: model, count: componentRows.count)
        #expect(model.folder == "tool.pkg")
        #expect(model.results.names == componentRows)
        #expect(window.firstResponder === table)
        #expect(!model.reading)
        #expect(window.isVisible)
        #expect(ArchiveWindows.all.count == 1)
        #expect(model.notice == nil)
        #expect(rig.browses == ["tool.pkg", "tool.pkg/Scripts", "tool.pkg"])
    }

    @Test func waitingShowsTheExpandedRowsAndEndsReading() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.component()
        try await rig.expanding("Payload", in: window, model: model)

        rig.archive.report(summary(items: 40, skipped: 2))
        rig.archive.releaseBrowse()
        _ = try await rig.listed(window, model: model, count: 2)
        #expect(model.results.names == ["Applications", "readme.txt"])
        #expect(!model.reading)
        #expect(model.summary?.items == 40)
        #expect(model.notice == nil)
        let skipped = try await rig.element(ArchiveStatusBar.skippedID, in: window)
        #expect(AXTree.names(of: skipped).contains(String(localized: "\(2) items skipped", table: "Archive")))

        rig.archive.holdBrowse("tool.pkg/Payload/Applications")
        try rig.enter("Applications", in: window, model: model)
        try await untilTrue(waitingFor: "the held listing of Applications") { rig.archive.waitingBrowses == 1 }
        #expect(!model.reading)
        rig.archive.releaseBrowse()
        _ = try await rig.listed(window, model: model, count: 1)
        #expect(model.results.names == ["Tool.app"])
    }

    @Test func enteringAgainAfterAStopReadsAgain() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.component()
        try await rig.expanding("Scripts", in: window, model: model)
        #expect(AXTree.press(try await rig.element(ArchiveStatusBar.stopID, in: window)))
        _ = try await rig.listed(window, model: model, count: componentRows.count)
        #expect(!model.reading)

        try await rig.expanding("Scripts", in: window, model: model)
        rig.archive.releaseBrowse()
        _ = try await rig.listed(window, model: model, count: 1)
        #expect(model.results.names == ["postinstall"])
        #expect(!model.reading)
        #expect(rig.browses == ["tool.pkg", "tool.pkg/Scripts", "tool.pkg", "tool.pkg/Scripts"])
    }

    @Test func noSpaceAfterEnteringNamesItAndKeepsTheWindow() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.component()
        try await rig.expanding("Payload", in: window, model: model)

        let problem = ArchiveProblem.noSpace(needed: 2_000_000_000, volume: "Macintosh HD")
        let line = ArchiveWindowModel.line(problem, name: archiveName)
        rig.archive.report(summary(problem: problem))
        rig.archive.releaseBrowse(empty: true)
        try await untilTrue(waitingFor: "the no-space line; reading \(model.reading)") { !model.reading && model.notice != nil }
        #expect(model.notice == line)
        #expect(model.problem == nil)
        #expect(window.isVisible)
        #expect(rig.table(window) != nil)
        #expect(AXTree.names(of: try await rig.element(ArchiveStatusBar.noticeID, in: window)).contains(line))

        model.goEnclosing()
        _ = try await rig.listed(window, model: model, count: componentRows.count)
        #expect(model.folder == "tool.pkg")
        #expect(model.notice == nil)

        try rig.enter("Payload", in: window, model: model)
        try await untilTrue(waitingFor: "the no-space line again; folder \(model.folder), browses \(rig.browses)") { !model.results.isPending && model.notice == line }
        #expect(!model.reading)
        #expect(model.problem == nil)
    }

    @Test func commandUpWhileReadingActsLikeStop() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (window, model) = try await rig.component()
        try await rig.expanding("Scripts", in: window, model: model)

        try commandUp(window)
        let table = try await rig.listed(window, model: model, count: componentRows.count)
        #expect(model.folder == "tool.pkg")
        #expect(window.firstResponder === table)
        #expect(!model.reading)
        #expect(window.isVisible)
        #expect(rig.browses == ["tool.pkg", "tool.pkg/Scripts", "tool.pkg"])
    }

    @Test func stopDuringTheFirstListingClosesTheWindow() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.archive.holdBrowse("")
        rig.windows.open(rig.pkg)
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        try await untilTrue(waitingFor: "the held first listing") { rig.archive.waitingBrowses == 1 }
        #expect(controller.model.reading)
        #expect(AXTree.press(try await rig.element(ArchiveStatusBar.stopID, in: window)))
        try await untilTrue(waitingFor: "the window to close") { ArchiveWindows.all.isEmpty }
        #expect(!window.isVisible)
    }
}
