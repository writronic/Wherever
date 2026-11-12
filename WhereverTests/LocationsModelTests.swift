import Combine
import Dispatch
import Foundation
import os
import Testing
@testable import Wherever
import WhereverInterface

private nonisolated let archive = IndexedVolume(id: "A", name: "Archive", path: "/Volumes/Archive", indexed: false)

private nonisolated final class Recorder: SearchClient {
    struct Refused: Error {}

    struct Calls {
        var excluded: [[String]] = []
        var indexed: [Set<String>] = []
        var changesOnMain: [Bool] = []
        var readsOnMain: [Bool] = []
    }

    private let refuses: Bool
    private let gate: DispatchSemaphore?
    private let calls = OSAllocatedUnfairLock(initialState: Calls())

    init(refuses: Bool = false, holdsFirst: Bool = false) {
        self.refuses = refuses
        gate = holdsFirst ? DispatchSemaphore(value: 0) : nil
    }

    var excluded: [[String]] { calls.withLock { $0.excluded } }
    var indexed: [Set<String>] { calls.withLock { $0.indexed } }
    var changesOnMain: [Bool] { calls.withLock { $0.changesOnMain } }
    var readsOnMain: [Bool] { calls.withLock { $0.readsOnMain } }
    var reads: Int { readsOnMain.count }

    func release() { gate?.signal() }

    var events: AsyncStream<SearchEvent> { AsyncStream { _ in } }
    func makeSession() throws -> any SearchSessionClient { throw Refused() }
    func recordOpen(_ path: String) throws {}
    func clearOpens() throws {}
    func flushOpens() throws {}
    func isSettling() throws -> Bool { false }
    func setTypoSearch(_ on: Bool) throws {}
    func setLiveUpdates(_ on: Bool) throws {}

    func setExcludedFolders(_ paths: [String]) throws {
        let onMain = Thread.isMainThread
        let first = calls.withLock { calls in
            calls.excluded.append(paths)
            calls.changesOnMain.append(onMain)
            return calls.excluded.count == 1
        }
        if first { _ = gate?.wait(timeout: .now() + 10) }
        if refuses { throw Refused() }
    }

    func setIndexedVolumes(_ ids: Set<String>) throws {
        let onMain = Thread.isMainThread
        calls.withLock { calls in
            calls.indexed.append(ids)
            calls.changesOnMain.append(onMain)
        }
        if refuses { throw Refused() }
    }

    func volumes() throws -> [IndexedVolume] {
        let onMain = Thread.isMainThread
        calls.withLock { $0.readsOnMain.append(onMain) }
        return [archive]
    }
}

private func suite(_ name: String) -> String { "com.writronic.wherever.tests.locationsmodel.\(name)" }

private func freshDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: suite(name))!
    defaults.removePersistentDomain(forName: suite(name))
    return defaults
}

private func stored(_ name: String, _ key: String) -> [String]? {
    UserDefaults.standard.persistentDomain(forName: suite(name))?[key] as? [String]
}

private func drainMain() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
}

@Suite(.serialized) struct LocationsModelTests {
    @Test func twoQuickRemovalsReachTheEngineOffTheMainThreadInOrder() async throws {
        let defaults = freshDefaults("order")
        defaults.set(["/Users/test/A", "/Users/test/B"], forKey: LocationsModel.Key.excluded)
        let client = Recorder(holdsFirst: true)
        let model = LocationsModel(client: client, defaults: defaults, chooseFolder: { nil })
        model.selection = .folder("/Users/test/A")
        model.removeSelected()
        model.selection = .folder("/Users/test/B")
        model.removeSelected()
        try await untilTrue(waitingFor: "the first change to reach the engine") { client.excluded.count == 1 }
        #expect(client.excluded == [["/Users/test/B"]])
        #expect(model.excluded == ["/Users/test/A", "/Users/test/B"], "the second change ran before the first finished")
        client.release()
        await model.change?.value
        #expect(client.excluded == [["/Users/test/B"], []])
        #expect(client.changesOnMain == [false, false])
        #expect(stored("order", LocationsModel.Key.excluded) == [])
        #expect(model.excluded.isEmpty)
        #expect(model.selection == nil)
    }

    @Test func aDiskChangeAndItsReloadRunOffTheMainThread() async throws {
        let defaults = freshDefaults("disk")
        defaults.set([String](), forKey: LocationsModel.Key.excluded)
        let client = Recorder()
        let model = LocationsModel(client: client, defaults: defaults, chooseFolder: { nil })
        model.selection = .disk(archive.id)
        model.removeSelected()
        await model.change?.value
        #expect(client.indexed == [[archive.id]])
        #expect(client.changesOnMain == [false])
        #expect(!client.readsOnMain.isEmpty && !client.readsOnMain.contains(true))
        #expect(stored("disk", LocationsModel.Key.indexedVolumes) == [archive.id])
        #expect(model.indexed == [archive.id])
        #expect(model.selection == nil)
    }

    @Test func refreshReadsTheDisksOffTheMainThread() async throws {
        let client = Recorder()
        let model = LocationsModel(client: client, defaults: freshDefaults("read"), chooseFolder: { nil })
        await model.refresh().value
        #expect(client.readsOnMain == [false])
        #expect(model.volumes == [archive])
    }

    @Test func refreshShowsAnOutsideChangeAndTheNextRemovalKeepsIt() async throws {
        let defaults = freshDefaults("outside")
        defaults.set(["/Users/test/A"], forKey: LocationsModel.Key.excluded)
        let client = Recorder()
        let model = LocationsModel(client: client, defaults: defaults, chooseFolder: { nil })
        defaults.set(["/Users/test/A", "/Users/test/C"], forKey: LocationsModel.Key.excluded)
        await model.refresh().value
        #expect(model.excluded == ["/Users/test/A", "/Users/test/C"])
        #expect(model.rows == [.disk(archive.id), .folder("/Users/test/A"), .folder("/Users/test/C")])
        model.selection = .folder("/Users/test/A")
        model.removeSelected()
        await model.change?.value
        #expect(client.excluded == [["/Users/test/C"]])
        #expect(stored("outside", LocationsModel.Key.excluded) == ["/Users/test/C"])
    }

    @Test func aRefusedChangeShowsTheLineUntilTheNextRefresh() async throws {
        let defaults = freshDefaults("refused")
        defaults.set(["/Users/test/A"], forKey: LocationsModel.Key.excluded)
        let model = LocationsModel(client: Recorder(refuses: true), defaults: defaults, chooseFolder: { nil })
        model.selection = .folder("/Users/test/A")
        model.removeSelected()
        await model.change?.value
        #expect(model.failed)
        #expect(model.excluded == ["/Users/test/A"])
        #expect(model.selection == .folder("/Users/test/A"))
        await model.refresh().value
        #expect(!model.failed)
    }

    @Test func aRefusedDiskChangeKeepsTheLineAfterItsOwnReload() async throws {
        let defaults = freshDefaults("refused.disk")
        let client = Recorder(refuses: true)
        let model = LocationsModel(client: client, defaults: defaults, chooseFolder: { nil })
        model.selection = .disk(archive.id)
        model.removeSelected()
        await model.change?.value
        #expect(client.indexed == [[archive.id]])
        #expect(!client.readsOnMain.isEmpty, "the change reloaded the disks")
        #expect(model.failed)
        #expect(model.indexed.isEmpty)
    }

    @Test func onlyTheTwoLocationKeysTriggerARefresh() async throws {
        let defaults = freshDefaults("keys")
        let client = Recorder()
        let model = LocationsModel(client: client, defaults: defaults, chooseFolder: { nil })
        await model.refresh().value
        let reads = client.reads
        defaults.set(true, forKey: "locationsmodel.unrelated")
        await drainMain()
        await drainMain()
        await model.change?.value
        #expect(client.reads == reads, "an unrelated key read the disks")
        defaults.set([archive.id], forKey: LocationsModel.Key.indexedVolumes)
        try await untilTrue(waitingFor: "the indexed key to refresh the model") { model.indexed == [archive.id] }
        #expect(client.reads > reads)
        defaults.set(["/Users/test/Z"], forKey: LocationsModel.Key.excluded)
        try await untilTrue(waitingFor: "the excluded key to refresh the model") { model.excluded == ["/Users/test/Z"] }
    }

    @Test func theRowsAreBuiltOnceAndPublishedOnlyWhenTheyChange() async throws {
        let defaults = freshDefaults("items")
        defaults.set(["/Users/test/Missing", "Library/Caches"], forKey: LocationsModel.Key.excluded)
        let model = LocationsModel(client: Recorder(), defaults: defaults, chooseFolder: { nil })
        model.shown = true
        await model.refresh().value
        #expect(model.items.map(\.row) == [.disk(archive.id), .folder("/Users/test/Missing"), .folder("Library/Caches")])
        #expect(model.items.map(\.name) == ["Archive", "Missing", "Library/Caches"])
        #expect(model.items.map(\.note) == [nil, nil, .invalid])
        var published = 0
        let watch = model.$items.dropFirst().sink { _ in published += 1 }
        let icons = model.items.map(\.icon)
        await model.refresh().value
        #expect(published == 0, "an unchanged list published again")
        #expect(zip(icons, model.items.map(\.icon)).allSatisfy { $0 === $1 })
        model.selection = .folder("Library/Caches")
        model.removeSelected()
        await model.change?.value
        #expect(published == 1)
        #expect(model.items.map(\.row) == [.disk(archive.id), .folder("/Users/test/Missing")])
        #expect(model.items[1].icon === icons[1])
        withExtendedLifetime(watch) {}
    }

    @Test func aHiddenPaneBuildsNoRows() async throws {
        let model = LocationsModel(client: Recorder(), defaults: freshDefaults("hidden"), chooseFolder: { nil })
        await model.refresh().value
        #expect(model.items.isEmpty)
        #expect(!model.rows.isEmpty)
        model.shown = true
        #expect(model.items.map(\.row) == model.rows)
    }
}
