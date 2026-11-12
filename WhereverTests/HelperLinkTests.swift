import AppKit
import Darwin
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private let everyCommand: [HelperCommand] = [.launcher, .settings, .shortcuts, .quit, .liveUpdates, .serve, .wake]

private func freshDefaults(_ name: String) -> UserDefaults {
    let domain = "com.writronic.wherever.tests.helperlink.\(name)"
    let store = UserDefaults(suiteName: domain)!
    store.removePersistentDomain(forName: domain)
    return store
}

private func makeBundle(at folder: URL, id: String?) throws {
    let contents = folder.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleName": folder.deletingPathExtension().lastPathComponent]
    if let id { info["CFBundleIdentifier"] = id }
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
}

private func withTree(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helperlink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try body(root.resolvingSymlinksInPath())
}

private func delivered(within seconds: Double = 5, _ received: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if received() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return received()
}

private func uniqueName() -> Notification.Name {
    Notification.Name("com.writronic.wherever.tests.helperlink.\(UUID().uuidString)")
}

private final class WakeRig {
    let seams = FakeHelperSeams()
    let wherever: UserDefaults
    let own: UserDefaults
    var syncs = 0
    var waiting: [@MainActor @Sendable () -> Void] = []
    var delays: [TimeInterval] = []
    private(set) lazy var wake = HelperWake(
        sender: seams.sender, wherever: wherever, own: own,
        synchronize: { [unowned self] in syncs += 1 },
        later: { [unowned self] delay, work in
            delays.append(delay)
            waiting.append(work)
        }
    )

    init(_ name: String) {
        wherever = freshDefaults("wake.\(name).wherever")
        own = freshDefaults("wake.\(name).own")
    }

    func delayPassed() {
        let work = waiting
        waiting = []
        work.forEach { $0() }
    }

    var wakes: [[String]] { seams.opens.map(\.arguments) }
}

private let wakeArguments = ["--command", "wake"]

@Suite(.serialized) struct HelperLinkTests {
    @Test func theRunRuleCoversEveryWelcomeIconAndShortcutCase() {
        let cases: [(welcome: Bool, icon: Bool?, shortcut: Data?, runs: Bool)] = [
            (false, nil, nil, false), (false, true, nil, false), (false, false, nil, false),
            (false, true, Data(), false), (false, false, Data([1]), false), (false, nil, Data(), false),
            (true, nil, nil, true), (true, true, nil, true), (true, false, nil, true),
            (true, nil, Data(), true), (true, true, Data(), true), (true, false, Data(), false),
            (true, nil, Data([1]), true), (true, true, Data([1]), true), (true, false, Data([1]), true),
        ]
        for item in cases {
            let got = HelperLink.shouldRun(welcomeCompleted: item.welcome, showMenuBarIcon: item.icon, shortcut: item.shortcut)
            #expect(got == item.runs, "welcome \(item.welcome), icon \(String(describing: item.icon)), shortcut \(String(describing: item.shortcut))")
        }
    }

    @Test func theRunRuleReadsTheStoredValues() {
        let store = freshDefaults("rule")
        #expect(!HelperLink.shouldRun(in: store))
        store.set(true, forKey: HelperLink.Key.welcomeCompleted)
        #expect(HelperLink.shouldRun(in: store))
        store.set(false, forKey: HelperLink.Key.showMenuBarIcon)
        #expect(HelperLink.shouldRun(in: store))
        store.set(Data(), forKey: HelperLink.Key.summonHotkey)
        #expect(!HelperLink.shouldRun(in: store))
        store.set(Data("not a hotkey".utf8), forKey: HelperLink.Key.summonHotkey)
        #expect(HelperLink.shouldRun(in: store))
        store.set(true, forKey: HelperLink.Key.showMenuBarIcon)
        store.set(Data(), forKey: HelperLink.Key.summonHotkey)
        #expect(HelperLink.shouldRun(in: store))
    }

    @Test func aHelperThatShouldNotRunEndsAndStartsNoStatusItem() {
        let store = freshDefaults("ends")
        var exits = 0
        var started = 0
        let begin = { if HelperLink.endUnlessNeeded(in: store, exit: { exits += 1 }) { started += 1 } }
        begin()
        #expect(exits == 1 && started == 0)
        store.set(true, forKey: HelperLink.Key.welcomeCompleted)
        store.set(false, forKey: HelperLink.Key.showMenuBarIcon)
        store.set(Data(), forKey: HelperLink.Key.summonHotkey)
        begin()
        #expect(exits == 2 && started == 0)
        store.removeObject(forKey: HelperLink.Key.summonHotkey)
        begin()
        #expect(exits == 2 && started == 1)
    }

    @Test func theParentIsFourComponentsUpWithWhereversID() throws {
        try withTree { root in
            let app = root.appendingPathComponent("Wherever.app")
            try makeBundle(at: app, id: HelperLink.whereverID)
            let helper = HelperLink.embeddedHelper(in: app)
            #expect(helper.path == app.path + "/Contents/Library/LoginItems/WhereverHelper.app")
            #expect(HelperLink.parent(ofHelperAt: helper)?.path == app.path)
        }
    }

    @Test func aParentWithAnotherIDIsRefused() throws {
        try withTree { root in
            let other = root.appendingPathComponent("Other.app")
            try makeBundle(at: other, id: "com.example.other")
            #expect(HelperLink.parent(ofHelperAt: HelperLink.embeddedHelper(in: other)) == nil)
            let bare = root.appendingPathComponent("Bare.app")
            try makeBundle(at: bare, id: nil)
            #expect(HelperLink.parent(ofHelperAt: HelperLink.embeddedHelper(in: bare)) == nil)
            let missing = root.appendingPathComponent("Missing.app")
            #expect(HelperLink.parent(ofHelperAt: HelperLink.embeddedHelper(in: missing)) == nil)
        }
    }

    @Test func aPostReachesAnObserverThatDropsWhileSuspended() async {
        let center = DistributedNotificationCenter.default()
        let name = uniqueName()
        var count = 0
        let observer = HelperObservation { count += 1 }
        center.addObserver(observer, selector: #selector(HelperObservation.fire(_:)), name: name, object: nil, suspensionBehavior: .drop)
        defer { center.removeObserver(observer) }
        let wasSuspended = center.suspended
        center.suspended = true
        defer { center.suspended = wasSuspended }
        HelperLink.post(name, object: nil)
        #expect(await delivered { count == 1 })
    }

    @Test func anObserverHearsAPostThatIsNotImmediateWhileSuspended() async {
        let center = DistributedNotificationCenter.default()
        let name = uniqueName()
        var count = 0
        let observer = HelperLink.observe(name, object: nil) { count += 1 }
        defer { center.removeObserver(observer) }
        let wasSuspended = center.suspended
        center.suspended = true
        defer { center.suspended = wasSuspended }
        center.postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: false)
        #expect(await delivered { count == 1 })
    }

    @Test func anObserverHearsOnlyItsObject() async {
        let center = DistributedNotificationCenter.default()
        let name = uniqueName()
        var mine = 0
        let observer = HelperLink.observe(name, object: "/mine") { mine += 1 }
        defer { center.removeObserver(observer) }
        HelperLink.post(name, object: "/other")
        HelperLink.post(name, object: "/mine")
        #expect(await delivered { mine == 1 })
        #expect(mine == 1)
    }

    @Test func aRunningWhereverGetsThePostForEveryCommandAndNeverAnOpen() {
        for command in everyCommand {
            let seams = FakeHelperSeams()
            seams.state = .running
            #expect(seams.sender.send(command), "\(command)")
            #expect(seams.posts == [FakeHelperPost(name: command.notification, object: seams.parent.path)], "\(command)")
            #expect(seams.opens.isEmpty, "\(command)")
        }
    }

    @Test func aClosedWhereverOpensWithTheCommandArgument() {
        let expected: [(HelperCommand, Bool)] = [(.launcher, false), (.settings, true), (.shortcuts, true), (.serve, false), (.wake, false)]
        for (command, activates) in expected {
            let seams = FakeHelperSeams()
            #expect(!seams.sender.send(command), "\(command)")
            #expect(seams.posts.isEmpty, "\(command)")
            #expect(
                seams.opens == [FakeHelperOpen(app: seams.parent, arguments: ["--command", command.rawValue], activates: activates)],
                "\(command)"
            )
        }
    }

    @Test func liveUpdatesAndQuitNeverOpenAClosedWherever() {
        let live = FakeHelperSeams()
        #expect(!live.sender.send(.liveUpdates))
        #expect(live.opens.isEmpty)
        #expect(live.posts == [FakeHelperPost(name: HelperCommand.liveUpdates.notification, object: live.parent.path)])

        let quit = FakeHelperSeams()
        #expect(!quit.sender.send(.quit))
        #expect(quit.opens.isEmpty)
        #expect(quit.posts.isEmpty)
    }

    @Test func aLaunchingWhereverGetsThePostOnlyAfterItFinishes() {
        let seams = FakeHelperSeams()
        seams.state = .launching
        #expect(seams.sender.send(.launcher))
        #expect(seams.posts.isEmpty)
        #expect(seams.opens.isEmpty)
        seams.finishLaunching()
        #expect(seams.posts == [FakeHelperPost(name: HelperCommand.launcher.notification, object: seams.parent.path)])
        #expect(seams.opens.isEmpty)
    }

    @Test func openWhereverIsAPlainActivatingOpen() {
        let seams = FakeHelperSeams()
        seams.state = .running
        seams.sender.openWherever()
        #expect(seams.opens == [FakeHelperOpen(app: seams.parent, arguments: [], activates: true)])
        #expect(seams.posts.isEmpty)
    }

    @Test func theCommandArgumentIsRead() {
        for command in everyCommand {
            #expect(HelperLink.command(in: ["/Wherever", "--command", command.rawValue]) == command)
        }
        #expect(HelperLink.command(in: ["/Wherever", "-NSDocumentRevisionsDebugMode", "YES", "--command", "launcher"]) == .launcher)
        #expect(HelperLink.command(in: ["/Wherever"]) == nil)
        #expect(HelperLink.command(in: ["/Wherever", "--command"]) == nil)
        #expect(HelperLink.command(in: ["/Wherever", "--command", "nonsense"]) == nil)
    }

    @Test func theMountedPathsAreRead() {
        #expect(HelperLink.mounted(in: ["Wherever", "--command", "wake"]).isEmpty)
        #expect(HelperLink.mounted(in: ["Wherever", "--mounted"]).isEmpty)
        #expect(HelperLink.mounted(in: ["Wherever", "--command", "wake", "--mounted", "/Volumes/Disk 1/", "--mounted", "/Volumes/Disk 2/"]) == ["/Volumes/Disk 1/", "/Volumes/Disk 2/"])
    }

    @Test func aWakeOpensAClosedWhereverWithItsPathsWithoutActivating() {
        let seams = FakeHelperSeams()
        seams.sender.wake(mounted: ["/Volumes/Disk 1/", "/Volumes/Disk 2/"])
        #expect(seams.opens == [FakeHelperOpen(
            app: seams.parent, arguments: wakeArguments + ["--mounted", "/Volumes/Disk 1/", "--mounted", "/Volumes/Disk 2/"], activates: false
        )])
        #expect(HelperLink.command(in: seams.opens[0].arguments) == .wake)
    }

    @Test func aRunningWhereverGetsNothingFromAWakeBecauseItHeardTheMountItself() {
        let seams = FakeHelperSeams()
        seams.state = .running
        seams.sender.wake(mounted: ["/Volumes/Disk 1/"])
        #expect(seams.opens.isEmpty && seams.posts.isEmpty && seams.mounted.isEmpty)
    }

    @Test func aLaunchingWhereverGetsThePathsOnlyAfterItFinishes() {
        let seams = FakeHelperSeams()
        seams.state = .launching
        seams.sender.wake(mounted: ["/Volumes/Disk 2/"])
        #expect(seams.mounted.isEmpty && seams.opens.isEmpty)
        seams.finishLaunching()
        #expect(seams.mounted == [["/Volumes/Disk 2/"]])
        #expect(seams.opens.isEmpty)
    }

    @Test func aTimerWakeDuringALaunchSendsNothing() {
        let seams = FakeHelperSeams()
        seams.state = .launching
        seams.sender.wake()
        seams.finishLaunching()
        #expect(seams.mounted.isEmpty && seams.opens.isEmpty && seams.posts.isEmpty)
    }

    @Test func theMountedPostReachesItsObserverWithThePaths() async {
        let object = "/tests/helperlink/\(UUID().uuidString)"
        var heard: [[String]] = []
        let observation = HelperLink.observeMounted(object: object) { heard.append($0) }
        defer { withExtendedLifetime(observation) {} }
        HelperLink.postMounted(["/Volumes/Disk 1", "/Volumes/Disk 2"], object: object)
        #expect(await delivered { !heard.isEmpty })
        #expect(heard == [["/Volumes/Disk 1", "/Volumes/Disk 2"]])
    }

    @Test func theDueRuleCoversTheSwitchTheLastCheckAndTheLastWake() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let day = HelperWake.checkInterval
        #expect(day == 86400)
        #expect(!HelperWake.checkDue(checksOn: false, lastCheck: nil, lastWake: nil, now: now))
        #expect(!HelperWake.checkDue(checksOn: false, lastCheck: now - 9 * day, lastWake: nil, now: now))
        #expect(HelperWake.checkDue(checksOn: true, lastCheck: nil, lastWake: nil, now: now))
        #expect(HelperWake.checkDue(checksOn: true, lastCheck: now - day, lastWake: nil, now: now))
        #expect(!HelperWake.checkDue(checksOn: true, lastCheck: now - day + 1, lastWake: nil, now: now), "Sparkle would not check yet, so the check slips a day")
        #expect(!HelperWake.checkDue(checksOn: true, lastCheck: now - 9 * day, lastWake: now - 3600, now: now), "a check that never ran starts Wherever every hour")
        #expect(HelperWake.checkDue(checksOn: true, lastCheck: now - 9 * day, lastWake: now - day, now: now))
        #expect(HelperWake.checkDue(checksOn: true, lastCheck: now + day, lastWake: nil, now: now), "a date in the future stops the checks")
    }

    @Test func theTimerWakesOnceADayWhileChecksAreOn() {
        let rig = WakeRig("daily")
        rig.wherever.set(true, forKey: HelperLink.Key.automaticChecks)
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        rig.wherever.set(start - HelperWake.checkInterval, forKey: HelperLink.Key.lastUpdateCheck)
        for hour in 0 ..< 48 { rig.wake.timerFired(now: start + Double(hour) * HelperWake.tick) }
        #expect(rig.wakes == [wakeArguments, wakeArguments], "fired at hours 0 and 24 of 48")
    }

    @Test func theTimerNeverWakesWhileChecksAreOffAndFollowsTheSwitchWhenItFires() {
        let rig = WakeRig("off")
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        rig.wake.timerFired(now: now)
        #expect(rig.wakes.isEmpty)
        #expect(rig.syncs == 1, "a switch changed in Wherever stays unread without a sync")
        #expect(rig.own.object(forKey: HelperLink.Key.lastWake) == nil)
        rig.wherever.set(true, forKey: HelperLink.Key.automaticChecks)
        rig.wake.timerFired(now: now + HelperWake.tick)
        #expect(rig.wakes == [wakeArguments])
        rig.wherever.set(false, forKey: HelperLink.Key.automaticChecks)
        rig.wake.timerFired(now: now + 2 * HelperWake.checkInterval)
        #expect(rig.wakes == [wakeArguments])
    }

    @Test(arguments: ["notification", "index"])
    func aMountWakesWhereverWithItsPath(_ answer: String) {
        let rig = WakeRig("mount.\(answer)")
        rig.wherever.set(answer, forKey: HelperLink.Key.newDiskChoice)
        rig.wake.diskMounted(at: "/Volumes/Disk 1/")
        #expect(rig.wakes.isEmpty, "the wake leaves before a second partition can join")
        #expect(rig.delays == [HelperWake.mountDelay])
        rig.delayPassed()
        #expect(rig.wakes == [wakeArguments + ["--mounted", "/Volumes/Disk 1/"]])
    }

    @Test func twoMountsTogetherShareOneWakeAndALaterOneHasItsOwn() {
        let rig = WakeRig("mount.two")
        rig.wherever.set("index", forKey: HelperLink.Key.newDiskChoice)
        rig.wake.diskMounted(at: "/Volumes/Disk 1/")
        rig.wake.diskMounted(at: "/Volumes/Disk 2/")
        #expect(rig.delays.count == 1)
        rig.delayPassed()
        #expect(rig.wakes == [wakeArguments + ["--mounted", "/Volumes/Disk 1/", "--mounted", "/Volumes/Disk 2/"]])
        rig.wake.diskMounted(at: "/Volumes/Card/")
        rig.delayPassed()
        #expect(rig.wakes.last == wakeArguments + ["--mounted", "/Volumes/Card/"])
    }

    @Test(arguments: [nil, "statusBar", "nothing"] as [String?])
    func aMountUnderAnAnswerThatNeedsNoWakeStartsNothing(_ answer: String?) {
        let rig = WakeRig("mount.none.\(String(describing: answer))")
        if let answer { rig.wherever.set(answer, forKey: HelperLink.Key.newDiskChoice) }
        rig.wake.diskMounted(at: "/Volumes/Disk 1/")
        rig.delayPassed()
        #expect(rig.wakes.isEmpty)
        #expect(rig.syncs == 1, "an answer changed in Wherever stays unread without a sync")
    }

    @Test func theWakeAnswersAndKeysMatchWherevers() {
        #expect(Set(HelperWake.answersThatAct) == [NewDiskChoice.notification.rawValue, NewDiskChoice.index.rawValue])
        #expect(HelperLink.Key.newDiskChoice == NewDiskChoice.key)
        #expect(HelperLink.Key.automaticChecks == UpdatesModel.automaticChecksKey)
        #expect(HelperLink.Key.lastUpdateCheck == "SULastCheckTime")
    }

    @Test func everyStoredNameStaysExact() {
        #expect(HelperLink.whereverID == AppIdentity.bundleIdentifier)
        #expect(HelperLink.helperID == "com.writronic.wherever.helper")
        #expect(HelperCommand.allCases == everyCommand)
        #expect(HelperLink.Note.commandDone.rawValue == "com.writronic.wherever.commandDone")
        #expect(HelperLink.Note.sync.rawValue == "com.writronic.wherever.helper.sync")
        #expect(MenuBarIcon.key == "showMenuBarIcon")
        #expect(MenuBarIcon.key == HelperLink.Key.showMenuBarIcon)
        #expect(AccessModel.completedKey == "welcomeCompleted")
        #expect(AccessModel.completedKey == HelperLink.Key.welcomeCompleted)
        #expect(HotkeyModel.defaultsKey == "summonHotkey")
        #expect(HotkeyModel.defaultsKey == HelperLink.Key.summonHotkey)
        #expect(IndexModel.pausedKey == "liveUpdatesPaused")
        #expect(IndexModel.pausedKey == HelperLink.Key.liveUpdatesPaused)
        #expect(HelperLink.Key.appleLanguages == "AppleLanguages")
    }

    @Test func aSecondCopyCannotTakeTheLockUntilTheFirstEnds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wherever-helperlock-\(UUID().uuidString)/deep", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let file = folder.appendingPathComponent("helper.lock")
        let first = try #require(HelperLock.take(at: file))
        #expect(first >= 0)
        #expect(HelperLock.take(at: file) == nil)
        close(first)
        let next = try #require(HelperLock.take(at: file))
        #expect(next >= 0)
        close(next)
    }

    @Test func aLockThatCannotBeOpenedStillLetsTheHelperRun() {
        #expect(HelperLock.take(at: URL(fileURLWithPath: "/dev/null/helper.lock")) == -1)
    }

    @Test func theLockSitsInTheCommandSocketsFolder() {
        let file = HelperLock.file
        #expect(file.lastPathComponent == "helper.lock")
        #expect(file.deletingLastPathComponent().lastPathComponent == "com.writronic.wherever")
        #expect(file.path.contains("/C/"))
    }

    @Test func theEmbeddedHelpersExecutableHasAnIdentity() {
        #expect(HelperLink.identity(of: HelperLink.embeddedHelper(in: Bundle.main.bundleURL)) != nil)
    }

    @Test func theIdentityFollowsTheExecutableFile() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("wherever-helperidentity-\(UUID().uuidString)/WhereverHelper.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(HelperLink.identity(of: app) == nil)
        let executable = app.appendingPathComponent("Contents/MacOS/WhereverHelper")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: executable)
        let old = try #require(HelperLink.identity(of: app))
        #expect(HelperLink.identity(of: app) == old)
        let replacement = app.appendingPathComponent("Contents/MacOS/next")
        try Data("new".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(executable, withItemAt: replacement)
        #expect(HelperLink.identity(of: app) != old)
    }
}
