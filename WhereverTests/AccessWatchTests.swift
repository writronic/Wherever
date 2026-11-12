import AppKit
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private struct RelaunchFailed: Error {}

private func title(_ key: String, table: String = "Welcome") -> String {
    AccessFixture.bundle("en").localizedString(forKey: key, value: nil, table: table)
}

private extension AccessFixture {
    var button: NSButton? { model.welcome?.window?.defaultButtonCell?.controlView as? NSButton }
}

@Suite(.serialized) struct AccessWatchTests {
    @Test func theAppWatchesEveryThirtySeconds() {
        #expect(AccessModel.watchInterval == .seconds(30))
    }

    @Test func twoDenialsInARowWhileSearchingCallLostOnce() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, completed: true, watch: .milliseconds(20))
        defer { fixture.clean() }
        fixture.spy.script([.granted, .denied, .denied])
        #expect(fixture.model.stage == .ready)
        try await untilTrue(waitingFor: "the lost access") { fixture.losses == 1 }
        try await fixture.settle()
        #expect(fixture.losses == 1)
        #expect(fixture.spy.calls >= 5)
        #expect(fixture.model.stage == .ready)
        #expect(fixture.model.welcome == nil)
    }

    @Test func aRevokeOnPageOneBringsBackStillOffAndTheTicker() async throws {
        let fixture = AccessFixture(confirms: true, watch: .milliseconds(20))
        defer { fixture.clean() }
        _ = try await fixture.open()
        #expect(!fixture.model.isWatching)
        try await fixture.enter(.granted)
        #expect(fixture.model.isWatching && !fixture.model.isTicking)
        #expect(fixture.button?.title == title("Next"))
        fixture.spy.set(false)
        try await untilTrue(waitingFor: "the revoke") { fixture.model.stage == .stillOff }
        #expect(fixture.model.welcome?.page == .access)
        #expect(fixture.button?.title == title("Open System Settings"))
        #expect(fixture.model.isTicking && !fixture.model.isWatching)
        #expect(fixture.starts == 0 && fixture.losses == 0 && fixture.summons == 0)
        try await fixture.settle()
        fixture.spy.set(true)
        await fixture.model.tick()
        try await untilTrue(waitingFor: "the second grant") { fixture.model.stage == .granted }
        #expect(fixture.model.isWatching && !fixture.model.isTicking)
        #expect(fixture.prepares == 2)
    }

    @Test func aRevokeWithTheWelcomeClosedLeavesStillOffWithNoTickerUntilTheNextShow() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, watch: .milliseconds(20))
        defer { fixture.clean() }
        #expect(fixture.model.stage == .granted)
        #expect(fixture.model.isWatching)
        #expect(fixture.model.welcome == nil)
        fixture.spy.set(false)
        try await untilTrue(waitingFor: "the revoke") { fixture.model.stage == .stillOff }
        #expect(fixture.model.welcome == nil)
        #expect(!fixture.model.isTicking && !fixture.model.isWatching)
        fixture.model.openOrWelcome { Issue.record("a window opened after the revoke") }
        try await untilTrue(waitingFor: "the welcome after the revoke") { fixture.model.welcome?.window?.isVisible == true }
        #expect(fixture.model.isTicking)
        #expect(fixture.button?.title == title("Open System Settings"))
        #expect(fixture.starts == 0 && fixture.losses == 0)
    }

    @Test func oneDenialThenAGrantDoesNothing() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, completed: true, watch: .milliseconds(20))
        defer { fixture.clean() }
        fixture.spy.script([.denied, .granted, .denied, .granted, .denied])
        try await untilTrue(waitingFor: "the scripted probes") { fixture.spy.calls >= 8 }
        #expect(fixture.losses == 0)
        #expect(fixture.model.stage == .ready)
    }

    @Test func aFailedProbeNeitherCountsNorResets() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, completed: true, watch: .milliseconds(20))
        defer { fixture.clean() }
        fixture.spy.script([.denied, .failed, .denied])
        try await untilTrue(waitingFor: "the lost access") { fixture.losses == 1 }
        try await fixture.settle()
        #expect(fixture.losses == 1)

        let failing = AccessFixture(granted: true, confirms: true, completed: true, watch: .milliseconds(20))
        defer { failing.clean() }
        failing.spy.fail()
        try await untilTrue(waitingFor: "the failed probes") { failing.spy.calls >= 6 }
        #expect(failing.losses == 0)
        #expect(failing.model.stage == .ready)
    }

    @Test func aFailedStartIsNeverWatched() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, completed: true, startError: .io, watch: .milliseconds(20))
        defer { fixture.clean() }
        #expect(fixture.model.stage == .startFailed)
        #expect(!fixture.model.isWatching)
        fixture.spy.set(false)
        fixture.activate()
        await fixture.model.watch()
        try await fixture.settle()
        #expect(fixture.spy.calls == 1)
        #expect(fixture.losses == 0 && fixture.model.stage == .startFailed)
    }

    @Test func anEngineFailureAfterLetsGoStopsTheWatchAndKeepsQuit() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, startError: .io, watch: .milliseconds(20))
        defer { fixture.clean() }
        let window = try await fixture.open()
        #expect(fixture.model.isWatching)
        try fixture.complete()
        #expect(fixture.model.stage == .startFailed)
        #expect(!fixture.model.isWatching && !fixture.model.isTicking)
        let calls = fixture.spy.calls
        fixture.spy.set(false)
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.spy.calls == calls)
        #expect(fixture.model.stage == .startFailed && fixture.losses == 0)
        #expect(fixture.model.welcome?.window === window)
        #expect(fixture.button?.title == title("Quit Wherever", table: "MenuBar"))
    }

    @Test func reopenIsNeverWatchedAndActivationOnlyConfirms() async throws {
        let fixture = AccessFixture(granted: true, watch: .milliseconds(20))
        defer { fixture.clean() }
        #expect(fixture.model.stage == .reopen)
        #expect(!fixture.model.isWatching)
        _ = try await fixture.open()
        fixture.spy.set(false)
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.spy.calls == 1)
        #expect(fixture.model.stage == .reopen && fixture.losses == 0)
        #expect(fixture.confirmCalls >= 2)
        #expect(!fixture.model.isWatching && !fixture.model.isTicking)

        let ticked = AccessFixture(watch: .milliseconds(20))
        defer { ticked.clean() }
        _ = try await ticked.open()
        ticked.spy.set(true)
        await ticked.model.tick()
        try await untilTrue(waitingFor: "the reopen state") { ticked.model.stage == .reopen }
        #expect(!ticked.model.isWatching && !ticked.model.isTicking)
        #expect(ticked.prepares == 0 && ticked.starts == 0)
        let calls = ticked.spy.calls
        ticked.activate()
        try await ticked.settle()
        #expect(ticked.spy.calls == calls)
        #expect(ticked.model.stage == .reopen && ticked.losses == 0)
    }

    @Test func activationRunsOneWatchProbe() async throws {
        for completed in [true, false] {
            let fixture = AccessFixture(granted: true, confirms: true, completed: completed, watch: .seconds(60))
            defer { fixture.clean() }
            #expect(fixture.model.stage == (completed ? .ready : .granted))
            #expect(fixture.spy.calls == 1)
            fixture.activate()
            try await untilTrue(waitingFor: "the probe at activation") { fixture.spy.calls == 2 }
            try await fixture.settle()
            #expect(fixture.spy.calls == 2)
        }
    }

    @Test func aProbeInFlightBlocksASecondProbe() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, completed: true, watch: .seconds(60))
        defer { fixture.clean() }
        fixture.spy.block(true)
        let running = Task { await fixture.model.watch() }
        try await untilTrue(waitingFor: "the held probe") { fixture.spy.calls == 2 }
        await fixture.model.watch()
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.spy.calls == 2)
        fixture.spy.block(false)
        fixture.spy.release()
        await running.value
        #expect(fixture.model.stage == .ready && fixture.losses == 0)
    }

    @Test func aNilIntervalNeverWatches() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, completed: true)
        defer { fixture.clean() }
        #expect(!fixture.model.isWatching)
        fixture.spy.set(false)
        fixture.activate()
        await fixture.model.watch()
        await fixture.model.watch()
        try await fixture.settle()
        #expect(fixture.spy.calls == 1)
        #expect(fixture.losses == 0 && fixture.model.stage == .ready)
    }

    @Test func theLostActionResolvesThenRelaunchesThenStops() {
        var calls: [String] = []
        var answer: ((Bool) -> Void)?
        let action = WhereverApp.accessLostAction(
            previews: false, resolve: { done in
                calls.append("resolve")
                answer = done
            }, relaunch: { calls.append("relaunch") }, stop: { calls.append("stop") }
        )
        action()
        #expect(calls == ["resolve"])
        answer?(true)
        #expect(calls == ["resolve", "relaunch", "stop"])
    }

    @Test func aCancelledSaveOrAFailedRelaunchQuitsNothing() {
        var calls: [String] = []
        let cancelled = WhereverApp.accessLostAction(
            previews: false, resolve: { done in
                calls.append("resolve")
                done(false)
            }, relaunch: { calls.append("relaunch") }, stop: { calls.append("stop") }
        )
        cancelled()
        #expect(calls == ["resolve"])

        calls = []
        let failing = WhereverApp.accessLostAction(
            previews: false, resolve: { $0(true) }, relaunch: {
                calls.append("relaunch")
                throw RelaunchFailed()
            }, stop: { calls.append("stop") }
        )
        failing()
        #expect(calls == ["relaunch"])
    }

    @Test func thePreviewsLostActionDoesNothing() {
        var calls = 0
        let action = WhereverApp.accessLostAction(
            previews: true, resolve: { _ in calls += 1 }, relaunch: { calls += 1 }, stop: { calls += 1 }
        )
        action()
        #expect(calls == 0)
    }

    @Test func theTickerStaysWelcomeOnlyWithTheWatchOn() async throws {
        let fixture = AccessFixture(watch: .milliseconds(20))
        defer { fixture.clean() }
        #expect(!fixture.model.isTicking && !fixture.model.isWatching)
        let window = try await fixture.open()
        #expect(fixture.model.isTicking && !fixture.model.isWatching)
        try await untilTrue(waitingFor: "the probe at show") { fixture.spy.calls >= 2 }
        window.performClose(nil)
        try await fixture.settle()
        #expect(!fixture.model.isTicking && !fixture.model.isWatching)
        let calls = fixture.spy.calls
        fixture.activate()
        fixture.model.refresh()
        await fixture.model.watch()
        try await fixture.settle()
        #expect(fixture.spy.calls == calls)
    }

    @Test func aWatchedLaunchWithAccessShowsNoWelcomeAndProbesOnlyToWatch() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, completed: true, watch: .milliseconds(20))
        defer { fixture.clean() }
        #expect(!fixture.model.showsWelcome)
        #expect(fixture.model.isWatching && !fixture.model.isTicking)
        fixture.model.showWelcome(bundle: AccessFixture.bundle("en"))
        fixture.activate()
        try await untilTrue(waitingFor: "the watch probes") { fixture.spy.calls >= 4 }
        #expect(fixture.model.welcome == nil)
        #expect(!fixture.model.isTicking)
        #expect(fixture.model.stage == .ready && fixture.losses == 0)
    }

    @Test func aWatchedLaunchWithAccessStartsBeforeAnyWindowAndWaitsOneIntervalToProbe() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, completed: true, watch: .milliseconds(20))
        defer { fixture.clean() }
        #expect(fixture.starts == 1 && fixture.prepares == 0)
        #expect(fixture.spy.calls == 1 && fixture.confirmCalls == 1)
        var opened = 0
        fixture.model.openOrWelcome { opened += 1 }
        #expect(opened == 1)
        try await untilTrue(waitingFor: "the first watch probe") { fixture.spy.calls >= 2 }
        #expect(fixture.confirmCalls == 1)
        #expect(fixture.activations == 0 && fixture.summons == 0 && fixture.starts == 1)
    }

    @Test func aWatchedGrantMadeWhileTheWelcomeWasClosedIsSeenOnTheNextShow() async throws {
        let fixture = AccessFixture(watch: .milliseconds(20))
        defer { fixture.clean() }
        let window = try await fixture.open()
        window.performClose(nil)
        fixture.spy.set(true)
        let calls = fixture.spy.calls
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.spy.calls == calls)
        #expect(fixture.model.stage == .waiting && !fixture.model.isWatching)
        _ = try await fixture.open()
        try await untilTrue(waitingFor: "the reopen state") { fixture.model.stage == .reopen }
        #expect(!fixture.model.isWatching && fixture.starts == 0)
    }

    @Test func aWatchedGrantWaitsForTheClickAndTheWatchGoesOnAfterIt() async throws {
        let fixture = AccessFixture(confirms: true, watch: .milliseconds(20))
        defer { fixture.clean() }
        let window = try await fixture.open()
        fixture.spy.set(true)
        await fixture.model.tick()
        try await untilTrue(waitingFor: "the granted state") { fixture.model.stage == .granted }
        #expect(fixture.model.isWatching && !fixture.model.isTicking)
        let granted = fixture.spy.calls
        try await untilTrue(waitingFor: "a watch probe before the click") { fixture.spy.calls > granted }
        #expect(fixture.starts == 0 && fixture.summons == 0 && fixture.prepares == 1)
        try fixture.complete()
        #expect(fixture.model.stage == .ready)
        #expect(fixture.starts == 1 && fixture.summons == 1 && fixture.prepares == 1)
        #expect(fixture.model.welcome == nil && !window.isVisible)
        #expect(fixture.model.isWatching && !fixture.model.isTicking)
        let ready = fixture.spy.calls
        try await untilTrue(waitingFor: "a watch probe after the click") { fixture.spy.calls > ready }
        #expect(fixture.model.stage == .ready && fixture.losses == 0 && fixture.confirmCalls == 2)
    }

    @Test func aWatchedGrantMadeWhileTheWelcomeWasClosedWaitsForAClickOnTheNextSummon() async throws {
        let fixture = AccessFixture(confirms: true, watch: .milliseconds(20))
        defer { fixture.clean() }
        let window = try await fixture.open()
        window.performClose(nil)
        fixture.spy.set(true)
        let calls = fixture.spy.calls
        fixture.activate()
        try await fixture.settle()
        #expect(fixture.spy.calls == calls && !fixture.model.isWatching)
        fixture.model.openOrWelcome { Issue.record("a window opened before the grant") }
        try await untilTrue(waitingFor: "the granted state") { fixture.model.stage == .granted }
        #expect(fixture.model.isWatching)
        #expect(fixture.starts == 0 && fixture.summons == 0)
        try fixture.complete()
        #expect(fixture.model.stage == .ready && fixture.starts == 1 && fixture.summons == 1)
        #expect(fixture.model.isWatching)
    }

    @Test func aWatchedCloseInEveryStageStopsTheTickerAndWatchesOnlyTheGrant() async throws {
        for state in [AccessModel.Stage.waiting, .stillOff, .checkFailed, .settingsFailed, .granted, .reopen, .startFailed] {
            let fixture = AccessFixture(watch: .milliseconds(20))
            defer { fixture.clean() }
            let window = try await fixture.open()
            try await fixture.enter(state)
            window.performClose(nil)
            #expect(fixture.model.welcome == nil, "\(state)")
            #expect(!fixture.model.isTicking, "\(state)")
            #expect(fixture.model.isWatching == (state == .granted), "\(state)")
            try await fixture.settle()
            #expect(fixture.model.stage == state, "\(state)")
            #expect(fixture.losses == 0 && fixture.summons == 0, "\(state)")
        }
    }
}
