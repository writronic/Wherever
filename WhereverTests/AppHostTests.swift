import AppKit
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private final class StartCount {
    var count = 0
}

@Suite struct AppHostTests {
    @Test func theTestHostStartsNoEngine() {
        #expect(WhereverApp.usesPreviewServices)
    }

    @Test func theTestHostStartsReadyWithoutProbing() async throws {
        let suite = "com.writronic.wherever.tests.apphost.access.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(defaults.object(forKey: AccessModel.completedKey) == nil)
        let stage = WhereverApp.launchStage(
            previews: true, defaults: defaults,
            probe: {
                Issue.record("the previews wiring called the child probe")
                return .failed
            },
            confirm: {
                Issue.record("the previews wiring asked this process for access")
                return false
            }
        )
        #expect(stage == .ready)
        let starts = StartCount()
        let access = AccessModel(
            defaults: defaults, center: NotificationCenter(), stage: stage,
            probe: {
                Issue.record("the ready model called the child probe")
                return .failed
            },
            confirm: {
                Issue.record("the ready model asked this process for access")
                return false
            },
            start: { starts.count += 1 }, summon: {}, open: { _ in true }, quit: {}, activate: {}
        )
        #expect(starts.count == 1)
        #expect(!access.showsWelcome)
        access.showWelcome()
        try await Task.sleep(for: .milliseconds(2500))
        #expect(access.welcome == nil)
        #expect(!access.isTicking)
        #expect(!access.isWatching)
    }

    @Test func runsOnTheMainThreadInsideTheAppWithTheKitEmbedded() throws {
        #expect(Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier)
        #expect(Thread.isMainThread)
        let frameworks = try #require(Bundle.main.privateFrameworksURL)
        let kit = frameworks.appending(component: "WhereverKit.framework")
        #expect(FileManager.default.fileExists(atPath: kit.standardizedFileURL.path(percentEncoded: false)))
    }

}
