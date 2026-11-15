import AppKit
import Foundation
import os
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private nonisolated final class A11yCountingSession: SearchSessionClient {
    struct Log {
        var generation: UInt64 = 0
        var searches: [String] = []
        var sorts: [SearchSort] = []
        var rows: [Range<Int>] = []
    }

    let id = SearchSessionID(rawValue: 1)
    private let hit: @Sendable (Int) -> SearchHit
    private let log = OSAllocatedUnfairLock(initialState: Log())

    init(hit: @escaping @Sendable (Int) -> SearchHit = { row in
        SearchHit(name: "hit-\(row)", folder: "/Applications", size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .file)
    }) {
        self.hit = hit
    }

    var latest: SearchGeneration { log.withLock { SearchGeneration(rawValue: $0.generation) } }
    var searches: [String] { log.withLock { $0.searches } }
    var sorts: [SearchSort] { log.withLock { $0.sorts } }
    var rowRequests: [Range<Int>] { log.withLock { $0.rows } }

    func search(_ query: String, sort: SearchSort) throws -> SearchGeneration {
        log.withLock {
            $0.searches.append(query)
            $0.generation += 1
            return SearchGeneration(rawValue: $0.generation)
        }
    }

    func sort(_ sort: SearchSort) throws -> SearchGeneration {
        log.withLock {
            $0.sorts.append(sort)
            $0.generation += 1
            return SearchGeneration(rawValue: $0.generation)
        }
    }

    func searchContent(_ query: String, terms: [String], matchAll: Bool, sort: SearchSort) throws -> SearchGeneration {
        try search(query, sort: sort)
    }

    func narrow(_ query: String, sort: SearchSort) throws -> SearchGeneration { try search(query, sort: sort) }

    func refresh(_ query: String, sort: SearchSort) throws -> SearchGeneration { try search(query, sort: sort) }

    func stopContent() throws {}

    func rows(_ generation: SearchGeneration, in range: Range<Int>) throws -> [SearchHit] {
        log.withLock { $0.rows.append(range) }
        return range.map(hit)
    }
}

private final class A11yVoice {
    var posts: [(window: NSWindow, text: String)] = []
    private var waiting: [@MainActor () -> Void] = []
    private(set) var announcer: Announcer!

    init() {
        announcer = Announcer(
            post: { [weak self] window, text in self?.posts.append((window, text)) },
            schedule: { [weak self] work in self?.waiting.append(work) }
        )
    }

    var texts: [String] { posts.map(\.text) }
    var pending: Int { waiting.count }

    func settle() {
        let due = waiting
        waiting = []
        for work in due { work() }
    }
}

private final class A11yTableWindow {
    let session: A11yCountingSession
    let model: SearchModel
    let window: KeyedWindow
    let view: NSView
    let recorder = ActionRecorder()

    init(voice: A11yVoice, session: A11yCountingSession = A11yCountingSession(), key: Bool = true) {
        self.session = session
        model = SearchModel(session: session)
        let table = ResultsTable(model: model, appIcon: { _ in nil }, announcer: voice.announcer)
        let controller = NSHostingController(rootView: AnyView(table.environment(\.resultActions, recorder.actions)))
        window = KeyedWindow(contentViewController: controller)
        window.reportsKey = key
        view = controller.view
        window.setContentSize(NSSize(width: SearchMetrics.windowMinWidth, height: SearchMetrics.windowMinHeight))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.contentViewController = nil
        window.close()
    }

    var table: NSTableView? { a11yTableView(in: view) }

    func until(
        _ description: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        try await untilTrue(waitingFor: description(), sourceLocation: sourceLocation) {
            view.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    func search(_ query: String, count: Int) async throws {
        model.query = query
        model.handle(.resultsReady(session.latest, count: count))
        try await until("\(count) rows for \(query)") { !model.isPending && table?.numberOfRows == count }
    }

    func liveUpdate(count: Int) async throws {
        model.handle(.resultsChanged)
        model.handle(.resultsReady(session.latest, count: count))
        try await until("\(count) live rows") { model.results.live && table?.numberOfRows == count }
    }

    func cell(row: Int, column: ResultsTable.Column) -> ResultCell? {
        guard let table else { return nil }
        let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
        return table.view(atColumn: index, row: row, makeIfNecessary: false) as? ResultCell
    }

    func tableColumn(_ column: ResultsTable.Column) throws -> NSTableColumn {
        try #require(table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)))
    }
}

private func a11yTableView(in root: NSView) -> NSTableView? {
    if let table = root as? NSTableView { return table }
    for child in root.subviews {
        if let table = a11yTableView(in: child) { return table }
    }
    return nil
}

private func a11yOldTitle(of element: NSObject) -> String? {
    let selector = NSSelectorFromString("accessibilityAttributeValue:")
    guard element.responds(to: selector) else { return nil }
    return element.perform(selector, with: NSAccessibility.Attribute.title.rawValue)?.takeUnretainedValue() as? String
}

private func a11yBundle(_ language: String) throws -> Bundle {
    try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
}

private func a11yTableValue(_ key: String, _ table: String, _ language: String = "de") throws -> String {
    let text = try a11yBundle(language).localizedString(forKey: key, value: "\u{1}", table: table)
    try #require(text != "\u{1}" && !text.isEmpty, "\(table) holds no \(key) in \(language)")
    return text
}

@Suite(.serialized) struct AccessibilityTests {
    private static let english = Locale(identifier: "en")

    @Test func a2TheNameCellReadsThePlainNameBesideItsBoldMatch() async throws {
        let voice = A11yVoice()
        let session = A11yCountingSession { _ in
            SearchHit(name: "report.pdf", folder: "/tmp", size: 1, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .file, matches: [0..<3])
        }
        let host = A11yTableWindow(voice: voice, session: session)
        defer { host.close() }
        try await host.search("rep", count: 1)
        try await host.until("the name cell") { host.cell(row: 0, column: .name)?.textField?.stringValue == "report.pdf" }

        let field = try #require(host.cell(row: 0, column: .name)?.textField)
        #expect(field.accessibilityLabel() == "report.pdf")
        let drawn = field.attributedStringValue
        let font = try #require(drawn.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "the match is not drawn bold, so the label check proves nothing")
    }

    @Test func a3AFolderCutOnScreenReadsItsWholePath() async throws {
        let folder = "/" + (0..<30).map { "folder\($0 % 10)abc" }.joined(separator: "/")
        try #require(folder.count >= 300)
        let voice = A11yVoice()
        let session = A11yCountingSession { _ in
            SearchHit(name: "deep.txt", folder: folder, size: 1, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .file)
        }
        let host = A11yTableWindow(voice: voice, session: session)
        defer { host.close() }
        try await host.search("deep", count: 1)
        try await host.until("the folder cell") { host.cell(row: 0, column: .folder)?.textField != nil }

        let field = try #require(host.cell(row: 0, column: .folder)?.textField)
        #expect(field.lineBreakMode == .byTruncatingMiddle)
        #expect(field.stringValue == folder)
        #expect(field.accessibilityValue() == folder)
        #expect(field.accessibilityLabel() == nil || field.accessibilityLabel() == folder)
        #expect(field.intrinsicContentSize.width > field.frame.width, "the path fits, so nothing was cut on screen")
    }

    @Test func a4TheFileIconIsNoAccessibilityElement() async throws {
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        defer { host.close() }
        try await host.search("hit", count: 3)
        try await host.until("the name cell's icon") { host.cell(row: 0, column: .name)?.imageView?.image != nil }

        let icon = try #require(host.cell(row: 0, column: .name)?.imageView)
        #expect(!icon.isAccessibilityElement())
    }

    @Test func a5TheTableReportsFiveHeadersAndTheRowsOnScreenOverAMillion() async throws {
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        defer { host.close() }
        try await host.search("hit", count: 1_000_000)
        let table = try #require(host.table)
        try await host.until("rows on screen") { table.rows(in: table.visibleRect).length > 0 && host.cell(row: 0, column: .name) != nil }

        let titles = table.tableColumns.map(\.title)
        #expect(titles.count == 5)
        #expect(titles == ResultsTable.Column.defaults.map(\.title))
        let header = table.accessibilityHeader() as? NSView
        let headers = (header?.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
        #expect(headers.count == titles.count, "the header holds \(headers.count) elements")
        let spoken = headers.map { a11yOldTitle(of: $0) ?? "" }
        #expect(spoken == titles, "VoiceOver hears \(spoken)")
        #expect(table.accessibilityColumns()?.count == titles.count)
        let onScreen = table.rows(in: table.visibleRect)
        #expect(table.accessibilityVisibleRows()?.count == onScreen.length)
        #expect(onScreen.length < 1000)
        let reach = (onScreen.location + onScreen.length) / SearchModel.pageSize + 2
        #expect(host.session.rowRequests.allSatisfy { $0.upperBound <= reach * SearchModel.pageSize }, "\(host.session.rowRequests)")
    }

    @Test func a6AHeaderClickSortsOnceAndTheHeaderReportsItsDirection() async throws {
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        defer { host.close() }
        try await host.search("hit", count: 10)
        let table = try #require(host.table)
        let size = try host.tableColumn(.size)
        let name = try host.tableColumn(.name)

        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: true)]
        #expect(host.session.sorts.isEmpty, "sortDescriptors alone sorted")
        table.sortDescriptors = []

        let steps: [(sort: SearchSort, direction: NSAccessibilitySortDirection)] = [
            (SearchSort(column: .size, ascending: false), .descending),
            (SearchSort(column: .size, ascending: true), .ascending),
            (.bestMatch, .unknown),
        ]
        for (index, step) in steps.enumerated() {
            let before = host.session.sorts.count
            table.delegate?.tableView?(table, didClick: size)
            #expect(host.session.sorts.count == before + 1, "click \(index + 1) made \(host.session.sorts.count - before) sort calls")
            #expect(host.session.sorts.last == step.sort)
            try await host.until("the header reports \(step.direction.rawValue) after click \(index + 1)") {
                size.headerCell.accessibilitySortDirection() == step.direction
            }
            #expect(name.headerCell.accessibilitySortDirection() == .unknown)
            #expect((table.indicatorImage(in: size) == nil) == (step.sort == .bestMatch))
        }
    }
}

extension AccessibilityTests {
    @Test func a7TheCountReadsEachLanguagesPlural() throws {
        let cases: [(String, [(Int, String)])] = [
            ("en", [(3, "3 results")]),
            ("tr", [(3, "3 sonuç")]),
            ("de", [(1, "1 Ergebnis"), (3, "3 Ergebnisse")]),
            ("fr", [(3, "3 résultats")]),
            ("es", [(3, "3 resultados")]),
            ("ru", [(21, "21 результат"), (2, "2 результата"), (5, "5 результатов")]),
            ("nl", [(3, "3 resultaten")]),
            ("ja", [(3, "3 件の結果")]),
            ("zh-Hans", [(3, "3 个结果")]),
            ("ar", [(0, "لا توجد نتائج"), (1, "نتيجة واحدة"), (2, "نتيجتان"), (3, "3 نتائج"), (11, "11 نتيجة"), (100, "100 نتيجة")]),
            ("pl", [(3, "3 wyniki")]),
        ]
        for (language, counts) in cases {
            let bundle = try a11yBundle(language)
            for localeID in numberingLocaleIDs(language) {
                let locale = Locale(identifier: localeID)
                for (count, expected) in counts {
                    let text = ResultsTable.countText(count, bundle: bundle, locale: locale)
                    #expect(text == locale.digits(expected), "\(localeID), count \(count): \(text)")
                }
            }
        }
        let german = try a11yBundle("de")
        let empty = ResultsTable.countText(0, bundle: german, locale: Locale(identifier: "de"))
        #expect(empty == (try a11yTableValue("No results", "Results")), "de, count 0: \(empty)")
        #expect(empty != "No results", "de, count 0: \(empty)")
    }

    @Test func a7FiveTypedLettersSpeakTheLastCountOnce() async throws {
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        defer { host.close() }
        for (letters, count) in zip(["r", "re", "rep", "repo", "repor"], [900, 400, 120, 30, 7]) {
            try await host.search(letters, count: count)
        }
        #expect(voice.posts.isEmpty, "spoken before the delay ended")
        voice.settle()
        #expect(voice.texts == [ResultsTable.countText(7)])
        #expect(voice.posts.first?.window === host.window)
    }

    @Test func a7ALiveUpdateSpeaksNothing() async throws {
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        defer { host.close() }
        try await host.search("rep", count: 12)
        voice.settle()
        #expect(voice.texts == [ResultsTable.countText(12)])

        try await host.liveUpdate(count: 13)
        voice.settle()
        #expect(voice.texts == [ResultsTable.countText(12)], "the live count was spoken")
    }

    @Test func theEndOfAPressSpeaksTheFinalCountOnce() async throws {
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        defer { host.close() }
        host.model.content = ContentTerms(terms: ["alpha"])
        host.model.searchContent()
        let press = try #require(host.model.press)
        func grow(to count: Int, read: Int, done: Bool) async throws {
            host.model.handle(.resultsReady(host.session.latest, count: count))
            host.model.handle(.contentProgress(press, read: read, total: 10, notDownloaded: 0, unreadable: 0, done: done))
            try await host.until("\(count) rows") { host.table?.numberOfRows == count }
        }
        try await grow(to: 0, read: 0, done: false)
        try await grow(to: 2, read: 3, done: false)
        try await grow(to: 5, read: 6, done: false)
        voice.settle()
        #expect(voice.texts.isEmpty, "a growing set spoke: \(voice.texts)")

        try await grow(to: 7, read: 10, done: true)
        voice.settle()
        #expect(voice.texts == [ResultsTable.countText(7)])
        host.model.handle(.contentProgress(press, read: 10, total: 10, notDownloaded: 0, unreadable: 0, done: true))
        try await Task.sleep(for: .milliseconds(100))
        voice.settle()
        #expect(voice.texts == [ResultsTable.countText(7)], "the final count spoke more than once")
    }

    @Test func aSecondPressWithTheSameNameSpeaksAgain() async throws {
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        defer { host.close() }
        host.model.content = ContentTerms(terms: ["alpha"])
        for count in [7, 3] {
            host.model.searchContent()
            let press = try #require(host.model.press)
            host.model.handle(.resultsReady(host.session.latest, count: count))
            host.model.handle(.contentProgress(press, read: 10, total: 10, notDownloaded: 0, unreadable: 0, done: true))
            try await host.until("\(count) rows") { host.table?.numberOfRows == count }
            voice.settle()
        }
        #expect(voice.texts == [ResultsTable.countText(7), ResultsTable.countText(3)])
    }

    @Test func a7AWindowThatIsNotKeySpeaksNothing() async throws {
        let voice = A11yVoice()
        let front = A11yTableWindow(voice: voice)
        let back = A11yTableWindow(voice: voice, key: false)
        defer {
            back.close()
            front.close()
        }
        try await back.search("rep", count: 12)
        voice.settle()
        #expect(voice.posts.isEmpty, "the background window spoke")

        try await front.search("rep", count: 5)
        voice.settle()
        #expect(voice.texts == [ResultsTable.countText(5)])
        #expect(voice.posts.first?.window === front.window)
    }

    @Test func a7AHeaderClickSpeaksNoCount() async throws {
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        defer { host.close() }
        try await host.search("rep", count: 12)
        voice.settle()
        let table = try #require(host.table)
        table.delegate?.tableView?(table, didClick: try host.tableColumn(.size))
        host.model.handle(.resultsReady(host.session.latest, count: 11))
        try await host.until("the sorted results in the table") { !host.model.isPending && host.table?.numberOfRows == 11 }
        #expect(voice.pending == 0, "the header click asked to speak")
        voice.settle()
        #expect(voice.texts == [ResultsTable.countText(12)])
    }

    @Test func a8NoResultsSpeaksOnce() async throws {
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        defer { host.close() }
        try await host.search("rep", count: 12)
        try await host.search("repqzx", count: 0)
        voice.settle()
        #expect(voice.texts == [ResultsTable.countText(0)])
        #expect(ResultsTable.countText(0) != ResultsTable.countText(12))
    }

    @Test func a8TheEndOfIndexingSpeaksOnceFromTheKeyWindow() async throws {
        let voice = A11yVoice()
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake, announcer: voice.announcer)
        let front = A11yTableWindow(voice: voice)
        let back = A11yTableWindow(voice: voice, key: false)
        defer {
            back.close()
            front.close()
        }
        for phase in [IndexPhase.crawling, .finishing, .ready, .live] {
            fake.send(.stateChanged(IndexState(phase: phase, indexed: 10)))
            try await untilTrue(waitingFor: "the index at \(phase)") { index.indexState?.phase == phase }
            voice.settle()
        }
        #expect(voice.texts == [StatusBarView.text(.ready)])
        #expect(voice.posts.first?.window === front.window)
    }

    @Test func a8AFailedIndexSpeaksTheRecoveryLine() async throws {
        let voice = A11yVoice()
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake, announcer: voice.announcer)
        let front = A11yTableWindow(voice: voice)
        defer { front.close() }
        for phase in [IndexPhase.crawling, .finishing, .failed] {
            fake.send(.stateChanged(IndexState(phase: phase, indexed: 10)))
            try await untilTrue(waitingFor: "the index at \(phase)") { index.indexState?.phase == phase }
            voice.settle()
        }
        #expect(voice.texts == [StatusBarView.text(.failed)])
    }

    @Test func a9TheStatusBarReadsTheAnnouncedWords() async throws {
        let german = try a11yBundle("de")
        let fake = FakeSearchClient()
        let host = StatusHost(client: fake, locale: Locale(identifier: "de"))
        defer { host.close() }
        for phase in [IndexPhase.loading, .crawling, .finishing, .ready, .live, .failed] {
            let spoken = StatusBarView.text(phase, bundle: german)
            fake.send(.stateChanged(IndexState(phase: phase, indexed: 10)))
            try await host.until("the bar reads \(spoken)") { host.shows(spoken) }
        }
        #expect(StatusBarView.text(.ready, bundle: german) == (try a11yTableValue("Ready", "Localizable")))
        #expect(StatusBarView.text(.ready, bundle: german) != "Ready")
    }

    @Test func voiceOverReadsTheIndexingDisks() async throws {
        let german = try a11yBundle("de")
        let germanLocale = Locale(identifier: "de")
        let names = ["Disk 1", "Disk 2"]
        let spoken = StatusBarView.indexingText(names, bundle: german, locale: germanLocale)
        #expect(spoken == "Indiziere \(Bidi.name("Disk 1")) und \(Bidi.name("Disk 2"))")
        #expect(spoken != StatusBarView.indexingText(names, locale: Self.english))
        let fake = FakeSearchClient()
        let host = StatusHost(client: fake, locale: germanLocale)
        defer { host.close() }
        fake.send(.stateChanged(IndexState(phase: .crawling, bootPhase: .live, indexingDisks: names, indexed: 10)))
        try await host.until("the bar reads \(spoken)") { host.shows(spoken) }
    }

    @Test func theAnnouncementFollowsTheBootPhase() async throws {
        let voice = A11yVoice()
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake, announcer: voice.announcer)
        let front = A11yTableWindow(voice: voice)
        defer { front.close() }
        let states = [
            IndexState(phase: .live, indexed: 10),
            IndexState(phase: .crawling, bootPhase: .live, indexingDisks: ["Disk 1"], indexed: 11),
            IndexState(phase: .live, indexed: 12),
        ]
        for state in states {
            fake.send(.stateChanged(state))
            try await untilTrue(waitingFor: "the index at \(state.indexed)") { index.indexState == state }
            voice.settle()
        }
        #expect(voice.texts == [StatusBarView.indexingText(["Disk 1"])])
        #expect(!voice.texts.contains(StatusBarView.text(.live)))
    }
}

extension AccessibilityTests {
    @Test func a12EveryResultsMenuActionHasAKeyOutsideTheSystemsOwn() async throws {
        let reserved: [(key: String, modifiers: NSEvent.ModifierFlags)] = [
            (" ", [.command]), (" ", [.option, .command]), (" ", [.control, .command]), (" ", [.shift, .command]), (" ", [.control]),
            (" ", [.control, .option]), ("p", [.control, .option, .command]), (String(Character(NSEvent.SpecialKey.f2.unicodeScalar)), [.control]),
            ("f", [.control, .shift]),
        ]
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        defer { host.close() }
        try await host.search("hit", count: 3)
        let table = try #require(host.table)
        try await host.until("row 1 on screen") { host.cell(row: 1, column: .name) != nil }
        let rect = table.rect(ofRow: 1)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 1
        ))
        let menu = try #require(table.menu(for: event))
        #expect(menu.items.count == 4)
        for item in menu.items {
            #expect(!item.keyEquivalent.isEmpty, "\(item.title) has no key")
            let modifiers = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
            let taken = reserved.contains { $0.key == item.keyEquivalent.lowercased() && $0.modifiers == modifiers }
            #expect(!taken, "\(item.title) takes a system key")
        }
    }

    @Test func a14RowAndStatusTextIsTenPointsOrLarger() async throws {
        for size in TextSize.allCases {
            #expect(ResultsTable.font(size).pointSize >= 10, "\(size)")
            #expect(StatusBarView.font(size).pointSize >= 10, "\(size)")
        }
        let voice = A11yVoice()
        let session = A11yCountingSession { _ in
            SearchHit(name: "report.pdf", folder: "/tmp", size: 2048, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .file, matches: [0..<3])
        }
        let host = A11yTableWindow(voice: voice, session: session)
        defer { host.close() }
        try await host.search("rep", count: 1)
        try await host.until("every cell of row 0") { ResultsTable.Column.defaults.allSatisfy { host.cell(row: 0, column: $0) != nil } }
        for column in ResultsTable.Column.defaults {
            let field = try #require(host.cell(row: 0, column: column)?.textField)
            #expect((field.font?.pointSize ?? 0) >= 10, "\(column)")
            let text = field.attributedStringValue
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                #expect(((value as? NSFont)?.pointSize ?? 10) >= 10, "\(column) run")
            }
        }
    }

    @Test func a18EveryIndexStateHasWordsAndAShape() throws {
        let german = try a11yBundle("de")
        let phases: [IndexPhase?] = [nil, .loading, .crawling, .finishing, .ready, .live, .failed]
        for phase in phases { #expect(!StatusBarView.text(phase, bundle: german).isEmpty, "\(String(describing: phase))") }
        #expect(Set(phases.map { StatusBarView.text($0, bundle: german) }).count == phases.count)
        #expect(Set([IndexPhase.crawling, .ready, .live].map { StatusBarView.mark($0) }).count == 2)
        #expect(Set([IndexPhase.crawling, .ready, .live].map { StatusBarView.mark($0, paused: true) }) == [.ring, .pause])
        #expect(StatusBarView.text(.ready) != StatusBarView.text(.live))
        for phase in [IndexPhase.ready, .live] {
            let paused = StatusBarView.text(phase, paused: true, bundle: german)
            #expect(paused == StatusBarView.text(.live, paused: true, bundle: german) && paused != StatusBarView.text(phase, bundle: german))
        }
        #expect(StatusBarView.text(.crawling, paused: true) == StatusBarView.text(.crawling))
    }
}

extension AccessibilityTests {
    @Test func matrixClosingTheWindowBeforeTheDelaySpeaksNothing() async throws {
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        try await host.search("rep", count: 12)
        #expect(voice.pending > 0)
        host.close()
        voice.settle()
        #expect(voice.posts.isEmpty)
    }

    @Test func matrixAnotherWindowTurningKeyBeforeTheDelaySilencesBoth() async throws {
        let voice = A11yVoice()
        let first = A11yTableWindow(voice: voice)
        let second = A11yTableWindow(voice: voice, key: false)
        defer {
            second.close()
            first.close()
        }
        try await first.search("rep", count: 12)
        first.window.reportsKey = false
        second.window.reportsKey = true
        voice.settle()
        #expect(voice.posts.isEmpty)
    }

    @Test func matrixClearingTheTextSpeaksNothingAndDropsTheWaitingCount() async throws {
        let voice = A11yVoice()
        let host = A11yTableWindow(voice: voice)
        defer { host.close() }
        try await host.search("rep", count: 12)
        host.model.query = ""
        try await host.until("the cleared table") { host.table?.numberOfRows == 0 }
        voice.settle()
        #expect(voice.posts.isEmpty)

        try await host.search("rep", count: 12)
        voice.settle()
        #expect(voice.texts == [ResultsTable.countText(12)])
    }
}

private func a11yArray(_ element: NSObject, _ selector: String) -> NSArray {
    element.perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? NSArray ?? []
}

private func a11yAttribute(_ element: NSObject, _ attribute: String) -> Any? {
    element.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?.takeUnretainedValue()
}

private func a11yIndices(_ rows: NSArray) -> [Int] {
    rows.compactMap { ($0 as? NSObject).flatMap { a11yAttribute($0, "AXIndex") as? Int } }
}

extension AccessibilityTests {
    @Test func rowQueriesOnTwoMillionRowsAnswerOnlyVisibleRows() async throws {
        let host = A11yTableWindow(voice: A11yVoice())
        defer { host.close() }
        try await host.search("hit", count: 2_000_000)
        let table = try #require(host.table)
        try await host.until("rows on screen") { table.rows(in: table.visibleRect).length > 0 && host.cell(row: 0, column: .name) != nil }
        let onScreen = table.rows(in: table.visibleRect)
        let margin = ThemedTable.accessibilityMarginRows
        let bound = onScreen.length + 2 * margin
        let fetched = host.session.rowRequests.count

        var rows = NSArray(), children = NSArray(), navigation = NSArray()
        let spent = ContinuousClock().measure {
            rows = a11yArray(table, "accessibilityRows")
            children = a11yArray(table, "accessibilityChildren")
            navigation = a11yArray(table, "accessibilityChildrenInNavigationOrder")
        }
        #expect(rows.count <= bound, "AXRows holds \(rows.count) rows")
        let others = (table.accessibilityColumns()?.count ?? 0) + 1
        #expect(children.count <= bound + others, "AXChildren holds \(children.count) elements")
        #expect(navigation.count <= bound + others, "AXChildrenInNavigationOrder holds \(navigation.count) elements")
        #expect(spent < .milliseconds(100), "the three reads took \(spent)")
        try #require(rows.count <= bound, "reading each row's cells would walk every row")

        for case let row as NSObject in rows { _ = a11yAttribute(row, "AXChildren") }
        let pageSize = SearchModel.pageSize
        let low = max(0, onScreen.location - margin) / pageSize * pageSize
        let high = (onScreen.location + onScreen.length + margin) / pageSize * pageSize + pageSize
        let fresh = Array(host.session.rowRequests.dropFirst(fetched))
        #expect(fresh.allSatisfy { $0.lowerBound >= low && $0.upperBound <= high }, "\(fresh)")
        #expect(fresh.count <= (high - low) / pageSize, "\(fresh.count) page fetches")
    }

    @Test func selectAllOverTwoMillionRowsReadsOnlyTheScreen() async throws {
        let host = A11yTableWindow(voice: A11yVoice())
        defer { host.close() }
        try await host.search("hit", count: 2_000_000)
        let table = try #require(host.table as? ThemedTable)
        try await host.until("rows on screen") { table.rows(in: table.visibleRect).length > 0 && host.cell(row: 0, column: .name) != nil }
        let onScreen = table.rows(in: table.visibleRect)
        let margin = ThemedTable.accessibilityMarginRows
        let fetched = host.session.rowRequests.count

        table.selectAll(nil)
        #expect(table.selectedRowIndexes.count == 2_000_000)
        var selected: NSArray?
        let spent = ContinuousClock().measure { selected = table.accessibilitySelectedRows() as NSArray? }
        let rows = try #require(selected)
        #expect(rows.count > 0 && rows.count <= onScreen.length + 2 * margin, "AXSelectedRows holds \(rows.count) rows")
        #expect(a11yIndices(rows).allSatisfy { table.selectedRowIndexes.contains($0) })
        #expect(spent < .milliseconds(100), "AXSelectedRows took \(spent)")

        let pageSize = SearchModel.pageSize
        let low = max(0, onScreen.location - margin) / pageSize * pageSize
        let high = (onScreen.location + onScreen.length + margin) / pageSize * pageSize + pageSize
        let fresh = Array(host.session.rowRequests.dropFirst(fetched))
        #expect(fresh.allSatisfy { $0.lowerBound >= low && $0.upperBound <= high }, "\(fresh)")

        try await host.liveUpdate(count: 2_000_001)
        #expect(table.selectedRowIndexes.count == 2_000_001)
    }

    @Test func theRowCountStillReportsEveryRow() async throws {
        let host = A11yTableWindow(voice: A11yVoice())
        defer { host.close() }
        try await host.search("hit", count: 2_000_000)
        let table = try #require(host.table)
        #expect(table.accessibilityRowCount() == 2_000_000)
        #expect(a11yArray(table, "accessibilityRows").count < ThemedTable.accessibilityRowLimit)

        try await host.search("hit 5", count: 5)
        #expect(table.accessibilityRowCount() == 5)
        let rows = a11yArray(table, "accessibilityRows")
        #expect(a11yIndices(rows) == [0, 1, 2, 3, 4])
        let children = a11yArray(table, "accessibilityChildren").compactMap { $0 as? NSObject }
        #expect(children.filter { a11yAttribute($0, "AXRole") as? String == "AXRow" }.count == 5)
    }

    @Test func voiceOverStillMovesRowByRowAfterAScroll() async throws {
        let host = A11yTableWindow(voice: A11yVoice())
        defer { host.close() }
        try await host.search("hit", count: 2_000_000)
        let table = try #require(host.table)
        table.scrollRowToVisible(1_000_000)
        try await host.until("row 1,000,000 on screen") { NSLocationInRange(1_000_000, table.rows(in: table.visibleRect)) }
        let onScreen = table.rows(in: table.visibleRect)
        let below = onScreen.location + onScreen.length

        let rows = a11yArray(table, "accessibilityRows")
        try #require(rows.count <= onScreen.length + 2 * ThemedTable.accessibilityMarginRows, "AXRows holds \(rows.count) rows")
        let indices = a11yIndices(rows)
        let first = try #require(indices.first)
        #expect(indices == Array(first..<first + rows.count), "the rows are not one run: \(indices)")
        #expect(Set(onScreen.location - 1...below).isSubset(of: indices), "\(indices) misses the screen \(onScreen) or an edge")

        table.selectRowIndexes([below], byExtendingSelection: false)
        table.scrollRowToVisible(below)
        try await host.until("row \(below) on screen") { NSLocationInRange(below, table.rows(in: table.visibleRect)) }
        let selected = a11yArray(table, "accessibilitySelectedRows")
        #expect(selected.count == 1)
        #expect(a11yIndices(selected) == [below])
        let moved = a11yArray(table, "accessibilityRows")
        #expect(a11yIndices(moved).contains(below + 1), "VoiceOver's next row after \(below) is missing")
        #expect(selected.firstObject.map { moved.contains($0) } == true, "the selected row is missing from AXRows")
    }
}

func numberingLocaleIDs(_ language: String) -> [String] { language == "ar" ? ["ar", "ar_SA"] : [language] }

extension Locale {
    func digits(_ text: String) -> String {
        text.map { c in c.isASCII ? c.wholeNumberValue.map { $0.formatted(.number.locale(self)) } ?? String(c) : String(c) }.joined()
    }
}
