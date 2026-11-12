import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private let entries: [FakeArchiveClient.Entry] = [
    .init("Trip", kind: .folder), .init("notes.txt", size: 2_048), .init("cover.jpg", size: 1_200_000), .init("Trip/IMG_0001.HEIC", size: 10),
]

@MainActor
private final class Rig {
    let defaults: UserDefaults
    let windows: ArchiveWindows
    let folder: URL
    let recorder = ActionRecorder()

    init(_ name: String) throws {
        let suite = "com.writronic.wherever.tests.archive-look.\(name)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        folder = FileManager.default.temporaryDirectory.appending(path: "archive-look-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "Photos 2024.zip"))
        let search = FakeSearchClient(hits: [])
        windows = ArchiveWindows(
            client: FakeArchiveClient(search: search, entries: entries), index: IndexModel(client: search), actions: recorder.actions,
            defaults: defaults, columnPreferences: ColumnPreferences(defaults: defaults), cache: folder.appending(path: "Cache", directoryHint: .isDirectory)
        )
    }

    func close() {
        ArchiveWindows.all.forEach { $0.window?.close() }
        try? FileManager.default.removeItem(at: folder)
    }

    func table(_ window: NSWindow) -> ThemedTable? {
        window.contentView?.layoutSubtreeIfNeeded()
        return window.contentView?.descendant(ThemedTable.self)
    }

    func open() async throws -> (NSWindow, ThemedTable, ArchiveWindowModel) {
        windows.open(SearchHit(
            name: "Photos 2024.zip", folder: folder.path(percentEncoded: false), size: 0, modified: Date(timeIntervalSince1970: 0),
            created: .distantPast, opened: .distantPast, kind: .file
        ))
        let controller = try #require(ArchiveWindows.all.last)
        let window = try #require(controller.window)
        let model = controller.model
        try await untilTrue(waitingFor: "3 rows and the summary; shown \(model.results.names)") {
            guard let table = table(window) else { return false }
            return !model.results.isPending && table.numberOfRows == 3 && model.summary != nil
        }
        return (window, try #require(table(window)), model)
    }
}

private func corners(_ window: NSWindow) -> [[Int]] {
    guard let view = window.contentView else { return [] }
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
    view.cacheDisplay(in: view.bounds, to: rep)
    return [srgbPixel(rep, x: 2, y: 2), srgbPixel(rep, x: 2, y: rep.pixelsHigh - 3)].compactMap(\.self)
}

private func draws(_ window: NSWindow, _ theme: Theme, _ look: Look) -> Bool {
    let expected = eightBits(channels(theme.windowBackground, look))
    let drawn = corners(window)
    return drawn.count == 2 && drawn.allSatisfy { $0.count == 3 && zip($0, expected).allSatisfy { abs($0 - $1) <= 1 } }
}

@Suite(.serialized) struct ArchiveLookTests {
    @Test(arguments: Theme.allCases)
    func theArchiveWindowDrawsItsThemeUnderEachForcedMode(theme: Theme) async throws {
        let rig = try Rig("theme-\(theme.rawValue)")
        defer { rig.close() }
        rig.defaults.set(theme.rawValue, forKey: Theme.key)
        let previous = NSApplication.shared.appearance
        defer { setAppAppearance(previous) }
        setAppAppearance(Look.light.appearance)
        let (window, table, _) = try await rig.open()
        #expect(window.appearance == nil)
        for look in [Look.light, .dark, .light] {
            setAppAppearance(look.appearance)
            try await untilTrue(waitingFor: "\(theme) \(look) in the archive window; drawn \(corners(window))") { draws(window, theme, look) }
            #expect(channels(table.backgroundColor, look) == channels(theme.rowBackground, look), "\(theme) rows under \(look)")
            #expect(channels(table.stripe, look) == channels(theme.stripeBackground, look), "\(theme) stripes under \(look)")
        }
        #expect(rig.recorder.refused == 0)
    }

    @Test func eachProgressBarIsNamedByTheLineBesideIt() async throws {
        let rig = try Rig("progress")
        defer { rig.close() }
        let (window, _, model) = try await rig.open()
        let content = try #require(window.contentView)
        let shown = Bidi.name("Photos 2024.zip")
        let states: [(set: () -> Void, line: String, text: String)] = [
            ({ model.saving = .init(name: "Photos 2024.zip", fraction: nil) }, ArchiveStatusBar.savingID, String(localized: "Saving “\(shown)”…", table: "Archive")),
            ({ model.saving = .init(name: "Photos 2024.zip", fraction: 0.5) }, ArchiveStatusBar.savingID, String(localized: "Saving “\(shown)”…", table: "Archive")),
            ({ model.saving = nil; model.expansion = .running(name: "Photos 2024.zip", fraction: nil) }, ArchiveStatusBar.expandingID,
             String(localized: "Expanding “\(shown)”…", table: "Archive")),
            ({ model.expansion = .running(name: "Photos 2024.zip", fraction: 0.25) }, ArchiveStatusBar.expandingID,
             String(localized: "Expanding “\(shown)”…", table: "Archive")),
        ]
        for state in states {
            state.set()
            try await untilTrue(waitingFor: "the bar named “\(state.text)”") {
                content.layoutSubtreeIfNeeded()
                guard let bar = AXTree.element(ArchiveStatusBar.progressID, in: content),
                      let line = AXTree.element(state.line, in: content) else { return false }
                return (AXTree.value("accessibilityLabel", of: bar) as String?) == state.text && AXTree.names(of: line).contains(state.text)
            }
        }
        model.expansion = nil
        #expect(rig.recorder.refused == 0)
    }

    @Test func theArchiveWindowAndItsPasswordSheetFollowTheTextSizeLive() async throws {
        let rig = try Rig("size")
        defer { rig.close() }
        let (window, table, model) = try await rig.open()
        let content = try #require(window.contentView)
        let field = try #require(window.searchField)
        let list = try #require(table.enclosingScrollView)
        func bars() -> (bar: CGFloat, status: CGFloat) {
            content.layoutSubtreeIfNeeded()
            let rows = list.convert(list.bounds, to: nil)
            return (field.convert(field.bounds, to: nil).minY - rows.maxY, rows.minY)
        }
        try await untilTrue(waitingFor: "the path bar and the status bar") {
            content.layoutSubtreeIfNeeded()
            return AXTree.element(ArchivePathBar.barID, in: content) != nil && AXTree.element(ArchiveStatusBar.statusID, in: content) != nil
        }
        let (bar, status) = bars()
        #expect(table.rowHeight == ResultsTable.rowHeight(.standard))
        let large = TextSize.maximum
        let barGrows = ResultsTable.rowHeight(large) - ResultsTable.rowHeight(.standard)
        let statusGrows = StatusBarView.lineHeight(large) - StatusBarView.lineHeight(.standard)
        try #require(barGrows > 0 && statusGrows > 0, "the sizes \(barGrows) and \(statusGrows) cannot tell the text sizes apart")

        rig.defaults.set(large.rawValue, forKey: TextSize.key)
        try await untilTrue(waitingFor: "taller rows and bars; bars \(bars()), at first \(bar) and \(status)") {
            table.rowHeight == ResultsTable.rowHeight(large) && bars() == (bar + barGrows, status + statusGrows)
        }

        model.askPassword()
        try await untilTrue(waitingFor: "the password sheet") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let width = (ResultsTable.font(large).pointSize * 28).rounded()
        func sheetWidth() -> CGFloat? {
            guard let view = sheet.contentView, AXTree.element(ArchivePasswordSheet.sheetID, in: view) != nil else { return nil }
            return view.frame.width
        }
        try await untilTrue(waitingFor: "a sheet \(width) wide, now \(String(describing: sheetWidth()))") { sheetWidth() == width }
        #expect(width > (ResultsTable.font(.standard).pointSize * 28).rounded())
        model.cancelPassword()
        try await untilTrue(waitingFor: "the sheet to close") { window.attachedSheet == nil }

        rig.defaults.removeObject(forKey: TextSize.key)
        try await untilTrue(waitingFor: "the standard size again") {
            table.rowHeight == ResultsTable.rowHeight(.standard) && bars() == (bar, status)
        }
        #expect(rig.recorder.refused == 0)
    }
}
