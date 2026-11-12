import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever

private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "com.writronic.wherever.tests.menubar.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private final class PolicySpy {
    var policies: [NSApplication.ActivationPolicy] = []

    func presence(center: NotificationCenter = NotificationCenter()) -> AppPresence {
        AppPresence(center: center, apply: { [self] in policies.append($0) })
    }
}

private let launching = Notification(name: NSApplication.willFinishLaunchingNotification)

@Suite struct MenuBarIconTests {
    @Test func theKeyIsTheOneThePlanNames() {
        #expect(MenuBarIcon.key == "showMenuBarIcon")
        #expect(MenuBarIcon.standard)
    }
}

@Suite(.serialized) struct AppPresenceTests {
    @Test func aHeldQuitWaitsForTheHoldToEnd() async throws {
        var quits = 0
        let presence = AppPresence(center: NotificationCenter(), apply: { _ in })
        presence.staysRunning = { false }
        presence.quit = { quits += 1 }
        presence.holdQuit(for: 1)
        presence.quitIfIdle()
        try await pumpEvents(for: .milliseconds(20))
        #expect(quits == 0)
        try await untilTrue(waitingFor: "the quit after the hold") { quits == 1 }
    }

    @Test func aWindowStartGoesRegularInWillFinishLaunching() {
        let delegate = AppDelegate()
        var regulars = 0
        delegate.launchCommand = nil
        delegate.setRegular = { regulars += 1 }
        delegate.applicationWillFinishLaunching(launching)
        #expect(regulars == 1)
    }

    @Test func aHiddenStartStaysAccessoryInWillFinishLaunching() {
        let delegate = AppDelegate()
        var regulars = 0
        delegate.launchCommand = .launcher
        delegate.setRegular = { regulars += 1 }
        delegate.applicationWillFinishLaunching(launching)
        #expect(regulars == 0)
    }

    @Test func closingTheLastTitledWindowHidesTheDockAndReopeningRestoresItFirst() {
        let center = NotificationCenter()
        let spy = PolicySpy()
        let presence = spy.presence(center: center)
        let main = SpyWindow("main-AppWindow-1")
        let settings = SpyWindow("settings")
        presence.prepareToShowWindow()
        #expect(spy.policies.last == .regular)
        center.post(name: NSWindow.didBecomeKeyNotification, object: main)
        center.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        center.post(name: NSWindow.willCloseNotification, object: main)
        #expect(spy.policies.last == .regular)
        center.post(name: NSWindow.willCloseNotification, object: settings)
        #expect(spy.policies.last == .accessory)
        presence.prepareToShowWindow()
        #expect(spy.policies.last == .regular)
        center.post(name: NSWindow.didBecomeKeyNotification, object: main)
        center.post(name: NSWindow.willCloseNotification, object: main)
        #expect(spy.policies.last == .accessory)
    }

    @Test func anOpenWindowWithoutFocusStillKeepsTheDockWhenItsSiblingCloses() {
        let center = NotificationCenter()
        let spy = PolicySpy()
        let presence = spy.presence(center: center)
        let focused = SpyWindow("main-AppWindow-1")
        let restored = SpyWindow("main-AppWindow-2")
        center.post(name: NSWindow.didBecomeKeyNotification, object: focused)
        center.post(name: NSWindow.didUpdateNotification, object: restored)
        center.post(name: NSWindow.willCloseNotification, object: focused)
        #expect(spy.policies.last == .regular)
        center.post(name: NSWindow.willCloseNotification, object: restored)
        #expect(spy.policies.last == .accessory)
        withExtendedLifetime(presence) {}
    }

    @Test func panelsAndTransparentLaunchGatesNeverKeepTheDockVisible() {
        let center = NotificationCenter()
        let spy = PolicySpy()
        let presence = spy.presence(center: center)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        let gate = SpyWindow("main-AppWindow-gate")
        gate.alphaValue = 0
        presence.applyPolicy()
        for window in [panel, gate] {
            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            center.post(name: NSWindow.willCloseNotification, object: window)
        }
        #expect(spy.policies == [.accessory])
        let main = SpyWindow("main-AppWindow-1")
        center.post(name: NSWindow.didBecomeKeyNotification, object: main)
        #expect(spy.policies.last == .regular)
        center.post(name: NSWindow.willCloseNotification, object: main)
        #expect(spy.policies.last == .accessory)
    }

    @Test func aWindowLosingFocusOrBeingMinimizedStaysOpenUntilItCloses() {
        let center = NotificationCenter()
        let spy = PolicySpy()
        let presence = spy.presence(center: center)
        let main = SpyWindow("main-AppWindow-1")
        center.post(name: NSWindow.didBecomeKeyNotification, object: main)
        for event in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSApplication.didHideNotification] {
            center.post(name: event, object: main)
            #expect(spy.policies.last == .regular)
        }
        presence.prepareToShowWindow()
        #expect(spy.policies.last == .regular)
        center.post(name: NSWindow.willCloseNotification, object: main)
        #expect(spy.policies.last == .accessory)
    }

    @Test func theLastWindowClosingQuitsOnTheNextTurnAndNeverInsideTheClose() async throws {
        let center = NotificationCenter()
        let presence = PolicySpy().presence(center: center)
        var quits = 0
        presence.staysRunning = { false }
        presence.quit = { quits += 1 }
        let first = SpyWindow("main-AppWindow-1")
        let second = SpyWindow("settings")
        center.post(name: NSWindow.didBecomeKeyNotification, object: first)
        center.post(name: NSWindow.didBecomeKeyNotification, object: second)
        center.post(name: NSWindow.willCloseNotification, object: first)
        try await pumpEvents(for: .milliseconds(20))
        #expect(quits == 0, "a window is still open")
        center.post(name: NSWindow.willCloseNotification, object: second)
        #expect(quits == 0, "the quit ran inside the close")
        try await pumpEvents(for: .milliseconds(20))
        #expect(quits == 1)
    }

    @Test func theLastWindowClosingWithTheLauncherShownStays() async throws {
        let center = NotificationCenter()
        let presence = PolicySpy().presence(center: center)
        var shown = true
        var quits = 0
        presence.staysRunning = { shown }
        presence.quit = { quits += 1 }
        let window = SpyWindow("main-AppWindow-1")
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        center.post(name: NSWindow.willCloseNotification, object: window)
        try await pumpEvents(for: .milliseconds(20))
        #expect(quits == 0)
        shown = false
        presence.quitIfIdle()
        try await pumpEvents(for: .milliseconds(20))
        #expect(quits == 1)
    }

    @Test func theWindowlessStartsOwnInvisibleWindowClosingDoesNotQuit() async throws {
        let center = NotificationCenter()
        let presence = PolicySpy().presence(center: center)
        var quits = 0
        presence.staysRunning = { false }
        presence.quit = { quits += 1 }
        let gate = SpyWindow("main-AppWindow-gate")
        gate.alphaValue = 0
        center.post(name: NSWindow.didBecomeKeyNotification, object: gate)
        center.post(name: NSWindow.willCloseNotification, object: gate)
        try await pumpEvents(for: .milliseconds(20))
        #expect(quits == 0)
    }

    @Test func awaitingAWindowHoldsTheQuitUntilThatWindowHasOpenedAndClosed() async throws {
        let center = NotificationCenter()
        let presence = PolicySpy().presence(center: center)
        var quits = 0
        presence.staysRunning = { false }
        presence.quit = { quits += 1 }
        presence.prepareToShowWindow()
        #expect(presence.awaitingWindow)
        presence.quitIfIdle()
        try await pumpEvents(for: .milliseconds(20))
        #expect(quits == 0)
        let window = SpyWindow("main-AppWindow-1")
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(!presence.awaitingWindow)
        center.post(name: NSWindow.willCloseNotification, object: window)
        try await pumpEvents(for: .milliseconds(20))
        #expect(quits == 1)
    }

    @Test func aPresenceNobodyBoundNeverQuits() async throws {
        let presence = PolicySpy().presence()
        var quits = 0
        presence.quit = { quits += 1 }
        presence.quitIfIdle()
        try await pumpEvents(for: .milliseconds(20))
        #expect(quits == 0)
    }

    @Test func mainSettingsAndReopenPrepareThePolicyBeforeOpeningButTheLauncherDoesNot() {
        let center = NotificationCenter()
        let spy = PolicySpy()
        let presence = spy.presence(center: center)
        let access = AccessModel(defaults: freshDefaults("access"), center: NotificationCenter(), stage: .ready, probe: { .denied }, confirm: { false }, start: {}, summon: {})
        let window = SpyWindow("main-AppWindow-1")
        var events: [String] = []
        func opened(_ name: String) {
            #expect(spy.policies.last == .regular)
            events.append(name)
            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }
        let routes = WhereverApp.routes(
            access: access, summon: { opened("summon") }, openWindow: { opened("main") }, showSettings: { opened("settings") },
            activate: {}, open: { _ in }, quit: {}, launcher: { events.append("launcher") },
            about: { opened("about") }, keyboardShortcuts: { opened("shortcuts") }, presence: presence
        )
        let delegate = AppDelegate()
        delegate.summon = routes.menu.summon
        presence.applyPolicy()
        routes.hotkey()
        #expect(spy.policies == [.accessory])
        let actions: [() -> Void] = [
            routes.menu.newWindow, routes.menu.showSettings, routes.window, routes.menu.summon,
            { #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)) },
            routes.menu.about, routes.menu.keyboardShortcuts,
        ]
        for action in actions {
            #expect(spy.policies.last == .accessory)
            action()
            center.post(name: NSWindow.willCloseNotification, object: window)
            #expect(spy.policies.last == .accessory)
        }
        #expect(events == ["launcher", "main", "settings", "main", "summon", "summon", "about", "shortcuts"])
    }

    @Test func aDeferredWelcomeSurvivesTheTransparentGateClosingThenReleasesTheDock() {
        let center = NotificationCenter()
        let spy = PolicySpy()
        let presence = spy.presence(center: center)
        let gate = SpyWindow("main-AppWindow-gate")
        gate.alphaValue = 0
        let welcome = SpyWindow("welcome")
        presence.prepareToShowWindow()
        center.post(name: NSWindow.didBecomeKeyNotification, object: gate)
        center.post(name: NSWindow.willCloseNotification, object: gate)
        #expect(spy.policies.last == .regular)
        center.post(name: NSWindow.didBecomeKeyNotification, object: welcome)
        center.post(name: NSWindow.willCloseNotification, object: welcome)
        #expect(spy.policies.last == .accessory)
    }

    @Test func theHostIsAnAccessoryAppByItsPlistAndRegularFromWillFinishLaunching() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
        #expect(NSApp.activationPolicy() == .regular)
    }

    @Test func theTestHostChangesNoPolicy() {
        #expect(WhereverApp.usesPreviewServices)
        let before = NSApp.activationPolicy()
        WhereverApp.presence.applyPolicy()
        #expect(NSApp.activationPolicy() == before)
    }
}

@Suite(.serialized) struct MenuBarActionTests {
    private final class Calls {
        var events: [String] = []

        var actions: MenuBarActions {
            MenuBarActions(
                summon: { self.events.append("summon") },
                newWindow: { self.events.append("newWindow") },
                showSettings: { self.events.append("settings") },
                open: { self.events.append("open \($0.absoluteString)") },
                quit: { self.events.append("quit") },
                about: { self.events.append("about") },
                keyboardShortcuts: { self.events.append("shortcuts") }
            )
        }
    }

    @Test func theDonateLinkIsTheWritronicPage() {
        #expect(AppLinks.donate.absoluteString == "https://writronic.com/donate")
    }

    @Test func donateHandsTheURLSeamExactlyThatURLOnce() {
        let calls = Calls()
        calls.actions.donate()
        #expect(calls.events == ["open https://writronic.com/donate"])
    }

    @Test func newWindowTwiceCallsTheSeamTwiceAndNeverSummons() {
        let calls = Calls()
        calls.actions.newWindow()
        calls.actions.newWindow()
        #expect(calls.events == ["newWindow", "newWindow"])
    }
}

private func viewMenuItem(_ title: String) -> NSMenuItem? {
    func find(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if item.title == title { return item }
            if let found = find(in: item.submenu) { return found }
        }
        return nil
    }
    return find(in: NSApp.mainMenu)
}

private final class SpyWindow: NSWindow {
    var fronted = 0

    convenience init(_ identifier: String) {
        self.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        isReleasedWhenClosed = false
    }

    override var isVisible: Bool { true }
    override func makeKeyAndOrderFront(_ sender: Any?) { fronted += 1 }
}

@Suite(.serialized) struct AppReopenTests {
    private final class Opens {
        var count = 0
    }

    private func delegate(windows: [NSWindow], opens: Opens) -> AppDelegate {
        let model = HotkeyModel(
            defaults: freshDefaults("reopen"),
            windows: { windows }, unhide: {}, activate: {}
        )
        model.configure { opens.count += 1 }
        let delegate = AppDelegate()
        delegate.summon = { model.summon() }
        return delegate
    }

    @Test func aReopenCallsTheSummonSeamOnceAndTellsAppKitItIsHandled() {
        var summons = 0
        let delegate = AppDelegate()
        delegate.summon = { summons += 1 }
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(summons == 1)
    }

    @Test func aReopenWithNoWindowOpensExactlyOne() {
        let opens = Opens()
        _ = delegate(windows: [], opens: opens).applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        #expect(opens.count == 1)
    }

    @Test func theIconOffAndNoShortcutAndNoWindowStillReopenAndBringTheDockBack() {
        let defaults = freshDefaults("reopen.nothing")
        defaults.set(false, forKey: MenuBarIcon.key)
        defaults.set(Data(), forKey: HotkeyModel.defaultsKey)
        let spy = PolicySpy()
        let presence = spy.presence()
        let opens = Opens()
        let model = HotkeyModel(
            defaults: defaults,
            windows: { [] }, unhide: {}, activate: {}
        )
        model.configure { opens.count += 1 }
        let access = AccessModel(defaults: freshDefaults("reopen.nothing.access"), center: NotificationCenter(), stage: .ready, probe: { .denied }, confirm: { false }, start: {}, summon: {})
        let routes = WhereverApp.routes(
            access: access, summon: { model.summon() }, openWindow: {}, showSettings: {}, activate: {},
            open: { _ in }, quit: {}, presence: presence
        )
        let delegate = AppDelegate()
        delegate.summon = routes.menu.summon
        presence.applyPolicy()
        #expect(spy.policies == [.accessory])
        #expect(model.hotkey == nil)

        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))

        #expect(opens.count == 1)
        #expect(spy.policies.last == .regular)
    }

    @Test func aClosedWelcomeWithNoIconReopensItAndBringsTheDockBack() async throws {
        let defaults = freshDefaults("reopen.welcome")
        defaults.set(false, forKey: MenuBarIcon.key)
        let spy = PolicySpy()
        let presence = spy.presence()
        presence.applyPolicy()
        let access = AccessModel(defaults: defaults, center: NotificationCenter(), stage: .waiting, probe: { .denied }, confirm: { false }, start: {}, summon: {})
        let routes = WhereverApp.routes(
            access: access, summon: {}, openWindow: {}, showSettings: {}, activate: {},
            open: { _ in }, quit: {}, launcher: {}, presence: presence
        )
        #expect(spy.policies == [.accessory])
        #expect(access.welcome == nil)
        routes.window()
        try await untilTrue(waitingFor: "the welcome") { access.welcome?.window?.isVisible == true }
        #expect(spy.policies.last == .regular)
        access.welcome?.window?.close()
        try await untilTrue(waitingFor: "the welcome to close") { access.welcome == nil }
        spy.policies = []
        routes.hotkey()
        try await untilTrue(waitingFor: "the welcome again") { access.welcome?.window?.isVisible == true }
        #expect(spy.policies.last == .regular)
        access.welcome?.window?.close()
    }

    @Test func aReopenWithAWindowOpensNoneAndFrontsIt() {
        let opens = Opens()
        let window = SpyWindow("main-AppWindow-1")
        _ = delegate(windows: [window], opens: opens).applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        #expect(opens.count == 0)
        #expect(window.fronted == 1)
    }

    @Test func aSettingsWindowAloneDoesNotAnswerAReopen() {
        let opens = Opens()
        let settings = SpyWindow("com_apple_SwiftUI_Settings_window")
        _ = delegate(windows: [settings], opens: opens).applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        #expect(opens.count == 1)
        #expect(settings.fronted == 0)
    }
}

private final class TextHost {
    let window: KeyedWindow
    let view: NSView

    init(_ content: some View, locale: String, height: CGFloat = 240) {
        let controller = NSHostingController(rootView: AnyView(content.environment(\.locale, Locale(identifier: locale))))
        window = KeyedWindow(contentViewController: controller)
        view = controller.view
        window.setContentSize(NSSize(width: 400, height: height))
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

    func until(
        _ description: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        try await untilTrue(waitingFor: description(), sourceLocation: sourceLocation) {
            view.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    func shows(_ text: String) -> Bool {
        elements().contains { labels(of: $0).contains { $0.contains(text) } }
    }

    func press(_ title: String) -> Bool {
        guard let button = element(.button, title), button.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        return true
    }

    private func element(_ role: NSAccessibility.Role, _ title: String) -> NSObject? {
        elements().first {
            $0.responds(to: NSSelectorFromString("accessibilityRole")) && ($0.value(forKey: "accessibilityRole") as? String) == role.rawValue
                && labels(of: $0).contains { $0.contains(title) }
        }
    }

    private func elements() -> [NSObject] {
        ([view] + descendants(in: view)).flatMap { collect($0) }
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func collect(_ object: NSObject) -> [NSObject] {
        var found = [object]
        if object.responds(to: NSSelectorFromString("accessibilityChildren")) {
            for child in object.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] { found += collect(child) }
        }
        return found
    }

    private func labels(of object: NSObject) -> [String] {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { key in
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) as? String : nil
        }
    }
}

@Suite(.serialized) struct QuitWindowsTests {
    @Test func commandQAndTheDocksQuitEndWhereverAndADockClickStillSummons() {
        let delegate = AppDelegate()
        var opens = 0
        delegate.summon = { opens += 1 }
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(opens == 1)
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
    }

    @Test func fileMenuCloseAllWithUnsavedEditsAsks() async throws {
        let closeAll = NSSelectorFromString("closeAll:")
        func item(in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            menu.delegate?.menuNeedsUpdate?(menu)
            return menu.items.first { $0.action == closeAll } ?? menu.items.lazy.compactMap { item(in: $0.submenu) }.first
        }
        _ = try #require(item(in: NSApp.mainMenu), "the File menu holds no Close All item")

        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (first, firstWindow) = try await rig.edited(UnsavedArchives.first)
        let (second, secondWindow) = try await rig.edited(UnsavedArchives.second)
        for window in [firstWindow, secondWindow] where window.delegate?.windowShouldClose?(window) != false { window.close() }
        _ = try await rig.question(on: firstWindow)
        _ = try await rig.question(on: secondWindow)
        #expect(first.unsaved && second.unsaved)

        try await rig.press(ArchiveWindows.unsavedCancelID, on: firstWindow)
        try await rig.press(ArchiveWindows.unsavedSaveID, on: secondWindow)
        try await rig.closed(secondWindow)
        try await rig.answered(firstWindow)
        #expect(firstWindow.isVisible && firstWindow.isDocumentEdited)
        #expect(rig.bytes(UnsavedArchives.first) == UnsavedArchives.original)
        #expect(rig.bytes(UnsavedArchives.second) == FakeArchiveClient.saved)
    }

    @Test func theAppMenuHoldsOneQuitItemAndNoCloseAll() async throws {
        var events: [String] = []
        let actions = MenuBarActions(summon: {}, newWindow: {}, showSettings: {}, open: { _ in }, quit: { events.append("quit") })
        let host = TextHost(QuitItems(actions: actions), locale: "en", height: 200)
        defer { host.close() }
        try await host.until("the quit item") { host.shows("Quit Wherever") }
        #expect(!host.shows("Close All"))
        #expect(AXTree.element("app-stop-wherever", in: host.view) == nil)
        try #require(host.press("Quit Wherever"))
        #expect(events == ["quit"])
    }

    @Test func theAppMenuDonateItemOpensTheDonatePageOnce() async throws {
        var opened: [URL] = []
        let actions = MenuBarActions(summon: {}, newWindow: {}, showSettings: {}, open: { opened.append($0) }, quit: {})
        let host = TextHost(DonateItems(actions: actions), locale: "en", height: 200)
        defer { host.close() }
        try await host.until("the Donate item") { host.shows("Donate…") }
        try #require(host.press("Donate…"))
        #expect(opened == [AppLinks.donate])
    }

    @Test func theHostAppMenuHoldsDonateAndQuitOnCommandQ() throws {
        let donate = try #require(viewMenuItem("Donate…"), "the app menu holds no Donate item")
        #expect(donate.isEnabled)
        let quit = try #require(viewMenuItem("Quit Wherever"), "the app menu holds no Quit Wherever item")
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == .command)
    }
}
