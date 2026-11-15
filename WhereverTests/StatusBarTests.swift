import AppKit
import CoreText
import Foundation
import os
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private nonisolated final class FolderChecks: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var done: Int { count.withLock { $0 } }

    func wrap(_ real: @escaping @Sendable (String) -> (path: String, isFolder: Bool)) -> @Sendable (String) -> (path: String, isFolder: Bool) {
        { [self] path in
            let found = real(path)
            count.withLock { $0 += 1 }
            return found
        }
    }
}

@Suite(.serialized) struct StatusBarTests {
    private static let english = Locale(identifier: "en")

    private static func store(_ name: String) -> UserDefaults {
        let suite = "com.writronic.wherever.tests.statusbar.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }
    private static let phaseTexts = ["Starting", "Loading the saved index", "Indexing the disk", "Ready", "Live updates on"]
    private static let accessLines = [
        ("Limited access: no Full Disk Access", "Localizable"), ("Other disks are searched only when Wherever has Full Disk Access.", "Settings"),
    ]

    private struct Step {
        let state: IndexState
        let text: String
        let count: String
    }

    private static let steps = [
        Step(state: IndexState(phase: .loading, indexed: 0), text: "Loading the saved index", count: "0"),
        Step(state: IndexState(phase: .crawling, indexed: 100_000), text: "Indexing the disk", count: "100,000"),
        Step(state: IndexState(phase: .ready, indexed: 1_234_567), text: "Ready", count: "1,234,567"),
        Step(state: IndexState(phase: .live, indexed: 1_234_568), text: "Live updates on", count: "1,234,568"),
    ]

    @Test func theBarStartsNeutralAndFollowsEveryStateTheEngineReports() async throws {
        let fake = FakeSearchClient()
        let host = StatusHost(client: fake, locale: Self.english)
        defer { host.close() }
        try await host.until("the neutral bar") { host.shows("Starting") }
        #expect(!host.shows("Files:"))

        for step in Self.steps {
            fake.send(.stateChanged(step.state))
            let count = "Files: \(step.count)"
            try await host.until("\(step.text) with \(count)") { host.shows(step.text) && host.shows(count) }
            for other in Self.phaseTexts where other != step.text { #expect(!host.shows(other), "\(other) beside \(step.text)") }
            if step.state.bootPhase == .live {
                #expect(AXTree.element(StatusBarView.liveUpdatesID, in: host.view) != nil, "the live line is a button")
                #expect(host.oneElementReads([count]))
            } else {
                #expect(host.oneElementReads([step.text, count]), "the state and the count are two elements")
            }
        }
    }

    @Test func theLocationsPaneAndTheStatusBarShowNoAccessLine() async throws {
        for language in ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"] {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            for (key, table) in Self.accessLines {
                #expect(bundle.localizedString(forKey: key, value: "\u{1}", table: table) == "\u{1}", "\(table) in \(language) still holds \(key)")
            }
        }
        let fake = FakeSearchClient()
        let host = StatusHost(client: fake, locale: Self.english)
        defer { host.close() }
        for step in Self.steps {
            fake.send(.stateChanged(step.state))
            try await host.until(step.text) { host.shows(step.text) && host.shows("Files: \(step.count)") }
            for (key, _) in Self.accessLines { #expect(!host.shows(key), "\(key) beside \(step.text)") }
        }
    }

    private static func state(
        boot: IndexPhase, disks: [String] = []
    ) -> IndexState {
        IndexState(phase: disks.isEmpty ? boot : .crawling, bootPhase: boot, indexingDisks: disks, indexed: 1_234_567)
    }

    @Test func theStatusSentencesIsolateEachDiskName() throws {
        let names = ["Disk 1", "قرص 2"]
        let troubles = names.flatMap { name in
            [DiskTrouble(path: "/Volumes/\(name)", kind: .unreadable), DiskTrouble(path: "/Volumes/\(name)", kind: .liveUpdatesOff)]
        }
        for language in ["en", "ar"] {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)))
            let locale = Locale(identifier: language)
            let lines = StatusBarView.troubleLines(troubles, bundle: bundle, locale: locale)
                + [StatusBarView.indexingText(names, bundle: bundle, locale: locale)]
            #expect(lines.count == 3)
            for line in lines {
                for name in names { #expect(line.contains("\u{2068}\(name)\u{2069}")) }
            }
        }
    }

    @Test func theBarReadsLiveWhileADiskIndexes() async throws {
        let fake = FakeSearchClient()
        let host = StatusHost(client: fake, locale: Self.english)
        defer { host.close() }
        fake.send(.stateChanged(Self.state(boot: .live, disks: ["Disk 1", "Disk 2"])))
        try await host.until("Live updates on with both disks") { host.shows("Live updates on") && host.shows("Indexing \(Bidi.name("Disk 1")) and \(Bidi.name("Disk 2"))") }
        #expect(!host.shows("Indexing the disk"))
        #expect(host.oneElementReads(["Indexing \(Bidi.name("Disk 1")) and \(Bidi.name("Disk 2"))", "Files: 1,234,567"]))
        #expect(!host.oneElementReads(["Live updates on", "Files: 1,234,567"]), "the live line is its own button")

        fake.send(.stateChanged(Self.state(boot: .live, disks: ["Disk 2"])))
        try await host.until("a disk that left the group") { host.shows("Indexing \(Bidi.name("Disk 2"))") && !host.shows("Disk 1") }
    }

    @Test func noIndexingDiskShowsNoGroup() async throws {
        let fake = FakeSearchClient()
        let host = StatusHost(client: fake, locale: Self.english)
        defer { host.close() }
        fake.send(.stateChanged(Self.state(boot: .live, disks: ["Disk 1"])))
        try await host.until("the group") { host.shows("Indexing \(Bidi.name("Disk 1"))") }
        fake.send(.stateChanged(Self.state(boot: .live)))
        try await host.until("all disks done") { host.shows("Live updates on") && !host.shows("Indexing \(Bidi.name("Disk 1"))") }
        #expect(!host.shows("Indexing the disk"))
    }

    @Test func theFirstCrawlStillReadsIndexingTheDisk() async throws {
        let fake = FakeSearchClient()
        let host = StatusHost(client: fake, locale: Self.english)
        defer { host.close() }
        fake.send(.stateChanged(Self.state(boot: .crawling)))
        try await host.until("Indexing the disk") { host.shows("Indexing the disk") }
        #expect(!host.shows("Live updates on"))
    }

    @Test func finishingShowsFinishingTheIndex() async throws {
        let line = "Finishing the index…"
        let fake = FakeSearchClient()
        let host = StatusHost(client: fake, locale: Self.english)
        defer { host.close() }
        fake.send(.stateChanged(Self.state(boot: .crawling)))
        try await host.until("Indexing the disk") { host.shows("Indexing the disk") }
        fake.send(.stateChanged(Self.state(boot: .finishing)))
        try await host.until(line) { host.shows(line) && !host.shows("Indexing the disk") }
        #expect(host.oneElementReads([line, "Files: 1,234,567"]))
        #expect(StatusBarView.text(.finishing) == line)
        #expect(StatusBarView.mark(.finishing) == .ring)
        fake.send(.stateChanged(Self.state(boot: .ready)))
        try await host.until("Ready after finishing") { host.shows("Ready") && !host.shows(line) }
    }

    @Test func theFailedPhaseShowsTheRecoveryLine() async throws {
        let line = "Wherever could not build the index. Choose Quit Wherever from the Wherever menu, then open Wherever again."
        for language in ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"] {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            for key in [line, "Finishing the index…"] {
                let text = bundle.localizedString(forKey: key, value: "\u{1}", table: "Results")
                #expect(text != "\u{1}" && (language == "en") == (text == key), "\(language): \(text)")
            }
        }
        let fake = FakeSearchClient()
        let host = StatusHost(client: fake, locale: Self.english)
        defer { host.close() }
        fake.send(.stateChanged(Self.state(boot: .crawling)))
        try await host.until("Indexing the disk") { host.shows("Indexing the disk") }
        fake.send(.stateChanged(Self.state(boot: .failed)))
        try await host.until("the recovery line") { host.shows(line) && !host.shows("Indexing the disk") }
        #expect(StatusBarView.text(.failed) == line)
        #expect(host.oneElementReads([line, "Files: 1,234,567"]))
    }

    private static let failedKey = "Wherever could not build the index. Choose Quit Wherever from the Wherever menu, then open Wherever again."

    private static func coreTextLines(_ text: String, _ size: TextSize, width: CGFloat) -> Int {
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: StatusBarView.font(size)]))
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        return CFArrayGetCount(CTFrameGetLines(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)))
    }

    private struct FailedBar {
        let index: IndexModel
        let model: SearchModel
        let store: UserDefaults
        let language: String

        func height(width: CGFloat) -> CGFloat {
            let bar = StatusBarView(index: index, model: model).environment(\.locale, Locale(identifier: language)).defaultAppStorage(store)
            return NSHostingView(rootView: bar.frame(width: width)).fittingSize.height
        }
    }

    private static func failedBar(_ language: String, _ size: TextSize, phase: IndexPhase = .failed) async throws -> (FailedBar, FakeSearchClient) {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let store = Self.store("failed-\(language)")
        store.set(size.rawValue, forKey: TextSize.key)
        fake.send(.stateChanged(Self.state(boot: phase)))
        try await untilTrue(waitingFor: "the \(phase) phase") { index.indexState?.bootPhase == phase }
        return (FailedBar(index: index, model: index.makeModel(), store: store, language: language), fake)
    }

    private static func expectWrapped(_ bar: FailedBar, _ size: TextSize, width: CGFloat, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        let bundle = try #require(Bundle.main.url(forResource: bar.language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(bar.language).lproj")
        let sentence = bundle.localizedString(forKey: failedKey, value: "\u{1}", table: "Results")
        #expect(sentence != "\u{1}", sourceLocation: sourceLocation)
        let inner = width - 2 * SearchMetrics.sideInset
        let lines = coreTextLines(sentence, size, width: inner)
        let line = StatusBarView.lineHeight(size)
        let font = Font(StatusBarView.font(size) as CTFont)
        let single = NSHostingView(rootView: Text(verbatim: "Ag").font(font).fixedSize()).fittingSize.height
        let wrapped = NSHostingView(rootView: Text(verbatim: sentence).font(font).frame(width: inner)).fittingSize.height
        #expect(Int((wrapped / single).rounded()) == lines, "SwiftUI draws \(wrapped) pt of \(single) pt lines, Core Text counts \(lines)", sourceLocation: sourceLocation)
        let height = bar.height(width: width)
        #expect(height == 1 + CGFloat(lines + 1) * line + 2 * SearchMetrics.statusVerticalInset,
            "\(bar.language) at \(size.rawValue) and \(width) pt: \(height) pt for \(lines) sentence lines of \(line) pt", sourceLocation: sourceLocation)
        return lines
    }

    @Test func theFailedSentenceTakesItsOwnLineAtTheMinimumWidth() async throws {
        let (bar, _) = try await Self.failedBar("en", .standard)
        _ = try Self.expectWrapped(bar, .standard, width: SearchMetrics.windowMinWidth)
        #expect(bar.height(width: SearchMetrics.windowMinWidth) > 1 + StatusBarView.lineHeight(.standard) + 2 * SearchMetrics.statusVerticalInset)
    }

    @Test func theGermanFailedSentenceWrapsAtTheLargestTextSize() async throws {
        let (bar, _) = try await Self.failedBar("de", .maximum)
        let lines = try Self.expectWrapped(bar, .maximum, width: SearchMetrics.windowMinWidth)
        #expect(lines > 1, "German at 18 needs more than one sentence line at 720 pt")
    }

    @Test func aWiderWindowTakesFewerSentenceLines() async throws {
        let (bar, _) = try await Self.failedBar("de", .maximum)
        let narrow = try Self.expectWrapped(bar, .maximum, width: SearchMetrics.windowMinWidth)
        let wide = try Self.expectWrapped(bar, .maximum, width: 1400)
        #expect(wide == 1 && narrow > wide)
        #expect(bar.height(width: 1400) < bar.height(width: SearchMetrics.windowMinWidth))
    }

    @Test func theFailedBarFollowsATextSizeChange() async throws {
        let (bar, _) = try await Self.failedBar("de", .standard)
        let small = try Self.expectWrapped(bar, .standard, width: SearchMetrics.windowMinWidth)
        bar.store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        let large = try Self.expectWrapped(bar, .maximum, width: SearchMetrics.windowMinWidth)
        #expect(large > small)
        bar.store.removeObject(forKey: TextSize.key)
        _ = try Self.expectWrapped(bar, .standard, width: SearchMetrics.windowMinWidth)
    }

    @Test func everyOtherStateKeepsTheOneLineHeight() async throws {
        let oneLine = 1 + StatusBarView.lineHeight(.standard) + 2 * SearchMetrics.statusVerticalInset
        #expect(oneLine == 24)
        let (live, _) = try await Self.failedBar("en", .standard, phase: .live)
        #expect(live.height(width: SearchMetrics.windowMinWidth) == oneLine)
        let (bar, fake) = try await Self.failedBar("en", .standard)
        #expect(bar.height(width: SearchMetrics.windowMinWidth) > oneLine)
        fake.send(.stateChanged(Self.state(boot: .live)))
        try await untilTrue(waitingFor: "live after the failure") { bar.index.indexState?.bootPhase == .live }
        #expect(bar.height(width: SearchMetrics.windowMinWidth) == oneLine)
        #expect(bar.height(width: 1400) == oneLine)
    }

    @Test func theFailedBarReadsTheSentenceBesideTheCount() async throws {
        for language in ["en", "de"] {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)))
            let sentence = bundle.localizedString(forKey: Self.failedKey, value: nil, table: "Results")
            let fake = FakeSearchClient()
            let host = StatusHost(client: fake, locale: Locale(identifier: language))
            defer { host.close() }
            fake.send(.stateChanged(Self.state(boot: .failed)))
            let count = 1_234_567.formatted(.number.locale(Locale(identifier: language)))
            try await host.until("\(language): the sentence and the count in one element") { host.oneElementReads([sentence, count]) }
            let bar = try #require(AXTree.element("status-bar", in: host.view))
            let read = AXTree.names(of: bar).joined(separator: "\n")
            #expect(read.components(separatedBy: sentence).count - 1 == 1, "\(language): \(read)")
        }
    }

    @Test func aRefusedDiskShowsCouldNotBeRead() async throws {
        for language in ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"] {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            for key in ["Could not read %@", "Live updates are off for %@"] {
                let text = bundle.localizedString(forKey: key, value: "\u{1}", table: "Results")
                #expect(text != "\u{1}" && (language == "en") == (text == key) && text.contains("%@"), "\(language): \(text)")
            }
        }
        let fake = FakeSearchClient()
        let host = StatusHost(client: fake, locale: Self.english)
        defer { host.close() }
        let refused = DiskTrouble(path: "/Volumes/Disk 1", kind: .unreadable)
        fake.send(.stateChanged(IndexState(phase: .failed, bootPhase: .live, troubles: [refused], indexed: 10)))
        try await host.until("the refused disk") { host.shows("Could not read \(Bidi.name("Disk 1"))") }
        #expect(host.shows("Live updates on"))
        #expect(host.oneElementReads(["Could not read \(Bidi.name("Disk 1"))", "Files: 10"]))

        let off = DiskTrouble(path: "/Volumes/Disk 2", kind: .liveUpdatesOff)
        fake.send(.stateChanged(IndexState(phase: .failed, bootPhase: .live, troubles: [refused, off], indexed: 10)))
        try await host.until("both lines") { host.shows("Could not read \(Bidi.name("Disk 1"))") && host.shows("Live updates are off for \(Bidi.name("Disk 2"))") }

        fake.send(.stateChanged(IndexState(phase: .live, indexed: 10)))
        try await host.until("no trouble left") { !host.shows("Could not read") && !host.shows("Live updates are off") }
        #expect(StatusBarView.troubleLines([]).isEmpty)
    }

    @Test func thePressShowsTheCountAndStopSaysWhereItEnded() async throws {
        let fake = FakeSearchClient(hits: [.named("a.txt")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.locale, Self.english)))
        defer { host.close() }
        fake.send(.stateChanged(Self.steps[2].state))
        try await host.until("Ready") { host.windowShows("Ready") }
        #expect(!host.windowShows("Read ") && !host.windowShows("Stopped"))

        model.content = ContentTerms(terms: ["alpha"])
        model.searchContent()
        let press = try #require(model.press)
        try await host.until("the press's first line") { host.windowShows("Read 0 of 0 files") }
        model.handle(.contentProgress(press, read: 3, total: 10, notDownloaded: 0, unreadable: 0, done: false))
        try await host.until("Read 3 of 10 files") { host.windowShows("Read 3 of 10 files") }
        model.handle(.contentProgress(press, read: 1, total: 1, notDownloaded: 0, unreadable: 0, done: false))
        try await host.until("Read 1 of 1 file") { host.windowShows("Read 1 of 1 file") && !host.windowShows("1 of 1 files") }

        model.handle(.contentProgress(press, read: 4, total: 10, notDownloaded: 0, unreadable: 0, done: true))
        try await host.until("Stopped after 4 of 10 files") { host.windowShows("Stopped after 4 of 10 files") && !host.windowShows("Read ") }

        model.searchContent()
        let second = try #require(model.press)
        model.handle(.contentProgress(second, read: 2, total: 2, notDownloaded: 0, unreadable: 0, done: true))
        try await host.until("the line gone after a read that ended") { !host.windowShows("Stopped") && !host.windowShows("Read ") }
    }

    @Test func aMissingFolderAddsItsLineBesideTheCountAtThePressAndNoEarlier() async throws {
        let line = "Folder not found"
        let fake = FakeSearchClient(hits: [.named("a.txt")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.readDelay = {}
        let host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.locale, Self.english)))
        defer { host.close() }
        fake.send(.stateChanged(Self.steps[2].state))
        try await host.until("Ready") { host.windowShows("Ready") }

        model.filters.folder = "/nonexistent-wherever/folder"
        model.content = ContentTerms(terms: ["alpha"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.folderMissing && !host.windowShows(line), "nothing before a press")

        model.searchContent()
        let press = try #require(model.press)
        model.handle(.resultsReady(press, count: 0))
        model.handle(.contentProgress(press, read: 0, total: 0, notDownloaded: 0, unreadable: 0, done: true))
        try await host.until("the line beside the count") { host.windowShows(line) && host.windowShows("0 results") }

        model.query = "report"
        try await untilTrue(waitingFor: "the narrow") { fake.narrows.count == 1 }
        #expect(model.folderMissing, "a narrow keeps the line")

        model.filters.folder = "/nonexistent-wherever/other"
        #expect(!model.folderMissing, "the line goes when the folder changes")
        try await untilTrue(waitingFor: "the new read") { fake.presses.count == 2 }
        try await host.until("the line back with the new read") { host.windowShows(line) }

        model.filters.folder = FileManager.default.temporaryDirectory.path
        try await untilTrue(waitingFor: "the read of a real folder") { fake.presses.count == 3 }
        try await host.until("no line for a real folder") { !host.windowShows(line) }

        model.filters.folder = "docs"
        try await untilTrue(waitingFor: "the read of a relative folder") { fake.presses.count == 4 }
        try await host.until("the line for a relative folder") { host.windowShows(line) }
        model.content = ContentTerms()
        try await host.until("the line goes when the press ends") { !host.windowShows(line) }
        #expect(model.press == nil && !model.folderMissing)
    }

    @Test(arguments: [".", "..", ",", ";", "=", "<", ">", "docs", "docs/", "./docs", "/nonexistent-wherever/folder", "~/nonexistent-wherever-folder"])
    func aBoxThatHoldsNoFolderIsMissingAtThePress(text: String) async throws {
        let fake = FakeSearchClient()
        let model = SearchModel(session: try fake.makeSession())
        model.contentDraft = "alpha"
        model.filters.folder = text
        #expect(!model.folderMissing)
        model.searchContent()
        try await untilTrue(waitingFor: "the folder answer for \(text)") { model.folderMissing }
        #expect(model.folderMissing, "\(text)")
        #expect(fake.presses.count == 1, "the press still goes to the engine")
    }

    @Test func aFileIsMissingAndARealFolderIsNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wherever-statusfolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data().write(to: file)
        for (text, missing) in [(file.path, true), (root.path, false), (root.path + "/", false), ("/", false), ("~", false), (nil, false)] as [(String?, Bool)] {
            let fake = FakeSearchClient()
            let model = SearchModel(session: try fake.makeSession())
            model.contentDraft = "alpha"
            let checks = FolderChecks()
            model.checkFolder = checks.wrap(model.checkFolder)
            model.filters.folder = text
            model.searchContent()
            if text != nil {
                try await untilTrue(waitingFor: "the folder check for \(text ?? "")") { checks.done == 1 }
                if missing {
                    try await untilTrue(waitingFor: "the missing answer for \(text ?? "")") { model.folderMissing }
                } else {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            #expect(model.folderMissing == missing, "\(text ?? "no folder")")
        }
    }

    @Test(arguments: [
        ("en", "Folder not found"), ("tr", "Klasör bulunamadı"), ("de", "Ordner nicht gefunden"), ("fr", "Dossier introuvable"),
        ("es", "Carpeta no encontrada"), ("ru", "Папка не найдена"), ("nl", "Map niet gevonden"), ("ja", "フォルダが見つかりません"),
        ("zh-Hans", "未找到文件夹"), ("ar", "لم يتم العثور على المجلد"), ("pl", "Nie znaleziono folderu"),
    ])
    func theFolderLineReadsInEveryLanguage(language: String, expected: String) throws {
        let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
        #expect(bundle.localizedString(forKey: "Folder not found", value: "\u{1}", table: nil) == expected)
    }

    @Test func theReadLineFollowsEachLanguagesPlurals() throws {
        func line(_ read: Int, _ total: Int, _ done: Bool, _ language: String, _ localeID: String? = nil) throws -> String {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            return try #require(StatusBarView.readLine(.init(read: read, total: total, done: done), bundle: bundle, locale: Locale(identifier: localeID ?? language)))
        }
        func check(_ read: Int, _ total: Int, _ done: Bool, _ language: String, _ expected: String) throws {
            for localeID in numberingLocaleIDs(language) {
                let text = try line(read, total, done, language, localeID)
                #expect(text == Locale(identifier: localeID).digits(expected), "\(localeID), read \(read)/\(total), done \(done): \(text)")
            }
        }
        try check(1, 1, false, "en", "Read 1 of 1 file")
        try check(3, 10, false, "en", "Read 3 of 10 files")
        try check(4, 10, true, "en", "Stopped after 4 of 10 files")
        try check(1, 1, false, "de", "1 von 1 Datei gelesen")
        try check(3, 21, false, "ru", "Прочитано 3 из 21 файла")
        try check(3, 5, false, "ru", "Прочитано 3 из 5 файлов")
        try check(1, 2, false, "ar", "تمت قراءة 1 من ملفين")
        for (total, files) in [(21, "21 файла"), (2, "2 файлов"), (5, "5 файлов")] {
            try check(0, total, false, "ru", "Прочитано 0 из \(files)")
            try check(0, total, true, "ru", "Остановлено после 0 из \(files)")
        }
        for (total, files) in [(0, "0 ملف"), (1, "ملف واحد"), (2, "ملفين"), (3, "3 ملفات"), (11, "11 ملفًا"), (100, "100 ملف")] {
            try check(0, total, false, "ar", "تمت قراءة 0 من \(files)")
            if total > 0 { try check(0, total, true, "ar", "توقف بعد قراءة 0 من \(files)") }
        }
        #expect(StatusBarView.readLine(.init(read: 2, total: 2, done: true)) == nil, "a read that ended shows no line")
        for language in ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"] {
            for done in [false, true] {
                for localeID in numberingLocaleIDs(language) {
                    let (text, locale) = (try line(3, 10, done, language, localeID), Locale(identifier: localeID))
                    #expect(text.contains(locale.digits("3")) && text.contains(locale.digits("10")), "\(localeID): \(text)")
                    if language != "en" { #expect(text != (try line(3, 10, done, "en")), "\(localeID) shows English") }
                }
            }
        }
    }

    @Test func skippedFilesAreCountedInTheStatusBar() async throws {
        let fake = FakeSearchClient(hits: [.named("a.txt")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.locale, Self.english)))
        defer { host.close() }
        fake.send(.stateChanged(Self.steps[2].state))
        try await host.until("Ready") { host.windowShows("Ready") }

        model.content = ContentTerms(terms: ["alpha"])
        model.searchContent()
        let press = try #require(model.press)
        model.handle(.contentProgress(press, read: 3, total: 10, notDownloaded: 2, unreadable: 0, done: false))
        try await host.until("Read 3 of 10 files, 2 files skipped") {
            host.windowShows("Read 3 of 10 files") && host.windowShows("2 files skipped") && !host.windowShows("not downloaded")
        }
        model.handle(.contentProgress(press, read: 9, total: 10, notDownloaded: 0, unreadable: 1, done: true))
        try await host.until("an unsupported file alone, counted") {
            host.windowShows("1 file skipped") && !host.windowShows("unsupported") && !host.windowShows("Stopped")
        }
        model.handle(.contentProgress(press, read: 7, total: 10, notDownloaded: 2, unreadable: 1, done: true))
        try await host.until("both kinds in one count and no stop") {
            host.windowShows("3 files skipped") && !host.windowShows("not downloaded") && !host.windowShows("unsupported")
                && !host.windowShows("Stopped") && !host.windowShows("Read ")
        }
        model.handle(.contentProgress(press, read: 4, total: 10, notDownloaded: 1, unreadable: 0, done: true))
        try await host.until("a stop keeps its line beside the count") {
            host.windowShows("Stopped after 4 of 10 files") && host.windowShows("1 file skipped")
        }
        model.handle(.contentProgress(press, read: 10, total: 10, notDownloaded: 0, unreadable: 0, done: true))
        try await host.until("no count without skips") { !host.windowShows("skipped") }

        func bundle(_ language: String) throws -> Bundle {
            try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
        }
        func count(_ notDownloaded: Int, _ unreadable: Int, _ language: String, _ localeID: String? = nil) throws -> String? {
            let progress = SearchModel.ContentProgress(total: 10, notDownloaded: notDownloaded, unreadable: unreadable, done: true)
            return StatusBarView.skipLine(progress, bundle: try bundle(language), locale: Locale(identifier: localeID ?? language))
        }
        func lines(_ notDownloaded: Int, _ unreadable: Int, _ language: String, _ localeID: String? = nil) throws -> [String] {
            let progress = SearchModel.ContentProgress(total: 10, notDownloaded: notDownloaded, unreadable: unreadable, done: true)
            return StatusBarView.skipLines(progress, bundle: try bundle(language), locale: Locale(identifier: localeID ?? language))
        }
        #expect(try count(0, 0, "en") == nil && lines(0, 0, "en").isEmpty)
        #expect(try count(2, 0, "en") == "2 files skipped" && lines(2, 0, "en") == ["2 files not downloaded"])
        #expect(try count(0, 1, "en") == "1 file skipped" && lines(0, 1, "en") == ["1 file in an unsupported format"])
        #expect(try count(1, 2, "en") == "3 files skipped" && lines(1, 2, "en") == ["1 file not downloaded", "2 files in unsupported formats"])
        #expect(try lines(21, 5, "ru") == ["21 файл не загружен", "5 файлов в неподдерживаемых форматах"])
        for (notDownloaded, unreadable, language, expected) in [
            (21, 0, "ru", "21 файл пропущен"), (2, 1, "ru", "3 файла пропущены"), (3, 2, "ru", "5 файлов пропущено"),
            (1, 1, "ar", "تم تخطي ملفين"), (2, 1, "ar", "تم تخطي 3 ملفات"), (1, 1, "pl", "2 pliki pominięte"), (3, 2, "pl", "5 plików pominiętych"),
        ] {
            for localeID in numberingLocaleIDs(language) {
                let found = try count(notDownloaded, unreadable, language, localeID)
                #expect(found == Locale(identifier: localeID).digits(expected), "\(localeID), \(notDownloaded + unreadable): \(found ?? "nothing")")
            }
        }
        #expect(StatusBarView.readLine(.init(read: 7, total: 10, notDownloaded: 2, unreadable: 1, done: true)) == nil, "skips alone are no stop")
        for language in ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"] {
            for localeID in numberingLocaleIDs(language) {
                let (text, locale) = (try lines(3, 4, language, localeID), Locale(identifier: localeID))
                #expect(text.count == 2 && text[0].contains(locale.digits("3")) && text[1].contains(locale.digits("4")), "\(localeID): \(text)")
                let found = try count(3, 4, language, localeID)
                #expect(found?.contains(locale.digits("7")) == true, "\(localeID): \(found ?? "nothing")")
            }
            let (text, found, english) = (try lines(3, 4, language), try count(3, 4, language), try count(3, 4, "en"))
            if language != "en" {
                let englishLines = try lines(3, 4, "en")
                #expect(text != englishLines && found != english, "\(language) shows English")
            }
        }
    }

    @Test func everyNumberFollowsTheRegionWhileTheWordsStayEnglish() async throws {
        let region = Locale(identifier: "en_TR")
        func grouped(_ number: Int) -> String { number.formatted(.number.locale(region)) }
        #expect(grouped(1_234_567) == "1.234.567")
        #expect(StatusBarView.readLine(.init(read: 72_162, total: 1_245_248, done: false), locale: region)
            == "Read \(grouped(72_162)) of \(grouped(1_245_248)) files")
        #expect(ResultsTable.countText(1_234_567, locale: region) == "\(grouped(1_234_567)) results")

        let fake = FakeSearchClient(hits: [.named("a.txt")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.locale, region)))
        defer { host.close() }
        fake.send(.stateChanged(Self.steps[2].state))
        model.query = "a"
        fake.send(.resultsReady(fake.latest, count: 1_234_567))
        try await host.until("the files and the result count in the region's grouping") {
            host.windowShows("Files: \(grouped(1_234_567))") && host.windowShows("Search: \(grouped(1_234_567)) results")
        }
    }

    @Test func theBarFollowsTheTextSize() {
        let fake = FakeSearchClient(hits: [.named("a.txt")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let store = Self.store("size")
        store.set(TextSize.extraLarge.rawValue, forKey: TextSize.key)
        let bar = StatusBarView(index: index, model: model).environment(\.locale, Self.english).defaultAppStorage(store)
        #expect(StatusBarView.font(.extraLarge).pointSize == 14)
        #expect(StatusBarView.lineHeight(.extraLarge) == 17)
        #expect(NSHostingView(rootView: bar).fittingSize.height == 28)
        #expect(StatusBarView.lineHeight(.maximum) == 18)
        store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        #expect(NSHostingView(rootView: bar).fittingSize.height == 29)
        store.removeObject(forKey: TextSize.key)
        #expect(NSHostingView(rootView: bar).fittingSize.height == 24)
    }

    @Test func theBarShowsStateFilesAndTheLastSearch() async throws {
        let fake = FakeSearchClient(hits: [.named("a.txt"), .named("b.txt"), .named("c.txt")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.locale, Self.english)))
        host.window.appearance = Look.light.appearance
        defer { host.close() }
        fake.send(.stateChanged(Self.steps[2].state))
        try await host.until("Ready with its file count") { host.windowShows("Ready") && host.windowShows("Files: 1,234,567") }
        #expect(!host.windowShows("Search:"), "no query, no search part")

        model.query = "a"
        fake.send(.resultsReady(fake.latest, count: 3))
        func search(_ time: Duration) -> String {
            let milliseconds = time.formatted(.units(allowed: [.milliseconds], width: .abbreviated).locale(Self.english))
            return "Search: \(ResultsTable.countText(3)) – \(milliseconds)"
        }
        try await host.until("the search part with the model's time") { model.lastSearchTime.map { host.windowShows(search($0)) } ?? false }

        let bar = NSHostingView(rootView: StatusBarView(index: index, model: model).environment(\.locale, Self.english)
            .defaultAppStorage(Self.store("height")))
        let height = bar.fittingSize.height
        #expect(StatusBarView.lineHeight(.standard) == 13)
        #expect(height == 24)
        #expect(height == 1 + StatusBarView.lineHeight(.standard) + 2 * SearchMetrics.statusVerticalInset)
        #expect((height * host.window.backingScaleFactor).truncatingRemainder(dividingBy: 1) == 0)
        let rep = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: rep)
        let pixel = try #require(srgbPixel(rep, x: 2, y: rep.pixelsHigh - 3))
        let expected = eightBits(channels(Theme.systemNative.windowBackground, .light))
        #expect(zip(pixel, expected).allSatisfy { abs($0 - $1) <= 1 }, "padding \(pixel), window \(expected)")

        model.query = ""
        try await host.until("the search part gone") { !host.windowShows("Search:") }
        #expect(host.windowShows("Files: 1,234,567"))
    }

    @Test func theFailureLineReplacesTheSearchPart() async throws {
        let line = "Search failed. Try again."
        for language in ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"] {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            let text = bundle.localizedString(forKey: line, value: "\u{1}", table: "Results")
            #expect(text != "\u{1}" && (language == "en") == (text == line), "\(language): \(text)")
        }

        let fake = FakeSearchClient(hits: [.named("a.txt")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.locale, Self.english)))
        defer { host.close() }
        fake.send(.stateChanged(Self.steps[2].state))
        model.query = "a"
        fake.send(.resultsReady(fake.latest, count: 1))
        try await host.until("the search part") { host.windowShows("Search: ") }
        #expect(!host.windowShows(line))

        fake.fail(with: .io)
        model.sort = SearchSort(column: .size, ascending: false)
        try await host.until("the failure line in place of the search part") { host.windowShows(line) && !host.windowShows("Search: ") }
        #expect(model.results.generation != nil, "the failed sort kept its rows")
        #expect(host.windowShows("Ready") && host.windowShows("Files: 1,234,567"))

        fake.fail(with: nil)
        model.query = "ab"
        fake.send(.resultsReady(fake.latest, count: 1))
        try await host.until("the search part back") { host.windowShows("Search: ") && !host.windowShows(line) }
    }

    @Test func theCountFollowsTheLocalesSeparator() async throws {
        let state = IndexState(phase: .ready, indexed: 1_234_567)
        for (locale, shown, absent) in [("en", "1,234,567", "1.234.567"), ("de", "1.234.567", "1,234,567")] {
            let fake = FakeSearchClient()
            let host = StatusHost(client: fake, locale: Locale(identifier: locale))
            defer { host.close() }
            fake.send(.stateChanged(state))
            try await host.until("\(shown) in \(locale)") { host.shows(shown) }
            #expect(!host.shows(absent), "\(absent) shown in \(locale)")
        }
    }

    @Test func tabStopsAreTheSameWithAndWithoutTheBar() async throws {
        try await Self.expectBareTabStops(with: Self.steps[2].state, control: false)
    }

    @Test func tabStopsAreTheSameWithTheLiveButtonShowingWhenFullKeyboardAccessIsOff() async throws {
        guard !NSApp.isFullKeyboardAccessEnabled else { return }
        try await Self.expectBareTabStops(with: Self.steps[3].state, control: true)
    }

    private static func expectBareTabStops(with state: IndexState, control: Bool) async throws {
        let expected: [String]
        do {
            let bare = StatusHost(client: FakeSearchClient(), locale: Self.english, withBar: false)
            defer { bare.close() }
            try await bare.focusField()
            expected = try await bare.tabStops()
        }
        #expect(Set(expected).count > 1, "Tab moved nothing in the bare window: \(expected)")

        let fake = FakeSearchClient()
        let host = StatusHost(client: fake, locale: Self.english)
        defer { host.close() }
        fake.send(.stateChanged(state))
        try await host.until("the bar") { host.shows("Files: \(state.indexed.formatted(.number.locale(Self.english)))") }
        try await host.until("the live button is \(control ? "showing" : "absent")") {
            (AXTree.element(StatusBarView.liveUpdatesID, in: host.view) != nil) == control
        }
        try await host.focusField()
        let actual = try await host.tabStops()
        #expect(actual == expected)
    }
}

extension StatusBarTests {
    @Test(arguments: Theme.allCases, [AppearanceMode.light, .dark])
    func theBarDrawsItsThemeUnderAForcedMode(theme: Theme, mode: AppearanceMode) async throws {
        let store = Self.store("forced-\(theme.rawValue)-\(mode.rawValue)")
        store.set(theme.rawValue, forKey: Theme.key)
        try await forced(mode) {
            let fake = FakeSearchClient()
            let index = IndexModel(client: fake)
            let model = index.makeModel()
            let host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.locale, Self.english).defaultAppStorage(store)))
            defer { host.close() }
            fake.send(.stateChanged(Self.steps[2].state))
            try await host.until("Ready with its file count") { host.windowShows("Ready") && host.windowShows("Files: 1,234,567") }
            let view = host.view
            let appearance = view.effectiveAppearance
            #expect(appearance.bestMatch(from: [.aqua, .darkAqua]) == appearanceName(mode), "\(theme) under \(mode)")
            let background = eightBits(channels(theme.windowBackground, appearance: appearance))
            let barHeight = StatusBarView.lineHeight(.standard) + 2 * SearchMetrics.statusVerticalInset + 1
            let strip = NSRect(x: 0, y: view.isFlipped ? view.bounds.height - barHeight : 0, width: view.bounds.width, height: barHeight)
            let padding = NSRect(x: 1, y: view.isFlipped ? view.bounds.height - 4 : 2, width: 2, height: 2)
            let corner = pixels(in: view, rect: padding)
            #expect(!corner.isEmpty && corner.allSatisfy { zip($0, background).allSatisfy { abs($0 - $1) <= 1 } }, "\(theme) \(mode) padding \(corner), window \(background)")
            let live = eightBits(channels(theme.stateLive, appearance: appearance))
            #expect(hasPixel(near: live, in: view, rect: strip), "\(theme) \(mode): no live dot of \(live) in the bar")

            fake.send(.stateChanged(Self.steps[1].state))
            try await host.until("Indexing the disk") { host.windowShows("Indexing the disk") }
            let indexing = eightBits(channels(theme.stateIndexing, appearance: appearance))
            #expect(hasPixel(near: indexing, in: view, rect: strip), "\(theme) \(mode): no indexing ring of \(indexing) in the bar")
        }
    }

    @Test(arguments: Theme.allCases)
    func theIndexAndManageLinksReadAtFourAndAHalfOnTheirWindow(theme: Theme) async throws {
        let first = IndexedVolume(id: "5F2A6C3E-0B1D-4C7A-9E58-2D4B7A91C0E3", name: "Disk 1", path: "/Volumes/Disk 1", indexed: false)
        let second = IndexedVolume(id: "8C1D4E7A-3F2B-4A6C-B9D0-1E5F7A2C4B68", name: "Disk 2", path: "/Volumes/Disk 2", indexed: false)
        for (disks, id) in [([first], StatusBarView.indexDiskID), ([first, second], StatusBarView.manageDisksID)] {
            let store = Self.store("link-\(theme.rawValue)-\(disks.count)")
            store.set(theme.rawValue, forKey: Theme.key)
            let fake = FakeSearchClient()
            fake.setVolumes(.success(disks))
            let index = IndexModel(client: fake, defaults: store)
            let model = index.makeModel()
            let host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.locale, Self.english).defaultAppStorage(store)))
            defer { host.close() }
            try await host.until("the \(id) link") { AXTree.element(id, in: host.view) != nil }
            let element = try #require(AXTree.element(id, in: host.view))
            let button = try #require((element as? NSButton) ?? ((element as? NSCell)?.controlView as? NSButton), "\(id) is a button")
            let color = try #require(button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            for look in Look.allCases {
                #expect(channels(color, look) == channels(theme.link, look), "\(theme) \(id) \(look)")
                let window = channels(theme.windowBackground, look)
                let value = ratio(over(channels(color, look), window), window)
                #expect(value >= 4.5, "\(theme) \(id) \(look): \(value):1")
            }
        }
    }

    @Test func aFailedIndexKeepsTheMinimumWindowHeight() async throws {
        let (bar, _) = try await Self.failedBar("en", .standard)
        let root = StatusBarView(index: bar.index, model: bar.model)
            .frame(minWidth: SearchMetrics.windowMinWidth, minHeight: SearchMetrics.windowMinHeight)
        let host = SearchHost(root: AnyView(root))
        defer { host.close() }
        try await host.until("a minimum size") { host.window.contentMinSize.height > 0 }
        #expect(host.window.contentMinSize.height <= SearchMetrics.windowMinHeight, "\(host.window.contentMinSize.height) pt")
    }

    @Test func aLongLanguageKeepsTheCountAndDropsTheDiskNoticeFirst() async throws {
        let disk = IndexedVolume(id: "5F2A6C3E-0B1D-4C7A-9E58-2D4B7A91C0E3", name: "Резервная копия данных проекта", path: "/Volumes/Backup", indexed: false)
        let fake = FakeSearchClient(hits: [.named("a.txt")])
        fake.setVolumes(.success([disk]))
        let index = IndexModel(client: fake, defaults: Self.store("long-language"))
        let model = index.makeModel()
        let host = SearchHost(root: AnyView(StatusBarView(index: index, model: model).environment(\.locale, Locale(identifier: "ru"))))
        defer { host.close() }
        fake.send(.stateChanged(Self.steps[3].state))
        model.query = "a"
        fake.send(.resultsReady(fake.latest, count: 1))
        host.window.setContentSize(NSSize(width: SearchMetrics.windowMinWidth, height: SearchMetrics.windowMinHeight))
        try await host.until("the Russian count") { host.windowShows("Поиск: ") && host.windowShows("Файлы: ") }
        #expect(!host.windowShows("не проиндексирован"), "the notice would cut the count")
        host.window.setContentSize(NSSize(width: 1600, height: SearchMetrics.windowMinHeight))
        try await host.until("the notice in a wide window") { host.windowShows("не проиндексирован") }
        #expect(host.windowShows("Поиск: ") && host.windowShows("Файлы: "))
    }

    @Test func theLauncherFooterHoldsNoFailureTextWhenTheListRowSaysIt() async throws {
        let line = "Search failed. Try again."
        for clearsBackground in [false, true] {
            let fake = FakeSearchClient(hits: [.named("a.txt")])
            let index = IndexModel(client: fake)
            let model = index.makeModel()
            let root = StatusBarView(index: index, model: model, clearsBackground: clearsBackground).environment(\.locale, Self.english)
            let host = SearchHost(root: AnyView(root))
            defer { host.close() }
            fake.send(.stateChanged(Self.steps[2].state))
            fake.fail(with: .io)
            model.query = "zz"
            try await untilTrue(waitingFor: "the failed search") { model.failed }
            #expect(model.results.generation == nil)
            func barReads(_ text: String) -> Bool {
                AXTree.element("status-bar", in: host.view).map { AXTree.names(of: $0).contains { $0.contains(text) } } ?? false
            }
            try await host.until("the bar") { host.windowShows("Ready") && barReads("Ready") }
            if clearsBackground {
                try await Task.sleep(for: .milliseconds(50))
                host.view.layoutSubtreeIfNeeded()
            } else {
                try await host.until("the failure line in the window bar") { host.windowShows(line) && barReads(line) }
            }
            #expect(host.windowShows(line) == !clearsBackground)
            #expect(barReads(line) == !clearsBackground)
        }
    }

    @Test func aFailedIndexDrawsNoRing() {
        #expect(StatusBarView.mark(.failed) == .empty)
        #expect(StatusBarView.mark(.failed, paused: true) == .empty)
        #expect(StatusBarView.mark(.crawling) == .ring)
    }
}
