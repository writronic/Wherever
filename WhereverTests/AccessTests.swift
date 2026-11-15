import AppKit
import Foundation
import os
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

nonisolated final class ProbeSpy: Sendable {
    private nonisolated struct State {
        var answer: AccessModel.ProbeResult
        var script: [AccessModel.ProbeResult] = []
        var calls = 0
        var blocks = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let gate = DispatchSemaphore(value: 0)

    init(_ answer: Bool) { state = OSAllocatedUnfairLock(initialState: State(answer: answer ? .granted : .denied)) }

    var calls: Int { state.withLock { $0.calls } }
    func set(_ answer: Bool) { state.withLock { $0.answer = answer ? .granted : .denied } }
    func fail() { state.withLock { $0.answer = .failed } }
    func script(_ answers: [AccessModel.ProbeResult]) { state.withLock { $0.script = answers } }
    func block(_ blocks: Bool) { state.withLock { $0.blocks = blocks } }
    func release() { gate.signal() }

    func probe() -> AccessModel.ProbeResult {
        let (answer, blocks) = state.withLock { state -> (AccessModel.ProbeResult, Bool) in
            state.calls += 1
            return (state.script.isEmpty ? state.answer : state.script.removeFirst(), state.blocks)
        }
        if blocks { gate.wait() }
        return answer
    }
}

final class AccessFixture {
    let spy: ProbeSpy
    let center = NotificationCenter()
    let suite = "com.writronic.wherever.tests.access.\(UUID().uuidString)"
    let defaults: UserDefaults
    var settingsOpens = true
    var startError: WhereverError?
    var confirms: Bool
    private(set) var confirmCalls = 0
    var onPrepare: @MainActor () -> Void = {}
    var onStart: @MainActor () throws -> Void = {}
    private(set) var prepares = 0
    private(set) var stageAtPrepare: AccessModel.Stage?
    private(set) var starts = 0
    private(set) var summons = 0
    private(set) var activations = 0
    private(set) var opened: [URL] = []
    private(set) var quits = 0
    private(set) var events: [String] = []
    private(set) var losses = 0
    let watch: Duration?
    private let tools: WelcomeTools
    var syncHelper: () -> Void = {}
    private(set) var model: AccessModel!

    init(
        granted: Bool = false, confirms: Bool = false, completed: Bool = false, startError: WhereverError? = nil,
        watch: Duration? = nil, tools: (UserDefaults) -> WelcomeTools = { _ in .inert() }
    ) {
        self.startError = startError
        self.watch = watch
        defaults = UserDefaults(suiteName: suite)!
        self.tools = tools(defaults)
        if completed { defaults.set(true, forKey: AccessModel.completedKey) }
        spy = ProbeSpy(granted)
        self.confirms = confirms
        model = makeModel()
    }

    func makeModel(previews: Bool = false) -> AccessModel {
        let spy = spy
        let stage = WhereverApp.launchStage(previews: previews, defaults: defaults, probe: { spy.probe() }, confirm: { confirm() })
        let model = AccessModel(
            defaults: defaults, center: center, stage: stage, probe: { spy.probe() },
            confirm: { [weak self] in self?.confirm() ?? false },
            prepare: { [weak self] in
                self?.prepares += 1
                self?.stageAtPrepare = self?.model?.stage
                self?.onPrepare()
            },
            start: { [weak self] in
                self?.starts += 1
                self?.events.append("start")
                if let error = self?.startError { throw error }
                try self?.onStart()
            },
            summon: { [weak self] in
                self?.summons += 1
                self?.events.append("summon")
            },
            open: { [weak self] url in
                self?.opened.append(url)
                return self?.settingsOpens ?? false
            },
            quit: { [weak self] in self?.quits += 1 },
            activate: { [weak self] in self?.activations += 1 },
            tools: tools, syncHelper: { [weak self] in self?.syncHelper() }, watchInterval: watch
        )
        model.lost = { [weak self] in self?.losses += 1 }
        return model
    }

    private func confirm() -> Bool {
        confirmCalls += 1
        return confirms
    }

    static func bundle(_ language: String) -> Bundle {
        Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? Bundle(for: AccessFixture.self)
    }

    func open(_ language: String = "en") async throws -> NSWindow {
        model.showWelcome(bundle: Self.bundle(language))
        try await untilTrue(waitingFor: "the welcome in \(language)") { model.welcome?.window?.isVisible == true }
        return try #require(model.welcome?.window)
    }

    func activate() { center.post(name: NSApplication.didBecomeActiveNotification, object: nil) }

    func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    func clean() {
        model.welcome?.window?.close()
        defaults.removePersistentDomain(forName: suite)
    }

    func complete() throws {
        let button = try #require(model.welcome?.window?.defaultButtonCell?.controlView as? NSButton)
        let go = Self.bundle("en").localizedString(forKey: "Let's Go!", value: nil, table: "Welcome")
        for _ in 0..<3 where button.title != go { button.performClick(nil) }
        #expect(button.title == go)
        button.performClick(nil)
    }

    func enter(_ stage: AccessModel.Stage) async throws {
        try await settle()
        switch stage {
        case .waiting: break
        case .stillOff:
            model.openSettings()
            activate()
        case .checkFailed: spy.fail()
        case .settingsFailed:
            settingsOpens = false
            model.openSettings()
        case .granted, .reopen:
            confirms = stage == .granted
            spy.set(true)
        case .startFailed:
            startError = .io
            confirms = true
            spy.set(true)
            await model.tick()
            model.completeWelcome(choices: model.storedChoices)
        case .ready: Issue.record("use complete() to start")
        }
        if stage != .settingsFailed { await model.tick() }
        try await untilTrue(waitingFor: "welcome stage \(stage)") { model.stage == stage }
    }

}

private let settingsLink = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

@Suite(.serialized) struct AccessModelTests {
    @Test func aLaunchWithoutAccessShowsTheWelcomeAgainAtTheNextLaunch() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        #expect(fixture.model.showsWelcome)
        let window = try await fixture.open()
        window.performClose(nil)
        #expect(fixture.model.welcome == nil)
        let next = fixture.makeModel()
        #expect(next.showsWelcome)
        #expect(next.stage == .waiting)
    }

    @Test func theChildProbeOpensTheThreeProtectedFilesAndReadsNothing() throws {
        let arguments = AccessModel.probeArguments(home: "/Users/me")
        #expect(arguments == [
            "-c", #"s=2; for f do e=$({ true < "$f"; } 2>&1) && exit 0; echo "$e"; case $e in *"not permitted"*) s=1;; esac; done; exit $s"#, "sh",
            "/Users/me/Library/Application Support/com.apple.TCC/TCC.db",
            "/Users/me/Library/Safari/Bookmarks.plist",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ])
        #expect(!arguments.contains { $0.contains("Containers") })

        let home = FileManager.default.temporaryDirectory.appending(component: "wherever.access.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let safari = home.appending(component: "Library/Safari")
        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
        try Data().write(to: safari.appending(component: "Bookmarks.plist"))
        #expect(AccessModel.run(URL(filePath: "/bin/sh"), AccessModel.probeArguments(home: home.path(percentEncoded: false)), timeout: 5) == .granted)
    }

    @Test func everyProbePathMissingIsACheckFailure() throws {
        let home = FileManager.default.temporaryDirectory.appending(component: "wherever.access.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let homePaths = { Array(AccessModel.probeArguments(home: home.path(percentEncoded: false)).dropLast()) }
        let probe = { AccessModel.run(URL(filePath: "/bin/sh"), homePaths(), timeout: 5) }
        #expect(probe() == .failed)
        let defaults = try #require(UserDefaults(suiteName: "com.writronic.wherever.tests.access.\(UUID().uuidString)"))
        #expect(WhereverApp.launchStage(previews: false, defaults: defaults, probe: probe, confirm: { true }) == .checkFailed)

        let bookmarks = home.appending(component: "Library/Safari/Bookmarks.plist")
        try FileManager.default.createDirectory(at: bookmarks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: bookmarks)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: bookmarks.path(percentEncoded: false))
        #expect(probe() == .failed)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bookmarks.path(percentEncoded: false))
        #expect(probe() == .granted)
    }

    @Test func aProbeFailureIsDistinctFromDeniedAccess() throws {
        #expect(AccessModel.run(URL(filePath: "/nonexistent/wherever-probe"), [], timeout: 5) == .failed)
        #expect(AccessModel.run(URL(filePath: "/usr/bin/true"), [], timeout: 5) == .granted)
        #expect(AccessModel.run(URL(filePath: "/usr/bin/false"), [], timeout: 5) == .denied)

        let pidFile = FileManager.default.temporaryDirectory.appending(component: "wherever.access.\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let started = ContinuousClock.now
        let sleeper = #"echo $$ > "$1"; exec /bin/sleep 30"#
        #expect(AccessModel.run(URL(filePath: "/bin/sh"), ["-c", sleeper, "sh", pidFile.path(percentEncoded: false)], timeout: 0.5) == .failed)
        #expect(ContinuousClock.now - started < .seconds(10))
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "the timed-out child \(pid) still runs")
    }

    @Test func theTickerProbesEveryTwoSecondsOnlyWhileTheWelcomeIsVisible() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        #expect(AccessModel.tickInterval == .seconds(2))
        #expect(!fixture.model.isTicking)
        let window = try await fixture.open()
        #expect(fixture.model.isTicking)
        try await untilTrue(within: .seconds(4), waitingFor: "the third probe") { fixture.spy.calls >= 3 }
        window.performClose(nil)
        #expect(!fixture.model.isTicking)
        let calls = fixture.spy.calls
        fixture.activate()
        fixture.model.refresh()
        try await fixture.settle()
        #expect(fixture.spy.calls == calls)

        let second = AccessFixture()
        defer { second.clean() }
        _ = try await second.open()
        try await untilTrue(waitingFor: "the probe at show") { second.spy.calls >= 2 }
        try await second.settle()
        second.spy.block(true)
        let before = second.spy.calls
        let running = Task { await second.model.tick() }
        try await untilTrue(waitingFor: "the held probe") { second.spy.calls == before + 1 }
        await second.model.tick()
        second.activate()
        try await second.settle()
        #expect(second.spy.calls == before + 1)
        second.spy.block(false)
        second.spy.release()
        await running.value
    }

    @Test func aLaunchWithAccessShowsNoWelcomeAndTheWelcomeNeverProbes() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, completed: true)
        defer { fixture.clean() }
        #expect(!fixture.model.showsWelcome)
        #expect(fixture.model.stage == .ready)
        #expect(fixture.spy.calls == 1)
        fixture.model.showWelcome(bundle: AccessFixture.bundle("en"))
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.model.welcome == nil)
        #expect(!fixture.model.isTicking)
        #expect(fixture.spy.calls == 1)
    }

    @Test func openSettingsOpensTheOneLink() {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        #expect(AccessModel.settingsURL.absoluteString == settingsLink)
        fixture.model.openSettings()
        #expect(fixture.opened == [AccessModel.settingsURL])
        fixture.model.openSettings()
        #expect(fixture.opened == [AccessModel.settingsURL, AccessModel.settingsURL])
        #expect(fixture.model.stage == .waiting)
    }

    @Test func returningFromSettingsWithoutAccessWarnsAndAGrantClearsIt() async throws {
        let fixture = AccessFixture(confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        try await fixture.settle()
        fixture.model.openSettings()
        await fixture.model.tick()
        #expect(fixture.model.stage == .waiting)
        fixture.activate()
        try await untilTrue(waitingFor: "the still-off warning") { fixture.model.stage == .stillOff }
        #expect(fixture.starts == 0 && fixture.model.isTicking)
        fixture.spy.set(true)
        await fixture.model.tick()
        #expect(fixture.model.stage == .granted && window.isVisible)
        #expect(fixture.starts == 0 && fixture.summons == 0 && fixture.activations == 0)
    }

    @Test func aFailedCheckRetriesAndKeepsDenialDistinct() async throws {
        let fixture = AccessFixture(confirms: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        try await fixture.enter(.checkFailed)
        #expect(fixture.model.isTicking && fixture.starts == 0)
        #expect(fixture.makeModel().stage == .checkFailed)
        let calls = fixture.spy.calls
        fixture.spy.set(false)
        try await untilTrue(within: .seconds(4), waitingFor: "the ticker's retry") { fixture.spy.calls > calls && fixture.model.stage == .waiting }
        fixture.spy.fail()
        await fixture.model.tick()
        #expect(fixture.model.stage == .checkFailed)
        fixture.spy.set(true)
        await fixture.model.tick()
        #expect(fixture.model.stage == .granted && fixture.starts == 0)
    }

    @Test func aFailedSettingsOpenShowsAProblemAndCanRetry() async throws {
        let fixture = AccessFixture(confirms: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        try await fixture.enter(.settingsFailed)
        #expect(fixture.opened == [AccessModel.settingsURL])
        #expect(fixture.model.isTicking && fixture.starts == 0)
        fixture.settingsOpens = true
        fixture.model.openSettings()
        #expect(fixture.opened == [AccessModel.settingsURL, AccessModel.settingsURL])
        #expect(fixture.model.stage == .waiting)
        fixture.settingsOpens = false
        fixture.model.openSettings()
        fixture.spy.set(true)
        await fixture.model.tick()
        #expect(fixture.model.stage == .granted && fixture.starts == 0)
    }

    @Test func aProbeThatFailsAfterTheGrantKeepsReopen() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        _ = try await fixture.open()
        fixture.spy.set(true)
        await fixture.model.tick()
        try await untilTrue(waitingFor: "the reopen state") { fixture.model.stage == .reopen }
        fixture.spy.set(false)
        await fixture.model.tick()
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.model.stage == .reopen)
        #expect(fixture.starts == 0)
    }

    @Test func aGrantMadeWhileTheWelcomeWasClosedIsSeenOnTheNextShow() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        let window = try await fixture.open()
        window.performClose(nil)
        fixture.spy.set(true)
        let calls = fixture.spy.calls
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.spy.calls == calls)
        #expect(fixture.model.stage == .waiting)
        _ = try await fixture.open()
        try await untilTrue(waitingFor: "the reopen state") { fixture.model.stage == .reopen }
        #expect(fixture.starts == 0)
    }
}

@Suite(.serialized) struct LaunchTests {
    @Test func permissionAloneWaitsForTheDefaultLetsGoButton() async throws {
        let fixture = AccessFixture(confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        try await fixture.settle()
        #expect(fixture.prepares == 0)
        fixture.spy.set(true)
        await fixture.model.tick()
        #expect(fixture.prepares == 1 && fixture.stageAtPrepare == .granted)
        #expect(fixture.starts == 0 && fixture.summons == 0)
        await fixture.model.tick()
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.prepares == 1 && fixture.starts == 0)
        #expect(window.isVisible)
        #expect(fixture.model.welcome?.window === window)
        #expect(window.defaultButtonCell?.title == AccessFixture.bundle("en").localizedString(forKey: "Next", value: nil, table: "Welcome"))
    }

    @Test func noWaitingStagePreparesAndAFailedStartLeavesOnePrepare() async throws {
        for stage in [AccessModel.Stage.waiting, .stillOff, .checkFailed, .settingsFailed] {
            let fixture = AccessFixture(confirms: true)
            defer { fixture.clean() }
            _ = try await fixture.open()
            try await fixture.enter(stage)
            #expect(fixture.prepares == 0, "\(stage)")
        }
        let failed = AccessFixture(confirms: true)
        defer { failed.clean() }
        _ = try await failed.open()
        try await failed.enter(.startFailed)
        #expect(failed.prepares == 1 && failed.starts == 1 && failed.summons == 0)
    }

    @Test func aCloseAfterTheGrantStartsNothingAndReopeningPreparesNoMore() async throws {
        let fixture = AccessFixture(confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        fixture.spy.set(true)
        await fixture.model.tick()
        #expect(fixture.prepares == 1)
        window.performClose(nil)
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.model.welcome == nil && fixture.model.stage == .granted)
        #expect(fixture.prepares == 1 && fixture.starts == 0 && fixture.summons == 0)
        #expect(fixture.defaults.object(forKey: AccessModel.completedKey) == nil)
        _ = try await fixture.open()
        try await fixture.settle()
        #expect(fixture.prepares == 1 && fixture.starts == 0 && fixture.summons == 0)
        try fixture.complete()
        #expect(fixture.prepares == 1 && fixture.starts == 1 && fixture.summons == 1)
    }

    @Test func aThrowingPrepareLeavesTheWelcomeWorkingAndLetsGoTriesAgain() async throws {
        for failures in [1, Int.max] {
            let fixture = AccessFixture(confirms: true)
            defer { fixture.clean() }
            var builds = 0
            let engine = BuiltOnce<NSObject> {
                builds += 1
                if builds <= failures { throw WhereverError.io }
                return NSObject()
            }
            fixture.onPrepare = WhereverApp.prepareAction(previews: false, engine: engine)
            fixture.onStart = { _ = try engine.value() }
            let window = try await fixture.open()
            fixture.spy.set(true)
            await fixture.model.tick()
            #expect(builds == 1 && fixture.model.stage == .granted)
            #expect(window.isVisible && fixture.starts == 0)
            try fixture.complete()
            #expect(fixture.starts == 1 && builds == 2)
            if failures == 1 {
                #expect(fixture.model.stage == .ready && fixture.summons == 1)
            } else {
                #expect(fixture.model.stage == .startFailed && fixture.summons == 0)
                #expect(window.isVisible)
            }
        }
    }

    @Test func accessBackAfterALostClickBuildsNoSecondEngine() async throws {
        let fixture = AccessFixture(confirms: true)
        defer { fixture.clean() }
        var builds = 0
        let engine = BuiltOnce<NSObject> {
            builds += 1
            return NSObject()
        }
        fixture.onPrepare = WhereverApp.prepareAction(previews: false, engine: engine)
        fixture.onStart = { _ = try engine.value() }
        _ = try await fixture.open()
        fixture.spy.set(true)
        await fixture.model.tick()
        fixture.confirms = false
        try fixture.complete()
        #expect(fixture.model.stage == .reopen && fixture.starts == 0)
        fixture.confirms = true
        fixture.activate()
        try await untilTrue(waitingFor: "the granted state") { fixture.model.stage == .granted }
        try fixture.complete()
        #expect(fixture.model.stage == .ready && fixture.starts == 1)
        #expect(builds == 1)
    }

    @Test func theHolderBuildsOnceAndKeepsTheValue() throws {
        var builds = 0
        let holder = BuiltOnce<NSObject> {
            builds += 1
            return NSObject()
        }
        #expect(builds == 0)
        let first = try holder.value()
        #expect(try holder.value() === first)
        #expect(builds == 1)
    }

    @Test func theHolderTriesAgainAfterAThrow() throws {
        var builds = 0
        let holder = BuiltOnce<NSObject> {
            builds += 1
            if builds == 1 { throw WhereverError.io }
            return NSObject()
        }
        #expect(throws: WhereverError.io) { _ = try holder.value() }
        let second = try holder.value()
        #expect(builds == 2)
        #expect(try holder.value() === second)
        #expect(builds == 2)
    }

    @Test func thePrepareActionBuildsOnceAndNothingInPreviews() {
        var builds = 0
        let holder = BuiltOnce<NSObject> {
            builds += 1
            return NSObject()
        }
        WhereverApp.prepareAction(previews: true, engine: holder)()
        #expect(builds == 0)
        let prepare = WhereverApp.prepareAction(previews: false, engine: holder)
        prepare()
        prepare()
        #expect(builds == 1)
    }

    @Test func firstLaunchWithAccessStillWaitsForLetsGo() {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        #expect(fixture.model.showsWelcome)
        #expect(fixture.model.stage == .granted)
        #expect(fixture.prepares == 1 && fixture.model.welcome == nil)
        #expect(fixture.starts == 0 && fixture.summons == 0)
    }

    @Test func previewsWithAnUnsetCompletionKeyStartReadyWithoutAWelcome() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        #expect(fixture.defaults.object(forKey: AccessModel.completedKey) == nil)
        let probes = fixture.spy.calls
        let model = fixture.makeModel(previews: true)
        #expect(model.stage == .ready && fixture.starts == 1 && fixture.prepares == 0)
        model.showWelcome()
        try await fixture.settle()
        #expect(model.welcome == nil && fixture.spy.calls == probes && fixture.confirmCalls == 0)
        #expect(fixture.defaults.object(forKey: AccessModel.completedKey) == nil)
    }

    @Test func accessLostBeforeTheClickDoesNotCompleteOrStart() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        fixture.confirms = false
        try fixture.complete()
        #expect(fixture.model.stage == .reopen)
        #expect(fixture.starts == 0 && fixture.summons == 0)
        #expect(fixture.defaults.object(forKey: AccessModel.completedKey) == nil)
    }

    @Test func anEngineFailureAfterLetsGoKeepsTheWelcomeAndOffersQuit() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, startError: .io)
        defer { fixture.clean() }
        let window = try await fixture.open()
        try fixture.complete()
        #expect(fixture.model.stage == .startFailed)
        #expect(fixture.starts == 1 && fixture.summons == 0)
        #expect(fixture.defaults.bool(forKey: AccessModel.completedKey))
        #expect(fixture.model.welcome?.window === window && window.isVisible)
        #expect(!fixture.model.isTicking)
        fixture.model.completeWelcome(choices: fixture.model.storedChoices)
        await fixture.model.tick()
        #expect(fixture.model.stage == .startFailed && fixture.starts == 1)
        let quit = try #require(window.defaultButtonCell?.controlView as? NSButton)
        #expect(quit.title == AccessFixture.bundle("en").localizedString(forKey: "Quit Wherever", value: nil, table: "MenuBar"))
        quit.performClick(nil)
        quit.performClick(nil)
        #expect(fixture.quits == 1)
    }

    @Test func anEngineFailureAtACompletedLaunchShowsTheWelcome() async throws {
        for error in [WhereverError.io, .staleGeneration, .stopped, .unknown] {
            let fixture = AccessFixture(granted: true, confirms: true, completed: true, startError: error)
            defer { fixture.clean() }
            #expect(fixture.model.stage == .startFailed && fixture.starts == 1)
            let window = try await fixture.open()
            #expect(window.isVisible && fixture.summons == 0)
            fixture.model.openOrWelcome { Issue.record("a failed engine allowed a search window") }
            try await fixture.settle()
            #expect(fixture.model.welcome?.window === window)
            #expect(fixture.starts == 1 && fixture.summons == 0)
        }
    }

    @Test func aThrowingServiceFactoryLeavesTheLaunchEmpty() {
        let launch = Launch()
        #expect(throws: WhereverError.io) {
            try launch.start { throw WhereverError.io }
        }
        #expect(launch.services == nil)
    }

    @Test func aLaunchWithoutAccessStartsNothingAndOpensOnlyTheWelcome() async throws {
        let fixture = AccessFixture(confirms: true)
        defer { fixture.clean() }
        #expect(fixture.model.stage == .waiting)
        #expect(fixture.starts == 0)
        #expect(fixture.confirmCalls == 0)
        let window = try await fixture.open()
        try await untilTrue(waitingFor: "the probe at show") { fixture.spy.calls >= 2 }
        try await fixture.settle()
        #expect(window.isVisible)
        #expect(fixture.starts == 0 && fixture.confirmCalls == 0 && fixture.summons == 0)
        #expect(fixture.model.stage == .waiting)
    }

    @Test func aGrantWaitsThenTheClickStartsOnceClosesTheWelcomeAndOpensOneWindow() async throws {
        let fixture = AccessFixture(confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        fixture.spy.set(true)
        await fixture.model.tick()
        try await untilTrue(waitingFor: "the granted state") { fixture.model.stage == .granted }
        #expect(fixture.prepares == 1)
        #expect(fixture.starts == 0 && fixture.summons == 0)
        #expect(fixture.activations == 0)
        try fixture.complete()
        #expect(fixture.model.stage == .ready)
        #expect(fixture.prepares == 1)
        #expect(fixture.starts == 1)
        #expect(fixture.summons == 1)
        #expect(fixture.confirmCalls == 2)
        #expect(fixture.model.welcome == nil)
        #expect(!window.isVisible)
        #expect(!fixture.model.isTicking)
        await fixture.model.tick()
        fixture.model.completeWelcome(choices: fixture.model.storedChoices)
        #expect(fixture.defaults.bool(forKey: AccessModel.completedKey))
        fixture.activate()
        fixture.model.showWelcome()
        try await fixture.settle()
        #expect(fixture.starts == 1 && fixture.summons == 1 && fixture.confirmCalls == 2)
        #expect(fixture.prepares == 1)
        #expect(fixture.model.welcome == nil)
        #expect(fixture.quits == 0)
    }

    @Test func letsGoStartsThenSummonsOnceAndASecondCallDoesNothing() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        #expect(fixture.prepares == 1 && fixture.events.isEmpty)
        try fixture.complete()
        #expect(fixture.model.stage == .ready)
        #expect(fixture.events == ["start", "summon"])
        #expect(fixture.model.welcome == nil)
        fixture.model.completeWelcome(choices: fixture.model.storedChoices)
        #expect(fixture.events == ["start", "summon"])
        #expect(fixture.prepares == 1)
    }

    @Test func accessLostAtTheClickReopensAndOffersOnlyQuit() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        fixture.confirms = false
        try fixture.complete()
        #expect(fixture.model.stage == .reopen)
        #expect(fixture.events.isEmpty)
        #expect(fixture.defaults.object(forKey: AccessModel.completedKey) == nil)
        let quit = try #require(fixture.model.welcome?.window?.defaultButtonCell?.controlView as? NSButton)
        #expect(quit.title == AccessFixture.bundle("en").localizedString(forKey: "Quit Wherever", value: nil, table: "MenuBar"))
        quit.performClick(nil)
        #expect(fixture.quits == 1 && fixture.events.isEmpty)
    }

    @Test func aFailingEngineStartsOnceAndSummonsNothing() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, startError: .io)
        defer { fixture.clean() }
        _ = try await fixture.open()
        try fixture.complete()
        #expect(fixture.model.stage == .startFailed)
        #expect(fixture.events == ["start"])
    }

    @Test func aGrantThisProcessCannotReadShowsReopenAndStartsNothing() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        let window = try await fixture.open()
        #expect(fixture.model.stage == .waiting)
        fixture.spy.set(true)
        await fixture.model.tick()
        try await untilTrue(waitingFor: "the reopen state") { fixture.model.stage == .reopen }
        #expect(fixture.confirmCalls == 1)
        #expect(fixture.prepares == 0)
        #expect(fixture.starts == 0 && fixture.summons == 0)
        #expect(fixture.model.stage == .reopen)
        #expect(!fixture.model.isTicking)
        let calls = fixture.spy.calls
        await fixture.model.tick()
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.spy.calls == calls)
        #expect(window.isVisible)
        #expect(fixture.quits == 0)
        #expect(fixture.starts == 0 && fixture.confirmCalls == 2)
        #expect(fixture.model.stage == .reopen)

        let activations = fixture.activations
        fixture.model.openOrWelcome { Issue.record("a window opened in the reopen state") }
        try await fixture.settle()
        #expect(fixture.model.welcome?.window === window)
        #expect(fixture.activations == activations + 1)
        #expect(fixture.starts == 0 && fixture.summons == 0)
        #expect(fixture.prepares == 0)

        fixture.confirms = true
        fixture.activate()
        try await untilTrue(waitingFor: "the granted state") { fixture.model.stage == .granted }
        #expect(fixture.prepares == 1 && fixture.stageAtPrepare == .granted && fixture.starts == 0)
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.prepares == 1 && fixture.starts == 0)

        let relaunch = AccessFixture(granted: true)
        defer { relaunch.clean() }
        #expect(relaunch.model.stage == .reopen)
        #expect(relaunch.prepares == 0)
        #expect(relaunch.model.showsWelcome)
        #expect(relaunch.starts == 0 && relaunch.confirmCalls == 1)
    }

    @Test func reopenChecksAgainOnActivationAndReachesGranted() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        let window = try await fixture.open()
        fixture.spy.set(true)
        await fixture.model.tick()
        try await untilTrue(waitingFor: "the reopen state") { fixture.model.stage == .reopen }
        let calls = fixture.confirmCalls
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.model.stage == .reopen && fixture.confirmCalls == calls + 1)

        fixture.confirms = true
        fixture.activate()
        try await untilTrue(waitingFor: "the granted state") { fixture.model.stage == .granted }
        #expect(window.isVisible && fixture.quits == 0)
        #expect(fixture.starts == 0 && fixture.summons == 0)
        #expect(fixture.defaults.bool(forKey: AccessModel.completedKey) == false)

        try fixture.complete()
        try await untilTrue(waitingFor: "the ready state") { fixture.model.stage == .ready }
        #expect(fixture.starts == 1 && fixture.summons == 1)
        #expect(fixture.defaults.bool(forKey: AccessModel.completedKey))
        #expect(fixture.model.welcome == nil)
    }

    @Test func openOrWelcomeFrontsTheWelcomeBeforeTheGrantAndOpensAfter() async throws {
        let fixture = AccessFixture(confirms: true)
        defer { fixture.clean() }
        var windows = 0
        var settings = 0
        var activations = 0
        var launchers = 0
        var launcherCloses = 0
        let suite = "com.writronic.wherever.tests.launch.routes"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let hotkey = HotkeyModel(defaults: defaults, windows: { [] }, unhide: {}, activate: {})
        let routes = WhereverApp.routes(
            access: fixture.model, summon: { hotkey.summon() }, openWindow: { windows += 1 }, showSettings: { settings += 1 },
            activate: { activations += 1 }, open: { _ in }, quit: {},
            launcher: { launchers += 1 }, closeLauncher: { launcherCloses += 1 }
        )
        hotkey.configure(openWindow: routes.window)
        let asks: [(String, () -> Void)] = [
            ("summon", { routes.menu.summon() }), ("New Window", { routes.menu.newWindow() }), ("Settings", { routes.menu.showSettings() }),
            ("Cmd-N", { routes.menu.newWindow() }), ("hotkey", { routes.hotkey() }),
        ]
        var welcome: NSWindow?
        for (name, ask) in asks {
            ask()
            try await untilTrue(waitingFor: "the welcome after \(name)") { fixture.model.welcome?.window?.isVisible == true }
            if welcome == nil { welcome = fixture.model.welcome?.window }
            #expect(fixture.model.welcome?.window === welcome, "\(name) made a second welcome")
            #expect(windows == 0 && settings == 0 && launchers == 0, "\(name) opened a window before the grant")
        }
        #expect(fixture.activations == asks.count)
        #expect(activations == 0)
        #expect(launcherCloses == 0, "New Window must not store a launcher query before the grant")

        fixture.spy.set(true)
        await fixture.model.tick()
        try await untilTrue(waitingFor: "the granted state") { fixture.model.stage == .granted }
        for (name, ask) in asks {
            ask()
            #expect(windows == 0 && settings == 0 && launchers == 0, "\(name) bypassed Let's Go")
        }
        try await fixture.settle()
        #expect(fixture.model.welcome?.window === welcome)
        try fixture.complete()
        #expect(fixture.model.stage == .ready)
        routes.menu.summon()
        #expect(windows == 1)
        routes.menu.newWindow()
        #expect(windows == 2 && activations == 1 && launcherCloses == 1)
        routes.menu.newWindow()
        #expect(windows == 3 && activations == 2 && launcherCloses == 2)
        routes.menu.showSettings()
        #expect(settings == 1)
        routes.window()
        #expect(windows == 4)
        routes.hotkey()
        #expect(launchers == 1 && windows == 4 && activations == 2)
        try await fixture.settle()
        #expect(fixture.model.welcome == nil)
    }

    @Test func aSearchWindowOpenedBeforeTheGrantClosesItselfAndAsksForTheWelcome() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        func gated() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LaunchGate(ask: { fixture.model.showWelcome() }))
            window.orderFront(nil)
            return window
        }
        let first = gated()
        defer { first.close() }
        try await untilTrue(waitingFor: "the gate to close its window") { !first.isVisible }
        #expect(first.alphaValue == 0)
        try await untilTrue(waitingFor: "the welcome") { fixture.model.welcome?.window?.isVisible == true }
        let welcome = fixture.model.welcome?.window
        let second = gated()
        defer { second.close() }
        try await untilTrue(waitingFor: "the second gate to close its window") { !second.isVisible }
        try await fixture.settle()
        #expect(fixture.model.welcome?.window === welcome)
        #expect(fixture.starts == 0 && fixture.summons == 0)
    }

    @Test func aGrantMadeWhileTheWelcomeWasClosedWaitsForAClickOnTheNextSummon() async throws {
        let fixture = AccessFixture(confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        window.performClose(nil)
        fixture.spy.set(true)
        let calls = fixture.spy.calls
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.spy.calls == calls)
        #expect(fixture.starts == 0 && fixture.prepares == 0)
        fixture.model.openOrWelcome { Issue.record("a window opened before the grant") }
        try await untilTrue(waitingFor: "the granted state") { fixture.model.stage == .granted }
        #expect(fixture.prepares == 1)
        #expect(fixture.starts == 0 && fixture.summons == 0)
        try fixture.complete()
        #expect(fixture.model.stage == .ready)
        #expect(fixture.prepares == 1)
        #expect(fixture.starts == 1)
        #expect(fixture.summons == 1)
        #expect(fixture.activations == 1)
        try await fixture.settle()
        #expect(fixture.model.welcome == nil)
    }

    @Test func aLaunchWithAccessStartsBeforeAnyWindowAndShowsNoWelcome() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, completed: true)
        defer { fixture.clean() }
        #expect(fixture.starts == 1 && fixture.prepares == 0)
        #expect(fixture.model.stage == .ready)
        #expect(fixture.spy.calls == 1 && fixture.confirmCalls == 1)
        var opened = 0
        fixture.model.openOrWelcome { opened += 1 }
        #expect(opened == 1)
        fixture.model.showWelcome()
        try await fixture.settle()
        #expect(fixture.model.welcome == nil)
        #expect(fixture.activations == 0 && fixture.summons == 0 && fixture.starts == 1)
    }
}

@Suite(.serialized) struct WelcomeWindowTests {
    private static let stages: [AccessModel.Stage] = [.waiting, .stillOff, .checkFailed, .settingsFailed, .granted, .reopen, .startFailed]

    private static func status(_ stage: AccessModel.Stage, _ language: String = "en") -> String {
        switch stage {
        case .waiting, .ready: waitingLine(language)
        case .stillOff: text("Full Disk Access is still off. In System Settings > Privacy & Security > Full Disk Access, turn on this copy of Wherever.", language)
        case .checkFailed: text("Wherever could not check Full Disk Access. It will try again. If this continues, quit and reopen Wherever.", language)
        case .settingsFailed: text("System Settings could not open. Open it from the Apple menu, then choose Privacy & Security > Full Disk Access.", language)
        case .granted: "✓ " + text("Full Disk Access is on. Wherever is ready to start.", language)
        case .reopen: reopenLine(language)
        case .startFailed: text("Wherever could not start its search. Quit and reopen Wherever, then try again.", language)
        }
    }

    private static func action(_ stage: AccessModel.Stage, _ language: String = "en") -> String {
        switch stage {
        case .granted: text("Next", language)
        case .reopen, .startFailed: quitTitle(language)
        default: openTitle(language)
        }
    }

    private static let languages = ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"]

    private static func text(_ key: String, _ language: String = "en", table: String = "Welcome") -> String {
        AccessFixture.bundle(language).localizedString(forKey: key, value: nil, table: table)
    }

    private static func title(_ language: String = "en") -> String { text("Welcome to Wherever", language) }

    private static func heading(_ language: String = "en") -> String { text("Welcome to Wherever!", language) }

    private static func motto(_ language: String = "en") -> String { text("Wherever it is, find it.", language) }

    private static func body(_ language: String = "en") -> String {
        [
            text("Wherever reads file names, sizes and dates, and in Normal mode the words inside your files. Nothing leaves your Mac.", language),
            text("Full Disk Access lets Wherever see every folder on this Mac, so it can find any file.", language),
        ].joined(separator: "\n\n")
    }

    private static func waitingLine(_ language: String = "en") -> String {
        text("Under Privacy & Security, Full Disk Access, turn on Wherever.", language)
    }

    private static func reopenLine(_ language: String = "en") -> String {
        text("Quit and reopen Wherever so it can search every folder.", language)
    }

    private static func openTitle(_ language: String = "en") -> String { text("Open System Settings", language) }

    private static func quitTitle(_ language: String = "en") -> String { text("Quit Wherever", language, table: "MenuBar") }

    private func reopen(_ fixture: AccessFixture) async throws {
        fixture.spy.set(true)
        await fixture.model.tick()
        try await untilTrue(waitingFor: "the reopen state") { fixture.model.stage == .reopen }
    }

    private func views<T: NSView>(_ type: T.Type, in window: NSWindow) -> [T] {
        func visit(_ view: NSView) -> [T] { view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + ($0 is NSButton ? [] : visit($0)) } }
        return window.contentView.map(visit)?.filter { !$0.isHiddenOrHasHiddenAncestor } ?? []
    }

    private func buttons(_ window: NSWindow) -> [NSButton] { views(NSButton.self, in: window).filter(\.isEnabled) }

    private func labels(_ window: NSWindow) -> [String] { views(NSTextField.self, in: window).map(\.stringValue) }

    private func checkboxes(_ window: NSWindow) -> [NSButton] { buttons(window).filter { $0.cell?.accessibilityRole() == .checkBox } }

    private func pushButtons(_ window: NSWindow) -> [NSButton] { buttons(window).filter { $0.cell?.accessibilityRole() != .checkBox } }

    private func actionButtons(_ window: NSWindow) -> [NSButton] { pushButtons(window).filter { !($0 is WelcomeStepDot) } }

    private func holder(_ key: String, _ window: NSWindow, sourceLocation: SourceLocation = #_sourceLocation) throws -> NSButton {
        let blanked = key == "\r" && !window.isKeyWindow
        let holders = buttons(window).filter { $0.keyEquivalent == key || (blanked && $0.cell === window.defaultButtonCell) }
        let report = buttons(window).map { "\($0.title) \($0.keyEquivalent.debugDescription)" }
        try #require(holders.count == 1, "\(key.debugDescription) held by \(holders.count) of \(report), key window: \(window.isKeyWindow)", sourceLocation: sourceLocation)
        if key == "\r" {
            try #require(window.defaultButtonCell === holders[0].cell, "Return's holder is not the default button cell", sourceLocation: sourceLocation)
        }
        return holders[0]
    }

    private func pressReturn(_ window: NSWindow, sourceLocation: SourceLocation = #_sourceLocation) throws {
        try holder("\r", window, sourceLocation: sourceLocation).performClick(nil)
    }

    @Test func theWelcomeHoldsIconTitleMottoTextOneButtonAndOneLine() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        let window = try await fixture.open()
        #expect(labels(window) == [Self.heading(), Self.motto(), Self.body(), Self.waitingLine()])
        #expect(buttons(window).map(\.title) == [Self.openTitle()])
        #expect(views(NSImageView.self, in: window).count == 1)

        try await reopen(fixture)
        #expect(labels(window) == [Self.heading(), Self.motto(), Self.body(), Self.reopenLine()])
        #expect(buttons(window).map(\.title) == [Self.quitTitle()])
        #expect(views(NSImageView.self, in: window).count == 1)

        let granted = AccessFixture()
        defer { granted.clean() }
        let shown = try await granted.open()
        try await granted.enter(.granted)
        #expect(labels(shown) == [Self.heading(), Self.motto(), Self.body(), Self.status(.granted)])
        #expect(checkboxes(shown).isEmpty)
        #expect(actionButtons(shown).map(\.title) == [Self.action(.granted)])
        #expect(views(NSImageView.self, in: shown).count == 1)
        #expect(views(NSTextField.self, in: shown).last?.accessibilityIdentifier() == "welcome-status")
    }

    @Test func returnOpensSystemSettingsWhileWaiting() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        let window = try await fixture.open()
        #expect(try holder("\r", window).title == Self.openTitle())
        try pressReturn(window)
        #expect(fixture.opened == [AccessModel.settingsURL])
        try pressReturn(window)
        #expect(fixture.opened == [AccessModel.settingsURL, AccessModel.settingsURL])
        #expect(fixture.quits == 0)
        #expect(window.isVisible)
    }

    @Test func returnQuitsOnceInReopen() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        let window = try await fixture.open()
        try pressReturn(window)
        try await reopen(fixture)
        #expect(try holder("\r", window).title == Self.quitTitle())
        try pressReturn(window)
        try pressReturn(window)
        #expect(fixture.quits == 1)
        #expect(fixture.opened == [AccessModel.settingsURL])
    }

    private func announcer(_ fixture: AccessFixture) -> (WelcomeWindowController, () -> [String]) {
        var posts: [String] = []
        let controller = WelcomeWindowController(model: fixture.model, bundle: AccessFixture.bundle("en")) { _, text in posts.append(text) }
        return (controller, { posts })
    }

    @Test func voiceOverHearsEachNewStatusAndTheButtonWhenItsRoleChanges() async throws {
        let fixture = AccessFixture(confirms: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        let (spy, posts) = announcer(fixture)
        defer { spy.window?.close() }
        #expect(posts().isEmpty, "the first render spoke")

        await fixture.model.tick()
        await fixture.model.tick()
        #expect(posts().isEmpty, "a repeated waiting stage spoke")

        try await fixture.enter(.stillOff)
        #expect(posts() == [Self.status(.stillOff)])

        try await fixture.enter(.granted)
        #expect(posts() == [Self.status(.stillOff), Self.status(.granted) + " " + Self.action(.granted)])

        try fixture.complete()
        try await untilTrue(waitingFor: "the start") { fixture.model.stage == .ready }
        #expect(posts().count == 2, "Let's Go! spoke the waiting line as the welcome closed")
    }

    @Test func voiceOverHearsReopenWithQuitAndThenTheGrantWithLetsGo() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        _ = try await fixture.open()
        let (spy, posts) = announcer(fixture)
        defer { spy.window?.close() }

        try await reopen(fixture)
        #expect(posts() == [Self.reopenLine() + " " + Self.quitTitle()])

        fixture.confirms = true
        fixture.model.refresh()
        try await untilTrue(waitingFor: "the grant after reopen") { fixture.model.stage == .granted }
        #expect(posts() == [Self.reopenLine() + " " + Self.quitTitle(), Self.status(.granted) + " " + Self.action(.granted)])
    }

    private func frame(of view: NSView, in content: NSView) -> CGRect {
        view.superview?.convert(view.alignmentRect(forFrame: view.frame), to: content) ?? .null
    }

    private func frames(_ window: NSWindow) throws -> [(name: String, frame: CGRect, margin: CGFloat)] {
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let margins: [CGFloat: CGFloat] = [
            WelcomeMetrics.titleSize: WelcomeMetrics.titleMargin, WelcomeMetrics.mottoSize: WelcomeMetrics.titleMargin, WelcomeMetrics.textSize: WelcomeMetrics.textMargin,
            WelcomeMetrics.lineSize: WelcomeMetrics.lineMargin,
        ]
        let texts = views(NSTextField.self, in: window).map { label in
            (name: label.stringValue, frame: frame(of: label, in: content), margin: margins[label.font?.pointSize ?? 0] ?? WelcomeMetrics.textMargin)
        }
        let controls = buttons(window).map { (name: $0.title, frame: frame(of: $0, in: content), margin: WelcomeMetrics.textMargin) }
        let images = views(NSImageView.self, in: window).map { (name: "image", frame: frame(of: $0, in: content), margin: CGFloat(0)) }
        return texts + controls + images
    }

    private func checkLayout(_ window: NSWindow, _ state: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let content = try #require(window.contentView)
        #expect(content.frame.width == WelcomeMetrics.width, "content width in \(state)", sourceLocation: sourceLocation)
        let all = try frames(window)
        for item in all {
            #expect(item.frame.minX >= item.margin && item.frame.maxX <= WelcomeMetrics.width - item.margin,
                    "\(item.name) at \(item.frame) leaves its \(item.margin) pt margins in \(state)", sourceLocation: sourceLocation)
            #expect(content.bounds.contains(item.frame), "\(item.name) at \(item.frame) is cut off in \(state)", sourceLocation: sourceLocation)
        }
        for label in views(NSTextField.self, in: window) {
            #expect(label.intrinsicContentSize.height <= label.frame.height, "\(label.stringValue) is clipped in \(state)", sourceLocation: sourceLocation)
        }
        for (index, item) in all.enumerated() {
            for other in all[(index + 1)...] {
                let overlap = item.frame.intersection(other.frame)
                #expect(overlap.isNull || overlap.width <= 0 || overlap.height <= 0,
                        "\(item.name) overlaps \(other.name) in \(state)", sourceLocation: sourceLocation)
            }
        }
        for button in buttons(window) {
            #expect(button.intrinsicContentSize.width <= button.frame.width, "\(button.title) is cut short in \(state)", sourceLocation: sourceLocation)
        }
    }

    @Test func everyLanguageFitsEveryState() async throws {
        for language in Self.languages {
            var widths: Set<CGFloat> = []
            for stage in Self.stages {
                let fixture = AccessFixture()
                defer { fixture.clean() }
                let window = try await fixture.open(language)
                try await fixture.enter(stage)
                #expect(labels(window) == [Self.heading(language), Self.motto(language), Self.body(language), Self.status(stage, language)])
                #expect(actionButtons(window).map(\.title) == [Self.action(stage, language)])
                if language != "en" {
                    #expect(Self.heading(language) != Self.heading(), "untranslated heading in \(language)")
                    #expect(Self.motto(language) != Self.motto(), "untranslated motto in \(language)")
                }
                let privacy = Self.text("Wherever reads file names, sizes and dates, and in Normal mode the words inside your files. Nothing leaves your Mac.", language)
                #expect(labels(window).contains { $0.contains(privacy) })
                if language != "en" {
                    #expect(privacy != Self.text("Wherever reads file names, sizes and dates, and in Normal mode the words inside your files. Nothing leaves your Mac."))
                    #expect(Self.status(stage, language) != Self.status(stage), "untranslated \(stage) in \(language)")
                }
                try checkLayout(window, "\(language) \(stage)")
                let button = try holder("\r", window)
                #expect(button.accessibilityIdentifier() == "welcome-action")
                #expect(views(NSTextField.self, in: window).last?.accessibilityIdentifier() == "welcome-status")
                widths.insert(button.frame.width)
                #expect(button.frame.width * window.backingScaleFactor == (button.frame.width * window.backingScaleFactor).rounded())
            }
            #expect(widths.count == 1, "the button changes width in \(language): \(widths)")
        }
    }

    @Test func theLayoutIsWelcomeMetricsInDevicePixels() async throws {
        for state in Self.stages {
            let fixture = AccessFixture()
            defer { fixture.clean() }
            let window = try await fixture.open()
            try await fixture.enter(state)
            let scale = window.backingScaleFactor
            func off(_ actual: CGFloat, _ expected: CGFloat) -> Int { Int(((actual - expected) * scale).rounded()) }
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded()
            let height = content.bounds.height
            #expect(off(height, (height * scale).rounded() / scale) == 0, "the window height is whole device pixels in \(state)")
            let icon = frame(of: try #require(views(NSImageView.self, in: window).first), in: content)
            let fields = views(NSTextField.self, in: window).map { frame(of: $0, in: content) }
            try #require(fields.count == 4, "fields in \(state)")
            let (heading, motto, body, line) = (fields[0], fields[1], fields[2], fields[3])
            let button = frame(of: try #require(pushButtons(window).first { $0.accessibilityIdentifier() == "welcome-action" }), in: content)
            let above = height - icon.maxY
            let below = body.minY - button.maxY
            #expect(abs(off(above, below)) <= 1, "above \(above), below \(below) in \(state)")
            let steps = frame(of: try #require(views(WelcomeSteps.self, in: window).first), in: content)
            #expect(above >= (content.bounds.height - steps.minY) + WelcomeMetrics.stepsToIcon, "icon top \(above) in \(state)")
            #expect(below >= WelcomeMetrics.textToButton, "text to button \(below) in \(state)")
            #expect(off(icon.width, WelcomeMetrics.iconSize) == 0 && off(icon.height, WelcomeMetrics.iconSize) == 0, "icon size in \(state)")
            #expect(off(icon.minY - heading.maxY, WelcomeMetrics.iconToTitle) == 0, "icon to title in \(state)")
            #expect(off(heading.minY - motto.maxY, WelcomeMetrics.titleToMotto) == 0, "title to motto in \(state)")
            #expect(off(motto.minY - body.maxY, WelcomeMetrics.mottoToText) == 0, "motto to text in \(state)")
            #expect(off(button.minY - line.maxY, WelcomeMetrics.buttonToLine) == 0, "button to line in \(state)")
            #expect(line.minY >= WelcomeMetrics.bottomMargin, "bottom margin \(line.minY) in \(state)")
            #expect(off(heading.width, WelcomeMetrics.titleWidth) == 0, "title width in \(state)")
            #expect(off(motto.width, WelcomeMetrics.titleWidth) == 0, "motto width in \(state)")
            #expect(off(body.width, WelcomeMetrics.textWidth) == 0, "text width in \(state)")
        }
    }

    @Test func aWelcomeBuiltAtTheLargestTextSizeScalesItsTextAndItsButton() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        fixture.defaults.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        let window = try await fixture.open()
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let fields = views(NSTextField.self, in: window)
        #expect(fields.map { $0.font?.pointSize } == [39, 24, 19, 17])
        #expect(fields.first?.font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        let button = try holder("\r", window)
        #expect(button.font?.pointSize == 18)
        #expect(button.intrinsicContentSize.width <= button.frame.width)
        for label in fields { #expect(label.intrinsicContentSize.height <= label.frame.height, "\(label.stringValue) is clipped") }
    }

    private func contrast(_ look: Look, foreground: NSColor, background: NSColor) -> Double {
        func luminance(_ c: [Double]) -> Double {
            let linear = c.prefix(3).map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (a, b) = (luminance(channels(foreground, look)), luminance(channels(background, look)))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test func theLinePassesFourAndAHalfToOneOnEveryThemeWindow() async throws {
        for theme in Theme.allCases {
            for state in Self.stages {
                let fixture = AccessFixture { defaults in
                    defaults.set(theme.rawValue, forKey: Theme.key)
                    return .inert()
                }
                defer { fixture.clean() }
                let window = try await fixture.open()
                try await fixture.enter(state)
                #expect(fixture.model.welcome?.choices.theme == theme)
                let line = try #require(views(NSTextField.self, in: window).last)
                #expect(line.font?.pointSize == WelcomeMetrics.lineSize)
                #expect(line.stringValue == Self.status(state))
                let color = try #require(line.textColor)
                for look in Look.allCases {
                    let expected = state == .granted ? Theme.welcomeGranted : Theme.welcomeWarning
                    #expect(channels(color, look) == channels(expected, look))
                    let ratio = contrast(look, foreground: color, background: theme.windowBackground)
                    #expect(ratio >= 4.5, "the \(state) line reads \(ratio):1 on \(theme) in \(look)")
                }
            }
        }
    }

    @Test func closeCommandWAndEscapeHideItAndStoreNothing() async throws {
        for state in Self.stages {
            for route in ["close", "escape", "plain"] {
                let fixture = AccessFixture()
                defer { fixture.clean() }
                let window = try await fixture.open()
                try await fixture.enter(state)
                let opened = fixture.opened
                let stored = fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]
                switch route {
                case "close": window.performClose(nil)
                case "escape": window.cancelOperation(nil)
                default: window.close()
                }
                #expect(fixture.model.welcome == nil, "\(route) in \(state)")
                #expect(!window.isVisible, "\(route) in \(state)")
                #expect(!fixture.model.isTicking, "\(route) in \(state)")
                #expect(fixture.quits == 0 && fixture.opened == opened, "\(route) in \(state)")
                fixture.confirms = state == .reopen
                #expect(NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]) == NSDictionary(dictionary: stored))
                #expect(fixture.defaults.bool(forKey: AccessModel.completedKey) == (state == .startFailed))
                #expect(fixture.makeModel().showsWelcome, "\(route) in \(state)")
            }
        }

        let fixture = AccessFixture()
        defer { fixture.clean() }
        let window = try await fixture.open()
        try pressReturn(window)
        window.cancelOperation(nil)
        #expect(fixture.opened == [AccessModel.settingsURL])
        #expect(fixture.model.welcome == nil)

        let racing = AccessFixture()
        defer { racing.clean() }
        let shown = try await racing.open()
        try await untilTrue(waitingFor: "the probe at show") { racing.spy.calls >= 2 }
        try await racing.settle()
        racing.spy.set(true)
        racing.spy.block(true)
        let before = racing.spy.calls
        let running = Task { await racing.model.tick() }
        try await untilTrue(waitingFor: "the held probe") { racing.spy.calls == before + 1 }
        shown.performClose(nil)
        racing.spy.block(false)
        racing.spy.release()
        await running.value
        #expect(racing.model.stage == .waiting)
        #expect(racing.model.welcome == nil)
        #expect(!shown.isVisible)
    }

    @Test func exactlyOneVisiblePushButtonHoldsReturnAndNoneHoldsEscape() async throws {
        for state in Self.stages {
            let fixture = AccessFixture()
            defer { fixture.clean() }
            let window = try await fixture.open()
            try await fixture.enter(state)
            #expect(try holder("\r", window).isEnabled, "Return in \(state)")
            #expect(buttons(window).filter { $0.keyEquivalent == "\u{1b}" }.isEmpty, "Escape in \(state)")
            #expect(actionButtons(window).count == 1, "push buttons in \(state)")
            #expect(buttons(window).filter { $0 is WelcomeStepDot }.count == (state == .granted ? 1 : 0), "enabled dots in \(state)")
            #expect(checkboxes(window).isEmpty, "checkboxes in \(state)")
        }
    }

    @Test func twoAsksOpenOneWelcome() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        fixture.model.showWelcome(bundle: AccessFixture.bundle("en"))
        let window = try await fixture.open()
        fixture.model.showWelcome(bundle: AccessFixture.bundle("en"))
        try await fixture.settle()
        #expect(fixture.model.welcome?.window === window)
        window.performClose(nil)
        #expect(fixture.model.welcome == nil)
        let again = try await fixture.open()
        #expect(again !== window)
        #expect(again.isVisible)
    }

    @Test func voiceOverReadsTitleTextButtonAndLineOnceWithNoImage() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        let window = try await fixture.open()
        #expect(window.title == Self.title())
        let images = views(NSImageView.self, in: window)
        #expect(images.count == 1)
        #expect(images.allSatisfy { $0.cell?.isAccessibilityElement() == false })
        for text in [Self.heading(), Self.motto(), Self.body(), Self.waitingLine()] { #expect(labels(window).filter { $0 == text }.count == 1) }
        #expect(buttons(window).allSatisfy { !$0.title.isEmpty })
    }

    @Test func realReturnAndEscapeEventsReachTheWindow() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        let window = try await fixture.open()
        func event(_ key: String, code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code
            ))
        }
        try #require(window.performKeyEquivalent(with: try event("\r", code: 36)), "no button took Return; the window is key: \(window.isKeyWindow)")
        #expect(fixture.opened == [AccessModel.settingsURL])
        (window.firstResponder ?? window).keyDown(with: try event("\u{1b}", code: 53))
        #expect(fixture.model.welcome == nil, "Escape did not close the welcome; first responder: \(String(describing: window.firstResponder))")
        #expect(!window.isVisible)
        #expect(fixture.quits == 0)
    }

    @Test func theWelcomeIsNeverAMainWindow() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        let window = try await fixture.open()
        #expect(window.identifier == nil)
        #expect(!MainWindow.isMain(window))
        try await reopen(fixture)
        #expect(!MainWindow.isMain(window))
    }
}
