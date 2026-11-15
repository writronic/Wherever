import AppKit
import Combine
import Dispatch
import Foundation
import os
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private final class LaunchSpy {
    var policies: [NSApplication.ActivationPolicy] = []
    var loginReads = 0
    var regulars = 0
    var activations: [Bool] = []
}

private final class LoginLaunchRig {
    let fake = FakeSearchClient()
    let spy: LaunchSpy
    let presence: AppPresence
    let launch: Launch
    let delegate = AppDelegate()
    let grant = OSAllocatedUnfairLock(initialState: false)
    let store: UserDefaults
    let storeName = "com.writronic.wherever.tests.login.\(UUID().uuidString)"
    private(set) var access: AccessModel!
    private(set) var roots: [SearchHost] = []
    private(set) var opened: [SearchHost] = []
    private(set) var statesAtOpen: [Bool] = []
    private(set) var settingsOpens = 0
    private(set) var starts = 0

    lazy var hotkey = HotkeyModel(
        defaults: store,
        windows: { [weak self] in self?.roots.map(\.window) ?? [] }, unhide: {}, activate: {}
    )

    lazy var services: AppServices = {
        let index = IndexModel(client: fake)
        let settings = SettingsWindow(
            launchAtLogin: .inert(),
            locations: LocationsModel(client: fake, defaults: store), hotkey: hotkey, client: fake,
            defaults: store, open: { _ in }, activate: {}
        )
        return AppServices(
            client: fake, archiveClient: PreviewArchiveClient(),
            archives: ArchiveWindows(client: PreviewArchiveClient(), index: index, actions: ActionRecorder().actions, cache: FileManager.default.temporaryDirectory.appending(path: "archive-\(UUID().uuidString)", directoryHint: .isDirectory)), index: index, settings: settings,
            launcher: Launcher(index: index, actions: ActionRecorder().actions, defaults: store)
        )
    }()

    lazy var routes = WhereverApp.routes(
        access: access, summon: { [weak self] in self?.hotkey.summon() },
        openWindow: WhereverApp.windowOpener(launch: launch) { [weak self] in
            guard let self else { return }
            statesAtOpen.append(launch.windowless)
            opened.append(hostRoot())
        },
        showSettings: { [weak self] in self?.settingsOpens += 1 }, activate: {}, open: { _ in }, quit: {},
        launcher: { [weak self] in self?.launch.services?.launcher.toggle() },
        closeLauncher: { [weak self] in self?.launch.services?.launcher.prepareHandOff() }
    )

    init(windowless: Bool = true, stage: AccessModel.Stage = .ready, confirms: Bool = true, finishLaunching: Bool = true) {
        launch = Launch(windowless: true)
        store = UserDefaults(suiteName: storeName)!
        let spy = LaunchSpy()
        self.spy = spy
        presence = AppPresence(center: NotificationCenter(), apply: { spy.policies.append($0) })
        let grant = grant
        access = AccessModel(
            defaults: store, center: NotificationCenter(), stage: stage, probe: { grant.withLock { $0 } ? .granted : .denied }, confirm: { confirms },
            start: { [weak self] in
                guard let self else { return }
                starts += 1
                launch.start { services }
            },
            summon: { [weak self] in self?.hotkey.summon() }, open: { _ in true }, quit: {}, activate: {}
        )
        delegate.launchCommand = windowless ? .serve : nil
        delegate.setRegular = { spy.regulars += 1 }
        delegate.refreshLoginStatus = { spy.loginReads += 1 }
        delegate.finishLaunch = { [launch, access, presence] in
            WhereverApp.finishLaunch(
                launch: launch, access: access!, previews: false, presence: presence, command: windowless ? .serve : nil,
                activate: { spy.activations.append(launch.windowless) }
            )
        }
        if finishLaunching { finish() }
        hotkey.configure(openWindow: routes.window)
        launch.services?.launcher.showAll = routes.menu.newWindow
    }

    func finish() {
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    @discardableResult
    func hostRoot() -> SearchHost {
        let host = SearchHost(root: AnyView(LaunchRoot(launch: launch, access: access, delegate: delegate).defaultAppStorage(store)))
        host.window.identifier = NSUserInterfaceItemIdentifier(MainWindow.id)
        roots.append(host)
        return host
    }

    func close() {
        access.welcome?.close()
        launch.services?.launcher.hide()
        launch.services?.launcher.panel?.contentView = nil
        launch.services?.settings.close()
        for root in roots { root.close() }
        store.removePersistentDomain(forName: storeName)
    }
}

@Suite(.serialized) struct LoginLaunchTests {
    private func field(in host: SearchHost) async throws -> NSSearchField {
        try await host.until("the search field") { host.field() != nil }
        return try #require(host.field())
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func expectClosed(_ host: SearchHost) async throws {
        try await host.until("the gate to hide its window") { host.window.alphaValue == 0 }
        await nextMainTurn()
        #expect(!host.window.isVisible)
        #expect(host.field() == nil)
    }

    @Test func theLaunchCallbackDoesNotRetainItsRig() {
        var rig: LoginLaunchRig? = LoginLaunchRig()
        weak let released = rig
        rig?.close()
        rig = nil
        #expect(released == nil)
    }

    @Test func aWindowlessLaunchBuildsNoSearchWindowUntilARouteAsks() async throws {
        let rig = LoginLaunchRig()
        defer { rig.close() }
        let initial = rig.hostRoot()
        try await expectClosed(initial)
        #expect(rig.starts == 1)
        #expect(rig.launch.services != nil)
        #expect(rig.fake.lastSession.rawValue == 0)
        #expect(rig.access.welcome == nil)

        rig.routes.window()
        let opened = try #require(rig.opened.first)
        _ = try await field(in: opened)
        initial.view.layoutSubtreeIfNeeded()
        #expect(rig.statesAtOpen == [false])
        #expect(opened.window.isVisible)
        #expect(rig.fake.lastSession.rawValue == 1)
        #expect(initial.field() == nil)
    }

    @Test func theFirstDockClickAfterAWindowlessStartOpensOneWindow() async throws {
        let rig = LoginLaunchRig()
        defer { rig.close() }
        try await expectClosed(rig.hostRoot())
        let delegate = AppDelegate()
        delegate.summon = { rig.hotkey.summon() }
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        let opened = try #require(rig.opened.first)
        _ = try await field(in: opened)
        #expect(rig.statesAtOpen == [false])
        #expect(rig.fake.lastSession.rawValue == 1)
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        #expect(rig.opened.count == 1)
    }

    @Test func menuRoutesOpenWindowsAfterAWindowlessStart() async throws {
        let rig = LoginLaunchRig()
        defer { rig.close() }
        try await expectClosed(rig.hostRoot())
        rig.routes.menu.summon()
        let first = try #require(rig.opened.first)
        _ = try await field(in: first)
        #expect(rig.statesAtOpen == [false])
        rig.routes.menu.newWindow()
        try #require(rig.opened.count == 2)
        _ = try await field(in: rig.opened[1])
        #expect(rig.opened.allSatisfy { $0.window.isVisible })
        #expect(rig.statesAtOpen == [false, false])
        #expect(rig.fake.lastSession.rawValue == 2)
    }

    @Test func newWindowCanBeTheFirstRouteAfterAWindowlessStart() async throws {
        let rig = LoginLaunchRig()
        defer { rig.close() }
        try await expectClosed(rig.hostRoot())
        rig.routes.menu.newWindow()
        let opened = try #require(rig.opened.first)
        _ = try await field(in: opened)
        #expect(rig.statesAtOpen == [false])
        #expect(rig.fake.lastSession.rawValue == 1)
    }

    @Test func aLauncherCommandStartShowsTheLauncherOnlyAndALaterPressClosesIt() async throws {
        let rig = LoginLaunchRig()
        defer { rig.close() }
        try await expectClosed(rig.hostRoot())
        let commands = HelperCommands()
        commands.run = HelperCommands.route(
            access: rig.access, launch: rig.launch, menu: rig.routes.menu, hotkey: rig.routes.hotkey,
            stop: {}, activate: {}, synchronize: {}
        )
        commands.finishLaunch(argument: .launcher)
        let launcher = rig.services.launcher
        try await untilTrue(waitingFor: "the started launcher's field") { launcher.panel?.searchField != nil }
        #expect(launcher.panel?.isVisible == true)
        #expect(rig.launch.windowless)
        #expect(rig.opened.isEmpty)
        #expect(rig.fake.lastSession.rawValue == 1)
        commands.receive(.launcher)
        #expect(launcher.panel?.isVisible == false)
        #expect(rig.launch.windowless)
        rig.routes.menu.showSettings()
        #expect(rig.settingsOpens == 1)
        #expect(rig.launch.windowless)
        #expect(rig.opened.isEmpty)
    }

    @Test func aRestoredWindowAtAWindowlessStartCloses() async throws {
        let rig = LoginLaunchRig()
        defer { rig.close() }
        try await expectClosed(rig.hostRoot())
        try await expectClosed(rig.hostRoot())
        #expect(rig.launch.windowless)
        #expect(rig.fake.lastSession.rawValue == 0)
        #expect(rig.access.welcome == nil)
        #expect(rig.starts == 1)
    }

    @Test func aWindowlessStartBeforeTheWelcomeIsFinishedShowsItThenWaitsForTheClick() async throws {
        for stage in [AccessModel.Stage.waiting, .granted, .reopen] {
            let rig = LoginLaunchRig(stage: stage, confirms: stage != .reopen)
            defer { rig.close() }
            let initial = rig.hostRoot()
            try await expectClosed(initial)
            try await untilTrue(waitingFor: "the login welcome") { rig.access.welcome?.window?.isVisible == true }
            let welcome = rig.access.welcome?.window
            rig.routes.window()
            rig.routes.menu.summon()
            rig.routes.menu.newWindow()
            rig.routes.hotkey()
            rig.routes.menu.showSettings()
            await nextMainTurn()
            #expect(rig.starts == 0)
            #expect(rig.launch.services == nil)
            #expect(rig.fake.lastSession.rawValue == 0)
            #expect(rig.opened.isEmpty)
            #expect(rig.settingsOpens == 0)
            #expect(rig.launch.windowless)
            #expect(rig.access.welcome?.window === welcome)
            #expect(rig.access.stage == stage)
            let boxes = (welcome?.contentView).map { checkboxes(in: $0) } ?? []
            #expect(boxes.isEmpty, "checkboxes in \(stage)")

            if stage == .waiting {
                rig.grant.withLock { $0 = true }
                await rig.access.tick()
                try await untilTrue(waitingFor: "the granted state") { rig.access.stage == .granted }
            }
            if stage != .reopen {
                #expect(rig.starts == 0 && rig.opened.isEmpty)
                rig.access.completeWelcome(choices: rig.access.storedChoices)
                try await untilTrue(waitingFor: "the granted login window") { rig.opened.count == 1 }
                _ = try await field(in: rig.opened[0])
                #expect(rig.statesAtOpen == [false])
                #expect(rig.starts == 1)
                #expect(rig.fake.lastSession.rawValue == 1)
                #expect(rig.access.welcome == nil)
                #expect(initial.field() == nil)
            }
        }
    }

    private func checkboxes(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { (($0 as? NSButton).flatMap { $0.cell?.accessibilityRole() == .checkBox ? [$0] : nil } ?? []) + checkboxes(in: $0) }
    }

    @Test func aPlainLaunchOpensItsWindow() async throws {
        let rig = LoginLaunchRig(windowless: false)
        defer { rig.close() }
        let host = rig.hostRoot()
        _ = try await field(in: host)
        #expect(host.window.isVisible)
        #expect(host.window.alphaValue == 1)
        #expect(rig.fake.lastSession.rawValue == 1)
        #expect(rig.access.welcome == nil)
        #expect(rig.starts == 1)
    }

    @Test func aWindowStartTakesTheFrontOnceAfterItsWindowsShowAndAWindowlessStartDoesNot() async throws {
        for (login, stage) in [(false, AccessModel.Stage.ready), (false, .granted), (true, .ready), (true, .granted)] {
            let rig = LoginLaunchRig(windowless: login, stage: stage, finishLaunching: false)
            defer { rig.close() }
            let row = "login \(login), \(stage)"
            let shows = !login || stage != .ready
            rig.delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            #expect(rig.spy.policies.isEmpty, "\(row)")
            #expect(rig.spy.regulars == (login ? 0 : 1), "\(row)")
            rig.finish()
            #expect(rig.spy.policies == (shows ? [.regular] : []), "\(row)")
            #expect(rig.spy.activations == (login ? [] : [false]), "\(row)")
            #expect(rig.launch.windowless == login)
            #expect(rig.spy.loginReads == 1)
            if stage == .granted {
                try await untilTrue(waitingFor: "the welcome") { rig.access.welcome?.window?.isVisible == true }
            }
        }
    }

    @Test func aPreviewRunNeverTakesTheFront() {
        let rig = LoginLaunchRig(windowless: false, finishLaunching: false)
        defer { rig.close() }
        var activations = 0
        WhereverApp.finishLaunch(launch: rig.launch, access: rig.access, previews: true, presence: rig.presence, command: nil, activate: { activations += 1 })
        #expect(activations == 0)
        #expect(!rig.launch.windowless)
    }

    @Test func onlyACommandStartsWindowless() {
        #expect(!WhereverApp.launchWindowless(previews: false, command: nil))
        for command in [HelperCommand.launcher, .settings, .shortcuts, .serve, .wake] {
            #expect(WhereverApp.launchWindowless(previews: false, command: command))
            #expect(!WhereverApp.launchWindowless(previews: true, command: command))
        }
    }

    @Test func aRootCreatedBeforeTheLaunchEventWaitsThenFollowsIt() async throws {
        for login in [true, false] {
            let rig = LoginLaunchRig(windowless: login, finishLaunching: false)
            defer { rig.close() }
            let initial = rig.hostRoot()
            try await initial.until("the pending window to hide") { initial.window.alphaValue == 0 }
            #expect(initial.field() == nil && rig.fake.lastSession.rawValue == 0)
            rig.finish()
            if login {
                try await expectClosed(initial)
                rig.routes.menu.newWindow()
                _ = try await field(in: try #require(rig.opened.first))
                #expect(initial.field() == nil)
                #expect(rig.statesAtOpen == [false])
            } else {
                _ = try await field(in: initial)
                #expect(initial.window.alphaValue == 1 && initial.window.isVisible)
            }
            #expect(rig.fake.lastSession.rawValue == 1)
        }
    }

    @Test func aRootFirstRenderedDuringTheLaunchEventStillDecides() async throws {
        for login in [true, false] {
            let rig = LoginLaunchRig(windowless: login, finishLaunching: false)
            defer { rig.close() }
            var mounted: SearchHost?
            let mount = rig.delegate.objectWillChange.sink { _ in
                MainActor.assumeIsolated {
                    guard mounted == nil else { return }
                    let host = rig.hostRoot()
                    host.view.layoutSubtreeIfNeeded()
                    mounted = host
                }
            }
            rig.finish()
            mount.cancel()
            let initial = try #require(mounted)
            rig.launch.objectWillChange.send()
            if login {
                try await expectClosed(initial)
                rig.hotkey.summon()
                _ = try await field(in: try #require(rig.opened.first))
                #expect(initial.field() == nil)
            } else {
                _ = try await field(in: initial)
                #expect(initial.window.alphaValue == 1 && initial.window.isVisible)
            }
        }
    }

    @Test func theLauncherHandOffAfterAWindowlessStartKeepsItsText() async throws {
        let rig = LoginLaunchRig()
        defer { rig.close() }
        let initial = rig.hostRoot()
        try await expectClosed(initial)
        rig.routes.hotkey()
        let launcher = rig.services.launcher
        try await untilTrue(waitingFor: "the login launcher's field") { launcher.panel?.searchField != nil }
        launcher.model.query = "report"
        launcher.showAll()
        let opened = try #require(rig.opened.first)
        let field = try await field(in: opened)
        initial.view.layoutSubtreeIfNeeded()
        #expect(field.stringValue == "report")
        #expect(rig.statesAtOpen == [false])
        #expect(launcher.panel?.isVisible == false)
        #expect(rig.services.index.nextQuery == nil)
        #expect(rig.fake.lastSession.rawValue == 2)
        try await untilTrue(waitingFor: "the handed-off search") {
            rig.fake.session(rig.fake.lastSession)?.searches == [.init(query: "report", sort: .bestMatch)]
        }
        #expect(initial.field() == nil)
        #expect(!initial.window.isVisible)
    }
}
