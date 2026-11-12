import AppKit
import Carbon
import CoreText
import Darwin
import Dispatch
import Foundation
import SwiftUI
import Testing
import UserNotifications
@testable import Wherever
import WhereverInterface

private func noticeDefaults(_ name: String) -> UserDefaults {
    let domain = "com.writronic.wherever.tests.disknotice.\(name)"
    let defaults = UserDefaults(suiteName: domain)!
    defaults.removePersistentDomain(forName: domain)
    return defaults
}

private let english = Locale(identifier: "en")
private let disk = IndexedVolume(id: "5F2A6C3E-0B1D-4C7A-9E58-2D4B7A91C0E3", name: "Disk 1", path: "/Volumes/Disk 1", indexed: false)
private let diskOn = IndexedVolume(id: disk.id, name: disk.name, path: disk.path, indexed: true)
private let noUUID = IndexedVolume(id: "/Volumes/Card", name: "Card", path: "/Volumes/Card", indexed: false, indexable: false)
private let line = "\(Bidi.name(disk.name)) is not indexed"
private let disk2 = IndexedVolume(id: "8C1D4E7A-3F2B-4A6C-B9D0-1E5F7A2C4B68", name: "Disk 2", path: "/Volumes/Disk 2", indexed: false)

private func drainMain() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
}

func realClick(_ id: String, in host: SearchHost) async throws -> String {
    let element = try #require(AXTree.element(id, in: host.view), "no \(id) in the window")
    let frame = try #require(AXTree.frame(of: element), "no frame for \(id)")
    let window = host.window
    let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
    func event(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
        ))
    }
    let down = try event(.leftMouseDown)
    let up = try event(.leftMouseUp)
    await EventQueueLock.run {
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        while let left = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            guard left.window === window else {
                NSApp.postEvent(left, atStart: true)
                break
            }
            NSApp.sendEvent(left)
        }
    }
    return "the click on \(id) at \(point) hit \(String(describing: window.contentView?.hitTest(point)))"
}

private final class Questions {
    var replies: [Bool] = []
    var asked: [String] = []

    func ask(_ volume: IndexedVolume) -> Bool {
        asked.append(volume.name)
        return replies.isEmpty ? false : replies.removeFirst()
    }
}

private final class Notices {
    var asks = 0
    var reads = 0
    var status = UNAuthorizationStatus.authorized
    var refuses = false
    var holds = false
    var failsPosts = false
    var held: [CheckedContinuation<Void, Never>] = []
    var posted: [String] = []
    var shown: Set<String> = []
    var steps: [String] = []

    var calls: DiskNotices {
        DiskNotices(
            ask: {
                self.asks += 1
                self.steps.append("ask")
                if self.refuses { self.status = .denied }
            },
            isOff: {
                self.reads += 1
                return DiskNotices.isOff(self.status)
            },
            needsSystemSettings: { DiskNotices.needsSystemSettings(self.status) },
            post: { volume in
                self.steps.append("post \(volume.name)")
                if self.holds { await withCheckedContinuation { self.held.append($0) } }
                if self.failsPosts { return false }
                self.posted.append(volume.name)
                self.shown.insert(volume.id)
                return true
            },
            withdraw: { self.shown.formIntersection($0) }
        )
    }

    func release() {
        for post in held { post.resume() }
        held = []
    }
}

private final class Presses {
    var count = 0
}

private struct NoticeRig {
    let fake = FakeSearchClient()
    let store: UserDefaults
    let mounts = NotificationCenter()
    let confirm = Questions()
    let notices = Notices()
    let manage = Presses()
    let index: IndexModel

    init(_ name: String, choice: NewDiskChoice? = nil, atLaunch: [IndexedVolume] = [], opens: (() -> Void)? = nil) {
        store = noticeDefaults(name)
        if let choice { store.set(choice.rawValue, forKey: NewDiskChoice.key) }
        fake.setVolumes(.success(atLaunch))
        let (confirm, notices, manage) = (confirm, notices, manage)
        index = IndexModel(
            client: fake, defaults: store, mounts: mounts, confirmIndex: { confirm.ask($0) }, notices: notices.calls,
            openLocations: {
                manage.count += 1
                opens?()
            }
        )
    }

    var storedIndexed: [String] { store.stringArray(forKey: LocationsModel.Key.indexedVolumes) ?? [] }

    func plugIn(_ volume: IndexedVolume, beside mounted: [IndexedVolume] = []) async {
        mounts.post(
            name: NSWorkspace.didMountNotification, object: nil,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: URL(filePath: volume.path + "/", directoryHint: .isDirectory)]
        )
        await drainMain()
        fake.setVolumes(.success(mounted + [volume]))
        fake.send(.volumesChanged)
    }

    func list(_ volumes: [IndexedVolume]) {
        fake.setVolumes(.success(volumes))
        fake.send(.volumesChanged)
    }

    func settle(_ count: Int) async throws {
        let marker = IndexState(phase: .ready, indexed: count)
        fake.send(.stateChanged(marker))
        try await untilTrue(waitingFor: "the marker state \(count)") { index.indexState == marker }
        await drainMain()
    }

    func host(_ model: SearchModel? = nil, reportsKey: Bool = false) -> SearchHost {
        SearchHost(
            root: AnyView(ContentView(index: index, model: model ?? index.makeModel()).environment(\.locale, english).defaultAppStorage(store)),
            reportsKey: reportsKey
        )
    }
}

@Suite(.serialized) struct DiskNoticeTests {
    @Test func everyNewStringIsInEveryLanguage() throws {
        let keys = [
            ("When a disk that isn’t indexed is connected", "Settings"), ("Ask in the Status Bar", "Settings"),
            ("Ask with a Notification", "Settings"), ("Index Automatically", "Settings"), ("Do Nothing", "Settings"),
            ("Notifications for Wherever are turned off. Allow them in System Settings > Notifications.", "Settings"),
            ("Not Now", "Normal"), ("Index", "Normal"), ("Index “%@”?", "Normal"), ("%@ is not indexed", "Results"),
        ]
        for language in ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"] {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            for (key, table) in keys {
                let text = bundle.localizedString(forKey: key, value: "\u{1}", table: table)
                #expect(text != "\u{1}" && (language == "en") == (text == key), "\(table) \(language): \(text)")
            }
        }
    }

    @Test func aMountedPathFromAWakeAsksThroughTheSameRuleAsAHeardMount() async throws {
        let rig = NoticeRig("wake.notice", choice: .notification, atLaunch: [disk])
        #expect(rig.notices.posted.isEmpty, "a disk listed at launch posted a notice")
        #expect(!rig.index.noticeWaits)
        rig.index.diskMounted(at: disk.path + "/")
        #expect(rig.index.noticeWaits)
        try await rig.settle(1)
        try await untilTrue(waitingFor: "the notice") { rig.notices.posted == ["Disk 1"] }
        #expect(rig.index.noticeWaits, "the post was the answer")
        rig.index.noticeAnswered(DiskNotices.notNowAction, diskID: disk.id)
        #expect(!rig.index.noticeWaits)
    }

    @Test func aRefusedNoticeEndsTheHoldAndGoesToTheBar() async throws {
        let rig = NoticeRig("wake.refused", choice: .notification, atLaunch: [disk])
        rig.notices.failsPosts = true
        var woke = 0
        rig.index.stateArrived = { _ in woke += 1 }
        rig.index.diskMounted(at: disk.path)
        try await untilTrue(waitingFor: "the hold to end") { !rig.index.noticeWaits }
        #expect(woke == 1, "nothing rechecked the idle quit, so a wake stays forever")
        #expect(rig.index.waitingDisks == [disk])
    }

    @Test func theBarNamesAMountedDiskUntilItIsSwitchedOnOrEjected() async throws {
        let rig = NoticeRig("bar.lifecycle", atLaunch: [disk])
        let host = rig.host()
        defer { host.close() }
        try await host.until("the line and its Index button") {
            host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil
        }
        #expect(rig.notices.posted.isEmpty, "a disk listed at launch posted a notice")

        rig.list([diskOn])
        try await host.until("no line once the disk is switched on") {
            !host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) == nil
        }
        rig.list([disk])
        try await host.until("the line again once it is switched off") { host.windowShows(line) }
        rig.list([])
        try await host.until("no line once the disk is ejected") { !host.windowShows(line) }
    }

    @Test func theIndexButtonAsksBeforeItSwitchesTheDiskOn() async throws {
        let rig = NoticeRig("bar.asks", atLaunch: [disk])
        let host = rig.host()
        defer { host.close() }
        try await host.until("the Index button") { AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil }
        let button = try #require(AXTree.element(StatusBarView.indexDiskID, in: host.view))

        rig.confirm.replies = [false]
        try #require(AXTree.press(button))
        try await untilTrue(waitingFor: "the question") { rig.confirm.asked == ["Disk 1"] }
        #expect(rig.fake.switchedOn.isEmpty && rig.storedIndexed.isEmpty, "Cancel switched the disk on")
        #expect(host.windowShows(line))

        rig.confirm.replies = [true]
        try #require(AXTree.press(button))
        try await untilTrue(waitingFor: "the switch after Index") { rig.fake.switchedOn == [[disk.id]] }
        #expect(rig.confirm.asked == ["Disk 1", "Disk 1"])
        #expect(rig.storedIndexed == [disk.id])
        #expect(rig.notices.posted.isEmpty)
    }

    @Test func theNoticePostsOncePerPlugInAndOnlyIndexSwitchesOn() async throws {
        let rig = NoticeRig("notice", choice: .notification, atLaunch: [disk])
        rig.list([disk])
        try await rig.settle(1)
        #expect(rig.notices.posted.isEmpty, "a disk listed at launch posted a notice")
        rig.list([])

        await rig.plugIn(disk)
        try await untilTrue(waitingFor: "the notice") { rig.notices.posted == ["Disk 1"] }
        rig.fake.send(.volumesChanged)
        try await rig.settle(2)
        #expect(rig.notices.posted == ["Disk 1"], "one plug-in posted twice")
        #expect(rig.notices.asks == 1, "the stored answer asked \(rig.notices.asks) times")

        for answer in [DiskNotices.notNowAction, UNNotificationDismissActionIdentifier, UNNotificationDefaultActionIdentifier] {
            rig.index.noticeAnswered(answer, diskID: disk.id)
        }
        rig.index.noticeAnswered(DiskNotices.indexAction, diskID: noUUID.id)
        try await rig.settle(3)
        #expect(rig.fake.switchedOn.isEmpty && rig.storedIndexed.isEmpty, "Not Now, a dismiss, a click or another disk's Index switched the disk on")
        #expect(rig.confirm.asked.isEmpty)

        rig.index.noticeAnswered(DiskNotices.indexAction, diskID: disk.id)
        try await untilTrue(waitingFor: "the switch after Index") { rig.fake.switchedOn == [[disk.id]] }
        #expect(rig.storedIndexed == [disk.id])
        #expect(rig.confirm.asked.isEmpty, "the notice's Index asked again")
    }

    @Test func clickingTheNoticeOpensLocationsAndKeepsTheDiskInTheBarWithoutSwitchingItOn() async throws {
        let rig = NoticeRig("notice.click", choice: .notification)
        let host = rig.host()
        defer { host.close() }
        await rig.plugIn(disk)
        try await untilTrue(waitingFor: "the notice") { rig.notices.shown == [disk.id] }
        try await rig.settle(1)
        try await host.until("the bar") { host.windowShows("Files: 1") }
        #expect(!host.windowShows(line) && rig.manage.count == 0)

        rig.index.noticeAnswered(DiskNotices.notNowAction, diskID: disk.id)
        rig.index.noticeAnswered(UNNotificationDismissActionIdentifier, diskID: disk.id)
        rig.index.noticeAnswered(UNNotificationDefaultActionIdentifier, diskID: noUUID.id)
        try await rig.settle(2)
        #expect(rig.manage.count == 0, "Not Now, a dismiss or another disk's click opened Locations")
        #expect(rig.index.waitingDisks.isEmpty)

        rig.index.noticeAnswered(UNNotificationDefaultActionIdentifier, diskID: disk.id)
        #expect(rig.manage.count == 1, "a click on the notice opened nothing")
        #expect(rig.index.waitingDisks == [disk], "the clicked disk dropped out of the bar")
        try await host.until("the line and its Index button after the click") {
            host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil
        }
        #expect(rig.notices.shown.isEmpty, "the clicked notice stayed beside the bar's line")
        try await rig.settle(3)
        #expect(rig.fake.switchedOn.isEmpty && rig.storedIndexed.isEmpty, "a click switched the disk on")
        #expect(rig.confirm.asked.isEmpty, "a click asked the index question")

        rig.list([])
        try await rig.settle(4)
        rig.index.noticeAnswered(UNNotificationDefaultActionIdentifier, diskID: disk.id)
        #expect(rig.manage.count == 1, "a click on an ejected disk's notice opened Locations")
    }

    @Test func theNoticeAsksTheAlertsQuestionAndCarriesIndexAndNotNow() throws {
        let request = DiskNotices.request(for: disk)
        #expect(request.identifier == disk.id && request.trigger == nil)
        #expect(request.content.categoryIdentifier == DiskNotices.category)
        #expect(request.content.title == String(localized: "Index “\(Bidi.name(disk.name))”?", table: "Normal") && request.content.title.contains("Disk 1"))
        #expect(request.content.body == String(
            localized: "Wherever reads every file name on this disk before it can search it. A large disk can take several minutes. To ignore it again, add it to Excluded Paths in Settings.",
            table: "Normal"
        ))
        let category = try #require(DiskNotices.categories.first { $0.identifier == DiskNotices.category })
        #expect(category.actions.map(\.identifier) == [DiskNotices.indexAction, DiskNotices.notNowAction])
        #expect(category.options.contains(.customDismissAction), "a dismissed notice never reports back, so a wake holds on it forever")
        #expect(category.actions.map(\.title) == [String(localized: "Index", table: "Normal"), String(localized: "Not Now", table: "Normal")])
    }

    @Test func theNotificationTitleIsolatesItsDiskName() {
        for name in ["Disk 1", "قرص 1"] {
            let volume = IndexedVolume(id: disk.id, name: name, path: disk.path, indexed: false)
            #expect(DiskNotices.request(for: volume).content.title.contains("\u{2068}\(name)\u{2069}"))
        }
    }

    @Test func indexOnANoticeWhoseDiskWasEjectedChangesNothing() async throws {
        let rig = NoticeRig("notice.ejected", choice: .notification)
        await rig.plugIn(disk)
        try await untilTrue(waitingFor: "the notice") { rig.notices.posted == ["Disk 1"] }
        #expect(rig.index.waitingDisks.isEmpty, "the bar also names the disk its notice asks about")
        rig.list([])
        try await rig.settle(1)
        rig.index.noticeAnswered(DiskNotices.indexAction, diskID: disk.id)
        try await rig.settle(2)
        #expect(rig.fake.switchedOn.isEmpty && rig.storedIndexed.isEmpty, "Index switched on an ejected disk")
    }

    @Test func aStoredNotificationAnswerAsksOnceBeforeItsFirstNotice() async throws {
        let rig = NoticeRig("ask.launch", choice: .notification)
        try await untilTrue(waitingFor: "the question at launch") { rig.notices.asks == 1 }
        await rig.plugIn(disk)
        try await untilTrue(waitingFor: "the first notice") { rig.notices.posted == ["Disk 1"] }
        await rig.plugIn(disk2)
        try await untilTrue(waitingFor: "the second notice") { rig.notices.posted == ["Disk 1", "Disk 2"] }
        #expect(rig.notices.steps == ["ask", "post Disk 1", "post Disk 2"], "asked again, or posted before the question")
    }

    @Test func anAnswerStoredWithoutAPickAsksBeforeItsNoticeAndNoOtherAnswerAsks() async throws {
        let rig = NoticeRig("ask.imported", choice: .statusBar)
        for (step, choice) in [NewDiskChoice.statusBar, .index, .nothing].enumerated() {
            rig.store.set(choice.rawValue, forKey: NewDiskChoice.key)
            await rig.plugIn(disk)
            try await rig.settle(step + 1)
        }
        #expect(rig.notices.asks == 0, "another answer asked for permission")

        rig.store.set(NewDiskChoice.notification.rawValue, forKey: NewDiskChoice.key)
        await rig.plugIn(disk2)
        try await untilTrue(waitingFor: "the notice") { rig.notices.posted == ["Disk 2"] }
        #expect(rig.notices.steps == ["ask", "post Disk 2"])
    }

    @Test func aRefusedQuestionSendsThePlugInToTheStatusBarOnly() async throws {
        let rig = NoticeRig("refused", choice: .statusBar)
        let host = rig.host()
        defer { host.close() }
        rig.notices.refuses = true
        rig.store.set(NewDiskChoice.notification.rawValue, forKey: NewDiskChoice.key)
        await rig.plugIn(disk)
        try await host.until("the line and its Index button") {
            host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil
        }
        #expect(rig.notices.asks == 1)
        #expect(rig.notices.posted.isEmpty, "the disk got a notice and the bar line both")
    }

    @Test func notificationsTurnedOffLaterSendTheNextPlugInToTheStatusBar() async throws {
        let rig = NoticeRig("turnedoff", choice: .notification)
        let host = rig.host()
        defer { host.close() }
        await rig.plugIn(disk)
        try await untilTrue(waitingFor: "the notice") { rig.notices.posted == ["Disk 1"] }
        try await rig.settle(1)
        try await host.until("the bar") { host.windowShows("Files: 1") }
        #expect(!host.windowShows(line), "an allowed notice also put the disk in the bar")

        rig.notices.status = .denied
        await rig.plugIn(disk2)
        try await host.until("the second disk in the bar") {
            host.windowShows("\(Bidi.name(disk2.name)) is not indexed") && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil
        }
        #expect(rig.notices.posted == ["Disk 1"], "a notice went out while notifications are off")
    }

    @Test func aFailedQuestionSendsThePlugInToTheStatusBarOnly() async throws {
        #expect(DiskNotices.isOff(.notDetermined) && DiskNotices.isOff(.denied) && DiskNotices.isOff(.provisional))
        #expect(!DiskNotices.isOff(.authorized) && !DiskNotices.isOff(.authorized, alert: .disabled) && !DiskNotices.isOff(.authorized, list: .disabled))
        #expect(DiskNotices.isOff(.authorized, alert: .disabled, list: .disabled), "allowed with no banner and no list reaches nobody")
        let rig = NoticeRig("failed", choice: .statusBar)
        let host = rig.host()
        defer { host.close() }
        rig.notices.status = .notDetermined
        rig.store.set(NewDiskChoice.notification.rawValue, forKey: NewDiskChoice.key)
        await rig.plugIn(disk)
        try await host.until("the line and its Index button") {
            host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil
        }
        #expect(rig.notices.asks == 1)
        #expect(rig.notices.posted.isEmpty, "a notice went out that nobody can see")
    }

    @Test func notificationsTurnedOffMoveTheWaitingDiskToTheBarWhenTheAppBecomesActive() async throws {
        let rig = NoticeRig("activate.off", choice: .notification)
        let host = rig.host()
        defer { host.close() }
        await rig.plugIn(disk)
        try await untilTrue(waitingFor: "the notice") { rig.notices.shown == [disk.id] }
        try await rig.settle(1)
        try await host.until("the bar") { host.windowShows("Files: 1") }
        #expect(!host.windowShows(line), "an allowed notice also put the disk in the bar")

        rig.notices.status = .denied
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await host.until("the line after the app becomes active") {
            host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil
        }
        try await untilTrue(waitingFor: "the notice withdrawn") { rig.notices.shown.isEmpty }
        #expect(rig.notices.posted == ["Disk 1"])
    }

    @Test func notificationsTurnedBackOnKeepTheBarsDiskAndNoticeTheNextPlugIn() async throws {
        let rig = NoticeRig("activate.on", choice: .notification)
        rig.notices.status = .denied
        let host = rig.host()
        defer { host.close() }
        await rig.plugIn(disk)
        try await host.until("the line") { host.windowShows(line) }

        rig.notices.status = .authorized
        let reads = rig.notices.reads
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await untilTrue(waitingFor: "the permission read again") { rig.notices.reads > reads }
        try await rig.settle(1)
        try await host.until("the bar") { host.windowShows("Files: 1") }
        #expect(host.windowShows(line), "the disk left the bar when notifications came back on")
        #expect(rig.notices.posted.isEmpty, "the disk in the bar got a late notice")

        await rig.plugIn(disk2, beside: [disk])
        try await untilTrue(waitingFor: "the second disk's notice") { rig.notices.posted == ["Disk 2"] }
        try await rig.settle(2)
        try await host.until("the bar") { host.windowShows("Files: 2") }
        #expect(host.windowShows(line), "the held disk left the bar")
        #expect(!host.windowShows("\(Bidi.name(disk2.name)) is not indexed") && !host.windowShows("disks are not indexed"), "the noticed disk is in the bar too")
    }

    @Test func pickingTheNotificationAnswerKeepsTheBarsDisks() async throws {
        let rig = NoticeRig("answer.hold", choice: .statusBar)
        let host = rig.host()
        defer { host.close() }
        await rig.plugIn(disk)
        try await host.until("the line") { host.windowShows(line) }
        rig.store.set(NewDiskChoice.notification.rawValue, forKey: NewDiskChoice.key)
        try await untilTrue(waitingFor: "the permission read") { rig.notices.reads >= 1 }
        try await rig.settle(1)
        try await host.until("the bar") { host.windowShows("Files: 1") }
        #expect(host.windowShows(line), "the pick took the disk out of the bar")

        await rig.plugIn(disk2, beside: [disk])
        try await untilTrue(waitingFor: "the second disk's notice") { rig.notices.posted == ["Disk 2"] }
        try await rig.settle(2)
        try await host.until("the bar") { host.windowShows("Files: 2") }
        #expect(host.windowShows(line) && !host.windowShows("\(Bidi.name(disk2.name)) is not indexed"))
    }

    @Test func aRefusedPostSendsThePlugInToTheStatusBar() async throws {
        let rig = NoticeRig("post.refused", choice: .notification)
        let host = rig.host()
        defer { host.close() }
        rig.notices.failsPosts = true
        await rig.plugIn(disk)
        try await host.until("the line and its Index button") {
            host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil
        }
        #expect(rig.notices.steps.contains("post Disk 1") && rig.notices.posted.isEmpty)
    }

    @Test func aNoticeWhoseDiskLeavesWhileItIsPostedIsWithdrawnOnceItArrives() async throws {
        let rig = NoticeRig("withdraw.inflight", choice: .notification)
        rig.notices.holds = true
        defer { rig.notices.release() }
        await rig.plugIn(disk)
        try await untilTrue(waitingFor: "the post on its way") { rig.notices.held.count == 1 }
        rig.list([])
        try await rig.settle(1)
        rig.notices.release()
        try await untilTrue(waitingFor: "the post returned") { rig.notices.posted == ["Disk 1"] }
        #expect(rig.notices.shown.isEmpty, "the ejected disk's notice stayed up")
    }

    @Test func ejectingOrSwitchingOnADiskWithdrawsItsNotice() async throws {
        let rig = NoticeRig("withdraw", choice: .notification)
        await rig.plugIn(disk)
        try await untilTrue(waitingFor: "the first notice") { rig.notices.shown == [disk.id] }
        await rig.plugIn(disk2)
        try await untilTrue(waitingFor: "the second notice") { rig.notices.posted == ["Disk 1", "Disk 2"] }
        #expect(rig.notices.shown == [disk2.id], "the ejected disk kept its notice, or the waiting one lost it")

        rig.list([IndexedVolume(id: disk2.id, name: disk2.name, path: disk2.path, indexed: true)])
        try await rig.settle(1)
        #expect(rig.notices.shown.isEmpty, "the disk switched on kept its notice")
    }

    @Test func leavingTheNotificationAnswerWithdrawsItsNotices() async throws {
        let rig = NoticeRig("withdraw.answer", choice: .notification)
        let host = rig.host()
        defer { host.close() }
        await rig.plugIn(disk)
        try await untilTrue(waitingFor: "the notice") { rig.notices.shown == [disk.id] }
        rig.store.set(NewDiskChoice.statusBar.rawValue, forKey: NewDiskChoice.key)
        try await host.until("the line in the bar") { host.windowShows(line) }
        try await untilTrue(waitingFor: "the notice withdrawn") { rig.notices.shown.isEmpty }
    }

    @Test func askInTheStatusBarPostsNoNotice() async throws {
        let rig = NoticeRig("notice.statusbar", choice: .statusBar)
        await rig.plugIn(disk)
        try await rig.settle(1)
        #expect(rig.index.waitingDisks == [disk])
        #expect(rig.notices.posted.isEmpty && rig.notices.asks == 0)
    }

    @Test func mountUnderTheCacheRaisesNoDiskNotice() async throws {
        let rig = NoticeRig("cache.mount", choice: .notification)
        let point = URL.cachesDirectory.appending(path: AppIdentity.bundleIdentifier + "/Archives/Mounts/dmg.Ab12Cd", directoryHint: .isDirectory)
        rig.mounts.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: point])
        await drainMain()
        rig.list([])
        try await rig.settle(1)
        #expect(rig.notices.posted.isEmpty, "a disk image under the cache posted a notice")
        #expect(rig.index.waitingDisks.isEmpty && rig.fake.switchedOn.isEmpty && rig.storedIndexed.isEmpty)

        await rig.plugIn(disk)
        try await untilTrue(waitingFor: "the notice for a real disk") { rig.notices.posted == ["Disk 1"] }
    }

    @Test func indexAutomaticallySwitchesThePlugInOnWithNoQuestion() async throws {
        let rig = NoticeRig("automatic", choice: .index, atLaunch: [disk])
        try await rig.settle(1)
        #expect(rig.fake.switchedOn.isEmpty, "a disk listed at launch was switched on")
        rig.list([])

        await rig.plugIn(disk)
        try await untilTrue(waitingFor: "the switch") { rig.fake.switchedOn == [[disk.id]] }
        #expect(rig.storedIndexed == [disk.id])
        #expect(rig.notices.posted.isEmpty && rig.confirm.asked.isEmpty)
    }

    @Test func doNothingShowsNothingAndAsksNothing() async throws {
        let rig = NoticeRig("nothing", choice: .nothing, atLaunch: [disk])
        let host = rig.host()
        defer { host.close() }
        await rig.plugIn(disk)
        try await rig.settle(1)
        try await host.until("the bar") { host.windowShows("Files: 1") }
        #expect(!host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) == nil)
        #expect(rig.notices.posted.isEmpty && rig.fake.switchedOn.isEmpty && rig.storedIndexed.isEmpty)

        rig.store.set(NewDiskChoice.statusBar.rawValue, forKey: NewDiskChoice.key)
        try await host.until("the line once the choice asks in the status bar") { host.windowShows(line) }
    }

    @Test(arguments: ["statusBar", "notification", "index", "nothing"])
    func aDiskWithNoUUIDGetsNoLineNoNoticeAndNoSwitch(_ raw: String) async throws {
        let choice = try #require(NewDiskChoice(rawValue: raw))
        let rig = NoticeRig("nouuid.\(raw)", choice: choice, atLaunch: [noUUID])
        let host = rig.host()
        defer { host.close() }
        await rig.plugIn(noUUID)
        try await rig.settle(1)
        try await host.until("the bar") { host.windowShows("Files: 1") }
        #expect(!host.windowShows("\(Bidi.name(noUUID.name)) is not indexed") && AXTree.element(StatusBarView.indexDiskID, in: host.view) == nil)
        #expect(rig.index.waitingDisks.isEmpty)
        #expect(rig.notices.posted.isEmpty && rig.fake.switchedOn.isEmpty && rig.storedIndexed.isEmpty)
    }

    @Test(arguments: ["statusBar", "notification", "index", "nothing"])
    func aDiskUnderAnExcludedRowGetsNoOfferNoNoticeAndNoSwitch(_ raw: String) async throws {
        let choice = try #require(NewDiskChoice(rawValue: raw))
        let rig = NoticeRig("covered.\(raw)", choice: choice)
        rig.store.set(["/Volumes"], forKey: LocationsModel.Key.excluded)
        await rig.plugIn(disk)
        try await rig.settle(1)
        #expect(rig.index.waitingDisks.isEmpty, "the bar offers a disk its row keeps out")
        #expect(rig.notices.posted.isEmpty && rig.fake.switchedOn.isEmpty && rig.storedIndexed.isEmpty)

        rig.confirm.replies = [true]
        rig.index.indexDisk(disk)
        rig.index.noticeAnswered(DiskNotices.indexAction, diskID: disk.id)
        try await rig.settle(2)
        #expect(rig.confirm.asked.isEmpty, "Index asked about a disk its row keeps out")
        #expect(rig.fake.switchedOn.isEmpty && rig.storedIndexed.isEmpty, "Index switched the disk on behind its row")
    }

    @Test func removingTheRowOffersTheDiskAgain() async throws {
        let rig = NoticeRig("covered.removed", choice: .statusBar, atLaunch: [disk])
        try await untilTrue(waitingFor: "the disk in the bar") { rig.index.waitingDisks == [disk] }
        rig.store.set(["/Volumes"], forKey: LocationsModel.Key.excluded)
        try await untilTrue(waitingFor: "the disk out of the bar under its row") { rig.index.waitingDisks.isEmpty }
        rig.store.set([String](), forKey: LocationsModel.Key.excluded)
        try await untilTrue(waitingFor: "the disk back in the bar") { rig.index.waitingDisks == [disk] }
        #expect(rig.notices.posted.isEmpty && rig.fake.switchedOn.isEmpty, "a removed row posted a notice or switched the disk on")
    }

    @Test func aRowHidesADiskExactlyAsTheEngineReadsIt() throws {
        let store = noticeDefaults("rowrule")
        func hides(_ row: String, _ volume: IndexedVolume = disk) -> Bool {
            store.set([row], forKey: LocationsModel.Key.excluded)
            let model = LocationsModel(client: FakeSearchClient(), defaults: store, chooseFolder: { nil })
            let (offer, note) = (LocationsModel.covered(volume, store), model.hidingRow(of: volume) != nil)
            #expect(offer == note, "\(row): the offer and the Settings note disagree")
            return offer
        }
        for row in ["/Volumes", "/Volumes/", "/Volumes//", "/Volumes/.", "/Volumes/Disk 1", "/Volumes/Disk 1/", "/"] {
            #expect(hides(row), "\(row) leaves the disk free")
        }
        for row in ["/Vol", "/Vol/", "/Volumes/Disk 1/Sub", "/Volumes/Disk 2", "/Volumes/Disk 11"] {
            #expect(!hides(row), "\(row) hides the disk")
        }

        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("rowrule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tree) }
        for name in ["Disks/Disk 1", "Other"] { try FileManager.default.createDirectory(at: tree.appendingPathComponent(name), withIntermediateDirectories: true) }
        let real = try #require(realpath(tree.path, nil).map { p -> String in defer { free(p) }; return String(cString: p) })
        let volume = IndexedVolume(id: disk.id, name: "Disk 1", path: real + "/Disks/Disk 1", indexed: false)
        for (name, target) in [("up", "Disks"), ("exact", "Disks/Disk 1"), ("beside", "Other"), ("dangling", "Gone")] {
            try FileManager.default.createSymbolicLink(atPath: tree.path + "/" + name, withDestinationPath: real + "/" + target)
        }
        #expect(hides(real + "/Disks/Disk 1", volume), "a row equal to the disk root")
        #expect(hides(tree.path + "/up", volume), "a link to a folder above the disk")
        #expect(hides(tree.path + "/up/", volume), "that link with a trailing slash")
        #expect(hides(tree.path + "/exact", volume), "a link to the disk root")
        #expect(!hides(tree.path + "/beside", volume), "a link to a folder beside the disk")
        #expect(!hides(tree.path + "/dangling", volume), "a link to nothing stays as given")
    }

    @Test func aRowWithATrailingSlashKeepsTheDiskOutOfTheBar() async throws {
        let rig = NoticeRig("covered.slash", choice: .statusBar, atLaunch: [disk])
        try await untilTrue(waitingFor: "the disk in the bar") { rig.index.waitingDisks == [disk] }
        rig.store.set(["/Volumes/"], forKey: LocationsModel.Key.excluded)
        try await untilTrue(waitingFor: "the disk out of the bar under its row") { rig.index.waitingDisks.isEmpty }
    }

    @Test func theLocationsPaneShowsTheStoredChoice() async throws {
        let store = noticeDefaults("pane")
        let model = LocationsModel(client: FakeSearchClient(), defaults: store, chooseFolder: { nil })
        let host = SearchHost(root: AnyView(LocationsPane(model: model).environment(\.locale, english).defaultAppStorage(store)))
        defer { host.close() }
        func value() -> String? {
            AXTree.element(LocationsPane.newDiskID, in: host.view).flatMap { (node: NSObject) -> String? in AXTree.value("accessibilityValue", of: node) }
        }
        try await host.until("the pop-up on its default, read \(value() ?? "nothing")") { value() == "Ask in the Status Bar" }
        #expect(host.windowShows("When a disk that isn’t indexed is connected"))
        store.set(NewDiskChoice.index.rawValue, forKey: NewDiskChoice.key)
        try await host.until("the pop-up on the stored choice, read \(value() ?? "nothing")") { value() == "Index Automatically" }
    }

    private static func paneHost(_ store: UserDefaults, _ notices: Notices) -> SearchHost {
        let model = LocationsModel(client: FakeSearchClient(), defaults: store, chooseFolder: { nil }, notices: notices.calls)
        return SearchHost(root: AnyView(LocationsPane(model: model).environment(\.locale, english).defaultAppStorage(store)))
    }

    @Test func pickingTheNotificationAnswerAsksOnceAndNoOtherAnswerAsks() async throws {
        let store = noticeDefaults("pane.asks")
        let notices = Notices()
        let host = Self.paneHost(store, notices)
        defer { host.close() }
        try await host.until("the pop-up") { AXTree.element(LocationsPane.newDiskID, in: host.view) != nil }
        #expect(notices.asks == 0, "showing the pane asked")

        for (item, choice) in [(2, NewDiskChoice.index), (3, .nothing), (0, .statusBar)] {
            try await AXTree.choose(try #require(AXTree.element(LocationsPane.newDiskID, in: host.view)), item: item)
            try await host.until("\(choice) stored") { store.string(forKey: NewDiskChoice.key) == choice.rawValue }
        }
        await drainMain()
        #expect(notices.asks == 0, "another answer asked for permission")

        try await AXTree.choose(try #require(AXTree.element(LocationsPane.newDiskID, in: host.view)), item: 1)
        try await host.until("the notification answer stored") { store.string(forKey: NewDiskChoice.key) == NewDiskChoice.notification.rawValue }
        try await untilTrue(waitingFor: "the permission question") { notices.asks == 1 }
        await drainMain()
        #expect(notices.asks == 1, "one pick asked twice")
    }

    @Test func aRefusedPermissionShowsTheCaptionOnlyUnderTheNotificationAnswer() async throws {
        let caption = "Notifications for Wherever are turned off. Allow them in System Settings > Notifications."
        let store = noticeDefaults("pane.caption")
        store.set(NewDiskChoice.notification.rawValue, forKey: NewDiskChoice.key)
        let notices = Notices()
        let host = Self.paneHost(store, notices)
        defer { host.close() }
        try await host.until("the pop-up") { AXTree.element(LocationsPane.newDiskID, in: host.view) != nil }
        await drainMain()
        #expect(!host.windowShows(caption), "the caption showed while notifications are allowed")

        notices.status = .denied
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await host.until("the caption after the app becomes active") {
            host.windowShows(caption) && AXTree.element(LocationsPane.notificationsOffID, in: host.view) != nil
        }
        #expect(notices.asks == 0, "reading the setting asked for permission")

        store.set(NewDiskChoice.statusBar.rawValue, forKey: NewDiskChoice.key)
        try await host.until("no caption under another answer") { !host.windowShows(caption) }
    }

    @Test func theCaptionRuleIgnoresAQuestionNotYetAnswered() {
        #expect(!DiskNotices.needsSystemSettings(.notDetermined))
        #expect(DiskNotices.needsSystemSettings(.denied))
        #expect(DiskNotices.needsSystemSettings(.authorized, alert: .disabled, list: .disabled))
        #expect(!DiskNotices.needsSystemSettings(.authorized, alert: .enabled, list: .disabled))
        #expect(!DiskNotices.needsSystemSettings(.authorized, alert: .disabled, list: .enabled))
        #expect(!DiskNotices.needsSystemSettings(.authorized))
    }

    @Test func theCaptionStaysHiddenWhileThePermissionQuestionIsOpen() async throws {
        let caption = "Notifications for Wherever are turned off. Allow them in System Settings > Notifications."
        let store = noticeDefaults("pane.caption.undetermined")
        store.set(NewDiskChoice.notification.rawValue, forKey: NewDiskChoice.key)
        let notices = Notices()
        notices.status = .notDetermined
        let host = Self.paneHost(store, notices)
        defer { host.close() }
        try await host.until("the pop-up") { AXTree.element(LocationsPane.newDiskID, in: host.view) != nil }
        await drainMain()
        #expect(!host.windowShows(caption), "the caption showed before the user answered macOS's question")

        notices.status = .denied
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await host.until("the caption once refused") { host.windowShows(caption) }
    }

    @Test func twoWaitingDisksShareOneCountedLineWithManage() async throws {
        let rig = NoticeRig("bar.count", atLaunch: [disk, disk2])
        let host = rig.host()
        defer { host.close() }
        let manage = { AXTree.element(StatusBarView.manageDisksID, in: host.view) }
        try await host.until("the counted line and Manage…") { host.windowShows("2 disks are not indexed") && manage() != nil }
        #expect(!host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) == nil, "the bar still named one disk")

        try #require(AXTree.press(try #require(manage())))
        try await untilTrue(waitingFor: "Manage… to open Settings > Locations") { rig.manage.count == 1 }
        #expect(rig.confirm.asked.isEmpty && rig.fake.switchedOn.isEmpty, "Manage… switched a disk on")

        rig.list([disk2])
        try await host.until("one disk back on its own line with Index") {
            host.windowShows("\(Bidi.name(disk2.name)) is not indexed") && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil
                && manage() == nil && !host.windowShows("disks are not indexed")
        }
        rig.list([disk, disk2, IndexedVolume(id: "B3", name: "Disk 3", path: "/Volumes/Disk 3", indexed: false)])
        try await host.until("three disks counted") { host.windowShows("3 disks are not indexed") }
    }

    @Test func showingSettingsOnLocationsOpensThatPane() async throws {
        let client = FakeSearchClient()
        let settings = SettingsWindow(
            launchAtLogin: .inert(),
            locations: LocationsModel(client: client, defaults: noticeDefaults("show.locations"), chooseFolder: { nil }),
            hotkey: HotkeyModel(defaults: noticeDefaults("show.hotkey"), windows: { [] }, unhide: {}, activate: {}),
            client: client, defaults: noticeDefaults("show.store"), open: { _ in }, activate: {}
        )
        defer { settings.close() }
        settings.selection.pane = .about
        settings.show(.locations)
        #expect(settings.selection.pane == .locations)
        let detail = settings.split.splitViewItems[1].viewController.view
        try await untilTrue(waitingFor: "the Locations pane") {
            detail.layoutSubtreeIfNeeded()
            return AXTree.element(SettingsPane.locations.paneID, in: detail) != nil
        }
        settings.show()
        #expect(settings.selection.pane == .locations, "a plain show moved off the pane")
    }

    @Test func theCountedLineFollowsEachLanguagesPlurals() throws {
        func text(_ count: Int, _ language: String, _ locale: Locale) throws -> String {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            return String(localized: "\(count) disks are not indexed", table: "Results", bundle: bundle, locale: locale)
        }
        let cases = [
            (2, "en", "2 disks are not indexed"), (3, "ru", "3 диска не проиндексированы"), (5, "ru", "5 дисков не проиндексировано"),
            (2, "ar", "قرصان غير مفهرسين"), (3, "ar", "3 أقراص غير مفهرسة"), (2, "pl", "2 dyski nie są zindeksowane"),
            (5, "pl", "5 dysków nie jest zindeksowanych"), (2, "de", "2 Festplatten sind nicht indiziert"),
        ]
        for (count, language, expected) in cases {
            for localeID in numberingLocaleIDs(language) {
                let locale = Locale(identifier: localeID)
                let found = try text(count, language, locale)
                #expect(found == locale.digits(expected), "\(localeID), \(count): \(found)")
            }
        }
        for language in ["tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"] {
            for localeID in numberingLocaleIDs(language) {
                let locale = Locale(identifier: localeID)
                let (found, englishText) = (try text(4, language, locale), try text(4, "en", english))
                #expect(found.contains(locale.digits("4")) && found != englishText, "\(localeID): \(found)")
            }
            let manage = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)))
                .localizedString(forKey: "Manage…", value: "\u{1}", table: "Results")
            #expect(manage != "\u{1}" && manage != "Manage…", "\(language): \(manage)")
        }
    }

    @Test func aRealClickReachesAnAppKitControlInTheSameHost() async throws {
        let rig = NoticeRig("click.control")
        rig.store.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
        let model = rig.index.makeModel()
        let host = rig.host(model, reportsKey: true)
        defer { host.close() }
        try await host.until("the Search Content button") { AXTree.element(NormalForm.searchContentID, in: host.view) != nil }
        try #require(host.window.isKeyWindow)
        model.content = ContentTerms(terms: ["alpha"])
        try await host.until("the Search Content button enabled") { AXTree.element(NormalForm.searchContentID, in: host.view).flatMap(AXTree.isEnabled) == true }
        let hit = try await realClick(NormalForm.searchContentID, in: host)
        try await untilTrue(waitingFor: "Search Content to start a press; \(hit)") { rig.fake.presses.count == 1 }
    }

    @Test func aRealClickOnManageOpensLocations() async throws {
        let rig = NoticeRig("click.manage", atLaunch: [disk, disk2])
        let host = rig.host(reportsKey: true)
        defer { host.close() }
        try await host.until("the counted line and Manage…") {
            host.windowShows("2 disks are not indexed") && AXTree.element(StatusBarView.manageDisksID, in: host.view) != nil
        }
        try #require(host.window.isKeyWindow)
        let hit = try await realClick(StatusBarView.manageDisksID, in: host)
        try await untilTrue(waitingFor: "Manage… to open Settings > Locations; \(hit)") { rig.manage.count == 1 }
        await drainMain()
        #expect(rig.manage.count == 1, "one click opened Locations \(rig.manage.count) times; \(hit)")
        #expect(rig.confirm.asked.isEmpty && rig.fake.switchedOn.isEmpty, "Manage… switched a disk on; \(hit)")
    }

    @Test func aRealClickOnManageLandsOnLocationsInARealSettingsWindow() async throws {
        let client = FakeSearchClient()
        let settings = SettingsWindow(
            launchAtLogin: .inert(),
            locations: LocationsModel(client: client, defaults: noticeDefaults("click.locations"), chooseFolder: { nil }),
            hotkey: HotkeyModel(defaults: noticeDefaults("click.hotkey"), windows: { [] }, unhide: {}, activate: {}),
            client: client, defaults: noticeDefaults("click.store"), open: { _ in }, activate: {}
        )
        defer { settings.close() }
        settings.selection.pane = .about
        let rig = NoticeRig("click.settings", atLaunch: [disk, disk2], opens: { settings.show(.locations) })
        let host = rig.host(reportsKey: true)
        defer { host.close() }
        try await host.until("Manage…") { AXTree.element(StatusBarView.manageDisksID, in: host.view) != nil }
        try #require(host.window.isKeyWindow)
        let hit = try await realClick(StatusBarView.manageDisksID, in: host)
        try await untilTrue(waitingFor: "Settings to show; \(hit)") { settings.window?.isVisible == true }
        #expect(settings.selection.pane == .locations, "Settings opened on \(settings.selection.pane); \(hit)")
        let detail = settings.split.splitViewItems[1].viewController.view
        try await untilTrue(waitingFor: "the Locations pane; \(hit)") {
            detail.layoutSubtreeIfNeeded()
            return AXTree.element(SettingsPane.locations.paneID, in: detail) != nil
        }
    }

    @Test func aRealClickOnIndexAsksAndCancelChangesNothing() async throws {
        let rig = NoticeRig("click.index", atLaunch: [disk])
        let host = rig.host(reportsKey: true)
        defer { host.close() }
        try await host.until("the line and its Index button") {
            host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil
        }
        try #require(host.window.isKeyWindow)
        let hit = try await realClick(StatusBarView.indexDiskID, in: host)
        try await untilTrue(waitingFor: "Index to ask; \(hit)") { rig.confirm.asked == ["Disk 1"] }
        try await rig.settle(1)
        #expect(rig.fake.switchedOn.isEmpty && rig.storedIndexed.isEmpty, "a cancelled Index switched the disk on; \(hit)")
        #expect(host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil, "the line went after Cancel")
    }

    @Test func theIndexLinkFollowsTheTextSize() async throws {
        let rig = NoticeRig("bar.size", atLaunch: [disk])
        rig.store.set(TextSize.extraLarge.rawValue, forKey: TextSize.key)
        let host = rig.host()
        defer { host.close() }
        try await host.until("the line and its Index button") {
            host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil
        }
        func link(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == StatusBarView.indexDiskID { return button }
            return view.subviews.lazy.compactMap(link).first
        }
        let button = try #require(link(in: host.view))
        let title = try #require(button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(title.pointSize == 14)
        #expect(button.font?.pointSize == 14)

        rig.store.set(TextSize.standard.rawValue, forKey: TextSize.key)
        try await host.until("the link back at 11 pt") { button.font?.pointSize == 11 }
    }

    @Test func theNoticeKeepsTheBarHeight() async throws {
        let rig = NoticeRig("click.height", atLaunch: [disk, disk2])
        let model = rig.index.makeModel()
        let bar = AnyView(StatusBarView(index: rig.index, model: model).environment(\.locale, english).defaultAppStorage(rig.store))
        let host = SearchHost(root: bar)
        defer { host.close() }
        try await host.until("the counted line and Manage…") {
            host.windowShows("2 disks are not indexed") && AXTree.element(StatusBarView.manageDisksID, in: host.view) != nil
        }
        let height = NSHostingView(rootView: bar).fittingSize.height
        #expect(height == 1 + StatusBarView.lineHeight(.standard) + 2 * SearchMetrics.statusVerticalInset, "the bar is \(height) pt with the notice")
    }

    @Test func theFailedSentenceWrapsToTheWidthLeftOfTheNotice() async throws {
        let rig = NoticeRig("failed.notice", atLaunch: [disk])
        let model = rig.index.makeModel()
        rig.fake.send(.stateChanged(IndexState(phase: .failed, bootPhase: .failed, indexed: 10)))
        let sentence = "Wherever could not build the index. Choose Quit Wherever from the Wherever menu, then open Wherever again."
        let font = StatusBarView.font(.standard)
        func lines(_ width: CGFloat) -> Int {
            let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: sentence, attributes: [.font: font]))
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
            return CFArrayGetCount(CTFrameGetLines(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)))
        }
        let typographic = ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: sentence, attributes: [.font: font])), nil, nil, nil)))
        let width = 2 * SearchMetrics.sideInset + typographic + SearchMetrics.statusItemSpacing
        let bar = AnyView(StatusBarView(index: rig.index, model: model).environment(\.locale, english).defaultAppStorage(rig.store).frame(width: width))
        let host = SearchHost(root: bar)
        defer { host.close() }
        try await host.until("the failed sentence beside the line and its Index button") {
            rig.index.indexState?.bootPhase == .failed && host.windowShows(line) && AXTree.element(StatusBarView.indexDiskID, in: host.view) != nil
        }
        let text = try #require(AXTree.element(StatusBarView.diskNoticeID, in: host.view).flatMap(AXTree.frame(of:)))
        let button = try #require(AXTree.element(StatusBarView.indexDiskID, in: host.view).flatMap(AXTree.frame(of:)))
        let notice = button.maxX - text.minX
        let left = width - 2 * SearchMetrics.sideInset - SearchMetrics.statusItemSpacing - notice
        #expect(lines(width - 2 * SearchMetrics.sideInset) == 1)
        #expect(lines(left) > 1, "the sentence fits \(left) pt beside a \(notice) pt notice")
        let height = NSHostingView(rootView: bar).fittingSize.height
        #expect(height == 1 + CGFloat(lines(left) + 1) * StatusBarView.lineHeight(.standard) + 2 * SearchMetrics.statusVerticalInset,
            "the bar is \(height) pt for \(lines(left)) sentence lines in \(left) pt")
    }
}
