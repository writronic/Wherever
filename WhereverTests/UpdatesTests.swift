import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Wherever

private let title = "Check for Updates…"
private let itemID = "app-menu-check-for-updates"

private final class FakeUpdater {
    let canCheck = CurrentValueSubject<Bool, Never>(false)
    let auto = CurrentValueSubject<Bool, Never>(false)
    private(set) var checks = 0
    private(set) var sets: [Bool] = []

    lazy var model = UpdatesModel(
        canCheckForUpdates: canCheck, automaticallyChecks: auto, check: { [self] in checks += 1 }, setAutomaticallyChecks: { [self] in sets.append($0) }
    )
}

private final class UpdatesHost {
    let window: KeyedWindow
    let view: NSView

    init(_ content: some View) {
        let controller = NSHostingController(rootView: AnyView(content.environment(\.locale, Locale(identifier: "en"))))
        window = KeyedWindow(contentViewController: controller)
        view = controller.view
        window.setContentSize(NSSize(width: 400, height: 240))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            window.reportsKey = true
            window.becomeKey()
        }
    }

    func close() {
        window.contentViewController = nil
        window.close()
    }

    func item() async throws -> NSObject {
        try await untilTrue(waitingFor: "the \(itemID) item") {
            view.layoutSubtreeIfNeeded()
            return AXTree.element(itemID, in: view) != nil
        }
        return try #require(AXTree.element(itemID, in: view))
    }

    func waitUntil(enabled: Bool) async throws {
        try await untilTrue(waitingFor: "the item \(enabled ? "enabled" : "disabled")") {
            view.layoutSubtreeIfNeeded()
            return AXTree.element(itemID, in: view).flatMap(AXTree.isEnabled) == enabled
        }
    }

    var itemCount: Int {
        AXTree.elements(in: view).filter {
            (AXTree.value("accessibilityRole", of: $0) as String?) == NSAccessibility.Role.button.rawValue && AXTree.identifier(of: $0) == itemID
        }.count
    }
}

@Suite(.serialized) struct UpdatesTests {
    private func appMenuItem(_ fake: FakeUpdater) -> UpdatesHost { UpdatesHost(CheckForUpdatesButton(model: fake.model)) }

    private func donateItems(_ fake: FakeUpdater) -> UpdatesHost {
        let actions = MenuBarActions(summon: {}, newWindow: {}, showSettings: {}, open: { _ in }, quit: {})
        return UpdatesHost(DonateItems(actions: actions, updates: fake.model))
    }

    @Test func theAppMenuItemFollowsCanCheckForUpdates() async throws {
        let fake = FakeUpdater()
        let host = appMenuItem(fake)
        defer { host.close() }
        try await host.waitUntil(enabled: false)
        fake.canCheck.send(true)
        try await host.waitUntil(enabled: true)
        fake.canCheck.send(false)
        try await host.waitUntil(enabled: false)
    }

    @Test func oneActivationOfTheAppMenuItemChecksOnce() async throws {
        let fake = FakeUpdater()
        fake.canCheck.send(true)
        let host = appMenuItem(fake)
        defer { host.close() }
        try await host.waitUntil(enabled: true)
        #expect(AXTree.press(try await host.item()))
        #expect(fake.checks == 1)
    }

    @Test func oneActivationInTheDonateGroupChecksOnceAndTouchesNoOtherItem() async throws {
        let fake = FakeUpdater()
        fake.canCheck.send(true)
        var other: [String] = []
        let actions = MenuBarActions(
            summon: { other.append("summon") }, newWindow: { other.append("newWindow") }, showSettings: { other.append("settings") },
            open: { other.append("open \($0)") }, quit: { other.append("quit") }
        )
        let host = UpdatesHost(DonateItems(actions: actions, updates: fake.model))
        defer { host.close() }
        try await host.waitUntil(enabled: true)
        #expect(AXTree.press(try await host.item()))
        #expect(fake.checks == 1)
        #expect(other.isEmpty, "\(other)")
    }

    @Test func theDonateGroupHoldsExactlyOneCheckForUpdatesItem() async throws {
        let host = donateItems(FakeUpdater())
        defer { host.close() }
        let item = try await host.item()
        #expect(host.itemCount == 1)
        #expect(AXTree.names(of: item).contains(title), "the item reads \(AXTree.names(of: item))")
    }

    @Test func aDonateGroupBuiltWithoutAnUpdaterShowsTheItemDisabled() async throws {
        let actions = MenuBarActions(summon: {}, newWindow: {}, showSettings: {}, open: { _ in }, quit: {})
        let host = UpdatesHost(DonateItems(actions: actions))
        defer { host.close() }
        try await host.waitUntil(enabled: false)
    }

    @Test func theModelTakesTheFirstValueAtOnceAndNeverChecksOnItsOwn() {
        let fake = FakeUpdater()
        fake.canCheck.send(true)
        #expect(fake.model.canCheckForUpdates)
        fake.canCheck.send(false)
        #expect(!fake.model.canCheckForUpdates)
        #expect(fake.checks == 0)
    }

    @Test func theModelFollowsTheAutomaticSwitchAndNeverSetsItOnItsOwn() {
        let fake = FakeUpdater()
        fake.auto.send(true)
        #expect(fake.model.automaticallyChecks)
        fake.auto.send(false)
        #expect(!fake.model.automaticallyChecks)
        fake.auto.send(true)
        #expect(fake.model.automaticallyChecks)
        #expect(fake.sets.isEmpty)
        #expect(fake.checks == 0)
    }

    @Test func theAutomaticSwitchAsksSparkleAndShowsWhatSparkleSays() async throws {
        let fake = FakeUpdater()
        let host = UpdatesHost(SoftwareUpdatesRows(model: fake.model))
        defer { host.close() }
        let name = "Automatically check for updates"
        let toggle = { AXTree.control(name, in: host.view) }
        try await untilTrue(waitingFor: "the switch off") { host.view.layoutSubtreeIfNeeded(); return toggle().flatMap(AXTree.isOn) == false }
        #expect(toggle().flatMap(AXTree.identifier(of:)) == "general-automatic-updates")
        #expect(AXTree.press(try #require(toggle())))
        try await untilTrue(waitingFor: "the first ask") { fake.sets == [true] }
        host.view.layoutSubtreeIfNeeded()
        #expect(toggle().flatMap(AXTree.isOn) == false, "the switch moved before Sparkle did")
        fake.auto.send(true)
        try await untilTrue(waitingFor: "the switch on") { host.view.layoutSubtreeIfNeeded(); return toggle().flatMap(AXTree.isOn) == true }
        #expect(AXTree.press(try #require(toggle())))
        try await untilTrue(waitingFor: "the second ask") { fake.sets == [true, false] }
        host.view.layoutSubtreeIfNeeded()
        #expect(toggle().flatMap(AXTree.isOn) == true)
        #expect(fake.checks == 0)
    }

    @Test func theSettingsGroupIsOneSwitch() async throws {
        let fake = FakeUpdater()
        fake.canCheck.send(true)
        let host = UpdatesHost(SoftwareUpdatesRows(model: fake.model))
        defer { host.close() }
        let toggle = { AXTree.element("general-automatic-updates", in: host.view) }
        try await untilTrue(waitingFor: "the switch") { host.view.layoutSubtreeIfNeeded(); return toggle() != nil }
        let role = { (element: NSObject) in AXTree.value("accessibilityRole", of: element) as String? ?? "" }
        let elements = AXTree.elements(in: host.view)
        let described = elements.map { "\(role($0)) \(AXTree.names(of: $0))" }
        let controlRoles = [NSAccessibility.Role.button, .checkBox, .popUpButton, .slider].map(\.rawValue)
        let controls = elements.filter { controlRoles.contains(role($0)) }
        #expect(controls.count == 1, "the group holds \(described)")
        #expect(controls.first.flatMap(AXTree.identifier(of:)) == "general-automatic-updates", "the group holds \(described)")
        let texts = elements.filter { role($0) == NSAccessibility.Role.staticText.rawValue && !AXTree.names(of: $0).contains("Automatically check for updates") }
        #expect(texts.isEmpty, "the group holds \(described)")
        #expect(host.itemCount == 0, "the group holds a button: \(described)")
    }

    @Test func theTestHostRunsWithTheUpdaterNotStartedAndNoAutomaticUpdates() {
        #expect(WhereverApp.usesPreviewServices)
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == false)
        for key in ["SUScheduledCheckInterval", "SUAutomaticallyUpdate", "SUEnableSystemProfiling"] { #expect(info[key] == nil, "\(key)") }
    }

    @Test func updateQuitWithUnsavedEditsAsksAndCancelKeepsRunning() async throws {
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        let probe = QuitProbe()
        #expect(probe.delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        try await rig.press(ArchiveWindows.unsavedCancelID, on: window)
        try await probe.replied([false])
        #expect(window.isVisible && window.isDocumentEdited)

        #expect(probe.delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        try await rig.press(ArchiveWindows.unsavedDontSaveID, on: window)
        try await probe.replied([false, true])
        #expect(rig.bytes() == UnsavedArchives.original)
    }
}

@Suite(.serialized) struct UpdateRemindersTests {
    private final class Seen {
        var policies: [NSApplication.ActivationPolicy] = []
        var badges: [String?] = []
    }

    private func make(_ seen: Seen, center: NotificationCenter) -> UpdateReminders {
        let presence = AppPresence(center: center) { seen.policies.append($0) }
        return UpdateReminders(presence: presence) { seen.badges.append($0) }
    }

    @Test func theDriverDelegateAnswersSparklesThreeGentleReminderHooks() {
        let reminders = make(Seen(), center: NotificationCenter())
        #expect(reminders.supportsGentleScheduledUpdateReminders)
        for name in [
            "standardUserDriverWillHandleShowingUpdate:forUpdate:state:", "standardUserDriverDidReceiveUserAttentionForUpdate:",
            "standardUserDriverWillFinishUpdateSession",
        ] {
            #expect(reminders.responds(to: NSSelectorFromString(name)), "\(name)")
        }
    }

    @Test func aScheduledUpdateBadgesAndBringsTheDockBackUntilAttendedAndTheSessionEnds() {
        let center = NotificationCenter()
        let seen = Seen()
        let reminders = make(seen, center: center)
        reminders.willShow(userInitiated: true)
        #expect(seen.badges.isEmpty)
        #expect(seen.policies.isEmpty)
        reminders.willShow(userInitiated: false)
        #expect(seen.badges == ["1"])
        #expect(seen.policies == [.regular])
        let alert = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        center.post(name: NSWindow.didBecomeKeyNotification, object: alert)
        _ = reminders.perform(NSSelectorFromString("standardUserDriverDidReceiveUserAttentionForUpdate:"), with: NSObject())
        #expect(seen.badges == ["1", nil])
        center.post(name: NSWindow.willCloseNotification, object: alert)
        _ = reminders.perform(NSSelectorFromString("standardUserDriverWillFinishUpdateSession"))
        #expect(seen.badges == ["1", nil, nil])
        #expect(seen.policies.last == .accessory)
    }
}
