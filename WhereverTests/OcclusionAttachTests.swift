import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private final class HiddenWindow: NSWindow {
    var seen = false

    override var occlusionState: NSWindow.OcclusionState { seen ? .visible : [] }

    func set(seen: Bool) {
        self.seen = seen
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }
}

@Suite(.serialized) struct OcclusionAttachTests {
    private func joinedWhileHidden(_ index: IndexModel, _ model: SearchModel) async throws -> HiddenWindow {
        let root = ContentView(index: index, model: model).environment(\.resultActions, ActionRecorder().actions)
        let controller = NSHostingController(rootView: AnyView(root.defaultAppStorage(hostStore())))
        let window = HiddenWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        try await untilTrue(waitingFor: "the watcher to read that the window, never ordered in, is hidden") {
            controller.view.layoutSubtreeIfNeeded()
            return !model.visible
        }
        #expect(!window.isVisible, "no real occlusion notification can have flipped it")
        return window
    }

    private func answered(_ fake: FakeSearchClient, _ model: SearchModel) async throws {
        let generation = fake.latest
        fake.send(.resultsReady(generation, count: 1))
        try await untilTrue(waitingFor: "the answer") { model.results.generation == generation }
    }

    private func handled(_ index: IndexModel, _ fake: FakeSearchClient) async throws {
        let marker = IndexState(phase: .ready, indexed: (index.indexState?.indexed ?? 0) + 1)
        fake.send(.stateChanged(marker))
        try await untilTrue(waitingFor: "every event before the marker") { index.indexState == marker }
    }

    @Test func aClosedWindowThatKeepsItsContentFreesItAndItsModel() async throws {
        let index = IndexModel(client: FakeSearchClient(hits: [.named("Old.app")]))
        weak var closedWindow: HiddenWindow?
        weak var closedModel: SearchModel?
        do {
            var model: SearchModel? = index.makeModel()
            var window: HiddenWindow? = try await joinedWhileHidden(index, try #require(model))
            closedWindow = window
            closedModel = model
            autoreleasepool {
                window?.close()
                window = nil
                model = nil
            }
        }
        try await untilTrue(waitingFor: "the closed window, its content still in it, and its model to go") {
            closedWindow == nil && closedModel == nil
        }
    }

    @Test func theWatcherFollowsOnlyItsOwnWindow() async throws {
        let index = IndexModel(client: FakeSearchClient(hits: [.named("Old.app")]))
        let model = index.makeModel()
        let window = try await joinedWhileHidden(index, model)
        let other = HiddenWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        defer {
            window.contentViewController = nil
            window.close()
            other.close()
        }

        window.set(seen: true)
        #expect(model.visible)
        window.set(seen: false)
        #expect(!model.visible)
        other.set(seen: true)
        #expect(!model.visible, "another window showing leaves this one hidden")
        window.set(seen: true)
        other.set(seen: false)
        #expect(model.visible, "another window hiding leaves this one shown")
    }

    @Test func aWindowMadeWhileHiddenSearchesNothingUntilItShows() async throws {
        let fake = FakeSearchClient(hits: [.named("Old.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        try await answered(fake, model)
        let window = try await joinedWhileHidden(index, model)
        defer {
            window.contentViewController = nil
            window.close()
        }

        fake.setHits([.named("New.app")])
        for _ in 0..<3 { fake.send(.resultsChanged) }
        try await handled(index, fake)
        #expect(fake.queries == ["a"], "a window made hidden searches nothing before its first visibility change")

        window.set(seen: true)
        #expect(model.visible)
        #expect(fake.queries == ["a", "a"], "it lists again once when it shows")
        try await answered(fake, model)
        #expect(model.names == ["New.app"])
    }

    @Test func typingInAWindowMadeWhileHiddenStillSearchesAtOnce() async throws {
        let fake = FakeSearchClient(hits: [.named("Old.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        try await answered(fake, model)
        let window = try await joinedWhileHidden(index, model)
        defer {
            window.contentViewController = nil
            window.close()
        }

        model.query = "ab"
        #expect(fake.queries == ["a", "ab"])
        try await answered(fake, model)
        window.set(seen: true)
        #expect(fake.queries == ["a", "ab"], "showing it with no change searches nothing")
    }
}
