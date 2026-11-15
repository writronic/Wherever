import AppKit
import Dispatch
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private func drainMain() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
}

@Suite struct SearchModelUnmountTests {
    private struct Window {
        let session: any SearchSessionClient
        let model: SearchModel

        init(_ fake: FakeSearchClient, mounts: NotificationCenter, folder: String?, presses: Bool = true) throws {
            session = try fake.makeSession()
            model = SearchModel(session: session, mounts: mounts)
            model.filters.folder = folder
            model.content = ContentTerms(terms: ["alpha"])
            if presses { model.searchContent() }
        }

        func stops(_ fake: FakeSearchClient) -> Int { fake.session(session.id)?.stops ?? -1 }
    }

    private static func unmount(_ path: String, in mounts: NotificationCenter) async {
        mounts.post(
            name: NSWorkspace.willUnmountNotification, object: nil,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: URL(filePath: path + "/", directoryHint: .isDirectory)]
        )
        await drainMain()
    }

    @Test(arguments: ["/Volumes/Disk 1", "/Volumes/Disk 1/", "/Volumes/Disk 1/Docs/Old"])
    func aPressOnTheUnmountingDiskStopsLikeTheStopButton(folder: String) async throws {
        let fake = FakeSearchClient()
        let mounts = NotificationCenter()
        let window = try Window(fake, mounts: mounts, folder: folder)
        let press = try #require(window.model.press)
        #expect(window.model.reading)
        await Self.unmount("/Volumes/Disk 1", in: mounts)
        #expect(window.stops(fake) == 1, "the disk is let go so it can eject")
        #expect(window.model.press == press, "the rows read so far stay, as Stop keeps them")
        #expect(fake.presses.count == 1, "no second press")
        window.model.handle(.contentProgress(press, read: 3, total: 10, notDownloaded: 0, unreadable: 0, done: true))
        #expect(!window.model.reading)
        #expect(window.model.progress == SearchModel.ContentProgress(read: 3, total: 10, done: true))
    }

    @Test func aPressOnAnotherDiskKeepsReading() async throws {
        let fake = FakeSearchClient()
        let mounts = NotificationCenter()
        let window = try Window(fake, mounts: mounts, folder: "/Volumes/Disk 2/Docs")
        await Self.unmount("/Volumes/Disk 1", in: mounts)
        #expect(window.stops(fake) == 0)
        #expect(window.model.reading)
    }

    @Test func aDiskWhoseNameOnlyStartsTheFolderLeavesIt() async throws {
        let fake = FakeSearchClient()
        let mounts = NotificationCenter()
        let window = try Window(fake, mounts: mounts, folder: "/Volumes/Disk 10/Docs")
        await Self.unmount("/Volumes/Disk 1", in: mounts)
        #expect(window.stops(fake) == 0, "Disk 1 is not Disk 10")
        #expect(window.model.reading)
    }

    @Test func aPressWithNoFolderIsLeftToTheEngine() async throws {
        let fake = FakeSearchClient()
        let mounts = NotificationCenter()
        let window = try Window(fake, mounts: mounts, folder: nil)
        await Self.unmount("/Volumes/Disk 1", in: mounts)
        #expect(window.stops(fake) == 0, "a press over every indexed disk keeps the engine's own eject handling")
        #expect(window.model.reading)
    }

    @Test func anUnmountWithNoPressRunningDoesNothing() async throws {
        let fake = FakeSearchClient()
        let mounts = NotificationCenter()
        let idle = try Window(fake, mounts: mounts, folder: "/Volumes/Disk 1", presses: false)
        await Self.unmount("/Volumes/Disk 1", in: mounts)
        #expect(idle.stops(fake) == 0)
        let done = try Window(fake, mounts: mounts, folder: "/Volumes/Disk 1")
        let press = try #require(done.model.press)
        done.model.handle(.contentProgress(press, read: 10, total: 10, notDownloaded: 0, unreadable: 0, done: true))
        await Self.unmount("/Volumes/Disk 1", in: mounts)
        #expect(done.stops(fake) == 0, "a finished press holds no file")
        #expect(fake.stops == 0)
    }

    @Test func theFolderOfThePressCountsNotTheFolderTypedAfter() async throws {
        let fake = FakeSearchClient()
        let mounts = NotificationCenter()
        let window = try Window(fake, mounts: mounts, folder: "/Volumes/Disk 1/Docs")
        window.model.filters.folder = "/Volumes/Disk 2"
        await Self.unmount("/Volumes/Disk 2", in: mounts)
        #expect(window.stops(fake) == 0, "the press still walks Disk 1")
        await Self.unmount("/Volumes/Disk 1", in: mounts)
        #expect(window.stops(fake) == 1)
    }

    @Test func theFolderOfANewReadCountsOnceItStarts() async throws {
        let fake = FakeSearchClient()
        let mounts = NotificationCenter()
        let window = try Window(fake, mounts: mounts, folder: "/Volumes/Disk 1/Docs")
        window.model.readDelay = {}
        window.model.filters.folder = "/Volumes/Disk 2"
        try await untilTrue(waitingFor: "the new read") { fake.presses.count == 2 }
        await Self.unmount("/Volumes/Disk 1", in: mounts)
        #expect(window.stops(fake) == 0, "the new read left Disk 1")
        await Self.unmount("/Volumes/Disk 2", in: mounts)
        #expect(window.stops(fake) == 1, "the new read walks Disk 2")
    }

    @Test func afterTheStopAPressOnAMountedFolderReadsAgain() async throws {
        let fake = FakeSearchClient()
        let mounts = NotificationCenter()
        let window = try Window(fake, mounts: mounts, folder: "/Volumes/Disk 1")
        let first = try #require(window.model.press)
        await Self.unmount("/Volumes/Disk 1", in: mounts)
        window.model.handle(.contentProgress(first, read: 2, total: 5, notDownloaded: 0, unreadable: 0, done: true))
        window.model.filters.folder = "/Volumes/Disk 2"
        window.model.searchContent()
        let second = try #require(window.model.press)
        #expect(second != first)
        #expect(fake.presses.count == 2)
        #expect(fake.presses.last?.query == "in:\"/Volumes/Disk 2\"")
        #expect(window.model.reading)
        #expect(window.stops(fake) == 1)
        await Self.unmount("/Volumes/Disk 1", in: mounts)
        #expect(window.stops(fake) == 1, "the new press reads Disk 2")
    }

    @Test func onlyTheWindowWhosePressReadsTheDiskStops() async throws {
        let fake = FakeSearchClient()
        let mounts = NotificationCenter()
        let reader = try Window(fake, mounts: mounts, folder: "/Volumes/Disk 1/Docs")
        let other = try Window(fake, mounts: mounts, folder: "/Volumes/Disk 2/Docs")
        await Self.unmount("/Volumes/Disk 1", in: mounts)
        #expect(reader.stops(fake) == 1)
        #expect(other.stops(fake) == 0)
        #expect(other.model.reading)
    }
}
