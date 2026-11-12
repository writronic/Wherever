import AppKit
import Foundation
import ServiceManagement
import Testing
@testable import Wherever
import WhereverInterface

private struct Refused: Error {}

private func freshSuite(_ name: String) -> (defaults: UserDefaults, domain: String) {
    let domain = "com.writronic.wherever.tests.reset.\(name)"
    let defaults = UserDefaults(suiteName: domain)!
    defaults.removePersistentDomain(forName: domain)
    return (defaults, domain)
}

private let storedKeys = [
    "colourTheme", "windowMode", "inspectorShown", "hidesInvisibleFiles", "resultColumns", "foldersFirst",
    "summonHotkey", "excludedFolders", "indexedVolumes", "welcomeCompleted", "NSWindow Frame main-AppWindow-1",
    "appearanceMode", "appLanguage", "AppleLanguages", "SUEnableAutomaticChecks", "launcherOpacity", "textSize", "commandLineTool", "showMenuBarIcon",
]

private func storedValue(_ key: String) -> Any { key == "AppleLanguages" ? ["stored"] : "stored" }

private func fill(_ defaults: UserDefaults) {
    for key in storedKeys { defaults.set(storedValue(key), forKey: key) }
}

private let pathBlock = """
# >>> wherever >>>
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
# <<< wherever <<<

"""

private final class ResetHome {
    let root = FileManager.default.temporaryDirectory.appending(path: "wherever-reset-home-\(UUID().uuidString)")
    var bin: URL { root.appending(path: ".local/bin") }
    var link: URL { bin.appending(path: "wherever") }
    var profile: URL { root.appending(path: ".zshenv") }
    var tool: URL { root.appending(path: "Applications/Wherever.app/Contents/Helpers/wherever") }

    init() throws {
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: tool)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    func close() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct ResetTests {
    @Test func aPendingResetEmptiesTheDomainAndTheDataFolder() {
        let (defaults, domain) = freshSuite("pending")
        fill(defaults)
        defaults.set(true, forKey: Relaunch.pendingKey)
        var removals = 0
        Relaunch.finishPendingReset(defaults: defaults, domain: domain) { removals += 1 }
        #expect(removals == 1)
        for key in storedKeys + [Relaunch.pendingKey] {
            #expect(UserDefaults.standard.persistentDomain(forName: domain)?[key] == nil, "\(key) survived the reset")
        }
    }

    @Test func noMarkerTouchesNothing() {
        let (defaults, domain) = freshSuite("nomarker")
        fill(defaults)
        var removals = 0
        Relaunch.finishPendingReset(defaults: defaults, domain: domain) { removals += 1 }
        #expect(removals == 0)
        let kept = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        for key in storedKeys {
            #expect((kept[key] as? NSObject)?.isEqual(storedValue(key)) == true, "\(key) was cleared without a reset")
        }
        defaults.removePersistentDomain(forName: domain)
    }

    @Test func theResetMarksThenRelaunchesThenUnregistersThenStops() async throws {
        let (defaults, domain) = freshSuite("order")
        defer { defaults.removePersistentDomain(forName: domain) }
        var events: [String] = []
        try await Relaunch.reset(
            defaults: defaults,
            removeCommandLine: { events.append(defaults.bool(forKey: Relaunch.pendingKey) ? "command line after mark" : "command line before mark") },
            relaunch: { events.append(defaults.bool(forKey: Relaunch.pendingKey) ? "relaunch after mark" : "relaunch before mark") },
            unregister: { events.append("unregister") },
            stop: { events.append("stop") }
        )
        #expect(events == ["command line after mark", "relaunch after mark", "unregister", "stop"])
        #expect(defaults.bool(forKey: Relaunch.pendingKey))
    }

    @Test func theResetUnregistersThenEndsTheCopyInThisBundleOnly() async throws {
        let (defaults, domain) = freshSuite("helper.order")
        defer { defaults.removePersistentDomain(forName: domain) }
        let spy = HelperStarterSpy()
        spy.status = .enabled
        spy.running = true
        spy.foreign = true
        let model = CommandLineToolModel.inert()
        let reset = WhereverApp.resetAction(
            previews: false, helper: spy.starter(defaults: defaults), commandLine: model, defaults: defaults, relaunch: { spy.events.append("relaunch") }
        ) { spy.events.append("stop") }
        try await reset()
        #expect(spy.events == ["relaunch", "unregister", "end 42", "stop"])
        #expect(spy.opens.isEmpty && spy.notes.isEmpty)
    }

    @Test func aPendingResetEmptiesTheHelpersDomain() {
        let (defaults, domain) = freshSuite("helper.domain")
        let helperDomain = domain + ".helper"
        let helper = UserDefaults(suiteName: helperDomain)!
        defer { helper.removePersistentDomain(forName: helperDomain) }
        helper.set("1:2", forKey: HelperLink.Key.helperIdentity)
        helper.set(true, forKey: HelperLink.Key.shortcutFailed)

        Relaunch.finishPendingReset(defaults: defaults, domain: domain) {}
        #expect(UserDefaults.standard.persistentDomain(forName: helperDomain)?[HelperLink.Key.helperIdentity] != nil)

        defaults.set(true, forKey: Relaunch.pendingKey)
        Relaunch.finishPendingReset(defaults: defaults, domain: domain) {}
        #expect(UserDefaults.standard.persistentDomain(forName: helperDomain)?.isEmpty ?? true)
        #expect(AppIdentity.bundleIdentifier + ".helper" == HelperLink.helperID)
    }

    @Test func resetAsksBeforeWritingThePendingKey() async throws {
        final class Calls {
            var events: [String] = []
        }
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        let (defaults, domain) = freshSuite("unsaved")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["tr"], forKey: AppLanguage.appleKey)
        let calls = Calls()
        let reset: @MainActor () async throws -> Void = {
            try await Relaunch.reset(
                defaults: defaults, removeCommandLine: { calls.events.append("command line") }, relaunch: { calls.events.append("relaunch") }, unregister: { calls.events.append("unregister") },
                stop: { calls.events.append("stop") }
            )
        }

        let cancelled = Task { @MainActor in try await reset() }
        _ = try await rig.question(on: window)
        #expect(defaults.object(forKey: Relaunch.pendingKey) == nil && calls.events.isEmpty)
        try await rig.press(ArchiveWindows.unsavedCancelID, on: window)
        try await cancelled.value
        #expect(defaults.object(forKey: Relaunch.pendingKey) == nil)
        #expect(UserDefaults.standard.persistentDomain(forName: domain)?[AppLanguage.appleKey] as? [String] == ["tr"])
        #expect(calls.events.isEmpty)
        #expect(window.isVisible && window.isDocumentEdited)

        let confirmed = Task { @MainActor in try await reset() }
        try await rig.press(ArchiveWindows.unsavedDontSaveID, on: window)
        try await confirmed.value
        #expect(calls.events == ["command line", "relaunch", "unregister", "stop"])
        #expect(defaults.bool(forKey: Relaunch.pendingKey))
        #expect(rig.bytes() == UnsavedArchives.original)
    }

    @Test func aFailedRelaunchClearsTheMarkerAndStays() async {
        let (defaults, domain) = freshSuite("failed")
        defer { defaults.removePersistentDomain(forName: domain) }
        var events: [String] = []
        await #expect(throws: Refused.self) {
            try await Relaunch.reset(
                defaults: defaults,
                removeCommandLine: { events.append("command line") },
                relaunch: { events.append("relaunch"); throw Refused() },
                unregister: { events.append("unregister") },
                stop: { events.append("stop") }
            )
        }
        #expect(events == ["command line", "relaunch"])
        #expect(defaults.object(forKey: Relaunch.pendingKey) == nil)
    }

    @Test func aFailedCommandLineRemovalLeavesTheAppRunningAndClearsTheMarker() async throws {
        let (defaults, domain) = freshSuite("commandline.failed")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["tr"], forKey: "AppleLanguages")
        var events: [String] = []
        await #expect(throws: Refused.self) {
            try await Relaunch.reset(
                defaults: defaults,
                removeCommandLine: { events.append("command line"); throw Refused() },
                relaunch: { events.append("relaunch") },
                unregister: { events.append("unregister") },
                stop: { events.append("stop") }
            )
        }
        #expect(events == ["command line"])
        #expect(defaults.object(forKey: Relaunch.pendingKey) == nil)
        #expect(UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] == ["tr"])
    }

    @Test func aProfileTheResetCannotEditStopsBeforeTheRelaunchAndTheHelper() async throws {
        let home = try ResetHome()
        defer { home.close() }
        let bytes = Data((pathBlock + "alias ll='ls -l'\n").utf8)
        try bytes.write(to: home.profile)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: home.profile.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.profile.path(percentEncoded: false)) }
        let (defaults, domain) = freshSuite("commandline.readonly")
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = CommandLineToolModel(linkFolder: home.bin, profile: home.profile, tool: home.tool, defaults: defaults)
        let spy = HelperStarterSpy()
        var events: [String] = []
        let reset = WhereverApp.resetAction(
            previews: false, helper: spy.starter(defaults: defaults), commandLine: model, defaults: defaults, relaunch: { events.append("relaunch") }
        ) { events.append("stop") }
        await #expect(throws: CommandLineToolModel.RemoveFailed.self) { try await reset() }
        #expect(events.isEmpty && spy.events.isEmpty)
        #expect(defaults.object(forKey: Relaunch.pendingKey) == nil)
        #expect(try Data(contentsOf: home.profile) == bytes)
    }

    @Test func theResetDropsTheLanguageOverrideBeforeItStops() async throws {
        let (defaults, domain) = freshSuite("language")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["tr"], forKey: "AppleLanguages")
        defaults.set("tr", forKey: "appLanguage")
        var atRelaunch: [String]?
        var atStop: [String]? = ["not stopped"]
        try await Relaunch.reset(
            defaults: defaults,
            removeCommandLine: {},
            relaunch: { atRelaunch = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] },
            unregister: {},
            stop: { atStop = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] }
        )
        #expect(atRelaunch == ["tr"], "the override went before the waiter started")
        #expect(atStop == nil, "the override survived to the stop: \(String(describing: atStop))")
    }

    @Test func aFailedRelaunchKeepsTheLanguageOverride() async {
        let (defaults, domain) = freshSuite("language.failed")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["tr"], forKey: "AppleLanguages")
        await #expect(throws: Refused.self) {
            try await Relaunch.reset(defaults: defaults, removeCommandLine: {}, relaunch: { throw Refused() }, unregister: {}, stop: {})
        }
        #expect(UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] == ["tr"])
    }

    @Test func theWaiterGetsThisPidAndBundlePath() throws {
        var calls: [(URL, [String])] = []
        try Relaunch.relaunch { calls.append(($0, $1)) }
        try #require(calls.count == 1)
        let (executable, arguments) = calls[0]
        #expect(executable.path(percentEncoded: false) == "/bin/sh")
        #expect(arguments == ["-c", Relaunch.waiterScript, String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath])
        #expect(!Relaunch.waiterScript.contains(Bundle.main.bundlePath))
        #expect(Relaunch.waiterScript.contains("kill -0 \"$0\"") && Relaunch.waiterScript.hasSuffix("open \"$1\""))
    }

    @Test func aPendingResetEmptiesTheDomainWhenThePresenceIsMade() {
        let (defaults, domain) = freshSuite("presence")
        defaults.set("dark", forKey: AppearanceMode.key)
        defaults.set(true, forKey: Relaunch.pendingKey)
        var removals = 0
        _ = WhereverApp.launchPresence(previews: false, defaults: defaults, domain: domain, center: NotificationCenter()) { removals += 1 }
        #expect(removals == 1)
        #expect(UserDefaults.standard.persistentDomain(forName: domain)?[AppearanceMode.key] == nil)
        #expect(UserDefaults.standard.persistentDomain(forName: domain)?[Relaunch.pendingKey] == nil)
    }

    @Test func withoutAPendingResetThePresenceKeepsTheSettings() {
        let (defaults, domain) = freshSuite("presence.nomarker")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("dark", forKey: AppearanceMode.key)
        var removals = 0
        _ = WhereverApp.launchPresence(previews: false, defaults: defaults, domain: domain, center: NotificationCenter()) { removals += 1 }
        #expect(removals == 0)
        #expect(defaults.string(forKey: AppearanceMode.key) == "dark")
    }

    @Test func previewsNeverResetEvenWithTheMarker() {
        let (defaults, domain) = freshSuite("presence.previews")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: Relaunch.pendingKey)
        var removals = 0
        _ = WhereverApp.launchPresence(previews: true, defaults: defaults, domain: domain, center: NotificationCenter()) { removals += 1 }
        #expect(removals == 0)
        #expect(UserDefaults.standard.persistentDomain(forName: domain)?[Relaunch.pendingKey] as? Bool == true)
    }

    private func resetWithFakes(_ home: ResetHome, _ name: String, linkIsOurs: Bool) async throws {
        let before = "export EDITOR=vi\n"
        let after = "alias ll='ls -l'\n"
        try Data((before + pathBlock + after).utf8).write(to: home.profile)
        let (defaults, domain) = freshSuite(name)
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: CommandLineToolModel.key)
        let model = CommandLineToolModel(linkFolder: home.bin, profile: home.profile, tool: home.tool, defaults: defaults)
        #expect(model.isOn && model.linked == linkIsOurs)
        var events: [String] = []
        let reset = WhereverApp.resetAction(
            previews: false, helper: HelperStarterSpy().starter(defaults: defaults), commandLine: model, defaults: defaults, relaunch: { events.append("relaunch") }
        ) { events.append("stop") }
        try await reset()
        #expect(events == ["relaunch", "stop"])
        #expect(try Data(contentsOf: home.profile) == Data((before + after).utf8))
        #expect(defaults.object(forKey: CommandLineToolModel.key) == nil && !model.isOn)
    }

    @Test func theResetRemovesTheCommandLinkAndThePathBlockAndKeepsTheOtherLines() async throws {
        let home = try ResetHome()
        defer { home.close() }
        try FileManager.default.createSymbolicLink(at: home.link, withDestinationURL: home.tool)
        try await resetWithFakes(home, "commandline", linkIsOurs: true)
        #expect((try? FileManager.default.attributesOfItem(atPath: home.link.path(percentEncoded: false))) == nil)
    }

    @Test func theResetLeavesAForeignFileAtTheLinkPath() async throws {
        let home = try ResetHome()
        defer { home.close() }
        let bytes = Data("#!/bin/sh\necho other\n".utf8)
        try bytes.write(to: home.link)
        try await resetWithFakes(home, "commandline.foreign", linkIsOurs: false)
        #expect(try Data(contentsOf: home.link) == bytes)
    }
}
