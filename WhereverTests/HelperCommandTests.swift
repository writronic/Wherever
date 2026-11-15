import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private let willFinish = Notification(name: NSApplication.willFinishLaunchingNotification)
private let didFinish = Notification(name: NSApplication.didFinishLaunchingNotification)
private let willTerminate = Notification(name: NSApplication.willTerminateNotification)

private final class CommandTally {
    var policies: [NSApplication.ActivationPolicy] = []
    var regulars = 0
    var events: [String] = []
    var replies: [NSApplication.TerminateReply] = []
    var spoken: [String] = []
}

private final class CommandRig {
    let fake = FakeSearchClient()
    let store: UserDefaults
    let storeName = "com.writronic.wherever.tests.helpercommands.\(UUID().uuidString)"
    let launch = Launch(windowless: true)
    let delegate = AppDelegate()
    let commands = HelperCommands()
    let tally: CommandTally
    let presence: AppPresence
    let announcer: Announcer
    private(set) var access: AccessModel!

    lazy var hotkey = HotkeyModel(defaults: store, windows: { [] }, unhide: {}, activate: {})

    lazy var services: AppServices = {
        let index = IndexModel(client: fake, announcer: announcer, defaults: store, pauseStore: store)
        let settings = SettingsWindow(
            launchAtLogin: .inert(), locations: LocationsModel(client: fake, defaults: store), hotkey: hotkey, client: fake,
            defaults: store, open: { _ in }, activate: {}
        )
        return AppServices(
            client: fake, archiveClient: PreviewArchiveClient(),
            archives: ArchiveWindows(client: PreviewArchiveClient(), index: index, actions: ActionRecorder().actions, cache: FileManager.default.temporaryDirectory.appending(path: "archive-\(UUID().uuidString)", directoryHint: .isDirectory)), index: index, settings: settings,
            launcher: Launcher(index: index, actions: ActionRecorder().actions, defaults: store)
        )
    }()

    init(command: HelperCommand? = nil, stage: AccessModel.Stage = .ready) {
        store = UserDefaults(suiteName: storeName)!
        let tally = CommandTally()
        self.tally = tally
        presence = AppPresence(center: NotificationCenter(), apply: { tally.policies.append($0) })
        announcer = Announcer(post: { _, text in tally.spoken.append(text) }, schedule: { work in work() })
        access = AccessModel(
            defaults: store, center: NotificationCenter(), stage: stage, probe: { .denied }, confirm: { true },
            start: { [weak self] in
                guard let self else { return }
                launch.start { services }
            },
            summon: {}, open: { _ in true }, quit: {}, activate: { tally.events.append("welcome") }
        )
        let routes = WhereverApp.routes(
            access: access, summon: {}, openWindow: { tally.events.append("window") }, showSettings: { tally.events.append("settings") },
            activate: {}, open: { _ in }, quit: {},
            launcher: { [launch] in launch.services?.launcher.toggle() },
            keyboardShortcuts: { tally.events.append("shortcuts") }, presence: presence
        )
        commands.run = HelperCommands.route(
            access: access, launch: launch, menu: routes.menu, hotkey: routes.hotkey,
            stop: { [weak delegate] in delegate?.quitFromHelper() },
            activate: { tally.events.append("front") }, synchronize: { tally.events.append("sync") }
        )
        delegate.launchCommand = command
        delegate.setRegular = { tally.regulars += 1 }
        delegate.terminate = { [weak delegate] in
            guard let delegate else { return }
            tally.replies.append(delegate.applicationShouldTerminate(NSApp))
        }
        delegate.finishLaunch = { [launch, access, presence, commands] in
            WhereverApp.finishLaunch(
                launch: launch, access: access!, previews: false, presence: presence, command: command, commands: commands
            )
        }
    }

    var launcher: Launcher? { launch.services?.launcher }
    var panelShown: Bool { launcher?.panel?.isVisible == true }

    func storePause(_ paused: Bool) { store.set(paused, forKey: IndexModel.pausedKey) }

    func start() {
        delegate.applicationWillFinishLaunching(willFinish)
        delegate.applicationDidFinishLaunching(didFinish)
    }

    func welcomeShown() async throws {
        try await untilTrue(waitingFor: "the welcome") { access.welcome?.window?.isVisible == true }
    }

    func close() {
        access.welcome?.close()
        launcher?.hide()
        launcher?.panel?.contentView = nil
        launch.services?.settings.close()
        store.removePersistentDomain(forName: storeName)
    }
}

@Suite(.serialized) struct HelperCommandTests {
    @Test func theLiveUpdatesCommandFollowsTheKeyOnceAndTheBarAndVoiceFollow() async throws {
        let rig = CommandRig()
        defer { rig.close() }
        rig.start()
        let index = try #require(rig.launch.services?.index)
        let host = SearchHost(
            root: AnyView(
                StatusBarView(index: index, model: index.makeModel(), clearsBackground: false)
                    .environment(\.locale, Locale(identifier: "en")).defaultAppStorage(rig.store)
            ),
            reportsKey: true
        )
        defer { host.close() }
        rig.announcer.watch(host.view)
        rig.fake.send(.stateChanged(IndexState(phase: .ready, indexed: 10)))
        try await untilTrue(waitingFor: "the index at ready") { index.indexState?.bootPhase == .ready }

        rig.storePause(true)
        rig.commands.receive(.liveUpdates)
        #expect(rig.tally.events == ["sync"])
        #expect(rig.fake.liveUpdates == [false])
        #expect(index.liveUpdatesPaused)
        try await untilTrue(waitingFor: "the paused bar") { host.windowShows("Live updates paused") }
        try await untilTrue(waitingFor: "the spoken state; got \(rig.tally.spoken)") { rig.tally.spoken == [StatusBarView.text(.live, paused: true)] }

        rig.commands.receive(.liveUpdates)
        #expect(rig.fake.liveUpdates == [false], "the same stored value called the engine again")

        rig.storePause(false)
        rig.commands.receive(.liveUpdates)
        #expect(rig.fake.liveUpdates == [false, true])
        #expect(!index.liveUpdatesPaused)
    }

    @Test func aRefusedLiveUpdatesWritesTheRealStateBack() throws {
        let rig = CommandRig()
        defer { rig.close() }
        rig.start()
        let index = try #require(rig.launch.services?.index)
        rig.fake.fail(with: .io)
        rig.storePause(true)
        rig.commands.receive(.liveUpdates)
        #expect(!index.liveUpdatesPaused)
        #expect(rig.store.object(forKey: IndexModel.pausedKey) as? Bool == false)
        #expect(rig.fake.liveUpdates.isEmpty)
    }

    @Test func withoutServicesTheLiveUpdatesCommandSendsNothing() async throws {
        let rig = CommandRig(stage: .waiting)
        defer { rig.close() }
        rig.start()
        try await rig.welcomeShown()
        rig.storePause(true)
        rig.commands.receive(.liveUpdates)
        #expect(rig.tally.events == ["sync"])
        #expect(rig.launch.services == nil)
        #expect(rig.fake.liveUpdates.isEmpty)
    }

    @Test func aColdLauncherShowsASecondColdKeepsItAndARunningOneToggles() {
        let rig = CommandRig(command: .launcher)
        defer { rig.close() }
        rig.start()
        #expect(rig.panelShown)
        rig.commands.run(.launcher, true)
        #expect(rig.panelShown)
        rig.commands.receive(.launcher)
        #expect(!rig.panelShown)
        rig.commands.receive(.launcher)
        #expect(rig.panelShown)
        #expect(!rig.tally.events.contains("front"))
    }

    @Test func aPressDuringTheLoadRunsAfterTheArgumentAndEndsHidden() {
        let rig = CommandRig(command: .launcher)
        defer { rig.close() }
        rig.commands.receive(.launcher)
        #expect(rig.launcher?.panel == nil)
        rig.start()
        #expect(rig.launcher?.panel != nil, "the argument never showed the panel")
        #expect(!rig.panelShown)
    }

    @Test func anEarlyCommandWaitsForTheEndOfTheLaunch() {
        let rig = CommandRig()
        defer { rig.close() }
        rig.commands.receive(.settings)
        rig.commands.receive(.launcher)
        #expect(rig.tally.events.isEmpty)
        #expect(rig.launcher?.panel == nil)
        rig.start()
        #expect(rig.tally.events == ["settings", "front"])
        #expect(rig.panelShown)
    }

    @Test func aClickWhileThePanelShowsEndsHidden() throws {
        let rig = CommandRig()
        defer { rig.close() }
        rig.start()
        let launcher = try #require(rig.launcher)
        launcher.show()
        #expect(rig.panelShown)
        rig.commands.receive(.launcher)
        #expect(!rig.panelShown)
        launcher.keyMoved(to: nil)
        #expect(!rig.panelShown)
    }

    @Test func aLauncherCommandWithoutAccessShowsTheWelcomeAndNoPanel() async throws {
        for cold in [true, false] {
            let rig = CommandRig(command: cold ? .launcher : nil, stage: .waiting)
            defer { rig.close() }
            rig.start()
            if !cold { rig.commands.receive(.launcher) }
            try await rig.welcomeShown()
            #expect(rig.tally.events == ["welcome", "front"], "cold \(cold)")
            #expect(rig.launch.services == nil)
            #expect(rig.tally.policies.last == .regular, "cold \(cold)")
        }
    }

    @Test func aColdLauncherStartNeverLeavesAccessoryAndOpensNoWindow() {
        let rig = CommandRig(command: .launcher)
        defer { rig.close() }
        rig.delegate.applicationWillFinishLaunching(willFinish)
        #expect(rig.tally.regulars == 0)
        #expect(rig.tally.policies.isEmpty)
        rig.delegate.applicationDidFinishLaunching(didFinish)
        #expect(rig.launch.windowless)
        #expect(rig.panelShown)
        #expect(rig.tally.regulars == 0)
        #expect(rig.tally.policies.isEmpty)
        #expect(rig.tally.events.isEmpty)
    }

    @Test func aColdWakeIsAWindowlessAccessoryAndShowsNothing() {
        let rig = CommandRig(command: .wake)
        defer { rig.close() }
        rig.delegate.applicationWillFinishLaunching(willFinish)
        #expect(rig.tally.regulars == 0)
        #expect(rig.tally.policies.isEmpty)
        rig.delegate.applicationDidFinishLaunching(didFinish)
        #expect(rig.launch.windowless)
        #expect(!rig.panelShown)
        #expect(rig.tally.regulars == 0)
        #expect(rig.tally.policies.isEmpty)
        #expect(rig.tally.events.isEmpty)
    }

    @Test func aColdWakeAfterARevokeKeepsTheWelcomeShut() {
        let rig = CommandRig(command: .wake, stage: .waiting)
        defer { rig.close() }
        rig.start()
        #expect(rig.access.welcome == nil)
        #expect(rig.tally.regulars == 0)
        #expect(rig.tally.policies.isEmpty)
        #expect(rig.tally.events.isEmpty)
    }

    @Test func aLauncherPressDuringAWakeStartShowsThePanel() {
        let rig = CommandRig(command: .wake)
        defer { rig.close() }
        rig.commands.receive(.launcher)
        rig.start()
        #expect(rig.panelShown, "the press was lost in a wake")
    }

    @Test func aWakeToARunningWhereverChangesNothing() {
        let rig = CommandRig()
        defer { rig.close() }
        rig.start()
        let policies = rig.tally.policies
        rig.commands.receive(.wake)
        #expect(rig.tally.events.isEmpty && !rig.panelShown)
        #expect(rig.tally.policies == policies)
    }

    @Test func theMountedPostReachesTheCommandsObserver() async throws {
        let rig = CommandRig()
        defer { rig.close() }
        let path = "/tests/helpercommands/\(UUID().uuidString)"
        var heard: [[String]] = []
        rig.commands.mounted = { heard.append($0) }
        rig.commands.observe(path: path)
        HelperLink.postMounted(["/Volumes/Disk 1"], object: path)
        try await untilTrue(waitingFor: "the post") { !heard.isEmpty }
        #expect(heard == [["/Volumes/Disk 1"]])
    }

    @Test func aColdServeIsAWindowlessAccessoryAndShowsNothing() {
        let rig = CommandRig(command: .serve)
        defer { rig.close() }
        rig.delegate.applicationWillFinishLaunching(willFinish)
        #expect(rig.tally.regulars == 0)
        #expect(rig.tally.policies.isEmpty)
        rig.delegate.applicationDidFinishLaunching(didFinish)
        #expect(rig.launch.windowless)
        #expect(rig.launch.services != nil)
        #expect(rig.launcher?.panel == nil)
        #expect(rig.tally.events.isEmpty)
        #expect(rig.tally.regulars == 0)
        #expect(rig.tally.policies.isEmpty)
    }

    @Test func onlyTheLauncherServeAndWakeStartHidden() {
        #expect(!HelperCommands.startsHidden(nil))
        for command in HelperCommand.allCases {
            #expect(HelperCommands.startsHidden(command) == [.launcher, .serve, .wake].contains(command), "\(command)")
        }
    }

    @Test func everyStartThatIsNotHiddenGoesRegularOnceInWillFinishLaunching() {
        let commands: [HelperCommand?] = [nil] + HelperCommand.allCases.map { Optional($0) }
        for command in commands {
            let rig = CommandRig(command: command)
            defer { rig.close() }
            rig.delegate.applicationWillFinishLaunching(willFinish)
            #expect(rig.tally.regulars == (HelperCommands.startsHidden(command) ? 0 : 1), "\(String(describing: command))")
        }
    }

    @Test func aColdShortcutsOpensOnlyThatWindowThenComesToTheFront() {
        let rig = CommandRig(command: .shortcuts)
        defer { rig.close() }
        rig.delegate.applicationWillFinishLaunching(willFinish)
        #expect(rig.tally.regulars == 1)
        #expect(rig.tally.policies.isEmpty)
        rig.delegate.applicationDidFinishLaunching(didFinish)
        #expect(rig.launch.windowless)
        #expect(rig.tally.events == ["shortcuts", "front"])
        #expect(rig.tally.policies.last == .regular)
        #expect(!rig.tally.policies.contains(.accessory))
    }

    @Test func aColdSettingsOpensOnlySettingsThenComesToTheFront() {
        let rig = CommandRig(command: .settings)
        defer { rig.close() }
        rig.delegate.applicationWillFinishLaunching(willFinish)
        #expect(rig.tally.regulars == 1)
        #expect(rig.tally.policies.isEmpty)
        rig.delegate.applicationDidFinishLaunching(didFinish)
        #expect(rig.launch.windowless)
        #expect(rig.tally.events == ["settings", "front"])
        #expect(rig.tally.policies.last == .regular)
        #expect(!rig.tally.policies.contains(.accessory))
    }

    @Test func aColdSettingsWithoutAccessShowsOnlyTheWelcome() async throws {
        let rig = CommandRig(command: .settings, stage: .waiting)
        defer { rig.close() }
        rig.start()
        try await rig.welcomeShown()
        #expect(rig.tally.events == ["welcome", "front"])
    }

    @Test func theQuitCommandEndsWhereverWithTheIconOn() {
        let rig = CommandRig()
        defer { rig.close() }
        rig.start()
        rig.commands.receive(.quit)
        #expect(rig.tally.replies == [.terminateNow])
    }

    @Test func onlyAQuitCommandPostsHelperQuitAtTermination() {
        let probe = QuitProbe()
        var posts = 0
        probe.delegate.postHelperQuit = { posts += 1 }
        probe.delegate.terminate()
        probe.delegate.applicationWillTerminate(willTerminate)
        #expect(posts == 0)
        probe.delegate.quitFromHelper()
        #expect(probe.terminations == [.terminateNow, .terminateNow])
        probe.delegate.applicationWillTerminate(willTerminate)
        #expect(posts == 1)
    }

    @Test func aCancelledQuitCommandLeavesALaterQuitWithoutHelperQuit() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        let probe = QuitProbe()
        var posts = 0
        probe.delegate.postHelperQuit = { posts += 1 }
        probe.delegate.quitFromHelper()
        #expect(probe.terminations == [.terminateLater])
        try await rig.press(ArchiveWindows.unsavedCancelID, on: window)
        try await probe.replied([false])

        probe.delegate.terminate()
        #expect(probe.terminations == [.terminateLater, .terminateLater])
        try await rig.press(ArchiveWindows.unsavedDontSaveID, on: window)
        try await probe.replied([false, true])
        probe.delegate.applicationWillTerminate(willTerminate)
        #expect(posts == 0)
    }

    @Test func aQuitCommandAnsweredWithDontSavePostsHelperQuit() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        let probe = QuitProbe()
        var posts = 0
        probe.delegate.postHelperQuit = { posts += 1 }
        probe.delegate.quitFromHelper()
        try await rig.press(ArchiveWindows.unsavedDontSaveID, on: window)
        try await probe.replied([true])
        probe.delegate.applicationWillTerminate(willTerminate)
        #expect(posts == 1)
    }
}
