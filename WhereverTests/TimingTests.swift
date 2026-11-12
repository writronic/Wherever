import AppKit
import Combine
import Foundation
import os
import Quartz
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface
import WhereverKit

let timingMode = (try? String(
    contentsOf: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wherever-measure"),
    encoding: .utf8
))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "gate"
let timingRuns = timingMode == "gate" ? 1 : 20
let timingWarmup = timingMode == "gate" ? 0 : 3
let timingFrame = Duration.seconds(1) / 120

func timingLine(_ label: String, _ times: [Duration], limit: Duration?) -> String {
    figureLine(label, times.map { $0 / .milliseconds(1) }, unit: nil, limit: limit.map { $0 / .milliseconds(1) })
}

func figureLine(_ label: String, _ values: [Double], unit: String?, limit: Double?) -> String {
    let limit = timingMode == "selftest" ? 0 : limit
    let shown = limit.map { String(format: "%.2f", $0) } ?? "none"
    let verdict = limit.map { timingP95(values) > $0 ? "LIMIT OVER" : "ok" } ?? "report"
    return "timing: \(label) \(timingFigures(values))\(unit.map { " " + $0 } ?? "") limit \(shown) \(verdict) " + timingTail(values.count)
}

func timingFigures(_ values: [Double]) -> String {
    "p50 \(String(format: "%.3f", timingP50(values))) p95 \(String(format: "%.3f", timingP95(values)))"
}

func workLine(_ label: String, _ times: [Duration], work: [UInt64], reference: [UInt64], limit: Double) -> String {
    let ms = times.map { $0 / .milliseconds(1) }
    let ratio = Double(timingP95(work)) / Double(timingP95(reference))
    let limit = timingMode == "selftest" ? 0 : limit
    let millions = { (counts: [UInt64]) in String(format: "%.2f", Double(timingP95(counts)) / 1_000_000) }
    return "timing: \(label) p50 \(String(format: "%.3f", timingP50(ms))) p95 \(String(format: "%.3f", timingP95(ms))) ms, "
        + "work p95 \(millions(work)) M instructions against \(millions(reference)) M for a plain AppKit reference, "
        + "ratio \(String(format: "%.3f", ratio)) limit \(String(format: "%.2f", limit)) \(ratio > limit ? "LIMIT OVER" : "ok") " + timingTail(times.count)
}

func timingP50<T: Comparable>(_ values: [T]) -> T { values.sorted()[values.count / 2] }

func timingP95<T: Comparable>(_ values: [T]) -> T { values.sorted()[(values.count * 95 + 99) / 100 - 1] }

func timingTail(_ count: Int) -> String {
    var loads = [Double](repeating: 0, count: 3)
    _ = getloadavg(&loads, 3)
    #if DEBUG
    let configuration = "Debug"
    #else
    let configuration = "Release"
    #endif
    return "| \(configuration) | \(timingMode) \(count) runs, \(timingWarmup) warmup | load \(String(format: "%.2f/%.2f/%.2f", loads[0], loads[1], loads[2]))"
}

func reportTiming(_ label: String, _ times: [Duration], limit: Duration?) {
    reportTimingLine(timingLine(label, times, limit: limit))
}

func reportTimingLine(_ text: String) {
    let path = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wherever-timing-lines").path
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    let line = Array((text + "\n").utf8)
    _ = write(fd, line, line.count)
}

func processUsage() throws -> rusage_info_v4 {
    var usage = rusage_info_v4()
    let read = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    try #require(read == 0, "proc_pid_rusage returned \(read)")
    return usage
}

func processInstructions() throws -> UInt64 { try processUsage().ri_instructions }

func timingCellText(_ table: NSTableView?, row: Int) -> String? {
    guard let table else { return nil }
    let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(ResultsTable.Column.name.rawValue))
    return (table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField?.stringValue
}

func timingVisibleRows(_ table: NSTableView) -> Range<Int> {
    let rows = table.rows(in: table.visibleRect)
    return rows.location..<rows.location + rows.length
}

nonisolated final class TimingCountingSession: SearchSessionClient {
    static let million = 1_000_000

    let id = SearchSessionID(rawValue: 1)
    let varied: Bool
    private let state = OSAllocatedUnfairLock(initialState: (generation: UInt64(0), requests: [Range<Int>]()))

    var requests: [Range<Int>] { state.withLock { $0.requests } }
    var latest: SearchGeneration { SearchGeneration(rawValue: state.withLock { $0.generation }) }

    init(varied: Bool = false) {
        self.varied = varied
    }

    func search(_ query: String, sort: SearchSort) throws -> SearchGeneration { next() }

    func refresh(_ query: String, sort: SearchSort) throws -> SearchGeneration { next() }

    func sort(_ sort: SearchSort) throws -> SearchGeneration { next() }

    func searchContent(_ query: String, terms: [String], matchAll: Bool, sort: SearchSort) throws -> SearchGeneration { next() }

    func narrow(_ query: String, sort: SearchSort) throws -> SearchGeneration { next() }

    func stopContent() throws {}

    func rows(_ generation: SearchGeneration, in range: Range<Int>) throws -> [SearchHit] {
        state.withLock { $0.requests.append(range) }
        return range.clamped(to: 0..<Self.million).map { Self.hit($0, varied: varied) }
    }

    static func hit(_ row: Int, varied: Bool = false) -> SearchHit {
        guard varied else {
            return SearchHit(name: "hit-\(row)", folder: "/nonexistent", size: 1, modified: .distantPast, created: .distantPast, opened: .distantPast, kind: .file)
        }
        let ext = ["txt", "pdf", "png", "zip", "mp3", "swift", "md"][row % 7]
        let modified = Date(timeIntervalSince1970: 1_700_000_000 + Double(row) * 3_607)
        return SearchHit(
            name: "hit-\(row).\(ext)", folder: "/nonexistent/f\(row % 9)", size: Int64(1 + row * 4_093), modified: modified, created: modified, opened: modified, kind: .file
        )
    }

    private func next() -> SearchGeneration {
        SearchGeneration(rawValue: state.withLock { state in
            state.generation += 1
            return state.generation
        })
    }
}

struct TimingTable {
    let session = TimingCountingSession()
    let model: SearchModel
    let host: SearchHost

    init(count: Int = TimingCountingSession.million, columnPreferences: ColumnPreferences = .shared) async throws {
        model = SearchModel(session: session, columnPreferences: columnPreferences)
        host = SearchHost(root: AnyView(ResultsTable(model: model)))
        model.query = "hit"
        model.handle(.resultsReady(session.latest, count: count))
        let host = host
        try await host.until("\(count) rows") { host.list()?.numberOfRows == count }
    }

    func table() throws -> NSTableView { try need(host.list(), "no results table") }

    func visible() throws -> Range<Int> {
        let table = try table()
        let rows = table.rows(in: table.visibleRect)
        if rows.length == 0 { throw Missing(description: "no row on screen") }
        return rows.location..<rows.location + rows.length
    }

    func text(row: Int) -> String? { timingCellText(host.list(), row: row) }

    func expectRowsOnScreen(since before: Int, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let rows = try visible()
        let page = SearchModel.pageSize
        let first = rows.lowerBound / page, last = (rows.upperBound - 1) / page
        let allowed = max(0, (first - 1) * page)..<(last + 2) * page
        let requests = session.requests.dropFirst(before)
        #expect(requests.allSatisfy { allowed.contains($0.lowerBound) && $0.upperBound <= allowed.upperBound },
                "requests \(requests) outside \(allowed)", sourceLocation: sourceLocation)
        #expect(requests.count <= last - first + 3, "\(requests.count) calls for \(last - first + 1) visible pages", sourceLocation: sourceLocation)
        #expect(text(row: rows.lowerBound) == "hit-\(rows.lowerBound)", sourceLocation: sourceLocation)
        #expect(text(row: rows.upperBound - 1) == "hit-\(rows.upperBound - 1)", sourceLocation: sourceLocation)
    }
}

struct TimingPane {
    let session: TimingCountingSession
    let model: SearchModel
    let host: SearchHost

    init(shown: Bool, varied: Bool = false) async throws {
        session = TimingCountingSession(varied: varied)
        let name = "com.writronic.wherever.tests.timing.pane"
        let store = try need(UserDefaults(suiteName: name), "no suite \(name)")
        store.removePersistentDomain(forName: name)
        store.set(shown, forKey: InspectorPane.shownKey)
        model = SearchModel(session: session)
        host = SearchHost(root: AnyView(ResultsPane(model: model).defaultAppStorage(store)), reportsKey: true)
        model.query = "hit"
        model.handle(.resultsReady(session.latest, count: TimingCountingSession.million))
        let host = host
        try await host.until("a million rows on screen, the inspector \(shown ? "shown" : "hidden")") {
            guard let table = host.list(), table.numberOfRows == TimingCountingSession.million, table.rows(in: table.visibleRect).length > 0 else { return false }
            return splitController(in: host.view)?.inspectorItem.isCollapsed == !shown
        }
    }

    var inspector: InspectorModel? { splitController(in: host.view)?.pane.inspector }

    var previews: [QLPreviewView] { splitController(in: host.view).map { quickLookViews(in: $0.pane.view) } ?? [] }
}

final class PlainClickTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = KeyedWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let table = NSTableView()
    let name = NSTextField(labelWithString: "")
    private let preview = NSImageView()
    private let summary = NSTextField(labelWithString: "")
    private let values = (0..<7).map { _ in NSTextField(labelWithString: "") }
    private let archive = NSButton(title: String(localized: "Show Archive Contents", table: "Results"), target: nil, action: nil)
    private let sizes = ByteCountFormatter()
    private let varied: Bool
    private let showsArchive: (SearchHit) -> Bool

    var rows: Int

    init(
        like source: NSTableView, size: NSSize, pane: CGFloat?, varied: Bool = false, rows: Int = TimingCountingSession.million,
        showsArchive: @escaping (SearchHit) -> Bool = { _ in false }
    ) {
        self.varied = varied
        self.rows = rows
        self.showsArchive = showsArchive
        super.init()
        for column in source.tableColumns where !column.isHidden {
            let added = NSTableColumn(identifier: column.identifier)
            added.title = column.title
            added.width = column.width
            table.addTableColumn(added)
        }
        table.style = .inset
        table.rowSizeStyle = .custom
        table.rowHeight = source.rowHeight
        table.intercellSpacing = source.intercellSpacing
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        sizes.countStyle = .file
        sizes.includesActualByteCount = true
        if let pane {
            let split = NSSplitView()
            split.isVertical = true
            split.dividerStyle = .thin
            split.addArrangedSubview(scroll)
            split.addArrangedSubview(inspector())
            window.contentView = split
            window.setContentSize(size)
            split.layoutSubtreeIfNeeded()
            split.setPosition(size.width - pane - split.dividerThickness, ofDividerAt: 0)
        } else {
            window.contentView = scroll
            window.setContentSize(size)
        }
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.reportsKey = true
        window.becomeKey()
    }

    private func inspector() -> NSView {
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.heightAnchor.constraint(equalToConstant: SearchMetrics.previewHeight).isActive = true
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        summary.font = small
        let keys = [
            String(localized: "Kind", table: "Results"), String(localized: "Size", table: "Results"), String(localized: "Where", table: "Inspector"),
            String(localized: "Created", table: "Inspector"), String(localized: "Modified", table: "Results"), String(localized: "Owner", table: "Inspector"),
            String(localized: "Permissions", table: "Inspector"),
        ]
        let grid = NSGridView(views: zip(keys, values).map { key, value in
            let label = NSTextField(labelWithString: key)
            label.font = small
            value.font = small
            return [label, value]
        })
        let buttons = NSStackView(views: [
            NSButton(title: String(localized: "Quick Look", table: "Results"), target: nil, action: nil),
            NSButton(title: String(localized: "Show in Finder", table: "Results"), target: nil, action: nil),
        ])
        archive.isHidden = true
        let heading = NSTextField(labelWithString: String(localized: "Information", table: "Inspector"))
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let line = NSBox()
        line.boxType = .separator
        let stack = NSStackView(views: [preview, name, summary, buttons, archive, line, heading, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SearchMetrics.inspectorSpacing
        let inset = SearchMetrics.inspectorPadding
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        return stack
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, let column = ResultsTable.Column(rawValue: identifier.rawValue) else { return nil }
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? Self.cell(identifier, column: column)
        let hit = TimingCountingSession.hit(row, varied: varied)
        switch column {
        case .name: cell.textField?.stringValue = hit.name
        case .folder: cell.textField?.stringValue = hit.folder
        case .size: cell.textField?.stringValue = ByteCountFormatter.string(fromByteCount: hit.size, countStyle: .file)
        case .modified, .created, .opened: cell.textField?.stringValue = FileDates.current.string(hit.modified)
        case .kind: cell.textField?.stringValue = ResultType.of(hit).kind
        }
        cell.imageView?.image = column == .name ? ResultType.of(hit).icon : nil
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0 else { return }
        let hit = TimingCountingSession.hit(table.selectedRow, varied: varied)
        let type = ResultType.of(hit)
        let size = sizes.string(fromByteCount: hit.size)
        preview.image = type.icon
        name.stringValue = hit.name
        summary.stringValue = String(localized: "\(type.kind) · \(ByteCountFormatter.string(fromByteCount: hit.size, countStyle: .file))", table: "Inspector")
        let shown = [type.kind, size, hit.folder, "--", FileDates.current.string(hit.modified), "--", InspectorPane.permissions(nil)]
        for (field, text) in zip(values, shown) { field.stringValue = text }
        let hidden = !showsArchive(hit)
        if archive.isHidden != hidden { archive.isHidden = hidden }
    }

    private static func cell(_ identifier: NSUserInterfaceItemIdentifier, column: ResultsTable.Column) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.font = column.isDate ? ResultsTable.dateFont(.standard) : ResultsTable.font(.standard)
        text.alignment = column == .size ? .right : .natural
        text.lineBreakMode = column == .folder ? .byTruncatingMiddle : .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(text)
        cell.textField = text
        var leading = cell.leadingAnchor
        if column == .name {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: SearchMetrics.cellPadding),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: SearchMetrics.iconSize),
                image.heightAnchor.constraint(equalToConstant: SearchMetrics.iconSize),
            ])
            leading = image.trailingAnchor
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: column == .name ? SearchMetrics.iconGap : SearchMetrics.cellPadding),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -SearchMetrics.cellPadding),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

nonisolated final class TimingArchiveSession: ArchiveSessionClient {
    let base: any ArchiveSessionClient
    private let state = OSAllocatedUnfairLock(initialState: (latest: SearchGeneration?.none, requests: [Range<Int>]()))

    init(_ base: any ArchiveSessionClient) {
        self.base = base
    }

    var id: SearchSessionID { base.id }
    var latest: SearchGeneration? { state.withLock { $0.latest } }
    var requests: [Range<Int>] { state.withLock { $0.requests } }

    func search(_ query: String, sort: SearchSort) throws -> SearchGeneration { try asked(base.search(query, sort: sort)) }

    func refresh(_ query: String, sort: SearchSort) throws -> SearchGeneration { try asked(base.refresh(query, sort: sort)) }

    func sort(_ sort: SearchSort) throws -> SearchGeneration { try asked(base.sort(sort)) }

    func browse(_ folder: String) throws -> SearchGeneration { try asked(base.browse(folder)) }

    func rows(_ generation: SearchGeneration, in range: Range<Int>) throws -> [SearchHit] {
        state.withLock { $0.requests.append(range) }
        return try base.rows(generation, in: range)
    }

    func summary() throws -> WhereverInterface.ArchiveSummary { try base.summary() }

    func unlock(_ password: String) throws -> Bool { try base.unlock(password) }

    func encrypted(_ entry: String) throws -> Bool { try base.encrypted(entry) }

    func extract(entries: [String], folder: String, readOnly: Bool) throws -> ArchiveJobID { try base.extract(entries: entries, folder: folder, readOnly: readOnly) }

    func expand(entries: [String], folder: String, whole: Bool) throws -> ArchiveJobID { try base.expand(entries: entries, folder: folder, whole: whole) }

    func job(_ id: ArchiveJobID) throws -> WhereverInterface.ArchiveJob { try base.job(id) }

    func cancel(_ id: ArchiveJobID) throws { try base.cancel(id) }

    func setChanges(_ changes: [WhereverInterface.ArchiveChange]) throws -> SearchGeneration { try asked(base.setChanges(changes)) }

    func clashes(folder: String, names: [String]) throws -> [WhereverInterface.ArchiveClash] { try base.clashes(folder: folder, names: names) }

    func writeEdited(to out: String) throws -> ArchiveJobID { try base.writeEdited(to: out) }

    func close() throws { try base.close() }

    private func asked(_ generation: SearchGeneration) -> SearchGeneration {
        state.withLock { $0.latest = generation }
        return generation
    }
}

final class TimingEvents {
    private var received: [(event: SearchEvent, at: ContinuousClock.Instant)] = []
    private var pump: Task<Void, Never>?

    init(_ events: AsyncStream<SearchEvent>) {
        pump = Task { [weak self] in
            for await event in events { self?.received.append((event, .now)) }
        }
    }

    func stop() { pump?.cancel() }

    func ready(_ asked: SearchGeneration?) async throws -> (count: Int, at: ContinuousClock.Instant) {
        let generation = try need(asked, "the model asked the archive for nothing")
        var found: (count: Int, at: ContinuousClock.Instant)?
        var failed = false
        try await untilTrue(within: .seconds(30), waitingFor: "the engine's answer for generation \(generation.rawValue)") {
            for item in received {
                if case .resultsReady(generation, let count) = item.event { found = (count, item.at) }
                if case .searchFailed(generation) = item.event { failed = true }
            }
            return found != nil || failed
        }
        return try need(found, "generation \(generation.rawValue) failed")
    }
}

struct TimingArchive {
    static let folders = 1_000
    static let perFolder = 100
    static let entries = folders * perFolder

    let base = URL.temporaryDirectory.appending(component: "TimingArchive-\(UUID().uuidString)", directoryHint: .isDirectory).resolvingSymlinksInPath()
    let services: WhereverServices
    let events: TimingEvents
    let preferences: ColumnPreferences
    private let store = "com.writronic.wherever.tests.timing.archive"

    init(kept: Int = 0) throws {
        let root = base.appending(component: "files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var entries = (0..<Self.folders).flatMap { folder in
            (0..<Self.perFolder).map { ZipFixture.Entry(Self.folder(folder) + "/" + Self.entry($0), Data(count: Self.size($0))) }
        }
        entries += (0..<kept).map { ZipFixture.Entry(Self.kept($0), Data(count: 1)) }
        try ZipFixture.write(entries, to: root.appending(component: "Timing.zip"))
        services = try WhereverServices(
            root: root.path(percentEncoded: false), home: root.path(percentEncoded: false),
            dataFolder: base.appending(component: "index").path(percentEncoded: false), excluded: []
        )
        events = TimingEvents(services.search.events)
        let defaults = try need(UserDefaults(suiteName: store), "no suite \(store)")
        defaults.removePersistentDomain(forName: store)
        preferences = ColumnPreferences(defaults: defaults)
    }

    static func folder(_ index: Int) -> String { String(format: "folder-%03d", index) }

    static func entry(_ index: Int) -> String { String(format: "entry-%02d.bin", index) }

    static func kept(_ index: Int) -> String { String(format: "kept-%02d.bin", index) }

    var path: String { base.appending(path: "files/Timing.zip").path(percentEncoded: false) }

    static func size(_ index: Int) -> Int { index * 37 % perFolder }

    func open() throws -> (session: TimingArchiveSession, model: SearchModel, call: Duration) {
        var opened: (TimingArchiveSession, SearchModel)?
        let call = try ContinuousClock().measure {
            let session = TimingArchiveSession(try services.archive.openArchive(path: path, shownAs: path))
            opened = (session, SearchModel(session: session, listsAll: true, columnPreferences: preferences))
        }
        let (session, model) = try need(opened, "no archive session")
        return (session, model, call)
    }

    func remove() {
        events.stop()
        UserDefaults(suiteName: store)?.removePersistentDomain(forName: store)
        withExtendedLifetime(services) { try? FileManager.default.removeItem(at: base) }
    }
}

@Suite(.serialized) struct TimingTests {
    private let clock = ContinuousClock()

    @Test func oneKeystrokeInTheFieldAndTheModelFitsOneFrame() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        let keys = Array("asfzxbom")
        var times: [Duration] = []
        for run in 0..<timingWarmup + timingRuns {
            let before = fake.queries.count
            let time = try clock.measure {
                try host.sendKeys(String(keys[run % keys.count]))
                host.view.layoutSubtreeIfNeeded()
                host.window.displayIfNeeded()
            }
            #expect(fake.queries.count == before + 1, "keystroke \(run) reached the session \(fake.queries.count - before) times")
            if run >= timingWarmup { times.append(time) }
        }
        #expect(model.query.count == timingWarmup + timingRuns)
        reportTiming("keystroke in the field and the window's model", times, limit: timingFrame)
    }

    @Test func aRowFetchForTheVisibleRangeFitsOneFrame() throws {
        let session = TimingCountingSession()
        let model = SearchModel(session: session)
        model.query = "hit"
        model.handle(.resultsReady(session.latest, count: TimingCountingSession.million))
        try #require(model.count == TimingCountingSession.million)
        let visible = Int((SearchMetrics.windowMinHeight / ResultsTable.rowHeight(.standard)).rounded(.up))
        let page = SearchModel.pageSize
        let total = timingWarmup + timingRuns
        var times: [Duration] = []
        for run in 0..<total {
            let start = (run + 1) * (TimingCountingSession.million / (total + 1))
            let before = session.requests.count
            var rows: [SearchHit] = []
            let time = clock.measure { rows = model.rows(in: start..<start + visible) }
            #expect(rows.map(\.name) == (start..<start + visible).map { "hit-\($0)" })
            let pages = (start / page...(start + visible - 1) / page).map { $0 * page..<($0 + 1) * page }
            #expect(Array(session.requests.dropFirst(before)) == pages)
            if run >= timingWarmup { times.append(time) }
        }
        reportTiming("row fetch for the \(visible) visible rows of 1000000", times, limit: timingFrame)
    }

    @Test func oneScrollStepOverAMillionRowsFitsOneFrame() async throws {
        let rig = try await TimingTable()
        defer { rig.host.close() }
        let table = try rig.table()
        let page = SearchModel.pageSize
        try await rig.host.until("rows on screen") { rig.host.list().map { $0.rows(in: $0.visibleRect).length > 0 } == true }
        let screen = try rig.visible().count
        try #require(screen < page, "\(screen) rows on screen, page \(page)")
        let total = timingWarmup + timingRuns
        var times: [Duration] = []
        for run in 0..<total {
            let next = (run + 1) * (TimingCountingSession.million / page / (total + 1)) + 1
            let fresh = next * page..<(next + 1) * page
            let landing = fresh.lowerBound - (screen - 2)
            table.scrollRowToVisible(landing)
            try await rig.host.until("row \(landing) on screen") { (try? rig.visible().contains(landing)) == true && rig.text(row: landing) != nil }
            let rows = try rig.visible()
            let target = rows.upperBound - 1 + rows.count
            try #require(fresh.contains(target) && !rig.session.requests.contains(fresh),
                         "run \(run): rows \(rows), target \(target), page \(fresh), requests \(rig.session.requests)")
            let before = rig.session.requests.count
            let time = clock.measure {
                table.scrollRowToVisible(target)
                table.enclosingScrollView?.layoutSubtreeIfNeeded()
                table.displayIfNeeded()
            }
            try await rig.host.until("row \(target) on screen") { (try? rig.visible().contains(target)) == true && rig.text(row: target) != nil }
            try rig.expectRowsOnScreen(since: before)
            #expect(rig.session.requests.dropFirst(before).contains(fresh), "run \(run): the step to row \(target) never asked for \(fresh)")
            if run >= timingWarmup { times.append(time) }
        }
        reportTiming("scroll step of one screen over 1000000 rows", times, limit: timingFrame)
    }

    @Test func oneResizeLayoutOfTheWindowFitsOneFrame() async throws {
        let rig = try await TimingTable()
        defer { rig.host.close() }
        let sizes = [
            NSSize(width: SearchMetrics.windowMinWidth + 240, height: SearchMetrics.windowMinHeight + 160),
            NSSize(width: SearchMetrics.windowMinWidth, height: SearchMetrics.windowMinHeight),
        ]
        var times: [Duration] = []
        for run in 0..<timingWarmup + timingRuns {
            let size = sizes[run % sizes.count]
            let before = rig.session.requests.count
            let time = clock.measure {
                rig.host.window.setContentSize(size)
                rig.host.window.layoutIfNeeded()
                rig.host.window.displayIfNeeded()
            }
            #expect(rig.host.window.contentView?.frame.size == size)
            try await rig.host.until("the rows after the resize") { (try? rig.visible()).map { rig.text(row: $0.upperBound - 1) != nil } == true }
            try rig.expectRowsOnScreen(since: before)
            if run >= timingWarmup { times.append(time) }
        }
        reportTiming("resize layout of the window over 1000000 rows", times, limit: timingFrame)
    }

    @Test func aClickOnARowWithTheInspectorHiddenFitsOneFrame() async throws {
        try await clickWork(shown: false)
    }

    @Test func aClickOnARowWithTheInspectorShownFitsOneFrame() async throws {
        try await clickWork(shown: true)
    }

    @Test func aClickOnARowWithTheInspectorShownAndEveryFactChangingFitsOneFrame() async throws {
        try await clickWork(shown: true, varied: true)
    }

    @Test func aLiveRefreshUnderASelectedRowFitsOneFrame() async throws {
        let count = 1_611_684
        let name = "com.writronic.wherever.tests.timing.refresh"
        let store = try need(UserDefaults(suiteName: name), "no suite \(name)")
        store.removePersistentDomain(forName: name)
        let preferences = ColumnPreferences(defaults: store)
        preferences.shown = [.name, .folder, .size, .modified, .created, .kind]
        let rig = try await TimingTable(count: count, columnPreferences: preferences)
        defer { rig.host.close() }
        let visible = try need(rig.host.window.screen?.visibleFrame, "no screen")
        rig.host.window.setFrame(visible, display: true)
        try #require(rig.host.window.frame == visible)
        let table = try rig.table()
        let columns: Set<String> = ["name", "folder", "size", "modified", "created", "kind"]
        try #require(Set(table.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)) == columns)
        let row = 200
        table.scrollRowToVisible(row)
        table.selectRowIndexes([row], byExtendingSelection: false)
        try await rig.host.until("row \(row) selected on screen") {
            (try? rig.visible().contains(row)) == true && rig.text(row: row) == "hit-\(row)" && table.selectedRow == row
        }
        var times: [Duration] = []
        for run in 0..<timingWarmup + timingRuns {
            let before = rig.session.requests.count
            let generation = rig.session.latest
            let time = clock.measure {
                rig.model.handle(.resultsChanged)
                rig.model.handle(.resultsReady(rig.session.latest, count: count))
                rig.host.view.layoutSubtreeIfNeeded()
                rig.host.window.displayIfNeeded()
            }
            #expect(rig.session.latest.rawValue == generation.rawValue + 1, "run \(run): the change asked for no refresh")
            #expect(rig.model.results == SearchModel.Results(generation: rig.session.latest, count: count, live: true))
            #expect(rig.session.requests.count > before, "run \(run): the table reloaded no row inside the measured frame")
            #expect(table.selectedRow == row)
            if run >= timingWarmup { times.append(time) }
        }
        reportTiming("live refresh of 1611684 rows at \(Int(visible.width))x\(Int(visible.height)), six columns, row 200 selected", times, limit: timingFrame)
    }

    @Test func archiveOpenListsOffTheMainActor() async throws {
        let (stalls, _, work, plain) = try await archiveOpens(reference: true)
        reportTimingLine(workLine(
            "archive open of \(TimingArchive.entries) entries in \(TimingArchive.folders) folders, longest main-actor stall", stalls, work: work, reference: plain, limit: 1.05
        ))
    }

    @Test func archiveOpenFitsItsLimit() async throws {
        let (_, opens, _, _) = try await archiveOpens(reference: false)
        reportTimingLine(figureLine(
            "archive open of \(TimingArchive.entries) entries in \(TimingArchive.folders) folders to the first rows on screen", opens, unit: "ms", limit: 370
        ))
    }

    private func archiveOpens(reference: Bool) async throws -> (stalls: [Duration], opens: [Double], work: [UInt64], plain: [UInt64]) {
        let rig = try TimingArchive()
        defer { rig.remove() }
        var stalls: [Duration] = []
        var opens: [Double] = []
        var work: [UInt64] = []
        var plain: [UInt64] = []
        for run in 0..<timingWarmup + timingRuns {
            let start = clock.now
            let (session, model, call) = try rig.open()
            let host = SearchHost(root: AnyView(ResultsTable(model: model)))
            defer { host.close() }
            let generation = try need(session.latest, "run \(run): no listing asked")
            let (count, arrived) = try await rig.events.ready(generation)
            var summary: WhereverInterface.ArchiveSummary?
            let before = try processInstructions()
            let shown = try clock.measure {
                model.handle(.resultsReady(generation, count: count))
                summary = try session.summary()
                host.view.layoutSubtreeIfNeeded()
                host.window.displayIfNeeded()
            }
            let done = try processInstructions() - before
            try #require(count == TimingArchive.folders, "run \(run): the root listed \(count) rows")
            try #require(summary?.items == UInt64(TimingArchive.entries), "run \(run): the archive listed \(summary?.items ?? 0) entries")
            try #require(session.requests.contains(0..<SearchModel.pageSize), "run \(run): the first page never came, requests \(session.requests)")
            try #require(timingCellText(host.list(), row: 0) == TimingArchive.folder(0), "run \(run): row 0 shows \(timingCellText(host.list(), row: 0) ?? "nothing")")
            try session.close()
            let table = try need(host.list(), "run \(run): no results table")
            let size = try need(host.window.contentView?.frame.size, "run \(run): no content view")
            host.close()
            let fill = try reference ? plainFirstFill(like: table, size: size) : 0
            if run >= timingWarmup {
                stalls.append(max(call, shown))
                opens.append((start.duration(to: arrived) + shown) / .milliseconds(1))
                work.append(done)
                plain.append(fill)
            }
        }
        return (stalls, opens, work, plain)
    }

    private func plainFirstFill(like table: NSTableView, size: NSSize) throws -> UInt64 {
        let plain = PlainClickTable(like: table, size: size, pane: nil, rows: 0)
        defer { plain.window.close() }
        let view = try need(plain.window.contentView, "no content view in the plain table's window")
        view.layoutSubtreeIfNeeded()
        plain.window.displayIfNeeded()
        try #require(plain.table.numberOfRows == 0 && plain.table.rows(in: plain.table.visibleRect).length == 0, "the plain table filled before its measured block")
        plain.rows = TimingArchive.folders
        let before = try processInstructions()
        plain.table.reloadData()
        view.layoutSubtreeIfNeeded()
        plain.window.displayIfNeeded()
        let work = try processInstructions() - before
        try #require(timingCellText(plain.table, row: 0) == TimingCountingSession.hit(0).name, "the plain table's first row shows \(timingCellText(plain.table, row: 0) ?? "nothing")")
        return work
    }

    @Test func archiveScrollFitsAFrame() async throws {
        let rig = try TimingArchive()
        defer { rig.remove() }
        let (session, model, _) = try rig.open()
        let host = SearchHost(root: AnyView(ResultsTable(model: model)))
        defer { host.close() }
        let generation = try need(session.latest, "no listing")
        let count = try await rig.events.ready(generation).count
        try #require(count == TimingArchive.folders)
        model.handle(.resultsReady(generation, count: count))
        let table = try need(host.list(), "no results table")
        try await host.until("the archive's rows on screen") { timingCellText(table, row: 0) == TimingArchive.folder(0) }
        let page = SearchModel.pageSize
        let screen = timingVisibleRows(table).count
        try #require(screen > 2 && screen < page - 2, "\(screen) rows on screen, page \(page)")
        var times: [Duration] = []
        for run in 0..<timingWarmup + timingRuns {
            let fresh = (1 + run % 6) * page..<(2 + run % 6) * page
            table.scrollRowToVisible(0)
            try await host.until("row 0 on screen") { timingVisibleRows(table).contains(0) }
            model.handle(.resultsReady(generation, count: count))
            let flushed = session.requests.count
            let landing = fresh.lowerBound - (screen - 2)
            table.scrollRowToVisible(landing)
            try await host.until("row \(landing) on screen") { timingCellText(table, row: landing) == TimingArchive.folder(landing) }
            let rows = timingVisibleRows(table)
            let target = rows.upperBound - 1 + rows.count
            try #require(fresh.contains(target) && !session.requests.dropFirst(flushed).contains(fresh),
                         "run \(run): rows \(rows), target \(target), page \(fresh), requests \(session.requests.dropFirst(flushed))")
            let before = session.requests.count
            let time = clock.measure {
                table.scrollRowToVisible(target)
                table.enclosingScrollView?.layoutSubtreeIfNeeded()
                table.displayIfNeeded()
            }
            try await host.until("row \(target) on screen") { timingCellText(table, row: target) == TimingArchive.folder(target) }
            try #require(session.requests.dropFirst(before).contains(fresh), "run \(run): the step to row \(target) never fetched \(fresh)")
            let shown = timingVisibleRows(table)
            #expect(timingCellText(table, row: shown.lowerBound) == TimingArchive.folder(shown.lowerBound))
            #expect(timingCellText(table, row: shown.upperBound - 1) == TimingArchive.folder(shown.upperBound - 1))
            if run >= timingWarmup { times.append(time) }
        }
        reportTiming("archive scroll step of one screen over the \(TimingArchive.folders) folders of \(TimingArchive.entries) entries", times, limit: timingFrame)
    }

    @Test func archiveSortBySizeFitsItsLimit() async throws {
        let rig = try TimingArchive()
        defer { rig.remove() }
        let (session, model, _) = try rig.open()
        let root = try need(session.latest, "no listing")
        model.handle(.resultsReady(root, count: try await rig.events.ready(root).count))
        let folder = TimingArchive.folder(0)
        _ = try session.browse(folder)
        model.reload()
        let listed = try need(session.latest, "no browse")
        let count = try await rig.events.ready(listed).count
        try #require(count == TimingArchive.perFolder, "\(folder) listed \(count) rows")
        model.handle(.resultsReady(listed, count: count))
        let entries = 0..<TimingArchive.perFolder
        try #require(model.rows(in: 0..<count).map(\.name) == entries.map(TimingArchive.entry), "\(folder) does not list by name first")
        var times: [Duration] = []
        var previous = listed
        for run in 0..<timingWarmup + timingRuns {
            let ascending = run % 2 == 1
            let start = clock.now
            model.sort = SearchSort(column: .size, ascending: ascending, foldersFirst: model.sort.foldersFirst)
            let generation = try need(session.latest, "run \(run): no sort asked")
            try #require(generation != previous, "run \(run): the sort asked the engine for nothing")
            previous = generation
            let (sorted, arrived) = try await rig.events.ready(generation)
            let handled = clock.measure { model.handle(.resultsReady(generation, count: sorted)) }
            let order = entries.sorted { ascending ? TimingArchive.size($0) < TimingArchive.size($1) : TimingArchive.size($0) > TimingArchive.size($1) }
            let rows = model.rows(in: 0..<sorted)
            try #require(rows.map(\.name) == order.map(TimingArchive.entry), "run \(run): \(rows.prefix(5).map(\.name)) is not by size, ascending \(ascending)")
            try #require(rows.map(\.size) == order.map { Int64(TimingArchive.size($0)) })
            if run >= timingWarmup { times.append(start.duration(to: arrived) + handled) }
        }
        reportTiming("archive sort by size of the \(TimingArchive.perFolder) entries of one folder in \(TimingArchive.entries)", times, limit: .microseconds(620))
    }

    @Test func archiveDeleteOf100kEntriesStaysInOneFrame() async throws {
        let kept = 60
        let rig = try TimingArchive(kept: kept)
        defer { rig.remove() }
        let (session, model, _) = try rig.open()
        let shownAs = rig.path
        let edits = ArchiveEdits(session: session, results: model, refuse: {})
        var actions = ResultActions.inert
        actions.remove = { edits.delete($0.compactMap { ArchiveWindowModel.inner($0, in: shownAs) }) }
        let host = SearchHost(root: AnyView(ResultsTable(model: model)), actions: actions)
        defer { host.close() }
        let root = try need(session.latest, "no listing")
        let listed = try await rig.events.ready(root).count
        try #require(listed == TimingArchive.folders + kept, "the root listed \(listed) rows")
        model.handle(.resultsReady(root, count: listed))
        let table = try need(host.list() as? ThemedTable, "no results table")
        try await host.until("the archive's rows on screen") { timingCellText(table, row: 0) == TimingArchive.folder(0) }
        try #require(host.window.makeFirstResponder(table))
        let screen = timingVisibleRows(table).count
        try #require(screen > 2 && screen < kept, "\(screen) rows on screen, \(kept) kept")
        let folders = IndexSet(integersIn: 0..<TimingArchive.folders)
        var stalls: [Duration] = []
        for run in -1..<timingWarmup + timingRuns {
            table.selectRowIndexes(folders, byExtendingSelection: false)
            host.view.layoutSubtreeIfNeeded()
            host.window.displayIfNeeded()
            let before = session.latest
            let pressed = try clock.measure {
                try host.pressDelete()
                host.view.layoutSubtreeIfNeeded()
                host.window.displayIfNeeded()
            }
            try #require(edits.changes == (0..<TimingArchive.folders).map { ArchiveChange.delete(path: TimingArchive.folder($0)) }, "run \(run): \(edits.changes.count) changes")
            try #require(table.selectedRowIndexes.isEmpty, "run \(run): the selection stayed")
            let generation = try need(session.latest, "run \(run): no reload asked")
            try #require(generation != before, "run \(run): the delete asked the engine for nothing")
            let left = try await rig.events.ready(generation).count
            try #require(left == kept, "run \(run): \(left) rows left after deleting the folders of \(TimingArchive.entries) entries, \(kept) expected")
            let shown = clock.measure {
                model.handle(.resultsReady(generation, count: left))
                host.view.layoutSubtreeIfNeeded()
                host.window.displayIfNeeded()
            }
            try #require(model.names == (0..<kept).map(TimingArchive.kept), "run \(run): \(model.names.prefix(3)) listed")
            try #require(timingCellText(table, row: 0) == TimingArchive.kept(0), "run \(run): row 0 shows \(timingCellText(table, row: 0) ?? "nothing")")
            if run >= timingWarmup { stalls.append(max(pressed, shown)) }
            edits.apply([], named: "")
            let back = try need(session.latest, "run \(run): no undo asked")
            let restored = try await rig.events.ready(back).count
            try #require(restored == listed, "run \(run): the undo listed \(restored) rows")
            model.handle(.resultsReady(back, count: restored))
            try await host.until("run \(run): the folders back on screen") { timingCellText(table, row: 0) == TimingArchive.folder(0) }
        }
        reportTiming(
            "archive delete of the \(TimingArchive.folders) folders holding \(TimingArchive.entries) entries, longest main-actor stall of the key and the reload",
            stalls, limit: timingFrame
        )
    }

    @Test func archiveFootprintPerEntryIsRecorded() async throws {
        let rig = try TimingArchive()
        defer { rig.remove() }
        var added: Double?
        for run in 0...timingWarmup {
            if run > 0 { try await Task.sleep(for: .milliseconds(200)) }
            _ = malloc_zone_pressure_relief(nil, 0)
            let before = try processUsage().ri_phys_footprint
            let (session, model, _) = try rig.open()
            let generation = try need(session.latest, "run \(run): no listing asked")
            let count = try await rig.events.ready(generation).count
            model.handle(.resultsReady(generation, count: count))
            let after = try processUsage().ri_phys_footprint
            try #require(count == TimingArchive.folders, "run \(run): the root listed \(count) rows")
            try #require(try session.summary().items == UInt64(TimingArchive.entries), "run \(run): the archive listed fewer entries")
            if run == timingWarmup { added = (Double(after) - Double(before)) / Double(TimingArchive.entries) }
            try session.close()
        }
        let perEntry = try need(added, "no footprint read")
        reportTimingLine(figureLine("archive footprint added per entry of \(TimingArchive.entries), the listing kept open", [perEntry], unit: "bytes", limit: 380))
    }

    private func clickWork(shown: Bool, varied: Bool = false) async throws {
        let rig = try await TimingPane(shown: shown, varied: varied)
        defer { rig.host.close() }
        let table = try need(rig.host.list(), "no results table")
        let inspector = try need(rig.inspector, "no inspector model")
        let size = try need(rig.host.window.contentView?.frame.size, "no content view")
        let pane = shown ? try need(splitController(in: rig.host.view)?.pane.view.frame.width, "no inspector pane") : nil
        let screen = table.rows(in: table.visibleRect)
        let rows = screen.location + 2..<screen.location + screen.length - 2
        try #require(rows.count >= 2, "\(screen.length) rows on screen")
        var changes = 0
        let watch = inspector.objectWillChange.sink { changes += 1 }
        var kept: QLPreviewView?
        let paneView = shown ? splitController(in: rig.host.view)?.pane.view : nil
        let names = paneView.map { view in
            { (row: Int) in AXTree.elements(in: view).contains { AXTree.names(of: $0).contains(TimingCountingSession.hit(row, varied: varied).name) } }
        }
        let ours = try await clicks(in: rig.host.window, table: table, rows: rows, names: names) { row, run in
            #expect(rig.host.recorder.opened.isEmpty)
            guard shown else { return }
            try await rig.host.until("row \(row) and its preview in the inspector") {
                let previews = rig.previews
                return inspector.hit?.name == TimingCountingSession.hit(row, varied: varied).name && inspector.facts != nil && previews.count == 1 && !previews[0].isHidden
            }
            let preview = rig.previews[0]
            if let kept { #expect(preview === kept, "run \(run): a new preview view") } else { kept = preview }
        }
        watch.cancel()
        if !shown {
            #expect(changes == 0, "a hidden inspector published \(changes) times")
            #expect(inspector.hit == nil)
        }
        rig.host.close()
        let plain = PlainClickTable(like: table, size: size, pane: pane, varied: varied)
        plain.window.setFrameOrigin(rig.host.window.frame.origin)
        defer { plain.window.close() }
        try await untilTrue(waitingFor: "rows \(rows) on the plain table's screen") {
            plain.window.contentView?.layoutSubtreeIfNeeded()
            let shows = plain.table.rows(in: plain.table.visibleRect)
            return shows.location <= rows.lowerBound && shows.location + shows.length >= rows.upperBound
        }
        let reference = try await clicks(in: plain.window, table: plain.table, rows: rows) { row, _ in
            #expect(!shown || plain.name.stringValue == TimingCountingSession.hit(row, varied: varied).name)
        }
        reportTimingLine(workLine(
            "click on a row of 1000000, inspector \(shown ? "shown" : "hidden")\(varied ? ", every fact changing" : "")", ours.times, work: ours.work, reference: reference.work, limit: 1.05
        ))
    }

    private func clicks(
        in window: NSWindow, table: NSTableView, rows: Range<Int>, names: ((Int) -> Bool)? = nil, settle: (Int, Int) async throws -> Void
    ) async throws -> (times: [Duration], work: [UInt64]) {
        let view = try need(window.contentView, "no content view")
        var times: [Duration] = []
        var work: [UInt64] = []
        for run in 0..<timingWarmup + timingRuns {
            let row = rows.lowerBound + run % rows.count
            let rect = table.rect(ofRow: row).intersection(table.visibleRect)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let (time, count, selected, emphasized, named) = try await EventQueueLock.run {
                try postClick(at: point, in: window)
                let before = try processInstructions()
                let time = clock.measure {
                    drainEvents()
                    view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    CATransaction.flush()
                }
                let count = try processInstructions() - before
                let named = names?(row) ?? true
                let selected = table.selectedRow
                let emphasized = (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?.backgroundStyle == .emphasized
                try await untilTrue(waitingFor: "the click to select row \(row), selected \(table.selectedRow)") {
                    view.layoutSubtreeIfNeeded()
                    drainEvents()
                    return table.selectedRow == row
                }
                return (time, count, selected, emphasized, named)
            }
            #expect(selected == row, "run \(run): row \(selected) selected inside the measured frame, not \(row)")
            #expect(named, "run \(run): the inspector did not name row \(row) inside the measured frame")
            #expect(emphasized, "run \(run): row \(row) drawn without the key window's selection color")
            try await settle(row, run)
            try await Task.sleep(for: InspectorModel.settle * 2)
            if run >= timingWarmup {
                times.append(time)
                work.append(count)
            }
        }
        return (times, work)
    }

    private func postClick(at point: NSPoint, in window: NSWindow) throws {
        let start = ProcessInfo.processInfo.systemUptime
        for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            NSApp.postEvent(try need(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: start + Double(offset) * 0.008, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ), "no \(type) event"), atStart: false)
        }
    }
}
