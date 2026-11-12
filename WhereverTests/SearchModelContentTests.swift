import Dispatch
import Foundation
import os
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Wherever
import WhereverInterface

private final class ReadGate {
    private var held: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { held.count }

    func wait() async { await withCheckedContinuation { held.append($0) } }

    func open() {
        let now = held
        held = []
        now.forEach { $0.resume() }
    }
}

private nonisolated final class FolderLookups: Sendable {
    private nonisolated struct State {
        var answers: [Bool]
        var onMain: [Bool] = []
        var done = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let gate = DispatchSemaphore(value: 0)
    private let holdsFirst: Bool

    init(_ answers: [Bool], holdsFirst: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(answers: answers))
        self.holdsFirst = holdsFirst
    }

    var onMain: [Bool] { state.withLock { $0.onMain } }
    var done: Int { state.withLock { $0.done } }
    func release() { gate.signal() }

    func check(_ path: String) -> (path: String, isFolder: Bool) {
        let main = Thread.isMainThread
        let (first, answer) = state.withLock { state -> (Bool, Bool) in
            state.onMain.append(main)
            return (state.onMain.count == 1, state.answers.isEmpty ? true : state.answers.removeFirst())
        }
        if first, holdsFirst { _ = gate.wait(timeout: .now() + 5) }
        state.withLock { $0.done += 1 }
        return (path, answer)
    }
}

@Suite struct SearchModelContentTests {
    private static let ready = IndexState(phase: .ready, indexed: 1)

    private struct Rig {
        let fake = FakeSearchClient()
        let gate = ReadGate()
        let index: IndexModel
        let model: SearchModel

        init(_ state: IndexState? = SearchModelContentTests.ready) async throws {
            let index = IndexModel(client: fake)
            self.index = index
            model = index.makeModel()
            model.readDelay = { [gate] in await gate.wait() }
            guard let state else { return }
            fake.send(.stateChanged(state))
            try await untilTrue(waitingFor: "the state") { index.indexState == state }
        }

        func waits(_ count: Int) async throws {
            try await untilTrue(waitingFor: "\(count) waiting reads, \(gate.waiting) waiting") { gate.waiting == count }
        }

        func endThePause(waits count: Int = 1) async throws {
            try await waits(count)
            gate.open()
            await settled()
        }

        func settled() async {
            try? await Task.sleep(for: .milliseconds(20))
        }

        func endThePress() throws {
            model.handle(.contentProgress(try #require(model.press), read: 1, total: 1, notDownloaded: 0, unreadable: 0, done: true))
        }
    }

    private typealias Press = FakeSearchClient.Press

    private static func press(_ query: String, _ terms: [String], all: Bool = false) -> Press {
        Press(query: query, terms: terms, matchAll: all, sort: .bestMatch)
    }

    @Test func aPressSendsTheNameQueryAndTheTerms() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.filters.kind = .documents
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        #expect(rig.fake.queries == ["report", "report type:doc"], "the press sends no name search")
        #expect(rig.fake.presses == [Self.press("report type:doc", ["alpha"])])
        #expect(rig.model.press == rig.fake.latest)
        #expect(rig.model.progress == SearchModel.ContentProgress())
    }

    @Test func aPressWithAnEmptyNameSendsIt() async throws {
        let rig = try await Rig()
        rig.model.content = ContentTerms(terms: ["alpha"])
        #expect(rig.fake.presses.isEmpty, "the terms wait for the press")
        rig.model.searchContent()
        #expect(rig.fake.presses == [Self.press("", ["alpha"])], "every file in scope is read")
        #expect(rig.fake.queries.isEmpty)
    }

    @Test func termsSearchNothingUntilThePress() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.contentDraft = "bet"
        rig.model.content.match = .all
        #expect(rig.fake.queries == ["report"], "edits to the row search nothing")
        #expect(rig.fake.presses.isEmpty)
        rig.model.searchContent()
        #expect(rig.fake.presses == [Self.press("report", ["alpha", "bet"], all: true)])
    }

    @Test func aKeystrokeAfterAPressNarrowsAndSearchesNothing() async throws {
        let rig = try await Rig()
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = "report"
        rig.model.query = "report 2"
        #expect(rig.fake.queries.isEmpty, "typing after the press reads and searches nothing")
        #expect(rig.fake.narrows == ["report", "report 2"])
        #expect(rig.fake.presses.count == 1)
        #expect(rig.model.press != nil, "the press's files stay held")
        await rig.settled()
        #expect(rig.gate.waiting == 0, "no read waits")
    }

    @Test func clearingTheNameAfterAPressNarrowsToTheWholeSet() async throws {
        let rig = try await Rig()
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = "report"
        rig.model.query = ""
        #expect(rig.fake.narrows == ["report", ""], "an empty File name shows every file the press kept")
        #expect(rig.model.results.generation == nil)
        #expect(rig.model.isPending)
    }

    @Test func aChangedPressedNameReadsAgainAfterThePause() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        let first = try #require(rig.model.press)
        rig.model.handle(.resultsReady(first, count: 3))
        rig.model.query = "reports"
        try await rig.waits(1)
        #expect(rig.fake.presses.count == 1, "the read waits for the pause")
        #expect(rig.model.press == first)
        #expect(rig.model.isPending, "a key acts on the new read, not on the old rows")
        try await rig.endThePause()
        #expect(rig.fake.presses == [Self.press("report", ["alpha"]), Self.press("reports", ["alpha"])])
        #expect(rig.fake.narrows.isEmpty, "the old set cannot answer")
        #expect(rig.fake.queries == ["report"], "no name search")
        let second = try #require(rig.model.press)
        #expect(second != first && second == rig.fake.latest)
        #expect(rig.model.progress == SearchModel.ContentProgress())
        #expect(rig.model.results == SearchModel.Results(generation: first, count: 3, live: false), "the old rows stay until the new read's first results")
        rig.model.handle(.resultsReady(second, count: 1))
        #expect(rig.model.results.generation == second && rig.model.results.count == 1)
        #expect(!rig.model.isPending)
    }

    @Test func clearingAPressedNameReadsAgain() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = ""
        try await rig.endThePause()
        #expect(rig.fake.presses.last == Self.press("", ["alpha"]), "no name reads more files than the press did")
        #expect(rig.fake.narrows.isEmpty)
    }

    @Test func aNameModeChangeOfAPressedNameReadsAgain() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.filters.nameMode = .beginsWith
        try await rig.endThePause()
        #expect(rig.fake.presses.last == Self.press("begins:\"report\"", ["alpha"]))
        #expect(rig.fake.narrows.isEmpty)
    }

    @Test func theSpacesAroundAPressedNameChangeNothing() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = "report "
        #expect(rig.fake.narrows == ["report "])
        await rig.settled()
        #expect(rig.gate.waiting == 0)
    }

    @Test func eachChangeRestartsTheWaitAndOneReadGoesOut() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = "reports"
        try await rig.waits(1)
        rig.model.query = "reports 2"
        try await rig.waits(2)
        rig.model.query = "reports 20"
        try await rig.endThePause(waits: 3)
        #expect(rig.fake.presses == [Self.press("report", ["alpha"]), Self.press("reports 20", ["alpha"])])
    }

    @Test func thePressedNameTypedBackCancelsTheWaitAndNarrows() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = "reports"
        try await rig.waits(1)
        rig.model.query = "report"
        #expect(rig.fake.narrows == ["report"], "the kept set answers again")
        try await rig.endThePause()
        #expect(rig.fake.presses.count == 1)
    }

    @Test func theRealPauseIsFourTenthsOfASecond() async throws {
        let rig = try await Rig()
        rig.model.readDelay = { try? await Task.sleep(for: SearchModel.readPause) }
        #expect(SearchModel.readPause == .milliseconds(400))
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        let changed = ContinuousClock.now
        rig.model.query = "reports"
        #expect(rig.fake.presses.count == 1)
        try await untilTrue(waitingFor: "the new read") { rig.fake.presses.count == 2 }
        #expect(changed.duration(to: .now) >= SearchModel.readPause)
    }

    @Test func theNewReadUsesTheTermsAsTheyReadNow() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = "reports"
        rig.model.content.terms = ["beta"]
        rig.model.content.match = .all
        rig.model.contentDraft = "gam"
        #expect(rig.fake.presses.count == 1, "terms alone still start nothing")
        try await rig.endThePause()
        #expect(rig.fake.presses.last == Self.press("reports", ["beta", "gam"], all: true))
    }

    @Test func emptyingTheTermsDuringTheWaitSendsNothingFurther() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = "reports"
        try await rig.waits(1)
        rig.model.content.terms = []
        #expect(rig.model.press == nil)
        #expect(rig.fake.queries.last == "reports", "the name list comes back")
        try await rig.endThePause()
        #expect(rig.fake.presses.count == 1)
    }

    @Test func aStopThenANameChangeFollowsTheSameRule() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.searchContent()
        #expect(rig.fake.stops == 1)
        try rig.endThePress()
        rig.model.query = "reports"
        try await rig.endThePause()
        #expect(rig.fake.presses.last == Self.press("reports", ["alpha"]), "a pressed name still reads again")
        rig.model.searchContent()
        #expect(rig.fake.stops == 2)
        try rig.endThePress()
        let empty = try await Rig()
        empty.model.content = ContentTerms(terms: ["alpha"])
        empty.model.searchContent()
        empty.model.searchContent()
        try empty.endThePress()
        empty.model.query = "report"
        #expect(empty.fake.narrows == ["report"], "a press with no name still narrows after its stop")
        await empty.settled()
        #expect(empty.gate.waiting == 0)
    }

    @Test func aStopDuringTheWaitDropsTheNewRead() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = "reports"
        try await rig.waits(1)
        rig.model.searchContent()
        #expect(rig.fake.stops == 1)
        try await rig.endThePause()
        #expect(rig.fake.presses.count == 1, "Stop means stop")
    }

    @Test func aPressDuringTheWaitReadsOnce() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        try rig.endThePress()
        rig.model.query = "reports"
        try await rig.waits(1)
        rig.model.searchContent()
        #expect(rig.fake.presses.count == 2)
        try await rig.endThePause()
        #expect(rig.fake.presses.count == 2, "the waiting read went with the press")
    }

    @Test func switchingToSimpleCancelsAWaitingRead() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = "reports"
        try await rig.waits(1)
        rig.model.dropNormalControls()
        try await rig.endThePause()
        #expect(rig.fake.presses.count == 1)
        #expect(rig.model.press == nil)
    }

    @Test func aFailedPressCancelsAWaitingRead() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = "reports"
        try await rig.waits(1)
        rig.model.handle(.searchFailed(try #require(rig.model.press)))
        try await rig.endThePause()
        #expect(rig.fake.presses.count == 1)
    }

    @Test func aFileChangeDuringTheWaitAddsNoSearch() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.query = "reports"
        try await rig.waits(1)
        rig.model.handle(.resultsChanged)
        #expect(rig.fake.queries == ["report"])
        try await rig.endThePause()
        rig.model.handle(.resultsChanged)
        #expect(rig.fake.queries == ["report"])
        #expect(rig.fake.presses.count == 2, "file changes never refresh content results")
    }

    @Test func aPillAfterAPressNarrows() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.filters.kind = .documents
        rig.model.filters.hidesHidden = true
        #expect(rig.fake.queries == ["report"])
        #expect(rig.fake.narrows == ["report type:doc", "report type:doc hidden:no"])
    }

    @Test func aPillChangedFromAPressedOneReadsAgain() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.filters.kind = .documents
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.filters.kind = .images
        try await rig.endThePause()
        #expect(rig.fake.presses.last == Self.press("report type:image", ["alpha"]))
        #expect(rig.fake.narrows.isEmpty)
    }

    @Test func hideInvisibleChangedFromAPressedOneReadsAgain() async throws {
        let rig = try await Rig()
        rig.model.filters.hidesHidden = true
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.filters.hidesHidden = false
        try await rig.endThePause()
        #expect(rig.fake.presses == [Self.press("hidden:no", ["alpha"]), Self.press("", ["alpha"])])
        #expect(rig.fake.narrows.isEmpty)
    }

    @Test func aSecondExtensionReadsAgainBecausePillsOfOneKindAddUp() async throws {
        let rig = try await Rig()
        rig.model.filters.extensions = "pdf"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.filters.extensions = "pdf,doc"
        try await rig.endThePause()
        #expect(rig.fake.presses.last == Self.press("ext:pdf,doc", ["alpha"]))
        #expect(rig.fake.narrows.isEmpty)
    }

    @Test func thePressChecksItsFolderOffTheMainThread() async throws {
        let rig = try await Rig()
        let lookups = FolderLookups([false])
        rig.model.checkFolder = { lookups.check($0) }
        rig.model.filters.folder = "/Volumes/Gone"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        #expect(rig.fake.presses.count == 1, "the press goes out without waiting for the folder")
        try await untilTrue(waitingFor: "the folder answer") { rig.model.folderMissing }
        #expect(lookups.onMain == [false], "the folder is checked off the main thread")
    }

    @Test func aSlowFolderAnswerYieldsToANewerPress() async throws {
        let rig = try await Rig()
        let lookups = FolderLookups([true, false], holdsFirst: true)
        defer { lookups.release() }
        rig.model.checkFolder = { lookups.check($0) }
        rig.model.filters.folder = "/Volumes/Slow"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        try await untilTrue(waitingFor: "the first check") { lookups.onMain.count == 1 }
        try rig.endThePress()
        rig.model.searchContent()
        #expect(rig.fake.presses.count == 2)
        try await untilTrue(waitingFor: "the second answer") { rig.model.folderMissing }
        lookups.release()
        try await untilTrue(waitingFor: "the first answer") { lookups.done == 2 }
        await rig.settled()
        #expect(rig.model.folderMissing, "the older press's answer is dropped")
    }

    @Test func aSlowFolderAnswerYieldsToANewFolder() async throws {
        let rig = try await Rig()
        let lookups = FolderLookups([false], holdsFirst: true)
        defer { lookups.release() }
        rig.model.checkFolder = { lookups.check($0) }
        rig.model.filters.folder = "/Volumes/Slow"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        try await untilTrue(waitingFor: "the first check") { lookups.onMain.count == 1 }
        rig.model.filters.folder = "/Volumes/Other"
        try await rig.waits(1)
        lookups.release()
        try await untilTrue(waitingFor: "the first answer") { lookups.done == 1 }
        await rig.settled()
        #expect(!rig.model.folderMissing, "an answer for the old folder stays out")
    }

    @Test func aFolderAfterAPressReadsAgain() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.filters.folder = "/Volumes/Archive"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        #expect(rig.fake.presses == [Self.press("report in:\"/Volumes/Archive\"", ["alpha"])], "the press reads that disk alone")
        rig.model.filters.folder = nil
        try await rig.waits(1)
        rig.model.filters.folder = "/Users/Shared"
        try await rig.endThePause(waits: 2)
        #expect(rig.fake.narrows.isEmpty, "a folder change never narrows, whatever its path")
        #expect(rig.fake.presses.last == Self.press("report in:\"/Users/Shared\"", ["alpha"]))
        #expect(rig.fake.presses.count == 2)
        #expect(rig.fake.queries == ["report", "report in:\"/Volumes/Archive\""])
    }

    @Test func aFolderInsideThePressedOneStillReadsAgain() async throws {
        let rig = try await Rig()
        rig.model.filters.folder = "/Volumes/Archive"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.filters.folder = "/Volumes/Archive/Docs"
        try await rig.endThePause()
        #expect(rig.fake.presses.last == Self.press("in:\"/Volumes/Archive/Docs\"", ["alpha"]))
        #expect(rig.fake.narrows.isEmpty)
    }

    @Test func everyWayOfChangingTheFolderReadsAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wherever-threeboxes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ways: [(String, @MainActor (SearchFolderBox) -> Void)] = [
            ("picked", { $0.commit(.path(root.path)) }),
            ("dropped", { box in
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
                    done(root.dataRepresentation, nil)
                    return nil
                }
                _ = box.drop([provider])
            }),
            ("browsed", { _ = $0.browse() }),
        ]
        for (way, change) in ways {
            let rig = try await Rig()
            rig.fake.setVolumes(.success([]))
            let box = SearchFolderBox(
                folder: Binding(get: { rig.model.filters.folder }, set: { rig.model.filters.folder = $0 }), client: rig.fake,
                confirmIndex: { _ in false }, chooseFolder: { _ in root }
            )
            rig.model.content = ContentTerms(terms: ["alpha"])
            rig.model.searchContent()
            change(box)
            try await rig.endThePause()
            #expect(rig.fake.presses.last == Self.press("in:\"\(root.path)\"", ["alpha"]), "\(way)")
            #expect(rig.fake.narrows.isEmpty, "\(way)")
        }
        let typed = try await Rig()
        typed.model.content = ContentTerms(terms: ["alpha"])
        typed.model.searchContent()
        typed.model.filters.folder = SearchFolderBox.scope(" " + root.path + " ")
        try await typed.endThePause()
        #expect(typed.fake.presses.last == Self.press("in:\"\(root.path)\"", ["alpha"]), "typed")
        #expect(typed.fake.narrows.isEmpty, "typed")
    }

    @Test func aSortAfterAPressResortsItsFiles() async throws {
        let rig = try await Rig()
        rig.model.query = ""
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        let byName = SearchSort(column: .name, ascending: true)
        rig.model.sort = byName
        #expect(rig.fake.session(rig.fake.lastSession)?.sorts == [byName], "an empty File name still resorts the press's files")
        #expect(rig.fake.queries.isEmpty)
        #expect(rig.fake.narrows.isEmpty)
    }

    @Test func aFileChangeAfterAPressSearchesNothing() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.handle(.resultsChanged)
        rig.model.handle(.resultsChanged)
        #expect(rig.fake.queries == ["report"], "file changes repeat no search")
        #expect(rig.fake.narrows.isEmpty)
        #expect(rig.fake.presses.count == 1)
    }

    @Test func aNameSearchRepeatsOnEveryChange() throws {
        let fake = FakeSearchClient()
        let model = SearchModel(session: try fake.makeSession())
        model.query = "report"
        for _ in 0..<3 {
            model.handle(.resultsReady(fake.latest, count: 0))
            model.handle(.resultsChanged)
        }
        #expect(fake.queries == ["report", "report", "report", "report"])
    }

    @Test func aPressWhileReadingStops() async throws {
        let rig = try await Rig()
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        let press = try #require(rig.model.press)
        #expect(rig.model.reading)
        rig.model.searchContent()
        #expect(rig.fake.stops == 1, "the button reads Stop while the press reads")
        #expect(rig.fake.presses.count == 1, "no second press")
        rig.model.handle(.contentProgress(press, read: 3, total: 10, notDownloaded: 0, unreadable: 0, done: true))
        #expect(!rig.model.reading)
        rig.model.searchContent()
        #expect(rig.fake.presses.count == 2, "after the stop the button presses again")
        #expect(rig.fake.stops == 1)
    }

    @Test func theProgressFollowsThePressOnly() async throws {
        let rig = try await Rig()
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        let press = try #require(rig.model.press)
        rig.model.handle(.contentProgress(SearchGeneration(rawValue: press.rawValue + 50), read: 9, total: 9, notDownloaded: 0, unreadable: 0, done: true))
        #expect(rig.model.progress == SearchModel.ContentProgress(), "another press's progress")
        rig.model.handle(.contentProgress(press, read: 4, total: 10, notDownloaded: 0, unreadable: 0, done: false))
        #expect(rig.model.progress == SearchModel.ContentProgress(read: 4, total: 10, done: false))
        rig.model.query = "x"
        #expect(rig.fake.narrows == ["x"])
        rig.model.handle(.contentProgress(press, read: 5, total: 10, notDownloaded: 0, unreadable: 0, done: false))
        #expect(rig.model.progress?.read == 5, "a narrow keeps the press's count")
    }

    @Test func emptyingTheTermsGoesBackToTheNameSearch() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.contentDraft = "be"
        rig.model.searchContent()
        rig.model.content.terms = []
        #expect(rig.fake.queries == ["report"], "the draft still holds a term")
        rig.model.contentDraft = ""
        #expect(rig.fake.queries == ["report", "report"], "the name search comes back")
        #expect(rig.fake.stops == 1, "the engine stops the read")
        #expect(rig.model.press == nil)
        #expect(rig.model.progress == nil)
        rig.model.query = "reports"
        #expect(rig.fake.queries.last == "reports", "typing searches names again")
        #expect(rig.fake.narrows.isEmpty)
    }

    @Test func editingTheTermsWithoutPressingChangesNothing() async throws {
        let rig = try await Rig()
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.content.terms = ["beta"]
        rig.model.content.match = .all
        rig.model.contentDraft = "gam"
        #expect(rig.fake.presses.count == 1)
        #expect(rig.fake.stops == 0)
        #expect(rig.model.press != nil)
    }

    @Test func switchingToSimpleStopsTheRead() async throws {
        let rig = try await Rig()
        rig.model.query = "report"
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.dropNormalControls()
        #expect(rig.fake.stops == 1)
        #expect(rig.model.press == nil)
        #expect(rig.fake.queries == ["report", "report"], "the name search runs, which drops the press's files")
        rig.model.query = "reports"
        #expect(rig.fake.narrows.isEmpty, "Simple searches names")
    }

    @Test func switchingToSimpleWithNothingSearchableStillStops() async throws {
        let rig = try await Rig()
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        rig.model.dropNormalControls()
        #expect(rig.fake.stops == 1)
        #expect(rig.fake.queries.isEmpty)
        #expect(rig.model.results == SearchModel.Results(), "no rows of the press stay")
        rig.model.query = "a"
        #expect(rig.fake.queries == ["a"])
        #expect(rig.fake.narrows.isEmpty)
    }

    @Test func aPressWithNothingSendsNothing() async throws {
        let rig = try await Rig()
        rig.model.contentDraft = "   "
        rig.model.searchContent()
        #expect(rig.fake.presses.isEmpty, "no terms and a blank draft")
        #expect(rig.model.press == nil)
    }

    @Test func aShortDraftCountsAtThePress() async throws {
        let rig = try await Rig()
        rig.model.contentDraft = "a"
        rig.model.contentDraft = "ab"
        #expect(rig.fake.presses.isEmpty)
        rig.model.searchContent()
        #expect(rig.fake.presses == [Self.press("", ["ab"])])
    }

    @Test func aReturnedDraftCountsOnce() async throws {
        let rig = try await Rig()
        rig.model.content = ContentTerms(terms: ["ab"])
        rig.model.contentDraft = "ab"
        rig.model.searchContent()
        #expect(rig.fake.presses == [Self.press("", ["ab"])])
    }

    @Test func findAllTermsAsksForEveryTerm() async throws {
        let rig = try await Rig()
        rig.model.content = ContentTerms(terms: ["alpha", "beta"])
        rig.model.searchContent()
        rig.model.handle(.contentProgress(try #require(rig.model.press), read: 1, total: 1, notDownloaded: 0, unreadable: 0, done: true))
        rig.model.content.match = .all
        #expect(rig.fake.presses.count == 1, "the match change waits for the press")
        rig.model.searchContent()
        #expect(rig.fake.presses == [Self.press("", ["alpha", "beta"]), Self.press("", ["alpha", "beta"], all: true)])
    }

    @Test func aPressBeforeTheFirstStateStillPresses() async throws {
        let off = try await Rig(nil)
        off.model.query = "report"
        off.model.content = ContentTerms(terms: ["alpha"])
        off.model.contentDraft = "beta"
        off.model.searchContent()
        #expect(off.fake.presses == [Self.press("report", ["alpha", "beta"])], "no state yet")
    }

    @Test func aGrowingSetIsLive() async throws {
        let rig = try await Rig()
        rig.model.content = ContentTerms(terms: ["alpha"])
        rig.model.searchContent()
        let press = try #require(rig.model.press)
        rig.model.handle(.resultsReady(press, count: 0))
        #expect(rig.model.results == SearchModel.Results(generation: press, count: 0, live: false))
        rig.model.handle(.resultsReady(press, count: 5))
        #expect(rig.model.results == SearchModel.Results(generation: press, count: 5, live: true))
    }
}
