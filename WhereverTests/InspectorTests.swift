import AppKit
import Combine
import Foundation
import os
import Quartz
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private func inspectorStore(shown: Bool) -> UserDefaults {
    let name = "com.writronic.wherever.tests.inspector"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    if shown { store.set(true, forKey: InspectorPane.shownKey) }
    return store
}

func splitController(in root: NSView) -> InspectorSplitController? {
    for view in root.subviews {
        if let split = view as? NSSplitView, let controller = split.delegate as? InspectorSplitController { return controller }
        if let found = splitController(in: view) { return found }
    }
    return nil
}

private struct TemporaryFiles {
    let folder: String
    let hits: [SearchHit]

    init(_ names: [String]) throws {
        folder = NSTemporaryDirectory() + "wherever-inspector-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var hits: [SearchHit] = []
        for (index, name) in names.enumerated() {
            let data = Data(repeating: 7, count: 1_000 * (index + 1))
            try data.write(to: URL(filePath: folder).appending(path: name, directoryHint: .notDirectory))
            hits.append(SearchHit(name: name, folder: folder, size: Int64(data.count), modified: Date(), created: .distantPast, opened: .distantPast, kind: .file))
        }
        self.hits = hits
    }

    func remove() { try? FileManager.default.removeItem(atPath: folder) }

    static func created(_ hit: SearchHit) throws -> String {
        let date = try #require(try hit.fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
        return FileDates.current.string(date)
    }

    static func summary(_ hit: SearchHit) -> String {
        "\(ResultType.of(hit).kind) · \(ByteCountFormatter.string(fromByteCount: hit.size, countStyle: .file))"
    }
}

@MainActor
private struct InspectorRig {
    let fake: FakeSearchClient
    let index: IndexModel
    let model: SearchModel
    let host: SearchHost
    let store: UserDefaults
    let recorder: ActionRecorder
    let archive: FakeArchiveClient?
    let archives: ArchiveWindows?

    init(hits: [SearchHit] = [], store: UserDefaults, locale: Locale? = nil, archived: Bool = false) {
        let fake = FakeSearchClient(hits: hits)
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let recorder = ActionRecorder()
        self.fake = fake
        self.index = index
        self.model = model
        self.store = store
        self.recorder = recorder
        var actions = recorder.actions
        if archived {
            let archive = FakeArchiveClient(search: fake, entries: [.init("notes.txt", size: 2_048)])
            let cache = FileManager.default.temporaryDirectory.appending(path: "inspector-archives-\(UUID().uuidString)", directoryHint: .isDirectory)
            let windows = ArchiveWindows(
                client: archive, index: index, actions: ActionRecorder().actions, defaults: store, columnPreferences: ColumnPreferences(defaults: store), cache: cache
            )
            actions.inside = windows.inside
            self.archive = archive
            archives = windows
        } else {
            archive = nil
            archives = nil
        }
        let view = SearchView(model: model).defaultAppStorage(store)
        host = SearchHost(root: locale.map { AnyView(view.environment(\.locale, $0)) } ?? AnyView(view), actions: actions)
    }

    func close() {
        for controller in ArchiveWindows.all { controller.window?.close() }
        host.close()
    }

    func split() -> InspectorSplitController? { splitController(in: host.view) }

    func parts() throws -> (split: InspectorSplitController, list: NSView, pane: NSView) {
        let split = try need(split(), "no inspector split")
        return (split, try need(split.splitViewItems.first?.viewController.view, "no list pane"), split.pane.view)
    }

    func table() throws -> NSTableView { try need(host.list(), "no results table") }

    func paneShows(_ text: String) -> Bool { host.shows(text, in: split()?.pane.view) }

    var paneHasPreview: Bool { split().map { hasQuickLookPreview($0.pane.view) } ?? false }

    var paneViews: [QLPreviewView] { split().map { quickLookViews(in: $0.pane.view) } ?? [] }

    var inspector: InspectorModel? { split()?.pane.inspector }

    func untilRead(_ path: String) async throws {
        try await host.until("the facts of \(path)") { inspector?.hit?.path == path && inspector?.facts != nil }
    }

    func paneElement(_ id: String) -> NSObject? { split().flatMap { AXTree.element(id, in: $0.pane.view) } }

    func search(_ query: String, count: Int) async throws {
        model.query = query
        fake.send(.resultsReady(fake.latest, count: count))
        try await host.until("\(count) rows for \(query)") { !model.isPending && host.list()?.numberOfRows == count }
    }

    func select(_ row: Int) async throws {
        try await host.focusList()
        try table().selectRowIndexes([row], byExtendingSelection: false)
    }

    func widths() -> (total: CGFloat, list: CGFloat, pane: CGFloat)? {
        guard let parts = try? parts(), parts.split.splitView.bounds.width > 0 else { return nil }
        return (parts.split.splitView.bounds.width, parts.list.frame.width, parts.split.inspectorItem.isCollapsed ? 0 : parts.pane.frame.width)
    }

    func untilShownAtFirstWidth() async throws {
        try await host.until("the pane at 260 beside the table, widths \(String(describing: widths()))") {
            guard let parts = try? parts() else { return false }
            let (split, list, pane) = parts
            guard !split.inspectorItem.isCollapsed, split.splitView.bounds.width > 0 else { return false }
            let scale = host.window.backingScaleFactor
            let total = split.splitView.bounds.width
            let paneRect = pane.convert(pane.bounds, to: split.splitView)
            let listRect = list.convert(list.bounds, to: split.splitView)
            let gap = paneRect.minX - listRect.maxX
            return gap == split.splitView.dividerThickness && (paneRect.width - SearchMetrics.inspectorWidth) * scale == 0
                && (paneRect.maxX - total) * scale == 0 && listRect.minX * scale == 0
        }
    }
}

private func textField(_ text: String, in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.stringValue == text, !field.isHidden { return field }
    return view is NSButton ? nil : view.subviews.lazy.compactMap { textField(text, in: $0) }.first
}

func quickLookViews(in view: NSView) -> [QLPreviewView] {
    (view as? QLPreviewView).map { [$0] } ?? view.subviews.flatMap { quickLookViews(in: $0) }
}

private func hasQuickLookPreview(_ view: NSView) -> Bool {
    quickLookViews(in: view).contains { !$0.isHidden }
}

private func viewMenuItem(_ title: String) -> NSMenuItem? {
    func find(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if item.title == title { return item }
            if let found = find(in: item.submenu) { return found }
        }
        return nil
    }
    return find(in: NSApp.mainMenu)
}

@Suite(.serialized) struct InspectorTests {
    @Test func theInspectorStartsHiddenAndTheTableTakesTheWidth() async throws {
        let rig = InspectorRig(store: inspectorStore(shown: false))
        defer { rig.host.close() }
        try await rig.host.until("the table across the content, widths \(String(describing: rig.widths()))") {
            rig.widths().map { $0.list == rig.host.view.bounds.width && $0.total == rig.host.view.bounds.width } == true
        }
        let (split, list, pane) = try rig.parts()
        #expect(split.inspectorItem.isCollapsed)
        #expect(split.splitView.isVertical)
        #expect(split.splitView.dividerStyle == .thin)
        #expect(split.inspectorItem.minimumThickness == SearchMetrics.inspectorMinWidth)
        #expect(split.inspectorItem.maximumThickness == SearchMetrics.inspectorMaxWidth)
        #expect(split.inspectorItem.canCollapse)
        #expect(split.inspectorItem.behavior == .default)
        #expect(split.inspectorItem.holdingPriority.rawValue > split.splitViewItems[0].holdingPriority.rawValue)

        rig.store.set(true, forKey: InspectorPane.shownKey)
        try await rig.untilShownAtFirstWidth()
        let scale = rig.host.window.backingScaleFactor
        let paneTop = pane.convert(pane.bounds, to: nil).maxY
        let listTop = list.convert(list.bounds, to: nil).maxY
        #expect((paneTop - listTop) * scale == 0, "the pane's top \(paneTop), the table's \(listTop)")
    }

    @Test func theViewMenuItemShowsAndHidesTheInspectorAndItsTitleFollows() async throws {
        let standard = UserDefaults.standard
        let before = standard.object(forKey: InspectorPane.shownKey)
        defer {
            if let before { standard.set(before, forKey: InspectorPane.shownKey) } else { standard.removeObject(forKey: InspectorPane.shownKey) }
        }
        standard.set(false, forKey: InspectorPane.shownKey)
        let show = String(localized: "Show Inspector", table: "Inspector")
        let hide = String(localized: "Hide Inspector", table: "Inspector")

        for (title, next, stored) in [(show, hide, true), (hide, show, false)] {
            try await untilTrue(waitingFor: "\(title) in the main menu") { viewMenuItem(title) != nil }
            let item = try #require(viewMenuItem(title))
            let menu = try #require(item.menu)
            #expect(item.keyEquivalent == "i")
            #expect(item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == [.command, .option])
            menu.performActionForItem(at: menu.index(of: item))
            try await untilTrue(waitingFor: "the stored value \(stored)") { standard.bool(forKey: InspectorPane.shownKey) == stored }
            try await untilTrue(waitingFor: "the title \(next)") { viewMenuItem(next) != nil }
        }
    }

    @Test func theSettingsRowShowsTheInspectorInEveryWindow() async throws {
        let store = inspectorStore(shown: false)
        let first = InspectorRig(store: store)
        let second = InspectorRig(store: store)
        let row = SearchHost(root: AnyView(InspectorSettingRow().defaultAppStorage(store).padding()))
        defer { first.host.close(); second.host.close(); row.close() }
        for rig in [first, second] {
            try await rig.host.until("a hidden inspector") { rig.split()?.inspectorItem.isCollapsed == true && rig.widths() != nil }
        }
        let title = String(localized: "Show inspector", table: "Inspector")
        try await row.until("the Show inspector switch") { AXTree.control(title, in: row.view) != nil }
        try #require(AXTree.press(try #require(AXTree.control(title, in: row.view))))
        try await row.until("the stored value") { store.bool(forKey: InspectorPane.shownKey) }
        for rig in [first, second] { try await rig.untilShownAtFirstWidth() }
    }

    @Test func draggingTheShutInspectorOpenStoresItAndTheMenuAndSwitchFollow() async throws {
        let standard = UserDefaults.standard
        let before = standard.object(forKey: InspectorPane.shownKey)
        defer {
            if let before { standard.set(before, forKey: InspectorPane.shownKey) } else { standard.removeObject(forKey: InspectorPane.shownKey) }
        }
        standard.set(false, forKey: InspectorPane.shownKey)
        let rig = InspectorRig(store: standard)
        let row = SearchHost(root: AnyView(InspectorSettingRow().defaultAppStorage(standard).padding()))
        defer { rig.close(); row.close() }
        let show = String(localized: "Show Inspector", table: "Inspector")
        let hide = String(localized: "Hide Inspector", table: "Inspector")
        let title = String(localized: "Show inspector", table: "Inspector")
        try await rig.host.until("a shut inspector") { rig.split()?.inspectorItem.isCollapsed == true && rig.widths() != nil }
        try await untilTrue(waitingFor: "\(show) in the main menu") { viewMenuItem(show) != nil }
        try await row.until("the Show inspector switch off") { AXTree.control(title, in: row.view).flatMap(AXTree.isOn) == false }

        try #require(rig.split()).inspectorItem.isCollapsed = false
        #expect(standard.bool(forKey: InspectorPane.shownKey))
        try await untilTrue(waitingFor: "\(hide) in the main menu") { viewMenuItem(hide) != nil }
        try await row.until("the Show inspector switch on") { AXTree.control(title, in: row.view).flatMap(AXTree.isOn) == true }
        #expect(rig.split()?.inspectorItem.isCollapsed == false)
    }

    @Test func theSettingsSwitchCanBeAddressedByItsIdentifier() async throws {
        let store = inspectorStore(shown: false)
        let row = SearchHost(root: AnyView(InspectorSettingRow().defaultAppStorage(store).padding()))
        defer { row.close() }
        try await row.until("the switch by its identifier") { AXTree.element(InspectorSettingRow.id, in: row.view) != nil }
        let toggle = try #require(AXTree.element(InspectorSettingRow.id, in: row.view))
        #expect(AXTree.isOn(toggle) == false)
        try #require(AXTree.press(toggle))
        try await row.until("the stored value") { store.bool(forKey: InspectorPane.shownKey) }
        try await row.until("the switch on") { AXTree.element(InspectorSettingRow.id, in: row.view).flatMap(AXTree.isOn) == true }
    }

    @Test func draggingTheDividerShutHidesTheInspectorEverywhereAndItStaysShut() async throws {
        let files = try TemporaryFiles(["dragged-a.txt", "dragged-b.txt"])
        defer { files.remove() }
        let store = inspectorStore(shown: true)
        let first = InspectorRig(hits: files.hits, store: store)
        let second = InspectorRig(hits: files.hits, store: store)
        let row = SearchHost(root: AnyView(InspectorSettingRow().defaultAppStorage(store).padding()))
        defer { first.close(); second.close(); row.close() }
        for rig in [first, second] { try await rig.untilShownAtFirstWidth() }
        let title = String(localized: "Show inspector", table: "Inspector")
        try await row.until("the Show inspector switch on") { AXTree.control(title, in: row.view).flatMap(AXTree.isOn) == true }
        let item = try #require(first.split()).inspectorItem
        #expect(!item.canCollapseFromWindowResize)

        item.isCollapsed = true
        #expect(!store.bool(forKey: InspectorPane.shownKey))
        try await second.host.until("the other window shut too") { second.split()?.inspectorItem.isCollapsed == true }
        try await row.until("the Show inspector switch off") { AXTree.control(title, in: row.view).flatMap(AXTree.isOn) == false }

        try await first.search("dragged", count: 2)
        try await second.search("dragged", count: 2)
        #expect(item.isCollapsed)
        #expect(second.split()?.inspectorItem.isCollapsed == true)
        #expect(!store.bool(forKey: InspectorPane.shownKey))

        try #require(AXTree.press(try #require(AXTree.control(title, in: row.view))))
        for rig in [first, second] {
            try await rig.host.until("the inspector open again") { rig.split()?.inspectorItem.isCollapsed == false }
        }
        #expect(store.bool(forKey: InspectorPane.shownKey))
    }

    @Test func theViewMenuItemFollowsADividerDragAndOpensTheInspectorAgain() async throws {
        let standard = UserDefaults.standard
        let before = standard.object(forKey: InspectorPane.shownKey)
        defer {
            if let before { standard.set(before, forKey: InspectorPane.shownKey) } else { standard.removeObject(forKey: InspectorPane.shownKey) }
        }
        standard.set(true, forKey: InspectorPane.shownKey)
        let rig = InspectorRig(store: standard)
        defer { rig.close() }
        try await rig.untilShownAtFirstWidth()
        let show = String(localized: "Show Inspector", table: "Inspector")
        let hide = String(localized: "Hide Inspector", table: "Inspector")
        try await untilTrue(waitingFor: "\(hide) in the main menu") { viewMenuItem(hide) != nil }

        try #require(rig.split()).inspectorItem.isCollapsed = true
        try await untilTrue(waitingFor: "\(show) in the main menu") { viewMenuItem(show) != nil }
        let item = try #require(viewMenuItem(show))
        let menu = try #require(item.menu)
        menu.performActionForItem(at: menu.index(of: item))
        try await rig.host.until("the inspector open again") { rig.split()?.inspectorItem.isCollapsed == false }
        try await untilTrue(waitingFor: "\(hide) in the main menu") { viewMenuItem(hide) != nil }
    }

    @Test func selectingARowShowsItsNameKindSizeAndFacts() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.txt"])
        defer { files.remove() }
        let (a, b) = (files.hits[0], files.hits[1])
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 2)
        try await rig.select(0)
        let readWrite = String(localized: "Read & Write", table: "Inspector")
        for (hit, other) in [(a, b), (b, a)] {
            if hit == b { try rig.host.press(.downArrow) }
            let created = try TemporaryFiles.created(hit)
            let modified = FileDates.current.string(hit.modified)
            try await rig.host.until("\(hit.name)'s name, summary, created \(created), modified \(modified), owner and permissions") {
                rig.paneShows(hit.name) && rig.paneShows(TemporaryFiles.summary(hit)) && rig.paneShows(created) && rig.paneShows(modified)
                    && rig.paneShows(NSUserName()) && rig.paneShows(readWrite)
            }
            #expect(!rig.paneShows(hit.modified.formatted(date: .abbreviated, time: .shortened)))
            #expect(!rig.paneShows(other.name))
            #expect(rig.paneShows(hit.folder))
        }
    }

    @Test func aDatalessFileGetsNoPreviewAndTheNotDownloadedLine() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.txt"])
        defer { files.remove() }
        InspectorModel.datalessCheck = { $0.hasSuffix("inspected-b.txt") }
        defer { InspectorModel.datalessCheck = isDataless }
        let line = String(localized: "In iCloud", table: "Inspector")
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 2)
        try await rig.select(0)
        try await rig.host.until("a local file's preview and no line") { rig.paneHasPreview && !rig.paneShows(line) }
        try rig.host.press(.downArrow)
        var previewed = false
        try await rig.host.until("the placeholder's In iCloud line") {
            if rig.paneShows(files.hits[1].name), rig.paneHasPreview { previewed = true }
            return rig.paneShows(line)
        }
        #expect(!previewed, "a shown preview beside the placeholder's name")
        try await rig.host.until("the line's own accessibility identifier") { rig.paneElement(InspectorPane.notDownloadedID) != nil }
        try await rig.host.until("no preview for the placeholder") { !rig.paneHasPreview }
        try rig.host.press(.upArrow)
        try await rig.host.until("the local file's preview again and no line") { rig.paneShows(files.hits[0].name) && rig.paneHasPreview && !rig.paneShows(line) }
    }

    @Test func thePreviewReceivesTheSelectedFileAndLosesItForAPlaceholderAndAMultiSelection() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.txt"])
        defer { files.remove() }
        InspectorModel.datalessCheck = { $0.hasSuffix("inspected-b.txt") }
        defer { InspectorModel.datalessCheck = isDataless }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.close() }
        try await rig.host.until("the inspector pane") { rig.split() != nil }
        try #require(rig.split()).pane.previewsFiles = true
        let item = { () -> URL? in (rig.paneViews.first?.previewItem as? NSURL) as URL? }
        try await rig.search("inspected", count: 2)
        try await rig.select(0)
        try await rig.host.until("the first file as the preview item, now \(String(describing: item()))") { item() == files.hits[0].fileURL }

        try rig.host.press(.downArrow)
        try await rig.host.until("no preview item for the placeholder, now \(String(describing: item()))") {
            rig.paneShows(files.hits[1].name) && item() == nil
        }
        try rig.host.press(.upArrow)
        try await rig.host.until("the first file as the preview item again, now \(String(describing: item()))") { item() == files.hits[0].fileURL }

        try rig.table().selectRowIndexes([0, 1], byExtendingSelection: false)
        try await rig.host.until("no preview view for two items") { rig.paneViews.isEmpty }
    }

    @Test func quickSelectionsReadOnlyWhereTheSelectionRests() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.txt", "inspected-c.txt", "inspected-d.txt"])
        defer { files.remove() }
        let paths = files.hits.map(\.path)
        let reads = OSAllocatedUnfairLock<[String]>(initialState: [])
        let folder = files.folder
        InspectorModel.datalessCheck = { path in
            if path.hasPrefix(folder) { reads.withLock { $0.append(path) } }
            return false
        }
        defer { InspectorModel.datalessCheck = isDataless }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 4)
        try await rig.select(0)
        try await rig.untilRead(paths[0])
        try await Task.sleep(for: InspectorModel.settle * 2)
        reads.withLock { $0.removeAll() }

        for _ in 0..<3 { try rig.host.press(.downArrow) }
        try await rig.untilRead(paths[3])
        try await Task.sleep(for: InspectorModel.settle * 2)
        #expect(reads.withLock { $0 } == [paths[1], paths[3]])

        try rig.host.press(.upArrow)
        try await rig.untilRead(paths[2])
        try await Task.sleep(for: InspectorModel.settle * 2)
        #expect(reads.withLock { $0 } == [paths[1], paths[3], paths[2]])
    }

    @Test func aNewQueryDuringABurstReadsNothingMore() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.txt", "inspected-c.txt"])
        defer { files.remove() }
        let paths = files.hits.map(\.path)
        let reads = OSAllocatedUnfairLock<[String]>(initialState: [])
        let folder = files.folder
        InspectorModel.datalessCheck = { path in
            if path.hasPrefix(folder) { reads.withLock { $0.append(path) } }
            return false
        }
        defer { InspectorModel.datalessCheck = isDataless }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 3)
        try await rig.select(0)
        try await rig.untilRead(paths[0])
        try await Task.sleep(for: InspectorModel.settle * 2)
        reads.withLock { $0.removeAll() }

        try rig.host.press(.downArrow)
        try rig.host.press(.downArrow)
        try await rig.search("inspected-a", count: 1)
        let none = String(localized: "No Selection", table: "Inspector")
        try await rig.host.until("No Selection after the new query") { rig.paneShows(none) }
        try await Task.sleep(for: InspectorModel.settle * 2)
        #expect(reads.withLock { $0 } == [paths[1]])
        #expect(rig.inspector?.hit == nil)
    }

    @Test func thePreviewIsOneViewAcrossSelections() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.txt", "inspected-c.txt"])
        defer { files.remove() }
        let paths = files.hits.map(\.path)
        let gate = DispatchSemaphore(value: 0)
        InspectorModel.datalessCheck = { path in
            if path == paths[1] { _ = gate.wait(timeout: .now() + 5) }
            return false
        }
        defer { InspectorModel.datalessCheck = isDataless }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 3)
        try await rig.select(0)
        try await rig.host.until("a shown preview for file 0") { rig.paneHasPreview && rig.inspector?.hit?.path == paths[0] }
        let kept = try #require(rig.paneViews.first)
        try await Task.sleep(for: InspectorModel.settle * 2)

        try rig.host.press(.downArrow)
        rig.host.view.layoutSubtreeIfNeeded()
        try await rig.host.until("the kept preview hidden while file 1 is read, views \(rig.paneViews)") {
            let views = rig.paneViews
            return rig.paneShows(files.hits[1].name) && views.count == 1 && views[0] === kept && views[0].isHidden
        }
        gate.signal()
        try await rig.untilRead(paths[1])
        try await rig.host.until("file 1's preview shown") { rig.paneHasPreview }
        #expect(rig.paneViews.count == 1 && rig.paneViews.first === kept)

        try await Task.sleep(for: InspectorModel.settle * 2)
        try rig.host.press(.downArrow)
        try await rig.untilRead(paths[2])
        try await rig.host.until("file 2's preview shown") { rig.paneHasPreview }
        #expect(rig.paneViews.count == 1 && rig.paneViews.first === kept)
    }

    @Test func aHiddenInspectorPublishesNothingUntilShown() async throws {
        let reads = OSAllocatedUnfairLock<[String]>(initialState: [])
        let folder = "/nonexistent-\(UUID().uuidString)"
        InspectorModel.datalessCheck = { path in
            if path.hasPrefix(folder) { reads.withLock { $0.append(path) } }
            return false
        }
        defer { InspectorModel.datalessCheck = isDataless }
        let (a, b) = (SearchHit.named("hidden-a.txt", in: folder), SearchHit.named("hidden-b.txt", in: folder))
        let model = InspectorModel()
        var changes = 0
        let watch = model.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        model.select(a)
        model.select(b)
        try await Task.sleep(for: InspectorModel.settle * 2)
        #expect(changes == 0)
        #expect(model.hit == nil)
        #expect(reads.withLock { $0 }.isEmpty)

        model.shown = true
        #expect(model.hit == b)
        try await untilTrue(waitingFor: "b's facts") { model.facts != nil }
        #expect(reads.withLock { $0 } == [b.path])

        model.select(nil)
        #expect(model.hit == nil)
        #expect(model.facts == nil)
    }

    @Test func aNewQueryShowsNoSelection() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.txt"])
        defer { files.remove() }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        let none = String(localized: "No Selection", table: "Inspector")
        try await rig.search("inspected", count: 2)
        try await rig.host.until("No Selection before a click") { rig.paneShows(none) }
        try await rig.select(0)
        try await rig.host.until("the selected file") { rig.paneShows(files.hits[0].name) && !rig.paneShows(none) }
        try await rig.search("inspected-a", count: 1)
        try await rig.host.until("No Selection after the new query") { rig.paneShows(none) && !rig.paneShows(files.hits[0].name) }
    }

    @Test func aLiveUpdateKeepsTheInspectedFile() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.txt"])
        defer { files.remove() }
        let (a, b) = (files.hits[0], files.hits[1])
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 2)
        try await rig.select(0)
        try await rig.host.until("a in the pane") { rig.paneShows(a.name) }
        rig.fake.setHits([b, a])
        let queries = rig.fake.queries.count
        rig.fake.send(.resultsChanged)
        try await rig.host.until("the live search") { rig.fake.queries.count == queries + 1 }
        rig.fake.send(.resultsReady(rig.fake.latest, count: 2))
        try await rig.host.until("the live results with a on row 1") { rig.model.results.live && (try? rig.table().selectedRow) == 1 }
        #expect(rig.paneShows(a.name))
        #expect(!rig.paneShows(b.name))
        #expect(!rig.paneShows(String(localized: "No Selection", table: "Inspector")))

        rig.fake.setHits([b])
        rig.fake.send(.resultsChanged)
        try await rig.host.until("the second live search") { rig.fake.queries.count == queries + 2 }
        rig.fake.send(.resultsReady(rig.fake.latest, count: 1))
        try await rig.host.until("No Selection once a leaves the results") {
            rig.paneShows(String(localized: "No Selection", table: "Inspector")) && !rig.paneShows(a.name)
        }
        #expect((try? rig.table().selectedRow) == -1)
    }

    @Test func aChangeToTheInspectedFileKeepsItsFactsAndReadsThemAgain() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.txt"])
        defer { files.remove() }
        let reads = OSAllocatedUnfairLock<[String]>(initialState: [])
        let folder = files.folder
        InspectorModel.datalessCheck = { path in
            if path.hasPrefix(folder) { reads.withLock { $0.append(path) } }
            return false
        }
        defer { InspectorModel.datalessCheck = isDataless }
        let (a, b) = (files.hits[0], files.hits[1])
        let model = InspectorModel()
        model.shown = true
        model.select(a)
        try await untilTrue(waitingFor: "a's facts") { model.facts != nil }
        var blanked = 0
        let watch = model.$state.sink { if $0.hit?.path == a.path, $0.count == 1, $0.facts == nil { blanked += 1 } }
        defer { watch.cancel() }

        let grown = SearchHit(name: a.name, folder: a.folder, size: a.size + 1, modified: a.modified.addingTimeInterval(1), created: a.created, opened: a.opened, kind: a.kind)
        model.select(grown)
        #expect(model.hit == grown)
        #expect(model.facts != nil)
        try await untilTrue(waitingFor: "a read again, read \(reads.withLock { $0 })") { reads.withLock { $0 } == [a.path, a.path] && model.facts != nil }
        #expect(blanked == 0)

        model.select(grown, count: 2)
        #expect(model.count == 2 && model.facts == nil)
        model.select(grown)
        #expect(model.count == 1 && model.facts == nil)
        try await untilTrue(waitingFor: "a read after the multi-selection") { model.facts != nil }
        model.select(b)
        #expect(model.hit == b && model.facts == nil)
        try await untilTrue(waitingFor: "b's facts") { model.facts != nil }
    }

    @Test func aLiveChangeToTheInspectedFileKeepsItsPreviewAndFacts() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.txt"])
        defer { files.remove() }
        let (a, b) = (files.hits[0], files.hits[1])
        let reads = OSAllocatedUnfairLock(initialState: 0)
        InspectorModel.datalessCheck = { path in
            if path == a.path, reads.withLock({ $0 += 1; return $0 }) > 1 { usleep(300_000) }
            return false
        }
        defer { InspectorModel.datalessCheck = isDataless }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.close() }
        try await rig.host.until("the inspector pane") { rig.split() != nil }
        try #require(rig.split()).pane.previewsFiles = true
        let item = { () -> URL? in (rig.paneViews.first?.previewItem as? NSURL) as URL? }
        let created = try TemporaryFiles.created(a)
        try await rig.search("inspected", count: 2)
        try await rig.select(0)
        try await rig.host.until("a's preview and facts, now \(String(describing: item()))") { item() == a.fileURL && rig.paneShows(created) }

        let grown = SearchHit(name: a.name, folder: a.folder, size: a.size + 1, modified: a.modified.addingTimeInterval(1), created: a.created, opened: a.opened, kind: a.kind)
        rig.fake.setHits([grown, b])
        let queries = rig.fake.queries.count
        rig.fake.send(.resultsChanged)
        try await rig.host.until("the live search") { rig.fake.queries.count == queries + 1 }
        var lost: [String] = []
        rig.fake.send(.resultsReady(rig.fake.latest, count: 2))
        try await rig.host.until("a read again after the live change") {
            if item() != a.fileURL { lost.append("preview \(String(describing: item()))") }
            if !rig.paneShows(created) { lost.append("created") }
            return rig.inspector?.hit == grown && reads.withLock { $0 } == 2 && rig.inspector?.facts != nil
        }
        #expect(lost.isEmpty, "the pane blanked: \(lost)")
        #expect(item() == a.fileURL && rig.paneShows(created))
        #expect((try? rig.table().selectedRow) == 0)
    }

    @Test func theQuickLookButtonActsLikeSpace() async throws {
        let files = try TemporaryFiles(["inspected-a.txt"])
        defer { files.remove() }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 1)
        try await rig.select(0)
        try await rig.host.until("the Quick Look button") { rig.paneElement(InspectorPane.quickLookID) != nil }
        try #require(rig.host.window.focusSearchField() != nil)
        try #require(AXTree.press(try #require(rig.paneElement(InspectorPane.quickLookID))))
        try await rig.host.until("the panel shown for the file") { rig.recorder.shown == [files.hits[0].fileURL] }
        #expect(rig.host.listHasFocus)
        try rig.host.sendKeys(" ")
        #expect(rig.recorder.hides == 1)
        #expect(rig.recorder.shown.count == 1)
    }

    @Test func theShowInFinderButtonRevealsTheSelectedFile() async throws {
        let files = try TemporaryFiles(["inspected-a.txt"])
        defer { files.remove() }
        let url = files.hits[0].fileURL
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 1)
        try await rig.select(0)
        try await rig.host.until("the Show in Finder button") { rig.paneElement(InspectorPane.showInFinderID) != nil }
        try #require(rig.host.window.focusSearchField() != nil)
        try #require(AXTree.press(try #require(rig.paneElement(InspectorPane.showInFinderID))))
        try await rig.host.until("the file revealed") { rig.recorder.revealed == [url] }
        #expect(rig.host.listHasFocus)
        try rig.host.pressReturn(command: true)
        #expect(rig.recorder.revealed == [url, url])
        #expect(rig.recorder.opened.isEmpty)
    }

    @Test func thePreviewTakesMouseAndWheelEventsAndTheControlsBesideItKeepTheirs() async throws {
        let files = try TemporaryFiles(["inspected-a.txt"])
        defer { files.remove() }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 1)
        try await rig.select(0)
        try await rig.untilRead(files.hits[0].path)
        try await rig.host.until("a shown preview and the buttons") {
            rig.paneHasPreview && rig.paneElement(InspectorPane.quickLookID) != nil && rig.paneElement(InspectorPane.showInFinderID) != nil
        }
        let (_, _, pane) = try rig.parts()
        pane.layoutSubtreeIfNeeded()
        let preview = try #require(rig.paneViews.first)
        let frame = try #require(rig.host.window.contentView?.superview)
        let hit = { (view: NSView, point: NSPoint) in frame.hitTest(view.convert(point, to: nil)) }
        let bounds = preview.bounds
        for (name, point) in [("centre", NSPoint(x: bounds.midX, y: bounds.midY)), ("scroller edge", NSPoint(x: bounds.maxX - 6, y: bounds.midY))] {
            let landed = hit(preview, point)
            #expect(landed?.isDescendant(of: preview) == true, "a hit at the preview's \(name) landed on \(String(describing: landed))")
        }
        let area = preview.convert(preview.bounds, to: nil)
        var covers = false
        var ancestor: NSView? = preview
        while let current = ancestor, current !== rig.host.window.contentView {
            for later in (current.superview?.subviews ?? []).drop(while: { $0 !== current }).dropFirst() where !later.isHidden && String(describing: type(of: later)) == "InspectorCanvas" {
                covers = covers || later.convert(later.bounds, to: nil).contains(area)
            }
            ancestor = current.superview
        }
        #expect(covers, "no drawing view lies above the preview, so a remote preview gets the window server's wheel, click and drag events")
        for id in [InspectorPane.quickLookID, InspectorPane.showInFinderID] {
            let button = try #require((rig.paneElement(id) as? NSCell)?.controlView as? NSButton)
            #expect(hit(button, NSPoint(x: button.bounds.midX, y: button.bounds.midY)) === button, "\(id) lost its clicks")
        }
        let owner = try #require(textField(NSUserName(), in: pane))
        let landed = hit(owner, NSPoint(x: owner.bounds.midX, y: owner.bounds.midY))
        #expect(landed?.isDescendant(of: preview) != true, "a hit on the facts landed in the preview")
    }

    @Test func thePreviewCannotDragTheFileOutButKeepsItsClickRecognizer() async throws {
        let files = try TemporaryFiles(["inspected-a.txt"])
        defer { files.remove() }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 1)
        try await rig.select(0)
        try await rig.untilRead(files.hits[0].path)
        try await rig.host.until("a shown preview") { rig.paneHasPreview }
        let recognizers = try #require(rig.paneViews.first).gestureRecognizers
        #expect(recognizers.filter { $0 is NSPanGestureRecognizer && $0.isEnabled }.isEmpty, "a drag in the preview still pulls the file out")
        #expect(recognizers.filter { $0 is NSPressGestureRecognizer && $0.isEnabled }.isEmpty, "a force touch in the preview still pulls the file out")
        #expect(recognizers.contains { $0 is NSClickGestureRecognizer && $0.isEnabled }, "the preview lost its click recognizer")
    }

    @Test func inspectorShowsTheButtonOnlyForAnArchive() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.zip"])
        defer { files.remove() }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true), archived: true)
        defer { rig.close() }
        try await rig.search("inspected", count: 2)
        try await rig.untilShownAtFirstWidth()
        try await rig.select(0)
        try await rig.untilRead(files.hits[0].path)
        try await rig.host.until("Quick Look for the text file") { rig.paneElement(InspectorPane.quickLookID) != nil }
        #expect(rig.paneElement(InspectorPane.showArchiveContentsID) == nil)

        try rig.table().selectRowIndexes([1], byExtendingSelection: false)
        try await rig.untilRead(files.hits[1].path)
        try await rig.host.until("Show Archive Contents for the zip") { rig.paneElement(InspectorPane.showArchiveContentsID) != nil }
        let button = try #require(rig.paneElement(InspectorPane.showArchiveContentsID))
        #expect(AXTree.names(of: button).contains(String(localized: "Show Archive Contents", table: "Results")))
        let (split, _, pane) = try rig.parts()
        let scale = rig.host.window.backingScaleFactor
        for width in [SearchMetrics.inspectorWidth, SearchMetrics.inspectorMinWidth] {
            split.splitView.setPosition(split.splitView.bounds.width - width - split.splitView.dividerThickness, ofDividerAt: 0)
            try await rig.host.until("the pane at \(width), widths \(String(describing: rig.widths()))") { rig.widths()?.pane == width }
            pane.layoutSubtreeIfNeeded()
            let quick = try #require(rig.paneElement(InspectorPane.quickLookID).flatMap(AXTree.frame(of:)))
            let finder = try #require(rig.paneElement(InspectorPane.showInFinderID).flatMap(AXTree.frame(of:)))
            let archive = try #require(rig.paneElement(InspectorPane.showArchiveContentsID).flatMap(AXTree.frame(of:)))
            let paneRect = try #require(pane.window).convertToScreen(pane.convert(pane.bounds, to: nil))
            #expect((finder.minY - quick.minY) * scale == 0, "Show in Finder left the first row at \(width) pt: \(quick), \(finder)")
            #expect(
                (quick.minY - archive.maxY - SearchMetrics.inspectorButtonSpacing) * scale == 0,
                "the archive button is not one gap under the first row at \(width) pt: \(quick), \(archive)"
            )
            #expect((archive.minX - quick.minX) * scale == 0, "the archive button does not start under Quick Look at \(width) pt: \(quick), \(archive)")
            #expect((archive.height - quick.height) * scale == 0)
            #expect(archive.width > 0 && archive.maxX <= paneRect.maxX - SearchMetrics.inspectorPadding, "the archive button runs past the pane at \(width) pt")
        }

        try rig.table().selectRowIndexes([0, 1], byExtendingSelection: false)
        try await rig.host.until("the pane to count two items") { rig.paneElement(InspectorPane.selectionID) != nil }
        #expect(rig.paneElement(InspectorPane.quickLookID) != nil)
        #expect(rig.paneElement(InspectorPane.showArchiveContentsID) == nil)
        try rig.table().selectRowIndexes([0], byExtendingSelection: false)
        try await rig.untilRead(files.hits[0].path)
        try await rig.host.until("the text file's name") { rig.paneShows(files.hits[0].name) }
        #expect(rig.paneElement(InspectorPane.showArchiveContentsID) == nil)
        #expect(rig.recorder.nothingHappened)
        #expect(ArchiveWindows.all.isEmpty)
    }

    @Test func inspectorButtonOpensTheWindow() async throws {
        let files = try TemporaryFiles(["inspected-b.zip"])
        defer { files.remove() }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true), archived: true)
        defer { rig.close() }
        let archive = try #require(rig.archive)
        try await rig.search("inspected", count: 1)
        try await rig.select(0)
        try await rig.host.until("the Show Archive Contents button") { rig.paneElement(InspectorPane.showArchiveContentsID) != nil }
        try #require(rig.host.window.focusSearchField() != nil)
        try #require(AXTree.press(try #require(rig.paneElement(InspectorPane.showArchiveContentsID))))
        try await rig.host.until("one archive window") { ArchiveWindows.all.count == 1 }
        let zip = files.hits[0].path
        #expect(archive.opened == [FakeArchiveClient.Opened(path: ArchiveWindows.resolved(zip), shownAs: zip)])
        let window = try #require(ArchiveWindows.all.first?.window)
        #expect(window.isVisible)
        #expect(window.identifier?.rawValue == ArchiveWindows.windowID)
        #expect(rig.host.listHasFocus)
        #expect(rig.recorder.nothingHappened)

        try rig.host.press(.downArrow, flags: .command)
        #expect(ArchiveWindows.all.count == 1)
        #expect(archive.opened.count == 1)
        #expect(ArchiveWindows.all.first?.window === window)
        #expect(window.isVisible)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func tabFromTheTableVisitsTheInspectorButtonsThenTheField() async throws {
        let files = try TemporaryFiles(["inspected-a.txt"])
        defer { files.remove() }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 1)
        try await rig.select(0)
        try await rig.untilShownAtFirstWidth()
        try await rig.host.until("the inspector's buttons") { rig.paneElement(InspectorPane.showInFinderID) != nil }
        let pane = try rig.parts().pane
        let table = try rig.table()
        let loop = rig.host.keyViewLoop(from: table)
        let names = loop.map { String(describing: type(of: $0)) }
        #expect(loop.last?.nextValidKeyView === rig.host.field(), "the stops \(names) do not wrap to the field")
        var links: [NSView] = [table]
        while let next = links.last?.nextKeyView, next !== rig.host.field(), !links.contains(where: { $0 === next }) { links.append(next) }
        #expect(links.contains { $0.isDescendant(of: pane) }, "no inspector view among the links \(links.map { String(describing: type(of: $0)) })")
        #expect(links.last?.nextKeyView === rig.host.field())
        if NSApp.isFullKeyboardAccessEnabled {
            let inspector = try #require(loop.firstIndex { $0.isDescendant(of: pane) }, "no inspector stop among \(names)")
            #expect(inspector > 0)
        }
        try rig.host.pressTab()
        if let first = loop.dropFirst().first {
            try await rig.host.until("Tab from the table to \(names[1]), stops \(names)") {
                (rig.host.window.firstResponder as? NSView)?.isDescendant(of: first) == true
            }
        } else {
            try await rig.host.until("Tab from the table to the field") { rig.host.fieldHasFocus }
        }
    }

    @Test func theInspectorKeepsItsMinimumWidth() async throws {
        let rig = InspectorRig(store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.untilShownAtFirstWidth()
        let split = try rig.parts().split
        for (asked, kept) in [(150, SearchMetrics.inspectorMinWidth), (500, SearchMetrics.inspectorMaxWidth)] {
            let total = split.splitView.bounds.width
            split.splitView.setPosition(total - CGFloat(asked) - split.splitView.dividerThickness, ofDividerAt: 0)
            try await rig.host.until("the pane at \(kept) after a drag to \(asked), widths \(String(describing: rig.widths()))") {
                rig.widths()?.pane == kept
            }
        }
    }

    @Test func aWindowResizeGoesToTheTable() async throws {
        let rig = InspectorRig(store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.untilShownAtFirstWidth()
        let before = try #require(rig.widths())
        let size = rig.host.view.frame.size
        rig.host.window.setContentSize(NSSize(width: size.width + 100, height: size.height))
        try await rig.host.until("the wider window, widths \(String(describing: rig.widths()))") { rig.widths()?.total == before.total + 100 }
        let after = try #require(rig.widths())
        #expect(after.pane == SearchMetrics.inspectorWidth)
        #expect(after.list == before.list + 100)
    }

    @Test func theInspectorReadsTheInspectorTableInGerman() async throws {
        let german = try #require(Bundle.main.url(forResource: "de", withExtension: "lproj").flatMap(Bundle.init(url:)), "no de.lproj")
        func word(_ key: String) throws -> String {
            let text = german.localizedString(forKey: key, value: "\u{1}", table: "Inspector")
            try #require(text != "\u{1}" && text != key, "the German Inspector table holds no \(key)")
            return text
        }
        let files = try TemporaryFiles(["inspected-a.txt"])
        defer { files.remove() }
        let store = inspectorStore(shown: true)
        let locale = Locale(identifier: "de")
        let rig = InspectorRig(hits: files.hits, store: store, locale: locale)
        defer { rig.host.close() }
        let none = try word("No Selection")
        try await rig.host.until("\(none) in the pane") { rig.paneShows(none) }
        try await rig.search("inspected", count: 1)
        try await rig.select(0)
        let keys = try ["Information", "Where", "Created", "Owner", "Permissions"].map { (english: $0, german: try word($0)) }
        try await rig.host.until("the German keys \(keys.map(\.german))") { keys.allSatisfy { rig.paneShows($0.german) } }
        for key in keys where key.english != "Information" { #expect(!rig.paneShows(key.english), "\(key.english) reads English") }

        let row = SearchHost(root: AnyView(InspectorSettingRow().defaultAppStorage(store).environment(\.locale, locale).padding()))
        defer { row.close() }
        let title = try word("Show inspector")
        try await row.until("the switch \(title)") { AXTree.control(title, in: row.view) != nil }
    }

    @Test func aGermanPaneAfterAnEnglishOneStillReadsGerman() async throws {
        let german = try #require(Bundle.main.url(forResource: "de", withExtension: "lproj").flatMap(Bundle.init(url:)), "no de.lproj")
        let owner = german.localizedString(forKey: "Owner", value: "\u{1}", table: "Inspector")
        let english = String(localized: "Owner", table: "Inspector", bundle: .main)
        try #require(owner != "\u{1}" && owner != english, "the German Owner key equals the English one")
        let files = try TemporaryFiles(["inspected-a.txt"])
        defer { files.remove() }
        for (locale, expected, other) in [(Locale(identifier: "en"), english, owner), (Locale(identifier: "de"), owner, english)] {
            let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true), locale: locale)
            defer { rig.host.close() }
            try await rig.search("inspected", count: 1)
            try await rig.select(0)
            try await rig.host.until("\(locale.identifier) key \(expected)") { rig.paneShows(expected) }
            #expect(!rig.paneShows(other), "\(locale.identifier) pane shows \(other)")
        }
    }
}

extension InspectorTests {
    @Test func severalSelectedFilesShowTheirCount() async throws {
        let files = try TemporaryFiles(["inspected-a.txt", "inspected-b.txt", "inspected-c.txt"])
        defer { files.remove() }
        let rig = InspectorRig(hits: files.hits, store: inspectorStore(shown: true))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 3)
        try await rig.select(0)
        try await rig.untilRead(files.hits[0].path)
        try rig.host.press(.downArrow, flags: .shift)
        try rig.host.press(.downArrow, flags: .shift)
        try #require(try rig.table().selectedRowIndexes == IndexSet(0...2))

        let count = String(localized: "\(3) items", table: "Results")
        try await rig.host.until("the pane to show \(count)") { rig.paneShows(count) && rig.paneElement(InspectorPane.selectionID) != nil }
        #expect(!rig.paneShows(String(localized: "Information", table: "Inspector")))
        #expect(rig.inspector?.facts == nil)
        #expect(rig.paneElement(InspectorPane.quickLookID) != nil)
        let reveal = try #require(rig.paneElement(InspectorPane.showInFinderID))
        try #require(rig.host.window.focusSearchField() != nil)
        try #require(AXTree.press(reveal))
        try await rig.host.until("the three files revealed") { rig.recorder.revealed == files.hits.map(\.fileURL) }
        #expect(rig.recorder.reveals == 1)
        #expect(rig.recorder.opened.isEmpty)

        try rig.table().selectRowIndexes([1], byExtendingSelection: false)
        try await rig.untilRead(files.hits[1].path)
        try await rig.host.until("file 1's name and summary") {
            rig.paneShows(files.hits[1].name) && rig.paneShows(TemporaryFiles.summary(files.hits[1]))
        }
        #expect(!rig.paneShows(count))
        #expect(rig.paneElement(InspectorPane.selectionID) == nil)
    }
}

private func staticTextFrame(_ text: String, in root: NSView) -> NSRect? {
    AXTree.elements(in: root).first { element in
        (AXTree.value("accessibilityRole", of: element) as String?) == NSAccessibility.Role.staticText.rawValue
            && (AXTree.names(of: element).contains(text) || (AXTree.value("accessibilityValue", of: element) as String?) == text)
    }.flatMap(AXTree.frame(of:))
}

extension InspectorTests {
    @Test func theInspectorFollowsTheTextSizeLive() async throws {
        let files = try TemporaryFiles(["inspected-size.txt"])
        defer { files.remove() }
        let hit = files.hits[0]
        let store = inspectorStore(shown: true)
        let rig = InspectorRig(hits: files.hits, store: store)
        defer { rig.host.close() }
        try await rig.search("inspected", count: 1)
        try await rig.select(0)
        try await rig.untilRead(hit.path)
        let (_, _, pane) = try rig.parts()
        let kindKey = String(localized: "Kind", table: "Results")
        let kind = ResultType.of(hit).kind
        func frames() -> (name: NSRect, key: NSRect, value: NSRect)? {
            guard let name = staticTextFrame(hit.name, in: pane), let key = staticTextFrame(kindKey, in: pane),
                  let value = staticTextFrame(kind, in: pane) else { return nil }
            return (name, key, value)
        }
        try await rig.host.until("the name and the Kind fact") { frames() != nil }
        let before = try #require(frames())
        let scale = rig.host.window.backingScaleFactor
        #expect((before.value.minX - before.key.minX - SearchMetrics.factKeyWidth - SearchMetrics.factGap) * scale == 0)

        store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        try await rig.host.until("the pane at 18 pt") { rig.split()?.pane.textSize == .maximum }
        #expect(TextSize.maximum.width(SearchMetrics.factKeyWidth) == 97 && TextSize.maximum.points(NSFont.smallSystemFontSize) == 15)
        try await rig.host.until("a taller name and fact, a 97 pt key column") {
            guard let after = frames() else { return false }
            return after.name.height - before.name.height > 3 && after.value.height - before.value.height > 3
                && (after.value.minX - after.key.minX - 97 - SearchMetrics.factGap) * scale == 0
        }
        store.removeObject(forKey: TextSize.key)
        try await rig.host.until("the pane at 13 pt again") {
            rig.split()?.pane.textSize == .standard && frames()?.name.height == before.name.height
        }
    }

    @Test func theSettingsRowLabelFollowsTheTextSize() async throws {
        let store = inspectorStore(shown: false)
        let row = SearchHost(root: AnyView(InspectorSettingRow().defaultAppStorage(store).padding()))
        defer { row.close() }
        let title = String(localized: "Show inspector", table: "Inspector")
        try await row.until("the Show inspector switch") { AXTree.control(title, in: row.view) != nil }
        func reference(_ font: Font?) -> NSSize {
            NSHostingView(rootView: Toggle(isOn: .constant(false)) { Text(title).font(font) }.toggleStyle(.switch).padding()).fittingSize
        }
        let standard = reference(nil), largest = reference(Font(TextSize.maximum.font(.preferredFont(forTextStyle: .body)) as CTFont))
        try #require(largest != standard, "the reference rows \(standard) and \(largest) cannot tell the sizes apart")
        #expect(row.view.fittingSize == standard)
        store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        try await row.until("the row \(largest) at 18 pt, now \(row.view.fittingSize)") { row.view.fittingSize == largest }
        store.removeObject(forKey: TextSize.key)
        try await row.until("the row at 13 pt again") { row.view.fittingSize == standard }
        #expect(!store.bool(forKey: InspectorPane.shownKey))
    }
}

extension InspectorTests {
    @Test(arguments: [("nl", 13), ("nl", 18), ("de", 11)])
    func theLongestLocalizedKeyFitsItsColumnOnOneLine(_ language: String, _ points: Int) async throws {
        let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
        let permissions = bundle.localizedString(forKey: "Permissions", value: "\u{1}", table: "Inspector")
        let kindKey = bundle.localizedString(forKey: "Kind", value: "\u{1}", table: "Results")
        try #require(permissions != "\u{1}" && permissions != "Permissions" && kindKey != "\u{1}" && kindKey != "Kind")
        let size = try #require(TextSize(rawValue: points))
        let files = try TemporaryFiles(["inspected-\(language)-\(points).txt"])
        defer { files.remove() }
        let hit = files.hits[0]
        let store = inspectorStore(shown: true)
        store.set(points, forKey: TextSize.key)
        let rig = InspectorRig(hits: files.hits, store: store, locale: Locale(identifier: language))
        defer { rig.host.close() }
        try await rig.search("inspected", count: 1)
        try await rig.select(0)
        try await rig.untilRead(hit.path)
        let (_, _, pane) = try rig.parts()
        let kind = ResultType.of(hit).kind
        func frames() -> (key: NSRect, value: NSRect, permissions: NSRect)? {
            guard let key = staticTextFrame(kindKey, in: pane), let value = staticTextFrame(kind, in: pane),
                  let long = staticTextFrame(permissions, in: pane) else { return nil }
            return (key, value, long)
        }
        try await rig.host.until("the \(language) Kind and \(permissions) facts at \(points) pt") { frames() != nil }
        let found = try #require(frames())
        let font = NSFont.systemFont(ofSize: size.points(NSFont.smallSystemFontSize))
        let single = ceil(NSAttributedString(string: permissions, attributes: [.font: font]).size().width)
        let column = found.value.minX - found.key.minX - SearchMetrics.factGap
        let scale = rig.host.window.backingScaleFactor
        #expect(column >= single, "\(permissions) needs \(single) pt, the column is \(column) pt")
        #expect((found.permissions.height - found.key.height) * scale == 0, "\(permissions) wraps")
    }
}

@MainActor
private func paneEntries(_ pane: NSView) -> [(entry: String, frame: NSRect)] {
    guard let window = pane.window else { return [] }
    let paneRect = window.convertToScreen(pane.convert(pane.bounds, to: nil))
    let hidden = [NSAccessibility.Role.scrollBar, .valueIndicator].map(\.rawValue)
    return AXTree.elements(in: pane).compactMap { element in
        guard let role: String = AXTree.value("accessibilityRole", of: element), !hidden.contains(role),
              !String(describing: type(of: element)).contains("Scroller") else { return nil }
        let text = [AXTree.identifier(of: element) ?? ""].filter { _ in role == NSAccessibility.Role.group.rawValue || role == NSAccessibility.Role.scrollArea.rawValue }
            + AXTree.names(of: element)
        let frame = AXTree.frame(of: element) ?? .zero
        let entry = "\(role) \(text.first { !$0.isEmpty } ?? "")"
        return (entry, NSRect(x: frame.minX - paneRect.minX, y: paneRect.maxY - frame.maxY, width: frame.width, height: frame.height))
    }
}

private func scrollView(in view: NSView) -> NSScrollView? {
    (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView(in:)).first
}

extension InspectorTests {
    @Test(arguments: [13, 18])
    func theInspectorLooksAsDrawn(_ points: Int) async throws {
        let size = try #require(TextSize(rawValue: points))
        let folder = NSTemporaryDirectory() + "wherever-looks-\(UUID().uuidString)"
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        var hits: [SearchHit] = []
        for (name, bytes) in [("Report.pdf", 12_345), ("Second Report.pdf", 23_456)] {
            let path = folder + "/" + name
            try Data(repeating: 7, count: bytes).write(to: URL(filePath: path))
            try FileManager.default.setAttributes([.creationDate: moment, .modificationDate: moment], ofItemAtPath: path)
            hits.append(SearchHit(name: name, folder: folder, size: Int64(bytes), modified: moment, created: moment, opened: moment, kind: .file))
        }
        InspectorModel.datalessCheck = { $0.hasSuffix("Second Report.pdf") }
        defer { InspectorModel.datalessCheck = isDataless }
        let store = inspectorStore(shown: true)
        store.set(points, forKey: TextSize.key)
        let rig = InspectorRig(hits: hits, store: store, locale: Locale(identifier: "en"))
        defer { rig.host.close() }
        try await rig.search("report", count: 2)
        try await rig.untilShownAtFirstWidth()
        let pane = try rig.parts().pane
        let words = { (key: String, table: String) in String(localized: String.LocalizationValue(key), table: table) }
        let keys = [("Kind", "Results"), ("Size", "Results"), ("Where", "Inspector"), ("Created", "Inspector"), ("Modified", "Results"), ("Owner", "Inspector"), ("Permissions", "Inspector")].map(words)
        let sizes = ByteCountFormatter()
        sizes.countStyle = .file
        sizes.includesActualByteCount = true
        func single(_ hit: SearchHit, dataless: Bool) -> [String] {
            let kind = ResultType.of(hit).kind
            let values = [kind, sizes.string(fromByteCount: hit.size), hit.folder, FileDates.current.string(moment), FileDates.current.string(moment), NSUserName(), words("Read & Write", "Inspector")]
            return ["AXGroup ", "AXScrollArea \(InspectorPane.id)", dataless ? "AXStaticText \(words("In iCloud", "Inspector"))" : "AXProgressIndicator Preview",
                    "AXStaticText \(hit.name)", "AXStaticText \(TemporaryFiles.summary(hit))", "AXButton \(words("Quick Look", "Results"))",
                    "AXButton \(words("Show in Finder", "Results"))", "AXStaticText \(words("Information", "Inspector"))", "AXGroup \(InspectorPane.infoID)"]
                + zip(keys, values).flatMap { ["AXStaticText \($0)", "AXStaticText \($1)"] }
        }
        let buttons = ["AXButton \(words("Quick Look", "Results"))", "AXButton \(words("Show in Finder", "Results"))"]
        let table = try rig.table()

        try await rig.host.until("the No Selection order, now \(paneEntries(pane).map(\.entry))") {
            paneEntries(pane).map(\.entry) == ["AXGroup ", "AXGroup \(InspectorPane.id)", "AXStaticText \(words("No Selection", "Inspector"))"]
        }
        try await rig.host.focusList()
        table.selectRowIndexes([0, 1], byExtendingSelection: false)
        try await rig.host.until("the several items order, now \(paneEntries(pane).map(\.entry))") {
            paneEntries(pane).map(\.entry) == ["AXGroup ", "AXGroup \(InspectorPane.id)", "AXStaticText \(String(localized: "\(2) items", table: "Results"))"] + buttons
        }
        table.selectRowIndexes([1], byExtendingSelection: false)
        try await rig.host.until("the In iCloud order, now \(paneEntries(pane).map(\.entry))") { paneEntries(pane).map(\.entry) == single(hits[1], dataless: true) }
        table.selectRowIndexes([0], byExtendingSelection: false)
        try await rig.host.until("the one item order, now \(paneEntries(pane).map(\.entry))") { paneEntries(pane).map(\.entry) == single(hits[0], dataless: false) }

        let scroll = try #require(scrollView(in: pane))
        scroll.scrollerStyle = .legacy
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        let frames = paneEntries(pane).map(\.frame)
        try #require(frames.count == 23)
        let probe: [Int: (name: CGSize, summary: CGSize, information: CGSize, keys: [CGFloat], key: CGFloat)] = [
            13: (CGSize(width: 69, height: 16), CGSize(width: 117, height: 14), CGSize(width: 64, height: 14), [24, 23, 35, 42, 46, 35, 64], 14),
            18: (CGSize(width: 91, height: 21), CGSize(width: 153, height: 19), CGSize(width: 83, height: 19), [31, 29, 45, 55, 60, 46, 83], 19),
        ]
        let drawn = try #require(probe[points])
        let native = NSButton(title: words("Quick Look", "Results"), target: nil, action: nil)
        native.bezelStyle = Availability.inspectorButtonBezel
        native.font = .systemFont(ofSize: size.points(NSFont.systemFontSize))
        let buttonHeight = native.intrinsicContentSize.height
        let pad = SearchMetrics.inspectorPadding
        let spacing = SearchMetrics.inspectorSpacing
        let content = pane.bounds.width - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) - 2 * pad
        let column = InspectorPane.keyWidth(keys, textSize: size)
        let scale = rig.host.window.backingScaleFactor
        let buttonWidth = { (title: String, proposal: CGFloat) in
            NSHostingController(rootView: Button(action: {}) { Text(verbatim: title).font(size.formText) }.environment(\.locale, Locale(identifier: "en")))
                .sizeThatFits(in: CGSize(width: proposal, height: CGFloat.infinity)).width
        }
        let titles = (words("Quick Look", "Results"), words("Show in Finder", "Results"))
        let ideals = (buttonWidth(titles.0, .infinity), buttonWidth(titles.1, .infinity))
        let fit = { (title: String, ideal: CGFloat, proposal: CGFloat) in proposal >= ideal ? ideal : min(buttonWidth(title, proposal), proposal) }
        let room = content - SearchMetrics.inspectorButtonSpacing
        var split = ideals
        if ideals.0 - buttonWidth(titles.0, 0) <= ideals.1 - buttonWidth(titles.1, 0) {
            split.0 = fit(titles.0, ideals.0, room / 2)
            split.1 = fit(titles.1, ideals.1, room - split.0)
        } else {
            split.1 = fit(titles.1, ideals.1, room / 2)
            split.0 = fit(titles.0, ideals.0, room - split.1)
        }
        let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
        let end = snap(split.0 + SearchMetrics.inspectorButtonSpacing + split.1)
        let widths = (quickLook: snap(split.0), showInFinder: end - snap(split.0) - SearchMetrics.inspectorButtonSpacing)
        func same(_ found: NSRect, _ expected: NSRect, _ what: String) {
            let gaps = [found.minX - expected.minX, found.minY - expected.minY, found.width - expected.width, found.height - expected.height]
            #expect(gaps.allSatisfy { $0 * scale == 0 }, "\(what) at \(points) pt is \(found), drawn \(expected)")
        }
        same(frames[2], NSRect(x: pad, y: pad, width: content, height: SearchMetrics.previewHeight), "the preview")
        same(frames[3], NSRect(origin: NSPoint(x: pad, y: pad + SearchMetrics.previewHeight + spacing), size: drawn.name), "the name")
        same(frames[4], NSRect(origin: NSPoint(x: pad, y: frames[3].maxY + SearchMetrics.inspectorTitleSpacing), size: drawn.summary), "the summary")
        let row = frames[4].maxY + spacing
        same(frames[5], NSRect(x: pad, y: row, width: widths.quickLook, height: buttonHeight), "Quick Look")
        same(frames[6], NSRect(x: pad + widths.quickLook + SearchMetrics.inspectorButtonSpacing, y: row, width: widths.showInFinder, height: buttonHeight), "Show in Finder")
        same(frames[7], NSRect(origin: NSPoint(x: pad, y: row + buttonHeight + spacing + 1 + spacing), size: drawn.information), "Information")
        var top = frames[7].maxY + spacing
        var widest: CGFloat = 0
        for (index, width) in drawn.keys.enumerated() {
            let key = frames[9 + 2 * index], value = frames[10 + 2 * index]
            same(key, NSRect(x: pad, y: top, width: width, height: drawn.key), keys[index])
            same(value, NSRect(x: pad + column + SearchMetrics.factGap, y: top, width: value.width, height: value.height), "the \(keys[index]) value")
            widest = max(widest, value.width)
            top += max(drawn.key, value.height) + SearchMetrics.factRowSpacing
        }
        same(frames[8], NSRect(x: pad, y: frames[7].maxY + spacing, width: column + SearchMetrics.factGap + widest, height: top - SearchMetrics.factRowSpacing - frames[7].maxY - spacing), "the facts group")
    }
}

private let refitMoment = Date(timeIntervalSince1970: 1_700_000_000)

private func refitHits(_ entries: [(name: String, bytes: Int?)]) throws -> (folder: String, hits: [SearchHit]) {
    let folder = NSTemporaryDirectory() + "wherever-refit-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let hits = try entries.map { entry in
        let path = folder + "/" + entry.name
        if let bytes = entry.bytes {
            try Data(repeating: 7, count: bytes).write(to: URL(filePath: path))
        } else {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        }
        return SearchHit(
            name: entry.name, folder: folder, size: Int64(entry.bytes ?? 0), modified: refitMoment, created: refitMoment, opened: refitMoment,
            kind: entry.bytes == nil ? .folder : .file
        )
    }
    return (folder, hits)
}

private struct RefitField: Equatable {
    let text: String
    let frame: NSRect
    let drawn: NSRect
}

@MainActor
private struct BarePane {
    let inspector = InspectorModel()
    let dates: FileDates
    let pane: InspectorPane
    let window: NSWindow

    init(
        dates: FileDates = .current, locale: Locale = Locale(identifier: "en"), direction: NSUserInterfaceLayoutDirection = .leftToRight, archives: Bool = false
    ) {
        inspector.shown = true
        self.dates = dates
        pane = InspectorPane(inspector: inspector, dates: dates, quickLook: {}, reveal: {}, allows: { _ in archives })
        pane.apply(theme: .systemNative, textSize: .standard, locale: locale)
        window = NSWindow(contentViewController: pane)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: SearchMetrics.inspectorWidth, height: SearchMetrics.windowMinHeight))
        pane.view.userInterfaceLayoutDirection = direction
        window.orderFront(nil)
    }

    func close() { window.close() }

    func restyle(theme: Theme? = nil, textSize: TextSize? = nil, locale: Locale? = nil) {
        pane.apply(theme: theme ?? pane.theme, textSize: textSize ?? pane.textSize, locale: locale ?? pane.locale)
    }

    func show(_ hit: SearchHit, count: Int = 1) async throws {
        inspector.select(hit, count: count)
        try await untilTrue(waitingFor: "the inspector on \(hit.name), \(count) selected") {
            inspector.hit == hit && inspector.count == count && (count > 1 || inspector.facts != nil)
        }
    }

    func fields() -> [RefitField] {
        func walk(_ view: NSView) -> [RefitField] {
            guard !view.isHidden, !(view is QLPreviewView), !(view is NSButton) else { return [] }
            let drawn = view.convert(view.bounds, to: nil)
            if let field = view as? NSTextField { return [RefitField(text: field.stringValue, frame: field.accessibilityFrame(), drawn: drawn)] }
            let own = view.accessibilityIdentifier() == InspectorPane.infoID ? [RefitField(text: InspectorPane.infoID, frame: window.convertToScreen(drawn), drawn: drawn)] : []
            return own + view.subviews.flatMap(walk)
        }
        return walk(pane.view)
    }

    func texts() -> [String] { fields().map(\.text).filter { $0 != InspectorPane.infoID } }

    func screenFrame(ofButton id: String) -> NSRect? {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.cell?.accessibilityIdentifier() == id { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(pane.view).map { window.convertToScreen($0.convert($0.bounds, to: nil)) }
    }

    func frame(_ text: String) -> NSRect? { fields().first { $0.text == text }?.frame }

    var info: NSRect? { frame(InspectorPane.infoID) }

    @discardableResult
    func settled(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) -> [RefitField] {
        pane.view.layoutSubtreeIfNeeded()
        let shown = fields()
        pane.view.needsLayout = true
        pane.view.layoutSubtreeIfNeeded()
        let laid = fields()
        let moved = zip(shown, laid).filter { $0 != $1 }.map { "\($0.text): \($0.frame) \($0.drawn) then \($1.frame) \($1.drawn)" }
        #expect(shown == laid, "\(what): a full layout changed \(moved), \(shown.count) fields then \(laid.count)", sourceLocation: sourceLocation)
        return laid
    }

    func shown() -> [String] {
        let texts = texts()
        guard texts.count == 17 else { return texts }
        return [texts[0], texts[1]] + stride(from: 4, to: 17, by: 2).map { texts[$0] }
    }

    func expected(_ hit: SearchHit) -> [String] {
        let kind = ResultType.of(hit).kind
        let folder = hit.kind == .folder
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        bytes.includesActualByteCount = true
        let facts = inspector.facts
        return [
            hit.name, folder ? kind : TemporaryFiles.summary(hit), kind, folder ? "--" : bytes.string(fromByteCount: hit.size), hit.folder,
            facts?.created.map(dates.string) ?? "--", dates.string(hit.modified), facts?.owner ?? "--", InspectorPane.permissions(facts),
        ]
    }

    func check(_ hit: SearchHit, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        settled(what, sourceLocation: sourceLocation)
        #expect(shown() == expected(hit), "\(what)", sourceLocation: sourceLocation)
    }
}

extension InspectorTests {
    @Test func theSameSizeWithANewKindRefitsTheNameAndSummary() async throws {
        let (folder, hits) = try refitHits([("b.txt", 4_096), ("A much longer report.pdf", 4_096), ("c.txt", 4_096)])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let bare = BarePane()
        defer { bare.close() }
        try await bare.show(hits[0])
        bare.check(hits[0], "b.txt")
        let first = try #require(bare.frame(TemporaryFiles.summary(hits[0])))
        try await bare.show(hits[1])
        bare.check(hits[1], "the pdf of the same size")
        let second = try #require(bare.frame(TemporaryFiles.summary(hits[1])))
        try #require(ResultType.of(hits[0]).kind != ResultType.of(hits[1]).kind && first.height == second.height)
        #expect(second.width != first.width)
        try await bare.show(hits[2])
        bare.check(hits[2], "back to a text file of the same size")
    }

    @Test func aFolderNextToAFileShowsItsKindAndNoSize() async throws {
        let (folder, hits) = try refitHits([("notes.txt", 2_000), ("Sub folder", nil), ("other.txt", 2_000)])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let bare = BarePane()
        defer { bare.close() }
        for (hit, what) in zip(hits, ["the file", "the folder beside it", "the next file"]) {
            try await bare.show(hit)
            bare.check(hit, what)
        }
        try await bare.show(hits[1])
        bare.check(hits[1], "the folder again")
        let shown = bare.shown()
        #expect(shown.count == 9 && shown[1] == ResultType.of(hits[1]).kind && shown[3] == "--")
    }

    @Test func aNameThatChangesHeightMovesEverythingBelowIt() async throws {
        let long = "A name long enough to wrap onto a second line in the inspector pane.txt"
        let (folder, hits) = try refitHits([("short.txt", 1_000), (long, 1_000), ("brief.txt", 1_000)])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let bare = BarePane()
        defer { bare.close() }
        var names: [NSRect] = []
        var summaries: [NSRect] = []
        for (hit, what) in zip(hits, ["one line", "two lines", "one line again"]) {
            try await bare.show(hit)
            bare.check(hit, what)
            names.append(try #require(bare.frame(hit.name)))
            summaries.append(try #require(bare.frame(TemporaryFiles.summary(hit))))
        }
        #expect(names[1].height > names[0].height, "the long name is \(names[1].height) high, the short one \(names[0].height)")
        #expect(summaries[1].maxY < summaries[0].maxY)
        #expect(names[2].height == names[0].height && summaries[2].maxY == summaries[0].maxY)
    }

    @Test func theFactsGroupFollowsTheWidestValue() async throws {
        let hit = { (name: String, folder: String) in
            SearchHit(name: name, folder: folder, size: 1_000, modified: refitMoment, created: refitMoment, opened: refitMoment, kind: .file)
        }
        let bare = BarePane()
        defer { bare.close() }
        func facts() throws -> (group: NSRect, values: [NSRect], texts: [String]) {
            let all = bare.fields()
            let start = try #require(all.firstIndex { $0.text == InspectorPane.infoID })
            let values = stride(from: start + 2, to: all.count, by: 2).map { all[$0] }
            return (all[start].frame, values.map(\.frame), values.map(\.text))
        }
        let narrow = hit("w-small.txt", "/w")
        try await bare.show(narrow)
        bare.check(narrow, "a narrow folder")
        let first = try facts()
        try #require(first.values.count == 7 && first.texts[2] == "/w")
        let widest = try #require(first.values.map(\.width).max())
        let details = try #require(scrollView(in: bare.pane.view)?.documentView)
        let room = details.bounds.width - 2 * SearchMetrics.inspectorPadding - (first.values[0].minX - first.group.minX)
        let label = NSTextField(labelWithString: "/w")
        label.font = .systemFont(ofSize: TextSize.standard.points(NSFont.smallSystemFontSize))
        while label.intrinsicContentSize.width < widest + 8 { label.stringValue += "x" }
        try #require(label.intrinsicContentSize.width < room - 8, "a one-line folder \(label.intrinsicContentSize.width) wide does not fit the room of \(room)")
        let wide = hit("w-wide.txt", label.stringValue)
        try await bare.show(wide)
        bare.check(wide, "a folder that becomes the widest value on one line")
        let grown = try facts()
        let back = hit("w-small-2.txt", "/w")
        try await bare.show(back)
        bare.check(back, "a folder that stops being the widest value")
        let shrunk = try facts()
        let heights = [first, grown, shrunk].map { $0.values[2].height }
        try #require(heights.allSatisfy { $0 == heights[0] }, "the folder is \(heights) high")
        #expect(grown.values[2].width > widest, "the wide folder is \(grown.values[2].width), the widest value was \(widest)")
        #expect(grown.group.width > first.group.width, "the facts group is \(grown.group.width) wide with the wide folder, \(first.group.width) before")
        #expect(shrunk.group.width == first.group.width, "the facts group is \(shrunk.group.width) wide after the wide folder, \(first.group.width) at first")
    }
}

extension InspectorTests {
    @Test func aTextSizeLanguageOrThemeChangeAfterARefitLaysOutAgain() async throws {
        let (folder, hits) = try refitHits([("first.txt", 1_000), ("second file.txt", 1_000), ("third.md", 3_000)])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let bare = BarePane()
        defer { bare.close() }
        try await bare.show(hits[0])
        bare.check(hits[0], "the first file")
        try await bare.show(hits[1])
        bare.check(hits[1], "the refitted second file")
        let standard = try #require(bare.frame(hits[1].name))
        bare.restyle(textSize: .maximum)
        bare.check(hits[1], "at 18 pt")
        let largest = try #require(bare.frame(hits[1].name))
        #expect(largest.height > standard.height && largest.width > standard.width)
        bare.restyle(locale: Locale(identifier: "de"))
        bare.check(hits[1], "in German")
        let german = try #require(Bundle.main.url(forResource: "de", withExtension: "lproj").flatMap(Bundle.init(url:)))
        let owner = german.localizedString(forKey: "Owner", value: nil, table: "Inspector")
        try #require(owner != "Owner")
        #expect(bare.texts().contains(owner), "the German facts read \(bare.texts())")
        bare.restyle(theme: .warmPaper)
        bare.check(hits[1], "in Warm Paper")
        try await bare.show(hits[2])
        bare.check(hits[2], "a refit after the three changes")
        try await bare.show(hits[0])
        bare.check(hits[0], "the first file at 18 pt in German")
    }

    @Test func severalItemsThenOneItemShowsThatItem() async throws {
        let (folder, hits) = try refitHits([("one.txt", 1_000), ("two items.txt", 5_000), ("three.pdf", 9_000)])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let bare = BarePane()
        defer { bare.close() }
        try await bare.show(hits[0])
        bare.check(hits[0], "one item")
        try await bare.show(hits[0], count: 3)
        bare.settled("three items")
        #expect(bare.texts() == [String(localized: "\(3) items", table: "Results")])
        try await bare.show(hits[2])
        bare.check(hits[2], "one other item after three")
        try await bare.show(hits[1])
        bare.check(hits[1], "a refit after the several items")
    }

    @Test func rightToLeftFramesMirrorAfterARefit() async throws {
        let (folder, hits) = try refitHits([("short.txt", 1_000), ("a longer name.txt", 2_000), ("mid.pdf", 3_000)])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let bare = BarePane(locale: Locale(identifier: "ar"), direction: .rightToLeft)
        defer { bare.close() }
        let scale = bare.window.backingScaleFactor
        for (hit, what) in zip(hits, ["the first file", "a refit to a longer name", "a refit to a pdf"]) {
            try await bare.show(hit)
            bare.check(hit, "right to left, \(what)")
            let details = try #require(scrollView(in: bare.pane.view)?.documentView)
            let right = bare.window.convertToScreen(details.convert(details.bounds, to: nil)).maxX - SearchMetrics.inspectorPadding
            let name = try #require(bare.frame(hit.name))
            let summary = try #require(bare.frame(TemporaryFiles.summary(hit)))
            #expect((name.maxX - right) * scale == 0 && (summary.maxX - right) * scale == 0, "\(what): the name ends at \(name.maxX), the summary at \(summary.maxX), the content at \(right)")
            let all = bare.fields()
            let start = try #require(all.firstIndex { $0.text == InspectorPane.infoID })
            let values = stride(from: start + 2, to: all.count, by: 2).map { all[$0].frame }
            try #require(values.count == 7)
            #expect(values.allSatisfy { ($0.maxX - values[0].maxX) * scale == 0 }, "\(what): the values end at \(values.map(\.maxX))")
        }
    }

    @Test func theArchiveButtonKeepsItsPlaceInEveryLanguageTextSizeAndWidth() async throws {
        let (folder, hits) = try refitHits([("bundle.zip", 1_000)])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let pad = SearchMetrics.inspectorPadding
        var shrunk = false
        for language in ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"] {
            let locale = Locale(identifier: language)
            let rtl = language == "ar"
            let bare = BarePane(locale: locale, direction: rtl ? .rightToLeft : .leftToRight, archives: true)
            defer { bare.close() }
            let scale = bare.window.backingScaleFactor
            let title = String(localized: "Show Archive Contents", table: "Results", bundle: AppearanceRow.bundle(locale))
            try await bare.show(hits[0])
            for size in [TextSize.standard, .maximum] {
                let ideal = NSHostingController(rootView: Button(action: {}) { Text(verbatim: title).font(size.formText) }.environment(\.locale, locale))
                    .sizeThatFits(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
                for width in [SearchMetrics.inspectorMinWidth, SearchMetrics.inspectorWidth, SearchMetrics.inspectorMaxWidth] {
                    let what = "\(language), \(size.rawValue) pt, \(width) pt wide"
                    bare.restyle(textSize: size)
                    bare.window.setContentSize(NSSize(width: width, height: SearchMetrics.windowMinHeight))
                    bare.settled(what)
                    let quick = try #require(bare.screenFrame(ofButton: InspectorPane.quickLookID), "no Quick Look button, \(what)")
                    let finder = try #require(bare.screenFrame(ofButton: InspectorPane.showInFinderID), "no Show in Finder button, \(what)")
                    let archive = try #require(bare.screenFrame(ofButton: InspectorPane.showArchiveContentsID), "no archive button, \(what)")
                    let details = try #require(scrollView(in: bare.pane.view)?.documentView, "no details view, \(what)")
                    let sheet = bare.window.convertToScreen(details.convert(details.bounds, to: nil))
                    let (left, right) = (sheet.minX + pad, sheet.maxX - pad)
                    #expect((finder.minY - quick.minY) * scale == 0, "Show in Finder left the first row, \(what): \(quick), \(finder)")
                    #expect(
                        (quick.minY - archive.maxY - SearchMetrics.inspectorButtonSpacing) * scale == 0,
                        "the archive button is not one gap under the first row, \(what): \(quick), \(archive)"
                    )
                    #expect((archive.height - quick.height) * scale == 0, "the archive button is \(archive.height) high, Quick Look \(quick.height), \(what)")
                    #expect(archive.width > 0 && (right - left - archive.width) * scale >= 0, "the archive button is \(archive.width) wide in \(right - left), \(what)")
                    #expect(
                        (rtl ? right - archive.maxX : archive.minX - left) * scale == 0 && (rtl ? right - quick.maxX : quick.minX - left) * scale == 0,
                        "the archive button and Quick Look do not share the leading edge, \(what): \(quick), \(archive), content \(left) to \(right)"
                    )
                    #expect(
                        rtl ? finder.maxX <= quick.minX && (finder.minX - left) * scale >= 0 : quick.maxX <= finder.minX && (right - finder.maxX) * scale >= 0,
                        "the first row is out of order or outside the content, \(what): \(quick), \(finder)"
                    )
                    if ideal <= right - left {
                        #expect((archive.width - (ideal * scale).rounded() / scale) * scale == 0, "the archive button is \(archive.width) wide, its title needs \(ideal), \(what)")
                    } else {
                        shrunk = true
                    }
                }
            }
        }
        #expect(shrunk, "no language shrank the archive button, so the long-title path never ran")
    }

    @Test(arguments: Theme.allCases, [AppearanceMode.light, .dark])
    func theInspectorDrawsEveryThemeInItsForcedLightOrDarkValues(theme: Theme, mode: AppearanceMode) async throws {
        let files = try TemporaryFiles(["themed-a.txt"])
        defer { files.remove() }
        let hit = files.hits[0]
        let look: Look = mode == .dark ? .dark : .light
        let other: Look = mode == .dark ? .light : .dark
        let store = inspectorStore(shown: true)
        store.set(theme.rawValue, forKey: Theme.key)
        let previous = NSApplication.shared.appearance
        setAppAppearance(mode.appearance)
        defer { setAppAppearance(previous) }
        let rig = InspectorRig(hits: files.hits, store: store)
        defer { rig.close() }
        try await rig.search("themed", count: 1)
        try await rig.select(0)
        try await rig.untilRead(hit.path)
        try await rig.untilShownAtFirstWidth()
        let pane = try #require(rig.split()).pane
        let summary = TemporaryFiles.summary(hit)
        try await rig.host.until("\(theme) \(mode) in the pane") {
            pane.theme == theme && rig.paneShows(hit.name) && rig.paneShows(summary) && rig.paneShows(NSUserName())
        }
        let what = "\(theme) under \(mode.rawValue)"
        #expect(pane.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == look.appearance.name, "\(what): the pane reads \(pane.view.effectiveAppearance.name.rawValue)")

        pane.view.layoutSubtreeIfNeeded()
        let rep = try #require(pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds))
        pane.view.cacheDisplay(in: pane.view.bounds, to: rep)
        let drawn = try #require(srgbPixel(rep, x: 2, y: 2))
        let wanted = eightBits(channels(theme.windowBackground, look))
        #expect(zip(drawn, wanted).allSatisfy { abs($0 - $1) <= 1 }, "\(what): the pane background is \(drawn), not \(wanted)")
        #expect(drawn != eightBits(channels(theme.windowBackground, other)), "\(what): the pane background shows the other mode's value \(drawn)")

        for (text, token, role) in [(hit.name, theme.text, "name"), (summary, theme.secondaryText, "summary"), (NSUserName(), theme.text, "owner")] {
            let field = try #require(textField(text, in: pane.view), "\(what): no \(role) field")
            let color = try #require(field.textColor)
            #expect(channels(color, look) == channels(token, look), "\(what): the \(role) is \(channels(color, look)), not \(channels(token, look))")
        }
    }

    @Test func aRegionChangeAfterARefitShowsTheNewDates() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var locale = Locale(identifier: "en_US")
        let dates = FileDates(calendar: calendar, localeProvider: { locale })
        let (folder, hits) = try refitHits([("dated.txt", 1_000), ("dated again.txt", 2_000)])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let bare = BarePane(dates: dates)
        defer { bare.close() }
        try await bare.show(hits[0])
        bare.check(hits[0], "the first file")
        try await bare.show(hits[1])
        bare.check(hits[1], "the refitted second file")
        let before = dates.string(refitMoment)
        let revision = dates.revision
        locale = Locale(identifier: "de_DE")
        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        try await untilTrue(waitingFor: "the German dates in the pane") { dates.revision > revision && bare.shown() == bare.expected(hits[1]) }
        try #require(dates.string(refitMoment) != before)
        bare.check(hits[1], "after the region change")
        try await bare.show(hits[0])
        bare.check(hits[0], "a refit after the region change")
    }
}

extension BarePane {
    func button(_ id: String) -> NSButton? {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.cell?.accessibilityIdentifier() == id { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(pane.view)
    }

    func view(_ id: String) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            view.accessibilityIdentifier() == id ? view : view.subviews.lazy.compactMap(find).first
        }
        return find(pane.view)
    }
}

extension InspectorTests {
    @Test func aCutInspectorButtonShowsItsFullTitleAsATooltip() async throws {
        let (folder, hits) = try refitHits([("tip.txt", 4_096)])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for (language, cut) in [("ru", true), ("fr", true), ("de", true), ("en", false)] {
            let bare = BarePane(locale: Locale(identifier: language))
            defer { bare.close() }
            try await bare.show(hits[0])
            bare.settled("\(language) buttons")
            let quick = try #require(bare.button(InspectorPane.quickLookID))
            let finder = try #require(bare.button(InspectorPane.showInFinderID))
            try #require(!quick.title.isEmpty && !finder.title.isEmpty)
            if cut {
                #expect(quick.toolTip == quick.title || finder.toolTip == finder.title, "\(language): no cut button has a tooltip")
            } else {
                #expect(quick.toolTip == nil && finder.toolTip == nil, "\(language): \(quick.toolTip ?? "") \(finder.toolTip ?? "")")
            }
            for button in [quick, finder] where button.toolTip != nil {
                #expect(button.toolTip == button.title)
            }
        }
    }

    @Test func bothRussianInspectorButtonsCarryTheirFullTitleAt260Points() async throws {
        let (folder, hits) = try refitHits([("tip.txt", 4_096)])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let bare = BarePane(locale: Locale(identifier: "ru"))
        defer { bare.close() }
        try await bare.show(hits[0])
        bare.settled("ru buttons")
        let quick = try #require(bare.button(InspectorPane.quickLookID))
        let finder = try #require(bare.button(InspectorPane.showInFinderID))
        #expect(quick.toolTip == quick.title && !quick.title.isEmpty)
        #expect(finder.toolTip == finder.title && !finder.title.isEmpty)
    }

    @Test func theInfoGroupReadsInformationAndThePreviewReadsPreviewInTheShownLanguage() async throws {
        let (folder, hits) = try refitHits([("label.txt", 4_096)])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for language in ["en", "ru", "de"] {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            let information = bundle.localizedString(forKey: "Information", value: "\u{1}", table: "Inspector")
            let preview = bundle.localizedString(forKey: "Preview", value: "\u{1}", table: "Inspector")
            try #require(information != "\u{1}" && preview != "\u{1}")
            let bare = BarePane(locale: Locale(identifier: language))
            defer { bare.close() }
            try await bare.show(hits[0])
            let info = try #require(bare.view(InspectorPane.infoID))
            let shown = try #require(quickLookViews(in: bare.pane.view).first)
            #expect(info.accessibilityLabel() == information, "\(language) info group")
            #expect(shown.accessibilityLabel() == preview, "\(language) preview")
        }
        let bare = BarePane(locale: Locale(identifier: "en"))
        defer { bare.close() }
        try await bare.show(hits[0])
        bare.restyle(locale: Locale(identifier: "ru"))
        let shown = try #require(quickLookViews(in: bare.pane.view).first)
        let russian = try #require(Bundle.main.url(forResource: "ru", withExtension: "lproj").flatMap(Bundle.init(url:)))
        #expect(shown.accessibilityLabel() == russian.localizedString(forKey: "Preview", value: nil, table: "Inspector"))
        #expect(bare.view(InspectorPane.infoID)?.accessibilityLabel() == russian.localizedString(forKey: "Information", value: nil, table: "Inspector"))
    }
}
