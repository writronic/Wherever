import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
import UserNotifications
@testable import Wherever
import WhereverInterface

private func freshDefaults(_ name: String) -> UserDefaults { freshSuite(name).defaults }

private func freshSuite(_ name: String) -> (defaults: UserDefaults, domain: String) {
    let domain = "com.writronic.wherever.tests.wiring.\(name)"
    let defaults = UserDefaults(suiteName: domain)!
    defaults.removePersistentDomain(forName: domain)
    return (defaults, domain)
}

private func services(
    _ client: FakeSearchClient, defaults: UserDefaults, presence: AppPresence = WhereverApp.presence, linger: CommandLinger = WhereverApp.linger
) -> AppServices {
    WhereverApp.services(
        client: client, archiveClient: FakeArchiveClient(search: client), defaults: defaults,
        hotkey: HotkeyModel(defaults: defaults, windows: { [] }, unhide: {}, activate: {}),
        launchAtLogin: .inert(), updates: .idle,
        commandLine: .inert(), presence: presence, linger: linger
    )
}

private final class TitledWindow: NSWindow {
    convenience init() {
        self.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }
}

private final class IdleRig {
    let client = FakeSearchClient()
    let center = NotificationCenter()
    let presence: AppPresence
    let launch = Launch()
    let delegate = AppDelegate()
    let linger: CommandLinger
    let defaults: UserDefaults
    var updating = false
    var quits = 0
    private(set) var access: AccessModel?

    init(_ name: String, previews: Bool = false, launched: Bool = true, answer: NewDiskChoice? = nil, paused: Bool = false) {
        defaults = freshDefaults("idle.\(name)")
        if let answer { defaults.set(answer.rawValue, forKey: NewDiskChoice.key) }
        if paused { defaults.set(true, forKey: IndexModel.pausedKey) }
        let presence = AppPresence(center: center) { _ in }
        self.presence = presence
        let linger = CommandLinger(seconds: 600) { presence.quitIfIdle() }
        self.linger = linger
        let (client, defaults) = (client, defaults)
        launch.start { services(client, defaults: defaults, presence: presence, linger: linger) }
        delegate.terminate = { [weak self] in self?.quits += 1 }
        WhereverApp.bind(delegate: delegate, launch: launch, presence: presence, previews: previews, linger: linger) { [weak self] in self?.updating == true }
        if launched { launchFinished() }
    }

    func launchFinished() {
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    func engine(_ phase: IndexPhase) async throws {
        client.send(.stateChanged(IndexState(phase: phase, indexed: 6)))
        let index = launch.services!.index
        try await untilTrue(waitingFor: "the state \(phase)") { index.indexState?.phase == phase }
        try await turn()
    }

    var launcher: Launcher { launch.services!.launcher }

    func openWindow() -> TitledWindow {
        let window = TitledWindow()
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        return window
    }

    func close(_ window: NSWindow) { center.post(name: NSWindow.willCloseNotification, object: window) }

    func turn() async throws { try await pumpEvents(for: .milliseconds(20)) }

    func finishLaunch(command: HelperCommand?, mounted: [String] = [], stage: AccessModel.Stage = .ready) {
        let access = AccessModel(defaults: defaults, center: NotificationCenter(), stage: stage, probe: { .granted }, confirm: { true }, start: {}, summon: {}, activate: {})
        self.access = access
        WhereverApp.finishLaunch(launch: launch, access: access, previews: false, presence: presence, command: command, mounted: mounted, linger: linger)
    }

    func end() {
        linger.timer?.invalidate()
        launcher.hide()
        launcher.panel?.contentView = nil
    }
}

private let wakeDisk = IndexedVolume(id: "5F2A6C3E-0B1D-4C7A-9E58-2D4B7A91C0E3", name: "Disk 1", path: "/Volumes/Disk 1", indexed: false)

@Suite(.serialized) struct AppWiringTests {
    @Test func theStartSendsTheStoredTypoSwitch() {
        for stored in [true, false] {
            let defaults = freshDefaults("typo.\(stored)")
            defaults.set(stored, forKey: TypoSearchRow.key)
            let client = FakeSearchClient()
            _ = services(client, defaults: defaults)
            #expect(client.typos == [stored], "stored \(stored)")
        }
    }

    @Test func aStartWithNothingStoredSendsTheSwitchOff() {
        let client = FakeSearchClient()
        _ = services(client, defaults: freshDefaults("typo.empty"))
        #expect(client.typos == [false])
    }

    @Test func theServicesPushTheStoredPauseToTheEngine() {
        let paused = freshDefaults("pause.push")
        paused.set(true, forKey: IndexModel.pausedKey)
        let stopped = FakeSearchClient()
        _ = services(stopped, defaults: paused)
        #expect(stopped.liveUpdates == [false])

        let live = FakeSearchClient()
        _ = services(live, defaults: freshDefaults("pause.push.empty"))
        #expect(live.liveUpdates == [true])
    }

    @Test func theServicesKeepThePauseInTheirOwnDefaultsAndABareModelKeepsItInMemory() {
        func ownerPause() -> Bool? {
            UserDefaults.standard.persistentDomain(forName: AppIdentity.bundleIdentifier)?[IndexModel.pausedKey] as? Bool
        }
        let before = ownerPause()
        let defaults = freshDefaults("pause.stored")
        defaults.set(true, forKey: IndexModel.pausedKey)
        let client = FakeSearchClient()
        let index = services(client, defaults: defaults).index
        #expect(index.liveUpdatesPaused)
        index.toggleLiveUpdates()
        #expect(client.liveUpdates == [false, true])
        #expect(defaults.object(forKey: IndexModel.pausedKey) as? Bool == false)
        #expect(ownerPause() == before)

        let bare = IndexModel(client: FakeSearchClient())
        #expect(!bare.liveUpdatesPaused)
        bare.toggleLiveUpdates()
        #expect(bare.liveUpdatesPaused)
        #expect(ownerPause() == before)
    }

    @Test func theLaunchAppliesTheStoredAppearance() {
        for (stored, applied) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let (defaults, domain) = freshSuite("appearance.\(stored)")
            defer { defaults.removePersistentDomain(forName: domain) }
            defaults.set(stored, forKey: AppearanceMode.key)
            var appearances: [NSAppearance.Name?] = []
            WhereverApp.prepareLaunch(previews: false, defaults: defaults) { appearances.append($0?.name) }
            #expect(appearances == [applied], "\(stored)")
        }
    }

    @Test func aResetWhileDarkLaunchesInTheSystemLook() {
        let (defaults, domain) = freshSuite("appearance.reset")
        defaults.set("dark", forKey: AppearanceMode.key)
        defaults.set(true, forKey: Relaunch.pendingKey)
        var removals = 0
        var appearances: [NSAppearance.Name?] = []
        _ = WhereverApp.launchPresence(previews: false, defaults: defaults, domain: domain, center: NotificationCenter()) { removals += 1 }
        WhereverApp.prepareLaunch(previews: false, defaults: defaults) { appearances.append($0?.name) }
        #expect(removals == 1)
        #expect(appearances == [nil])
    }

    @Test func thePrepareStepLeavesAPendingResetToThePresence() {
        let (defaults, domain) = freshSuite("appearance.prepare")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("dark", forKey: AppearanceMode.key)
        defaults.set(true, forKey: Relaunch.pendingKey)
        var appearances: [NSAppearance.Name?] = []
        WhereverApp.prepareLaunch(previews: false, defaults: defaults) { appearances.append($0?.name) }
        #expect(appearances == [.darkAqua])
        #expect(defaults.bool(forKey: Relaunch.pendingKey))
        #expect(defaults.string(forKey: AppearanceMode.key) == "dark")
    }

    @Test func previewsApplyNoAppearanceAndKeepThePendingReset() {
        let (defaults, domain) = freshSuite("appearance.previews")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("dark", forKey: AppearanceMode.key)
        defaults.set(true, forKey: Relaunch.pendingKey)
        var removals = 0
        var appearances: [NSAppearance.Name?] = []
        _ = WhereverApp.launchPresence(previews: true, defaults: defaults, domain: domain, center: NotificationCenter()) { removals += 1 }
        WhereverApp.prepareLaunch(previews: true, defaults: defaults) { appearances.append($0?.name) }
        #expect(removals == 0)
        #expect(appearances.isEmpty)
        #expect(defaults.bool(forKey: Relaunch.pendingKey))
    }

    @Test func theDocksQuitWithTheIconOnAndTheEngineUpEndsWhereverAndKeepsThePause() {
        let rig = IdleRig("dock")
        defer { rig.end() }
        rig.defaults.set(true, forKey: MenuBarIcon.key)
        rig.defaults.set(true, forKey: AccessModel.completedKey)
        rig.defaults.set(true, forKey: IndexModel.pausedKey)
        #expect(rig.launch.services != nil)
        #expect(rig.delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        rig.delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(rig.defaults.bool(forKey: IndexModel.pausedKey))
    }

    @Test func aQuitSavesTheOpenHistoryOnce() {
        let rig = IdleRig("flush")
        defer { rig.end() }
        #expect(rig.client.flushes == 0)
        rig.delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(rig.client.flushes == 1)
    }

    @Test func theLauncherHidingWithNoWindowQuitsWhenTheHoldEnds() async throws {
        let rig = IdleRig("hide")
        defer { rig.end() }
        rig.launcher.show()
        rig.presence.quitIfIdle()
        try await rig.turn()
        #expect(rig.quits == 0, "the launcher shows")
        rig.launcher.hide()
        #expect(rig.quits == 0, "the quit ran inside hide()")
        try await rig.turn()
        #expect(rig.quits == 0, "a second click had no time to reach Wherever")
        try await untilTrue(within: .seconds(NSEvent.doubleClickInterval + 2), waitingFor: "the quit after the hold") { rig.quits == 1 }
    }

    @Test func aPressDuringTheHoldKeepsWhereverAndTheNextHideHoldsAgain() async throws {
        let rig = IdleRig("hide.again")
        defer { rig.end() }
        rig.launcher.show()
        rig.launcher.hide()
        try await rig.turn()
        #expect(rig.quits == 0)
        rig.launcher.show()
        try await pumpEvents(for: .seconds(NSEvent.doubleClickInterval + 1.2))
        #expect(rig.quits == 0, "the first hold ended under an open launcher")
        rig.launcher.hide()
        try await rig.turn()
        #expect(rig.quits == 0)
        try await untilTrue(within: .seconds(NSEvent.doubleClickInterval + 2), waitingFor: "the quit after the second hold") { rig.quits == 1 }
    }

    @Test func theLauncherHidingWithSettingsOpenStaysAndTheWindowsCloseQuits() async throws {
        let rig = IdleRig("settings")
        defer { rig.end() }
        let settings = rig.openWindow()
        rig.launcher.show()
        rig.launcher.hide()
        try await rig.turn()
        #expect(rig.quits == 0)
        rig.close(settings)
        try await rig.turn()
        #expect(rig.quits == 0)
        try await untilTrue(within: .seconds(NSEvent.doubleClickInterval + 2), waitingFor: "the quit after the hold") { rig.quits == 1 }
    }

    @Test func theLastWindowClosingWithTheLauncherShownStaysUntilItHides() async throws {
        let rig = IdleRig("shown")
        defer { rig.end() }
        let window = rig.openWindow()
        rig.launcher.show()
        rig.close(window)
        try await rig.turn()
        #expect(rig.quits == 0)
        rig.launcher.hide()
        try await rig.turn()
        #expect(rig.quits == 0)
        try await untilTrue(within: .seconds(NSEvent.doubleClickInterval + 2), waitingFor: "the quit after the hold") { rig.quits == 1 }
    }

    @Test func aSparkleSessionHoldsTheIdleQuitAndItsEndQuits() async throws {
        let rig = IdleRig("sparkle")
        defer { rig.end() }
        let session = PassthroughSubject<Bool, Never>()
        let watch = WhereverApp.quitsWhenSessionEnds(session, presence: rig.presence)
        defer { watch.cancel() }
        rig.updating = true
        session.send(true)
        rig.presence.quitIfIdle()
        try await rig.turn()
        #expect(rig.quits == 0)
        rig.updating = false
        session.send(false)
        #expect(rig.quits == 0, "the quit ran inside the session's end")
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test func aSparkleSessionEndingWithAWindowOpenStays() async throws {
        let rig = IdleRig("sparkle.window")
        defer { rig.end() }
        let session = PassthroughSubject<Bool, Never>()
        let watch = WhereverApp.quitsWhenSessionEnds(session, presence: rig.presence)
        defer { watch.cancel() }
        let window = rig.openWindow()
        session.send(false)
        try await rig.turn()
        #expect(rig.quits == 0)
        rig.close(window)
    }

    @Test func aServeStartQuitsWhenItsLingerEndsWithNoAnswer() async throws {
        let rig = IdleRig("serve.off")
        defer { rig.end() }
        rig.finishLaunch(command: .serve)
        #expect(rig.linger.running)
        rig.presence.quitIfIdle()
        try await rig.turn()
        #expect(rig.quits == 0, "the linger runs")
        rig.linger.timer?.fire()
        #expect(!rig.linger.running)
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test func eachCommandDoneRestartsTheLingerAndTheLastOneIsWhatEndsIt() async throws {
        let rig = IdleRig("serve.done")
        defer { rig.end() }
        rig.finishLaunch(command: .serve)
        let first = try #require(rig.linger.timer)
        rig.linger.commandDone()
        let second = try #require(rig.linger.timer)
        #expect(first !== second && !first.isValid)
        #expect(second.fireDate >= first.fireDate)
        try await rig.turn()
        #expect(rig.quits == 0)
        second.fire()
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test func aServeStartsLingerEndingWithAWindowOpenStaysUntilItCloses() async throws {
        let rig = IdleRig("serve.window")
        defer { rig.end() }
        rig.finishLaunch(command: .serve)
        let window = rig.openWindow()
        rig.linger.timer?.fire()
        try await rig.turn()
        #expect(rig.quits == 0)
        rig.close(window)
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test func theLingerLastsTenSecondsAndOnlyAServeStartArmsIt() {
        let linger = CommandLinger {}
        linger.start()
        defer { linger.timer?.invalidate() }
        let left = linger.timer?.fireDate.timeIntervalSinceNow ?? 0
        #expect(left > 9 && left <= 10)

        for command in [HelperCommand.launcher, .settings, .shortcuts, .wake, nil] as [HelperCommand?] {
            let rig = IdleRig("serve.only.\(String(describing: command))")
            defer { rig.end() }
            rig.finishLaunch(command: command)
            #expect(!rig.linger.running, "\(String(describing: command))")
            rig.linger.commandDone()
            #expect(!rig.linger.running, "a done with no linger armed one, \(String(describing: command))")
        }
    }

    @Test func aCommandDoneNotificationRestartsTheLingerOnlyForThisApp() async throws {
        let path = "/nowhere/\(UUID().uuidString)/Wherever.app"
        let linger = CommandLinger(seconds: 600) {}
        defer { linger.timer?.invalidate() }
        linger.observeDone(path: path)
        linger.start()
        let first = try #require(linger.timer)
        HelperLink.post(HelperLink.Note.commandDone, object: "/nowhere/other/Wherever.app")
        try await pumpEvents(for: .milliseconds(100))
        #expect(linger.timer === first)
        HelperLink.post(HelperLink.Note.commandDone, object: path)
        try await untilTrue(waitingFor: "the restarted linger") { linger.timer !== first }
    }

    @Test func theLauncherHidingDuringACrawlStaysAndTheSettledStateQuits() async throws {
        let rig = IdleRig("settle.hide")
        defer { rig.end() }
        rig.client.setSettling(true)
        try await rig.engine(.crawling)
        rig.launcher.show()
        rig.launcher.hide()
        try await pumpEvents(for: .seconds(NSEvent.doubleClickInterval + 1.2))
        #expect(rig.quits == 0, "the idle quit threw the crawl away")
        try await rig.engine(.finishing)
        #expect(rig.quits == 0)
        rig.client.setSettling(false)
        try await rig.engine(.ready)
        #expect(rig.quits == 1)
    }

    @Test(arguments: [IndexPhase.ready, .live, .failed])
    func aSettledPhaseWithNothingOpenQuits(_ phase: IndexPhase) async throws {
        let rig = IdleRig("settle.\(phase)")
        defer { rig.end() }
        rig.client.setSettling(true)
        try await rig.engine(.loading)
        #expect(rig.quits == 0)
        rig.client.setSettling(false)
        try await rig.engine(phase)
        #expect(rig.quits == 1)
    }

    @Test func aStateWithAWindowOpenStaysAndTheWindowClosingDuringReadyQuits() async throws {
        let rig = IdleRig("settle.window")
        defer { rig.end() }
        let window = rig.openWindow()
        try await rig.engine(.ready)
        #expect(rig.quits == 0)
        rig.close(window)
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test func aStateBeforeTheLaunchFinishedNeverQuits() async throws {
        let rig = IdleRig("settle.early", launched: false)
        defer { rig.end() }
        try await rig.engine(.ready)
        #expect(rig.quits == 0, "a cold launcher or command start quit before it could show")
        rig.launchFinished()
        try await rig.engine(.live)
        #expect(rig.quits == 1)
    }

    @Test func aPauseThatEndsTheWaitQuits() async throws {
        let rig = IdleRig("settle.pause")
        defer { rig.end() }
        rig.client.setSettling(true)
        rig.presence.quitIfIdle()
        try await rig.turn()
        #expect(rig.quits == 0)
        rig.client.setSettling(false)
        rig.launch.services!.index.toggleLiveUpdates()
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test func aLingerEndingDuringACrawlStaysAndACommandDoneArmsItAgain() async throws {
        let rig = IdleRig("settle.linger")
        defer { rig.end() }
        rig.client.setSettling(true)
        rig.finishLaunch(command: .serve)
        try await rig.engine(.crawling)
        rig.linger.timer?.fire()
        try await rig.turn()
        #expect(!rig.linger.running)
        #expect(rig.quits == 0, "the command's retry saw Wherever quit under it")
        rig.linger.commandDone()
        #expect(rig.linger.running, "one script's next call would find Wherever gone")
        rig.linger.timer?.fire()
        try await rig.turn()
        #expect(rig.quits == 0)
    }

    @Test func theEngineSettlingAfterTheLingerEndedLeavesTheRetryItsAnswer() async throws {
        let rig = IdleRig("settle.retry")
        defer { rig.end() }
        rig.client.setSettling(true)
        rig.finishLaunch(command: .serve)
        try await rig.engine(.crawling)
        rig.linger.timer?.fire()
        try await rig.turn()
        rig.client.setSettling(false)
        try await rig.engine(.ready)
        #expect(rig.quits == 0, "the retry, 0.1 s away, would find no socket and fail")
        #expect(rig.linger.running)
        rig.linger.timer?.fire()
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test func anExplicitQuitDuringACrawlTerminatesAndStillFlushes() async throws {
        let rig = IdleRig("settle.explicit")
        defer { rig.end() }
        rig.client.setSettling(true)
        try await rig.engine(.crawling)
        #expect(rig.delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        rig.delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(rig.client.flushes == 1)
    }

    @Test func aWakeStartWithNothingDueAndNoNewDiskQuitsOnTheNextTurn() async throws {
        let rig = IdleRig("wake.nothing")
        defer { rig.end() }
        rig.finishLaunch(command: .wake)
        #expect(rig.quits == 0, "the quit ran before the turn Sparkle's start was queued ahead of")
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test func aWakeStartWithASparkleSessionRunningStaysUntilItEnds() async throws {
        let rig = IdleRig("wake.sparkle")
        defer { rig.end() }
        let session = PassthroughSubject<Bool, Never>()
        let watch = WhereverApp.quitsWhenSessionEnds(session, presence: rig.presence)
        defer { watch.cancel() }
        rig.updating = true
        session.send(true)
        rig.finishLaunch(command: .wake)
        try await rig.turn()
        #expect(rig.quits == 0)
        rig.updating = false
        session.send(false)
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test func sparklesFallingEdgeBeforeACheckThatIsDueLeavesAWakeRunning() async throws {
        let rig = IdleRig("wake.overdue")
        defer { rig.end() }
        let session = PassthroughSubject<Bool, Never>()
        let watch = WhereverApp.quitsWhenSessionEnds(session, presence: rig.presence)
        defer { watch.cancel() }
        rig.updating = true
        session.send(true)
        rig.finishLaunch(command: .wake)
        try await rig.turn()
        rig.updating = false
        session.send(false)
        rig.updating = true
        session.send(true)
        try await rig.turn()
        #expect(rig.quits == 0, "SPUUpdater.m:547,588: the interval probe ends and the check starts in one block")
    }

    @Test func aWakeStartWithANewDiskAndIndexAutomaticallyIndexesItBeforeItQuits() async throws {
        let rig = IdleRig("wake.index", answer: .index)
        defer { rig.end() }
        rig.client.setVolumes(.success([wakeDisk]))
        rig.client.setSettling(true)
        rig.finishLaunch(command: .wake, mounted: [wakeDisk.path + "/"])
        #expect(rig.client.switchedOn == [[wakeDisk.id]])
        try await rig.turn()
        #expect(rig.quits == 0, "the crawl of the new disk was cut off")
        rig.client.setSettling(false)
        try await rig.engine(.ready)
        #expect(rig.quits == 1)
    }

    @Test func aTimerWakeLeavesADiskListedAtLaunchAlone() async throws {
        let rig = IdleRig("wake.notnow", answer: .index)
        defer { rig.end() }
        rig.client.setVolumes(.success([wakeDisk]))
        rig.finishLaunch(command: .wake)
        try await rig.turn()
        #expect(rig.client.switchedOn.isEmpty)
        #expect(rig.quits == 1)
    }

    @Test func aWakeStartWithADiskImageTheListLeavesOutIndexesNothingAndQuits() async throws {
        let rig = IdleRig("wake.image", answer: .index)
        defer { rig.end() }
        rig.finishLaunch(command: .wake, mounted: ["/Volumes/Installer/"])
        try await rig.turn()
        #expect(rig.client.switchedOn.isEmpty)
        #expect(rig.quits == 1)
    }

    @Test(arguments: ["not-now", UNNotificationDismissActionIdentifier])
    func aNoticeHoldsAWakeUntilItIsAnswered(_ action: String) async throws {
        let rig = IdleRig("wake.notice.\(action)", answer: .notification)
        defer { rig.end() }
        rig.client.setVolumes(.success([wakeDisk]))
        rig.finishLaunch(command: .wake, mounted: [wakeDisk.path])
        let index = rig.launch.services!.index
        #expect(index.noticeWaits, "the hold starts before the permission and the post are awaited")
        try await rig.turn()
        try await rig.engine(.ready)
        #expect(rig.quits == 0)
        index.noticeAnswered(action, diskID: wakeDisk.id)
        #expect(!index.noticeWaits)
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test func aNoticeForADiskThatLeavesEndsTheHold() async throws {
        let rig = IdleRig("wake.notice.eject", answer: .notification)
        defer { rig.end() }
        rig.client.setVolumes(.success([wakeDisk]))
        rig.finishLaunch(command: .wake, mounted: [wakeDisk.path])
        try await rig.turn()
        #expect(rig.quits == 0)
        rig.client.setVolumes(.success([]))
        rig.client.send(.volumesChanged)
        let index = rig.launch.services!.index
        try await untilTrue(waitingFor: "the hold to end") { !index.noticeWaits }
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test func aNoticeClickOpeningLocationsDuringAWakeWaitsForTheWindow() async throws {
        let rig = IdleRig("wake.notice.click", answer: .notification)
        defer {
            rig.launch.services?.settings.close()
            rig.end()
        }
        rig.client.setVolumes(.success([wakeDisk]))
        rig.finishLaunch(command: .wake, mounted: [wakeDisk.path])
        try await rig.turn()
        rig.launch.services!.index.noticeAnswered(UNNotificationDefaultActionIdentifier, diskID: wakeDisk.id)
        #expect(rig.presence.awaitingWindow)
        try await rig.turn()
        #expect(rig.quits == 0, "the click quit Wherever before Settings could show")
    }

    @Test func aMountThatArrivesDuringAStartActsLikeOneHeardByTheRunningCopy() async throws {
        let rig = IdleRig("wake.launching", answer: .index)
        defer { rig.end() }
        rig.client.setVolumes(.success([wakeDisk]))
        rig.launch.services!.index.diskMounted(at: wakeDisk.path)
        #expect(rig.client.switchedOn == [[wakeDisk.id]])
    }

    @Test func aWakeAfterARevokeShowsNoWelcomeAndQuits() async throws {
        let rig = IdleRig("wake.revoked")
        defer { rig.end() }
        rig.finishLaunch(command: .wake, stage: .waiting)
        #expect(rig.access?.welcome == nil, "a wake put the Full Disk Access page on screen by itself")
        #expect(!rig.presence.awaitingWindow)
        try await rig.turn()
        #expect(rig.quits == 1)
    }

    @Test(arguments: [true, false])
    func aWakeChangesNothingAboutThePause(_ paused: Bool) async throws {
        let rig = IdleRig("wake.pause.\(paused)", paused: paused)
        defer { rig.end() }
        let index = rig.launch.services!.index
        #expect(index.liveUpdatesPaused == paused)
        rig.finishLaunch(command: .wake)
        try await rig.turn()
        #expect(rig.defaults.bool(forKey: IndexModel.pausedKey) == paused)
        #expect(index.liveUpdatesPaused == paused)
    }

    @Test func previewsNeverGetAQuit() async throws {
        let rig = IdleRig("previews", previews: true)
        defer { rig.end() }
        rig.launcher.show()
        rig.launcher.hide()
        rig.presence.quitIfIdle()
        try await rig.turn()
        #expect(rig.quits == 0)
    }

    @Test func aRouteWithADialogInFrontLeavesNothingAwaited() async throws {
        let rig = IdleRig("dialog.showall")
        defer { rig.launcher.hide() }
        let presence = AppPresence(center: NotificationCenter()) { _ in }
        let access = AccessModel(defaults: freshDefaults("dialog"), center: NotificationCenter(), stage: .ready, probe: { .granted }, confirm: { true }, start: {}, summon: {}, activate: {})
        let dialog = TitledWindow()
        let dialogs = ModalWindowCoordinator(windows: { [dialog] }, isActive: { true }, beep: {})
        var opened = 0
        let routes = WhereverApp.routes(
            access: access, summon: { opened += 1 }, openWindow: { opened += 1 }, showSettings: {}, activate: {}, open: { _ in }, quit: {},
            presence: presence, dialogs: dialogs
        )
        dialogs.start()
        dialogs.register(dialog)
        defer { dialog.close() }
        routes.menu.summon()
        #expect(!presence.awaitingWindow)
        routes.menu.newWindow()
        #expect(!presence.awaitingWindow)
        #expect(opened == 0)
        rig.launcher.show()
        rig.launcher.model.query = "rep"
        rig.launcher.showAll = WhereverApp.showAll(newWindow: routes.menu.newWindow, dialogs: dialogs)
        rig.launcher.showAll()
        try await rig.turn()
        #expect(rig.launcher.panel?.isVisible == true)
        #expect(rig.launcher.model.query == "rep")
        #expect(!presence.awaitingWindow)
        #expect(opened == 0)
        dialog.close()
        routes.menu.summon()
        #expect(presence.awaitingWindow)
        #expect(opened == 1)
    }
}
