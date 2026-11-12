import AppKit
import Darwin
import Foundation
import ServiceManagement
import Testing
@testable import Wherever

private let app = URL(fileURLWithPath: "/tmp/helperswitch/Wherever.app")
private let helperPath = HelperLink.embeddedHelper(in: app).path

private func store(_ name: String, welcome: Bool = true, icon: Bool? = nil, shortcut: Data? = nil) -> UserDefaults {
    let suite = "com.writronic.wherever.tests.helperswitch.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    if welcome { defaults.set(true, forKey: AccessModel.completedKey) }
    if let icon { defaults.set(icon, forKey: MenuBarIcon.key) }
    if let shortcut { defaults.set(shortcut, forKey: HotkeyModel.defaultsKey) }
    return defaults
}

struct SpyRefused: Error {}

nonisolated struct HelperStateRow: Sendable, CustomTestStringConvertible {
    nonisolated enum Action: Sendable { case nothing, open, register, exit }

    let login: Bool
    let welcome: Bool
    let icon: Bool
    let shortcut: Bool
    let running: Bool
    let action: Action

    var testDescription: String { "login \(login) welcome \(welcome) icon \(icon) key \(shortcut) running \(running)" }

    init(login: Bool, welcome: Bool = true, icon: Bool, shortcut: Bool, running: Bool = false, _ action: Action) {
        self.login = login
        self.welcome = welcome
        self.icon = icon
        self.shortcut = shortcut
        self.running = running
        self.action = action
    }

    static let table = [
        HelperStateRow(login: false, icon: false, shortcut: false, .nothing),
        HelperStateRow(login: false, icon: false, shortcut: false, running: true, .exit),
        HelperStateRow(login: false, icon: true, shortcut: false, .open),
        HelperStateRow(login: false, icon: true, shortcut: true, .open),
        HelperStateRow(login: false, icon: true, shortcut: true, running: true, .nothing),
        HelperStateRow(login: false, icon: false, shortcut: true, .open),
        HelperStateRow(login: true, icon: true, shortcut: false, .register),
        HelperStateRow(login: true, icon: true, shortcut: true, .register),
        HelperStateRow(login: true, icon: true, shortcut: true, running: true, .nothing),
        HelperStateRow(login: true, icon: false, shortcut: true, .register),
        HelperStateRow(login: true, icon: false, shortcut: false, .nothing),
        HelperStateRow(login: true, icon: false, shortcut: false, running: true, .exit),
        HelperStateRow(login: true, welcome: false, icon: true, shortcut: true, .nothing),
        HelperStateRow(login: false, welcome: false, icon: true, shortcut: true, .nothing),
        HelperStateRow(login: true, welcome: false, icon: true, shortcut: true, running: true, .exit),
    ]
}

final class HelperStarterSpy {
    struct Open: Equatable {
        let path: String
        let activates: Bool
    }

    var running = false
    var opens: [Open] = []
    var syncs: [String] = []
    var notes: [Notification.Name] = []
    var onPost: (Notification.Name) -> Void = { _ in }
    var status = SMAppService.Status.notRegistered
    var events: [String] = []
    var waits: [Duration] = []
    var launchdCopy = false
    var startsOnRegister = [true]
    var registerFails = false
    var unregisterFails = false
    var foreign = false
    var embedded: String?

    func starter(defaults: UserDefaults, previews: Bool = false, own: UserDefaults? = nil, helper: URL? = nil) -> HelperStarter {
        let store = own ?? defaults
        let path = helper ?? HelperLink.embeddedHelper(in: app)
        return HelperStarter(
            previews: previews, defaults: defaults, own: store, helper: path,
            isRunning: { [self] in running },
            open: { [self] url, activates in opens.append(Open(path: url.path, activates: activates)) },
            post: { [self] name, path in
                onPost(name)
                notes.append(name)
                if name == HelperLink.Note.sync { syncs.append(path) }
            },
            registerBundle: { [self] in events.append("registerBundle") },
            readStatus: { [self] in
                events.append("status")
                return status
            },
            registerItem: { [self] in
                events.append("register")
                if registerFails { throw SpyRefused() }
                status = .enabled
                guard startsOnRegister.isEmpty ? false : startsOnRegister.removeFirst() else { return }
                running = true
                launchdCopy = true
                store.set(embedded, forKey: HelperLink.Key.helperIdentity)
            },
            unregisterItem: { [self] in
                events.append("unregister")
                if unregisterFails { throw SpyRefused() }
                status = .notRegistered
                if launchdCopy {
                    running = false
                    launchdCopy = false
                }
            },
            running: { [self] in
                (running ? [(pid: 42, url: Optional(path))] : []) + (foreign ? [(pid: 7, url: Optional(URL(fileURLWithPath: "/Volumes/Old/Wherever.app")))] : [])
            },
            end: { [self] pid in
                events.append("end \(pid)")
                running = false
            },
            identity: { [self] in embedded },
            delay: { [self] in waits.append($0) }
        )
    }

    func model(
        _ defaults: UserDefaults, own: UserDefaults? = nil, helper: URL? = nil, layoutNotifications: NotificationCenter = NotificationCenter()
    ) -> HotkeyModel {
        HotkeyModel(
            defaults: defaults, helper: starter(defaults: defaults, own: own, helper: helper),
            windows: { [] }, unhide: {}, activate: {}, layoutNotifications: layoutNotifications
        )
    }
}

@Suite(.serialized) struct HelperSwitchTests {
    private func finishLaunch(_ starter: HelperStarter, defaults: UserDefaults, command: HelperCommand? = nil) {
        let access = AccessModel(defaults: defaults, center: NotificationCenter(), stage: .ready, probe: { .denied }, confirm: { false }, start: {}, summon: {})
        let presence = AppPresence(center: NotificationCenter()) { _ in }
        WhereverApp.finishLaunch(
            launch: Launch(windowless: true), access: access, previews: false, presence: presence,
            command: command, syncHelper: starter.sync
        )
    }

    @Test(arguments: [true as Bool?, nil], [HelperCommand.launcher as HelperCommand?, nil])
    func aLaunchWithTheIconOnOpensTheHelperOnceAndNeverActivatesIt(icon: Bool?, command: HelperCommand?) {
        let defaults = store("launch.on", icon: icon)
        let spy = HelperStarterSpy()
        finishLaunch(spy.starter(defaults: defaults), defaults: defaults, command: command)
        #expect(spy.opens == [.init(path: helperPath, activates: false)])
        #expect(spy.syncs.isEmpty)
    }

    @Test func aLaunchWithTheHelperAlreadyRunningOnlySyncsIt() {
        let defaults = store("launch.running")
        let spy = HelperStarterSpy()
        spy.running = true
        finishLaunch(spy.starter(defaults: defaults), defaults: defaults)
        #expect(spy.opens.isEmpty)
        #expect(spy.syncs == [helperPath])
    }

    @Test func aLaunchWithTheRuleFalsePostsOneSyncAndOpensNothing() {
        for (name, defaults) in [
            ("reset left the helper", store("launch.reset", welcome: false)),
            ("nothing to do", store("launch.nothing", icon: false, shortcut: Data())),
        ] {
            #expect(!HelperLink.shouldRun(in: defaults), "\(name)")
            let spy = HelperStarterSpy()
            spy.running = true
            finishLaunch(spy.starter(defaults: defaults), defaults: defaults)
            #expect(spy.opens.isEmpty, "\(name)")
            #expect(spy.syncs == [helperPath], "\(name)")
        }
    }

    @Test func aLaunchWithTheIconOffAndTheShortcutOnOpensTheHelperForTheKey() {
        let defaults = store("launch.keyonly", icon: false)
        #expect(HelperLink.shouldRun(in: defaults))
        let spy = HelperStarterSpy()
        finishLaunch(spy.starter(defaults: defaults), defaults: defaults)
        #expect(spy.opens == [.init(path: helperPath, activates: false)])
        #expect(spy.syncs.isEmpty)
    }

    @Test func aRunningHelperWithTheIconOffAndTheShortcutOnOnlySyncs() {
        let defaults = store("switch.keyonly", icon: false)
        let spy = HelperStarterSpy()
        spy.running = true
        spy.starter(defaults: defaults).sync()
        #expect(spy.opens.isEmpty)
        #expect(spy.syncs == [helperPath])
    }

    @Test func aFinishedWelcomeWithTheIconOffAndNoShortcutOpensNoHelper() {
        let defaults = store("switch.none", icon: false, shortcut: Data())
        let spy = HelperStarterSpy()
        spy.starter(defaults: defaults).sync()
        #expect(spy.opens.isEmpty)
        #expect(spy.syncs == [helperPath])
    }

    @Test func aPauseAndAResumeCarryTheHelperPathAndATestHostSendsNeither() {
        let defaults = store("notes")
        let spy = HelperStarterSpy()
        var paths: [String] = []
        var starter = spy.starter(defaults: defaults)
        starter.post = { name, path in
            spy.notes.append(name)
            paths.append(path)
        }
        starter.pause()
        starter.resume()
        #expect(spy.notes == [HelperLink.Note.pause, HelperLink.Note.resume])
        #expect(paths == [helperPath, helperPath])
        let host = HelperStarterSpy()
        let quiet = host.starter(defaults: defaults, previews: true)
        quiet.pause()
        quiet.resume()
        #expect(host.notes.isEmpty)
    }

    @Test func theFailureReadsTheHelpersDomainAndATestHostReadsNone() {
        let defaults = store("failure.wherever")
        let own = store("failure.helper", welcome: false)
        let spy = HelperStarterSpy()
        let starter = spy.starter(defaults: defaults, own: own)
        #expect(!starter.shortcutFailed)
        defaults.set(true, forKey: HelperLink.Key.shortcutFailed)
        #expect(!starter.shortcutFailed)
        own.set(true, forKey: HelperLink.Key.shortcutFailed)
        #expect(starter.shortcutFailed)
        #expect(!spy.starter(defaults: defaults, previews: true, own: own).shortcutFailed)
    }

    @Test func theSwitchTurningOnOpensAMissingHelperAndOnlySyncsARunningOne() {
        let defaults = store("switch.on", icon: false)
        let spy = HelperStarterSpy()
        let starter = spy.starter(defaults: defaults)
        defaults.set(true, forKey: MenuBarIcon.key)
        starter.sync()
        #expect(spy.opens == [.init(path: helperPath, activates: false)])
        #expect(spy.syncs.isEmpty)
        spy.running = true
        spy.opens = []
        starter.sync()
        #expect(spy.opens.isEmpty)
        #expect(spy.syncs == [helperPath])
    }

    @Test(arguments: [false, true])
    func inATestHostTheStarterOpensNothingAndPostsNothing(running: Bool) {
        #expect(WhereverApp.usesPreviewServices)
        #expect(WhereverApp.helperStarter.previews)
        let defaults = store("host", icon: true)
        let spy = HelperStarterSpy()
        spy.running = running
        spy.starter(defaults: defaults, previews: true).sync()
        #expect(spy.opens.isEmpty)
        #expect(spy.syncs.isEmpty)
        spy.starter(defaults: defaults, previews: false).sync()
        #expect(spy.opens.count == (running ? 0 : 1))
        #expect(spy.syncs.count == (running ? 1 : 0))
    }

    @Test(arguments: HelperStateRow.table)
    func aLaunchActsOnEveryStateTableRow(_ row: HelperStateRow) async {
        let name = "row.\(row.testDescription.replacingOccurrences(of: " ", with: "."))"
        let defaults = store(name, welcome: row.welcome, icon: row.icon, shortcut: row.shortcut ? Data([1]) : Data())
        let spy = HelperStarterSpy()
        spy.status = row.login ? .enabled : .notRegistered
        spy.running = row.running
        await spy.starter(defaults: defaults).launched().value
        switch row.action {
        case .nothing:
            #expect(spy.opens.isEmpty && !spy.events.contains("register") && !spy.events.contains("unregister"))
            #expect(spy.running == row.running)
        case .open:
            #expect(spy.opens == [HelperStarterSpy.Open(path: helperPath, activates: false)])
            #expect(!spy.events.contains("register") && !spy.events.contains("unregister"))
        case .register:
            #expect(spy.opens.isEmpty)
            #expect(spy.events.filter { $0 == "unregister" || $0 == "register" } == ["unregister", "register"])
            #expect(spy.running)
        case .exit:
            #expect(spy.syncs == [helperPath] && !HelperLink.shouldRun(in: defaults))
            #expect(spy.opens.isEmpty && !spy.events.contains("register") && !spy.events.contains("end 42"))
        }
    }

    @Test func aLaunchRegistersTheBundleBeforeItReadsTheStatusAndBeforeItReturns() async {
        let spy = HelperStarterSpy()
        let task = spy.starter(defaults: store("order", icon: true)).launched()
        #expect(spy.events == ["registerBundle"])
        await task.value
        #expect(Array(spy.events.prefix(2)) == ["registerBundle", "status"])
    }

    @Test func aPreviewLaunchTouchesNothing() async throws {
        let spy = HelperStarterSpy()
        let starter = spy.starter(defaults: store("previews", icon: true), previews: true)
        await starter.launched().value
        try await starter.registerLogin()
        try await starter.unregisterLogin()
        await starter.removeForReset()
        #expect(spy.events.isEmpty && spy.opens.isEmpty && spy.notes.isEmpty)
    }

    @Test func aChangedIdentityOnAnEnabledItemUnregistersThenRegisters() async {
        let defaults = store("identity.enabled", icon: true)
        defaults.set("old", forKey: HelperLink.Key.helperIdentity)
        let spy = HelperStarterSpy()
        spy.embedded = "new"
        spy.status = .enabled
        spy.running = true
        spy.launchdCopy = true
        await spy.starter(defaults: defaults).ensureCurrent()
        #expect(spy.events == ["status", "unregister", "register"])
        #expect(spy.opens.isEmpty && spy.running)
        #expect(defaults.string(forKey: HelperLink.Key.helperIdentity) == "new")
    }

    @Test func anOpenedCopyOnAnEnabledItemEndsBetweenUnregisterAndRegister() async {
        let defaults = store("identity.opened", icon: true)
        defaults.set("old", forKey: HelperLink.Key.helperIdentity)
        let spy = HelperStarterSpy()
        spy.embedded = "new"
        spy.status = .enabled
        spy.running = true
        await spy.starter(defaults: defaults).ensureCurrent()
        #expect(spy.events == ["status", "unregister", "end 42", "register"])
        #expect(spy.opens.isEmpty)
    }

    @Test(arguments: [true, false])
    func aChangedIdentityWithoutAnEnabledItemEndsByPidAndOpens(needsApproval: Bool) async {
        let defaults = store("identity.off.\(needsApproval)", icon: true)
        defaults.set("old", forKey: HelperLink.Key.helperIdentity)
        let spy = HelperStarterSpy()
        spy.embedded = "new"
        spy.status = needsApproval ? .requiresApproval : .notRegistered
        spy.running = true
        await spy.starter(defaults: defaults).ensureCurrent()
        #expect(spy.events == ["status", "end 42"])
        #expect(spy.opens == [HelperStarterSpy.Open(path: helperPath, activates: false)])
    }

    @Test func aMatchingIdentityRestartsNothing() async {
        let defaults = store("identity.same", icon: true)
        defaults.set("new", forKey: HelperLink.Key.helperIdentity)
        let spy = HelperStarterSpy()
        spy.embedded = "new"
        spy.status = .enabled
        spy.running = true
        spy.launchdCopy = true
        await spy.starter(defaults: defaults).ensureCurrent()
        #expect(spy.events == ["status"])
        #expect(spy.syncs == [helperPath])
    }

    @Test func aStaleCopyWithTheRuleFalseIsToldToExitAndNotRestarted() async {
        let defaults = store("identity.rulefalse", icon: false, shortcut: Data())
        defaults.set("old", forKey: HelperLink.Key.helperIdentity)
        let spy = HelperStarterSpy()
        spy.embedded = "new"
        spy.status = .enabled
        spy.running = true
        await spy.starter(defaults: defaults).ensureCurrent()
        #expect(spy.events == ["status"])
        #expect(spy.syncs == [helperPath])
    }

    @Test func theSecondTryRunsAfterTheWindowAndTheFirstSuccessStops() async {
        let spy = HelperStarterSpy()
        spy.status = .enabled
        spy.startsOnRegister = [false, true]
        await spy.starter(defaults: store("tries.second", icon: true)).ensureCurrent()
        #expect(spy.events.filter { $0 == "register" }.count == 2)
        #expect(spy.waits == [.zero, .seconds(3), .seconds(10), .seconds(3)])
        #expect(spy.opens.isEmpty)
    }

    @Test func twoFailedTriesOpenACopySoOneRuns() async {
        let spy = HelperStarterSpy()
        spy.status = .enabled
        spy.startsOnRegister = [false, false]
        await spy.starter(defaults: store("tries.none", icon: true)).ensureCurrent()
        #expect(spy.events.filter { $0 == "register" }.count == 2)
        #expect(spy.opens == [HelperStarterSpy.Open(path: helperPath, activates: false)])
    }

    @Test func aRefusedRegisterAtALaunchOpensACopyAndStopsTrying() async {
        let spy = HelperStarterSpy()
        spy.status = .enabled
        spy.registerFails = true
        await spy.starter(defaults: store("tries.refused", icon: true)).ensureCurrent()
        #expect(spy.events.filter { $0 == "register" }.count == 1)
        #expect(spy.opens == [HelperStarterSpy.Open(path: helperPath, activates: false)])
    }

    @Test func theSwitchOnEndsAnOpenedCopyThenRegistersAndOpensNothing() async throws {
        let spy = HelperStarterSpy()
        spy.running = true
        try await spy.starter(defaults: store("switch.on", icon: true)).registerLogin()
        #expect(spy.events == ["registerBundle", "end 42", "register"])
        #expect(spy.opens.isEmpty && spy.running && spy.status == .enabled)
    }

    @Test func aRefusedSwitchOnBringsTheEndedCopyBackAndShowsTheFailure() async {
        let spy = HelperStarterSpy()
        spy.running = true
        spy.registerFails = true
        let starter = spy.starter(defaults: store("switch.refused", icon: true))
        let model = LaunchAtLoginModel(
            readStatus: { spy.status },
            register: { try await starter.registerLogin() }, unregister: {}, openLoginItems: {}
        )
        await model.setEnabled(true)
        #expect(model.failed)
        #expect(spy.events == ["registerBundle", "end 42", "register"])
        #expect(spy.opens == [HelperStarterSpy.Open(path: helperPath, activates: false)])
    }

    @Test func theSwitchOffEndsTheLaunchdCopyThenOpensOneWhenTheRuleSaysRun() async throws {
        let spy = HelperStarterSpy()
        spy.status = .enabled
        spy.running = true
        spy.launchdCopy = true
        try await spy.starter(defaults: store("switch.off.run", icon: true)).unregisterLogin()
        #expect(spy.events == ["unregister"])
        #expect(spy.opens == [HelperStarterSpy.Open(path: helperPath, activates: false)])
    }

    @Test func theSwitchOffEndsAnOpenedCopyThenOpensOne() async throws {
        let spy = HelperStarterSpy()
        spy.status = .enabled
        spy.running = true
        try await spy.starter(defaults: store("switch.off.opened", icon: true)).unregisterLogin()
        #expect(spy.events == ["unregister", "end 42"])
        #expect(spy.opens == [HelperStarterSpy.Open(path: helperPath, activates: false)])
    }

    @Test func theSwitchOffWithTheRuleFalseLeavesNoHelper() async throws {
        let spy = HelperStarterSpy()
        spy.status = .enabled
        spy.running = true
        spy.launchdCopy = true
        try await spy.starter(defaults: store("switch.off.none", icon: false, shortcut: Data())).unregisterLogin()
        #expect(spy.opens.isEmpty && !spy.running)
    }

    @Test func aRefusedSwitchOffKeepsTheCopyRunning() async {
        let spy = HelperStarterSpy()
        spy.status = .enabled
        spy.running = true
        spy.unregisterFails = true
        let starter = spy.starter(defaults: store("switch.off.refused", icon: true))
        await #expect(throws: SpyRefused.self) { try await starter.unregisterLogin() }
        #expect(spy.events == ["unregister"] && spy.opens.isEmpty && spy.running)
    }

    @Test func onlyACopyInsideThisBundleCounts() {
        let other = URL(fileURLWithPath: "/Volumes/Old/Wherever.app")
        let apps: [(pid: pid_t, url: URL?)] = [(pid: 1, url: HelperLink.embeddedHelper(in: app)), (pid: 2, url: other), (pid: 3, url: nil)]
        #expect(HelperStarter.copies(of: HelperLink.embeddedHelper(in: app), among: apps) == [1])
    }

    @Test func theLiveStarterPointsAtTheHelperInsideThisApp() {
        #expect(WhereverApp.helperStarter.helper == HelperLink.embeddedHelper(in: Bundle.main.bundleURL))
    }

    @Test func aRealSyncCarriesTheHelperPathAndTheRuleIsFalseWithTheIconOff() async throws {
        let defaults = store("live.off", icon: false, shortcut: Data())
        let other = URL(fileURLWithPath: "/tmp/helperswitch-\(UUID().uuidString)/Wherever.app")
        var heard = 0
        let observation = HelperLink.observe(HelperLink.Note.sync, object: HelperLink.embeddedHelper(in: other).path) { heard += 1 }
        defer { DistributedNotificationCenter.default().removeObserver(observation) }
        HelperStarter.live(previews: false, defaults: defaults, app: other).sync()
        try await untilTrue(waitingFor: "the sync") { heard == 1 }
        #expect(!HelperLink.shouldRun(in: defaults))
    }
}
