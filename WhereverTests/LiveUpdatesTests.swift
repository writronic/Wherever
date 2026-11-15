import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private let english = Locale(identifier: "en")
private let languages = ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"]

private final class LiveVoice {
    var texts: [String] = []
    private(set) var announcer: Announcer!

    init() {
        announcer = Announcer(post: { [weak self] _, text in self?.texts.append(text) }, schedule: { work in work() })
    }
}

private struct LiveRig {
    let fake = FakeSearchClient()
    let store: UserDefaults
    let voice = LiveVoice()
    let index: IndexModel

    init(_ name: String, storedPause: Bool? = nil) {
        let domain = "com.writronic.wherever.tests.liveupdates.\(name)"
        store = UserDefaults(suiteName: domain)!
        store.removePersistentDomain(forName: domain)
        if let storedPause { store.set(storedPause, forKey: IndexModel.pausedKey) }
        index = IndexModel(client: fake, announcer: voice.announcer, defaults: store, pauseStore: store)
    }

    var storedPause: Bool? { store.object(forKey: IndexModel.pausedKey) as? Bool }

    func bar(clearsBackground: Bool = false) -> SearchHost {
        let host = SearchHost(
            root: AnyView(
                StatusBarView(index: index, model: index.makeModel(), clearsBackground: clearsBackground)
                    .environment(\.locale, english).defaultAppStorage(store)
            ),
            reportsKey: true
        )
        voice.announcer.watch(host.view)
        return host
    }

    func menu() -> SearchHost {
        SearchHost(root: AnyView(LiveUpdatesItems(index: index).environment(\.locale, english).defaultAppStorage(store)))
    }

    func go(_ phase: IndexPhase) async throws {
        fake.send(.stateChanged(IndexState(phase: phase, indexed: 10)))
        try await untilTrue(waitingFor: "the index at \(phase)") { index.indexState?.bootPhase == phase }
    }
}

private func button(in view: NSView) -> NSButton? {
    if let found = view as? NSButton, found.identifier?.rawValue == StatusBarView.liveUpdatesID { return found }
    return view.subviews.lazy.compactMap(button(in:)).first
}

@Suite(.serialized) struct LiveUpdatesTests {
    @Test func everyNewStringIsInEveryLanguage() throws {
        let keys = [
            ("Live updates paused", "Localizable"), ("Click to pause live updates", "Localizable"), ("Click to resume live updates", "Localizable"),
            ("Pause Live Updates", "MenuBar"), ("Resume Live Updates", "MenuBar"), ("Live Updates", "MenuBar"),
        ]
        for language in languages {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            for (key, table) in keys {
                let text = bundle.localizedString(forKey: key, value: "\u{1}", table: table)
                #expect(text != "\u{1}" && (language == "en") == (text == key), "\(table) \(language): \(text)")
            }
        }
    }

    @Test func aRealClickPausesAndAnotherResumes() async throws {
        let rig = LiveRig("click")
        let host = rig.bar()
        defer { host.close() }
        try await rig.go(.live)
        try await host.until("the live button") { host.windowShows("Live updates on") && AXTree.element(StatusBarView.liveUpdatesID, in: host.view) != nil }
        #expect(button(in: host.view)?.toolTip == "Click to pause live updates")

        let first = try await realClick(StatusBarView.liveUpdatesID, in: host)
        try await untilTrue(waitingFor: "paused; \(first)") { rig.fake.liveUpdates == [false] && host.windowShows("Live updates paused") }
        try await untilTrue(waitingFor: "the old live words to leave") { !host.windowShows("Live updates on") }
        #expect(rig.index.liveUpdatesPaused)
        #expect(StatusBarView.mark(.live, paused: true) == .pause)
        #expect(button(in: host.view)?.toolTip == "Click to resume live updates")

        let second = try await realClick(StatusBarView.liveUpdatesID, in: host)
        try await untilTrue(waitingFor: "resumed; \(second)") { rig.fake.liveUpdates == [false, true] && host.windowShows("Live updates on") }
        try await untilTrue(waitingFor: "the old paused words to leave") { !host.windowShows("Live updates paused") }
        #expect(!rig.index.liveUpdatesPaused)
        #expect(button(in: host.view)?.toolTip == "Click to pause live updates")
    }

    @Test func twoWindowsFollowOneModel() async throws {
        let rig = LiveRig("windows")
        let first = rig.bar()
        defer { first.close() }
        let second = rig.bar()
        defer { second.close() }
        try await rig.go(.live)
        for host in [first, second] {
            try await host.until("the live button") { AXTree.element(StatusBarView.liveUpdatesID, in: host.view) != nil }
        }
        let hit = try await realClick(StatusBarView.liveUpdatesID, in: first)
        try await untilTrue(waitingFor: "both bars paused; \(hit)") { first.windowShows("Live updates paused") && second.windowShows("Live updates paused") }
        #expect(rig.fake.liveUpdates == [false])
        rig.index.toggleLiveUpdates()
        try await untilTrue(waitingFor: "both bars live") { first.windowShows("Live updates on") && second.windowShows("Live updates on") }
    }

    @Test func aFailingClientLeavesTheStateAsItWas() async throws {
        let rig = LiveRig("throws")
        let host = rig.bar()
        defer { host.close() }
        try await rig.go(.live)
        try await host.until("the live button") { AXTree.element(StatusBarView.liveUpdatesID, in: host.view) != nil }
        rig.fake.fail(with: .io)
        rig.index.toggleLiveUpdates()
        #expect(!rig.index.liveUpdatesPaused && rig.fake.liveUpdates.isEmpty && rig.voice.texts.isEmpty)
        #expect(host.windowShows("Live updates on"))

        rig.fake.fail(with: nil)
        rig.index.toggleLiveUpdates()
        #expect(rig.index.liveUpdatesPaused && rig.fake.liveUpdates == [false])
        rig.fake.fail(with: .io)
        rig.index.toggleLiveUpdates()
        #expect(rig.index.liveUpdatesPaused, "a failed resume left the bar live")
        try await untilTrue(waitingFor: "still paused") { host.windowShows("Live updates paused") }
    }

    @Test func aStoredPauseReadsPausedFromTheFirstReadyAndTheFirstClickResumes() async throws {
        let rig = LiveRig("stored", storedPause: true)
        #expect(rig.index.liveUpdatesPaused)
        let host = rig.bar()
        defer { host.close() }
        try await rig.go(.ready)
        try await host.until("the paused line at ready") { host.windowShows("Live updates paused") && AXTree.element(StatusBarView.liveUpdatesID, in: host.view) != nil }
        #expect(button(in: host.view)?.toolTip == "Click to resume live updates")
        #expect(rig.fake.liveUpdates.isEmpty, "a stored pause called the engine")

        let hit = try await realClick(StatusBarView.liveUpdatesID, in: host)
        try await untilTrue(waitingFor: "resumed; \(hit)") { rig.fake.liveUpdates == [true] && host.windowShows("Ready") }
        #expect(rig.storedPause == false)
    }

    @Test func aClickFromLiveStoresThePause() async throws {
        let rig = LiveRig("stores")
        #expect(!rig.index.liveUpdatesPaused)
        #expect(rig.storedPause == nil, "a start wrote the key")
        rig.index.toggleLiveUpdates()
        #expect(rig.fake.liveUpdates == [false])
        #expect(rig.storedPause == true)
    }

    @Test func aFailedChangeLeavesTheStoredPauseAsItWas() {
        let paused = LiveRig("failed.resume", storedPause: true)
        paused.fake.fail(with: .io)
        paused.index.toggleLiveUpdates()
        #expect(paused.index.liveUpdatesPaused)
        #expect(paused.storedPause == true)

        let live = LiveRig("failed.pause")
        live.fake.fail(with: .io)
        live.index.toggleLiveUpdates()
        #expect(!live.index.liveUpdatesPaused)
        #expect(live.storedPause == nil)
    }

    @Test func pausedAtReadyShowsTheLineAndClicks() async throws {
        let rig = LiveRig("ready")
        let host = rig.bar()
        defer { host.close() }
        try await rig.go(.live)
        rig.index.toggleLiveUpdates()
        try await rig.go(.ready)
        try await host.until("the paused line at ready") { host.windowShows("Live updates paused") && AXTree.element(StatusBarView.liveUpdatesID, in: host.view) != nil }
        try await untilTrue(waitingFor: "Ready to leave the paused bar") { !host.windowShows("Ready") }
        let hit = try await realClick(StatusBarView.liveUpdatesID, in: host)
        try await untilTrue(waitingFor: "resumed at ready; \(hit)") { rig.fake.liveUpdates == [false, true] && host.windowShows("Ready") }
        #expect(AXTree.element(StatusBarView.liveUpdatesID, in: host.view) == nil, "ready, not paused, is plain text")
    }

    @Test func otherPhasesShowNoControlPausedOrNot() async throws {
        for paused in [false, true] {
            let rig = LiveRig("phases.\(paused)")
            let host = rig.bar()
            defer { host.close() }
            try await rig.go(.live)
            if paused { rig.index.toggleLiveUpdates() }
            for phase in [IndexPhase.loading, .crawling, .finishing, .failed] {
                try await rig.go(phase)
                try await host.until("no control at \(phase), paused \(paused)") {
                    host.view.layoutSubtreeIfNeeded()
                    return AXTree.element(StatusBarView.liveUpdatesID, in: host.view) == nil && button(in: host.view) == nil
                }
                try await untilTrue(waitingFor: "the live words to leave at \(phase), paused \(paused)") { !host.windowShows("Live updates") }
            }
            #expect(StatusBarView.hasLiveControl(nil, paused: paused) == false)
        }
    }

    @Test func theLauncherFooterHasTheWordsAndNoButton() async throws {
        let rig = LiveRig("launcher")
        let host = rig.bar(clearsBackground: true)
        defer { host.close() }
        try await rig.go(.live)
        try await host.until("the live words") { host.windowShows("Live updates on") }
        #expect(AXTree.element(StatusBarView.liveUpdatesID, in: host.view) == nil && button(in: host.view) == nil)
        rig.index.toggleLiveUpdates()
        try await host.until("the paused words") { host.windowShows("Live updates paused") }
        #expect(AXTree.element(StatusBarView.liveUpdatesID, in: host.view) == nil && button(in: host.view) == nil)
    }

    @Test func voiceOverPressesTheButtonAndHearsTheNewState() async throws {
        let rig = LiveRig("voice")
        let host = rig.bar()
        defer { host.close() }
        try await rig.go(.live)
        try await host.until("the live button") { AXTree.element(StatusBarView.liveUpdatesID, in: host.view) != nil }
        let element = try #require(AXTree.element(StatusBarView.liveUpdatesID, in: host.view))
        #expect(AXTree.names(of: element).contains("Live updates on"))
        try #require(AXTree.press(element), "the button took no press")
        try await untilTrue(waitingFor: "the press to pause") { rig.fake.liveUpdates == [false] }
        #expect(rig.voice.texts == ["Live updates paused"])
        let again = try #require(AXTree.element(StatusBarView.liveUpdatesID, in: host.view))
        try #require(AXTree.press(again))
        try await untilTrue(waitingFor: "the press to resume") { rig.fake.liveUpdates == [false, true] }
        #expect(rig.voice.texts == ["Live updates paused", "Live updates on"])
    }

    @Test func theBarKeepsOneLineInEveryState() async throws {
        let rig = LiveRig("height")
        let host = rig.bar()
        defer { host.close() }
        let expected = 1 + StatusBarView.lineHeight(.standard) + 2 * SearchMetrics.statusVerticalInset
        func height() -> CGFloat {
            NSHostingView(rootView: AnyView(
                StatusBarView(index: rig.index, model: rig.index.makeModel()).environment(\.locale, english).defaultAppStorage(rig.store)
            )).fittingSize.height
        }
        try await rig.go(.live)
        #expect(height() == expected, "live")
        rig.index.toggleLiveUpdates()
        #expect(height() == expected, "paused live")
        try await rig.go(.ready)
        #expect(height() == expected, "paused ready")
        try await rig.go(.crawling)
        #expect(height() == expected, "paused crawling")
        rig.index.toggleLiveUpdates()
        try await rig.go(.ready)
        #expect(height() == expected, "ready")
    }

    @Test func theViewMenuItemFollowsTheStateAndPauses() async throws {
        let rig = LiveRig("menu")
        let host = rig.menu()
        defer { host.close() }
        let id = "app-menu-live-updates"
        try await host.until("the disabled item") { host.windowShows("Pause Live Updates") && AXTree.element(id, in: host.view) != nil }
        #expect(AXTree.element(id, in: host.view).flatMap(AXTree.isEnabled) == false, "enabled before the index is live")

        try await rig.go(.live)
        try await host.until("the enabled item") { AXTree.element(id, in: host.view).flatMap(AXTree.isEnabled) == true }
        try #require(AXTree.element(id, in: host.view).map(AXTree.press) == true)
        try await untilTrue(waitingFor: "the item to pause") { rig.fake.liveUpdates == [false] && host.windowShows("Resume Live Updates") }
        try await untilTrue(waitingFor: "the old item title to leave") { !host.windowShows("Pause Live Updates") }

        try await rig.go(.ready)
        try await host.until("still enabled at ready while paused") { AXTree.element(id, in: host.view).flatMap(AXTree.isEnabled) == true }
        try await rig.go(.crawling)
        try await host.until("disabled while crawling") { AXTree.element(id, in: host.view).flatMap(AXTree.isEnabled) == false }

        try await rig.go(.ready)
        try await host.until("enabled again") { AXTree.element(id, in: host.view).flatMap(AXTree.isEnabled) == true }
        try #require(AXTree.element(id, in: host.view).map(AXTree.press) == true)
        try await untilTrue(waitingFor: "the item to resume") { rig.fake.liveUpdates == [false, true] && host.windowShows("Pause Live Updates") }
    }
}
