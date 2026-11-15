import AppKit
import DiskArbitration
import Dispatch
import Foundation
import os
import Testing
import WhereverInterface
@testable import WhereverKit

@Suite struct VolumeClassificationTests {
    private let id = "0A0A0A0A-0000-4000-8000-00000000000A"

    private func disk(_ path: String = "/Volumes/Disk 1", local: Bool = true, browsable: Bool = true, root: Bool = false, image: Bool = false) -> Mount {
        Mount(path: path, local: local, browsable: browsable, rootFileSystem: root, image: image)
    }

    @Test func keepsALocalBrowsableDiskWithAUUID() {
        #expect(volumes([disk()], unmounting: [], uuid: { _ in id }) == [MountedVolume(path: "/Volumes/Disk 1", id: id)])
    }

    @Test func dropsEveryOtherMount() {
        var asked: [String] = []
        let others = [disk(local: false), disk(browsable: false), disk("/", root: true), disk(image: true)]
        #expect(volumes(others, unmounting: [], uuid: { asked.append($0); return id }).isEmpty)
        #expect(asked.isEmpty)
        let unread: String?? = nil
        #expect(volumes([disk()], unmounting: [], uuid: { _ in unread }).isEmpty)
        #expect(volumes([disk()], unmounting: ["/Volumes/Disk 1"], uuid: { _ in id }).isEmpty)
    }

    @Test func readsADiskImageFromItsDevice() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "wherever-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appending(component: "probe.dmg")
        try #require(WhereverServices.hdiutil(["create", "-quiet", "-size", "2m", "-fs", "HFS+", "-volname", "Probe", image.path], timeout: 60) != nil, "hdiutil create failed")
        let attached = try #require(WhereverServices.hdiutil(["attach", "-nobrowse", "-noautoopen", "-plist", image.path], timeout: 60), "hdiutil attach failed")
        let entities = ((try? PropertyListSerialization.propertyList(from: attached, format: nil)) as? [String: Any])?["system-entities"] as? [[String: Any]] ?? []
        let mounted = try #require(entities.first { $0["mount-point"] != nil })
        defer { _ = WhereverServices.hdiutil(["detach", "-force", mounted["mount-point"] as? String ?? ""], timeout: 30) }
        let session = DASessionCreate(kCFAllocatorDefault)
        #expect(isDiskImage(device: try #require(mounted["dev-entry"] as? String), session: session))
        var root = statfs()
        #expect(statfs("/", &root) == 0)
        let device = withUnsafeBytes(of: root.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #expect(!isDiskImage(device: device, session: session))
        #expect(!isDiskImage(device: "/dev/disk9999s9", session: session))
        #expect(!isDiskImage(device: device, session: nil))
    }

    @Test func anUnmountingDiskStaysOutWhateverItsTrailingSlash() {
        #expect(volumes([disk()], unmounting: ["/Volumes/Disk 1/"], uuid: { _ in id }).isEmpty)
        let both = [disk("/Volumes/Disk 1/"), disk("/Volumes/Disk 2")]
        #expect(volumes(both, unmounting: ["/Volumes/Disk 1"], uuid: { _ in id }) == [MountedVolume(path: "/Volumes/Disk 2", id: id)])
    }
}

@Suite struct VolumeServiceTests {
    @Test func aFakeDiskJoinsTheIndexThroughTheTestInitializer() async throws {
        let boot = try makeFolder(files: ["alpha.txt", "Sub/beta.txt"])
        let disk = try makeFolder(files: ["ondisk.txt", "Inner/deep.txt"])
        defer { for path in [boot, boot + "-data", disk] { try? FileManager.default.removeItem(atPath: path) } }
        let id = "0A0A0A0A-0000-4000-8000-00000000000A"
        let volume = MountedVolume(path: disk, id: id)
        let client = try WhereverServices(root: boot, home: boot + "-home", dataFolder: boot + "-data", excluded: [], volumes: [volume], indexedVolumes: [id]).search
        let session = try client.makeSession()

        _ = try await events(in: client.events) { event in
            if case let .stateChanged(state) = event { state.indexed == 6 } else { false }
        }
        let generation = try session.search("deep", sort: .bestMatch)
        let found = try await events(in: client.events) { event in
            if case .resultsReady(generation, _) = event { true } else { false }
        }
        #expect(found.last == .resultsReady(generation, count: 1))
        let hit = try #require(try session.rows(generation, in: 0..<10).first)
        let real = try realPath(disk)
        #expect(hit.name == "deep.txt")
        #expect(hit.folder == real + "/Inner")
    }
}

@Suite struct LocationTests {
    @Test func volumesListsEveryDiskByItsFolderName() throws {
        let rig = try TwoDisks()
        defer { rig.remove() }
        let client = try rig.services()
        let names = [rig.first, rig.second].map { ($0 as NSString).lastPathComponent }
        #expect(try client.volumes() == [
            IndexedVolume(id: rig.ids[0], name: names[0], path: rig.first, indexed: true),
            IndexedVolume(id: rig.ids[1], name: names[1], path: rig.second, indexed: true),
        ])
    }

    @Test func aDiskStaysOutUntilItIsSwitchedOn() async throws {
        let rig = try TwoDisks()
        defer { rig.remove() }
        let client = try rig.services(indexed: [])
        #expect(try client.volumes().map(\.indexed) == [false, false])
        _ = try await events(in: client.events) { event in
            if case let .stateChanged(state) = event { state.indexed == 3 && (state.phase == .ready || state.phase == .live) } else { false }
        }
        try await search(client, "onfirst", until: 0)

        try client.setIndexedVolumes([rig.ids[0]])
        _ = try await events(in: client.events) { $0 == .volumesChanged }
        try await search(client, "onfirst", until: 1)
        try await search(client, "onsecond", until: 0)
        #expect(try client.volumes().map(\.indexed) == [true, false])
    }

    @Test func aSwitchedOffDiskLeavesTheIndexAndComesBack() async throws {
        let rig = try TwoDisks()
        defer { rig.remove() }
        let client = try rig.services()
        try await search(client, "onfirst", until: 1)
        try await search(client, "onsecond", until: 1)

        try client.setIndexedVolumes([rig.ids[1]])
        _ = try await events(in: client.events) { $0 == .volumesChanged }
        try await search(client, "onfirst", until: 0)
        try await search(client, "onsecond", until: 1)
        #expect(try client.volumes().map(\.indexed) == [false, true])

        try client.setIndexedVolumes(Set(rig.ids))
        _ = try await events(in: client.events) { $0 == .volumesChanged }
        try await search(client, "onfirst", until: 1)
        #expect(try client.volumes().map(\.indexed) == [true, true])
    }

    @Test func anExcludedFolderLeavesTheResultsAndARelativeOneThrows() async throws {
        let rig = try TwoDisks()
        defer { rig.remove() }
        let client = try rig.services()
        try await search(client, "hidden", until: 1)
        try client.setExcludedFolders([rig.boot + "/Hide"])
        try await search(client, "hidden", until: 0)
        #expect(throws: WhereverError.io) { try client.setExcludedFolders(["Hide"]) }
    }
}

@Suite struct VolumeTests {
    @MainActor @Test func theLaunchReadsDisksOffTheMainThread() throws {
        let rig = try Watched()
        defer { rig.remove() }
        let watcher = rig.watch()
        watcher.queue.sync {}
        #expect(rig.taken() == rig.disks.prefix(2).map { Watched.Read(path: $0, main: false) })
        #expect(try rig.client.volumes().map(\.path) == Array(rig.disks.prefix(2)))
    }

    @Test func anUnmountReadsNoDisk() throws {
        let rig = try Watched()
        defer { rig.remove() }
        let watcher = rig.watch()
        watcher.queue.sync {}
        _ = rig.taken()
        rig.post(NSWorkspace.willUnmountNotification, rig.disks[0])
        #expect(rig.taken().isEmpty)
        #expect(try rig.client.volumes().map(\.path) == [rig.disks[1]])
        rig.mounted.withLock { $0 = [rig.disks[1]] }
        rig.post(NSWorkspace.didUnmountNotification, rig.disks[0])
        watcher.queue.sync {}
        #expect(rig.taken().isEmpty)
        #expect(try rig.client.volumes().map(\.path) == [rig.disks[1]])
    }

    @Test func aDiskCrawlNamesTheDisk() async throws {
        let boot = try makeFolder(files: ["alpha.txt"])
        let disk = try makeFolder(files: ["ondisk.txt", "Inner/deep.txt"])
        defer { for path in [boot, boot + "-data", disk] { try? FileManager.default.removeItem(atPath: path) } }
        let id = "0A0A0A0A-0000-4000-8000-00000000000A"
        let volume = MountedVolume(path: disk, id: id)
        let client = try WhereverServices(root: boot, home: boot + "-home", dataFolder: boot + "-data", excluded: [], volumes: [volume], indexedVolumes: [id]).search

        let named = try await events(in: client.events) { event in
            if case let .stateChanged(state) = event { !state.indexingDisks.isEmpty } else { false }
        }
        guard case let .stateChanged(crawling)? = named.last else { Issue.record("no state names the disk"); return }
        #expect(crawling.indexingDisks == [(disk as NSString).lastPathComponent])
        #expect(crawling.phase == .crawling || crawling.phase == .loading)
        let done = try await events(in: client.events) { event in
            if case let .stateChanged(state) = event { state.phase == .ready || state.phase == .live } else { false }
        }
        guard case let .stateChanged(ready)? = done.last else { Issue.record("no Ready state"); return }
        #expect(ready.indexingDisks.isEmpty)
        #expect(ready.bootPhase == .ready || ready.bootPhase == .live)
    }

    @MainActor @Test func aRenameReadsTheNewPathOnce() throws {
        let rig = try Watched()
        let renamed = rig.disks[0] + "-renamed"
        defer {
            rig.remove()
            try? FileManager.default.removeItem(atPath: renamed)
        }
        let watcher = rig.watch()
        watcher.queue.sync {}
        _ = rig.taken()
        try FileManager.default.moveItem(atPath: rig.disks[0], toPath: renamed)
        rig.mounted.withLock { $0 = [renamed, rig.disks[1]] }
        rig.known.withLock { $0[renamed] = rig.ids[0] }
        rig.post(NSWorkspace.didRenameVolumeNotification, renamed)
        watcher.queue.sync {}
        #expect(rig.taken() == [Watched.Read(path: renamed, main: false)])
        #expect(try rig.client.volumes().map(\.path) == [renamed, rig.disks[1]])
    }

    @MainActor @Test func aMountReadsOnlyTheNewDisk() throws {
        let rig = try Watched()
        defer { rig.remove() }
        let watcher = rig.watch()
        watcher.queue.sync {}
        _ = rig.taken()
        rig.mounted.withLock { $0 = rig.disks }
        rig.post(NSWorkspace.didMountNotification, rig.disks[2])
        watcher.queue.sync {}
        #expect(rig.taken() == [Watched.Read(path: rig.disks[2], main: false)])
        rig.post(NSWorkspace.didMountNotification, rig.disks[0])
        watcher.queue.sync {}
        #expect(rig.taken() == [Watched.Read(path: rig.disks[0], main: false)])
        #expect(try rig.client.volumes().map(\.path) == rig.disks)
    }

    @Test func aDiskWithoutAVolumeIDIsListedButNeverIndexed() async throws {
        #expect(volumes([Mount(path: "/Volumes/CARD", local: true, browsable: true, rootFileSystem: false)], unmounting: [], uuid: { _ in .some(nil) })
            == [MountedVolume(path: "/Volumes/CARD", id: nil)])
        let rig = try Watched()
        defer { rig.remove() }
        rig.known.withLock { $0[rig.disks[1]] = nil }
        let watcher = rig.watch()
        watcher.queue.sync {}
        let card = rig.disks[1]
        #expect(try rig.client.volumes() == [
            IndexedVolume(id: rig.ids[0], name: (rig.disks[0] as NSString).lastPathComponent, path: rig.disks[0], indexed: true),
            IndexedVolume(id: card, name: (card as NSString).lastPathComponent, path: card, indexed: false, indexable: false),
        ])
        try rig.client.setIndexedVolumes(Set(rig.ids + [card]))
        try await search(rig.client, "onfirst", until: 1)
        try await search(rig.client, "onsecond", until: 0)
        withExtendedLifetime(watcher) { rig.post(NSWorkspace.didUnmountNotification, rig.disks[2]) }
        #expect(try rig.client.volumes().map(\.indexable) == [true, false])
    }

    @Test func anUnmountDuringAQueuedReadKeepsTheDiskOut() async throws {
        let rig = try Watched(holding: true)
        defer { rig.remove() }
        let watcher = rig.watch()
        #expect(waited(rig.entered))
        rig.post(NSWorkspace.willUnmountNotification, rig.disks[0])
        rig.release.signal()
        watcher.queue.sync {}
        #expect(try rig.client.volumes().map(\.path) == [rig.disks[1]])
        try await search(rig.client, "onsecond", until: 1)
        try await search(rig.client, "onfirst", until: 0)
    }
}

private final class Watched: Sendable {
    struct Read: Equatable {
        let path: String
        let main: Bool
    }

    let ids: [String]
    let boot: String
    let disks: [String]
    let mounted: OSAllocatedUnfairLock<[String]>
    let known: OSAllocatedUnfairLock<[String: String]>
    let reads = OSAllocatedUnfairLock<[Read]>(initialState: [])
    let held: String?
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let center = NotificationCenter()
    let client: SearchService

    init(holding: Bool = false) throws {
        let ids = ["0A0A0A0A-0000-4000-8000-00000000000A", "0B0B0B0B-0000-4000-8000-00000000000B", "0C0C0C0C-0000-4000-8000-00000000000C"]
        let boot = try makeFolder(files: ["alpha.txt"])
        let disks = try ["onfirst.txt", "onsecond.txt", "onthird.txt"].map { try makeFolder(files: [$0]) }
        self.ids = ids
        self.boot = boot
        self.disks = disks
        mounted = OSAllocatedUnfairLock(initialState: Array(disks.prefix(2)))
        known = OSAllocatedUnfairLock(initialState: Dictionary(uniqueKeysWithValues: zip(disks, ids)))
        held = holding ? disks[0] : nil
        client = try WhereverServices(root: boot, home: boot + "-home", dataFolder: boot + "-data", excluded: [], indexedVolumes: Set(ids)).search
    }

    func watch() -> VolumeWatcher {
        let operations = VolumeWatcher.Operations(
            mounts: { [mounted] in
                mounted.withLock { $0 }.map { Mount(path: $0, local: true, browsable: true, rootFileSystem: false) }
            },
            uuid: { [self] path in
                let main = Thread.isMainThread
                reads.withLock { $0.append(Read(path: path, main: main)) }
                if path == held {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 10)
                }
                return known.withLock { $0[path] }
            }
        )
        return VolumeWatcher(disks: client.disks, operations: operations, center: center)
    }

    func post(_ name: Notification.Name, _ path: String) {
        center.post(name: name, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: URL(filePath: path, directoryHint: .isDirectory)])
    }

    func taken() -> [Read] {
        reads.withLock { reads in
            let taken = reads
            reads = []
            return taken
        }
    }

    func remove() {
        for path in [boot, boot + "-data"] + disks {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

private func waited(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 10) == .success
}

private struct TwoDisks {
    let ids = ["0A0A0A0A-0000-4000-8000-00000000000A", "0B0B0B0B-0000-4000-8000-00000000000B"]
    let boot: String
    let first: String
    let second: String

    init() throws {
        boot = try makeFolder(files: ["alpha.txt", "Hide/hidden.txt"])
        first = try makeFolder(files: ["onfirst.txt"])
        second = try makeFolder(files: ["onsecond.txt"])
    }

    func services(indexed: Set<String>? = nil) throws -> SearchService {
        let volumes = [MountedVolume(path: first, id: ids[0]), MountedVolume(path: second, id: ids[1])]
        return try WhereverServices(root: boot, home: boot + "-home", dataFolder: boot + "-data", excluded: [], volumes: volumes, indexedVolumes: indexed ?? Set(ids)).search
    }

    func remove() {
        for path in [boot, boot + "-data", first, second] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

private func search(_ client: SearchService, _ query: String, until count: Int) async throws {
    let session = try client.makeSession()
    while true {
        let generation = try session.search(query, sort: .bestMatch)
        let seen = try await events(in: client.events) { event in
            if case .resultsReady(generation, _) = event { true } else { false }
        }
        if seen.last == .resultsReady(generation, count: count) { return }
        if !seen.contains(.resultsChanged) {
            _ = try await events(in: client.events) { $0 == .resultsChanged }
        }
    }
}

private func makeFolder(files: [String]) throws -> String {
    let root = URL.temporaryDirectory.appending(component: "WhereverKitVolumeTests-\(UUID().uuidString)")
    for path in files {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1).write(to: file)
    }
    return try realPath(root.path(percentEncoded: false))
}

private func realPath(_ path: String) throws -> String {
    let resolved = try #require(realpath(path, nil))
    defer { free(resolved) }
    return String(cString: resolved)
}

private func events(in stream: AsyncStream<SearchEvent>, until done: @escaping @Sendable (SearchEvent) -> Bool) async throws -> [SearchEvent] {
    let seen = try await withThrowingTaskGroup(of: [SearchEvent]?.self) { group in
        group.addTask {
            var seen: [SearchEvent] = []
            for await event in stream {
                seen.append(event)
                if done(event) { return seen }
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            return nil
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
    return try #require(seen, "no awaited event within 10 s")
}
