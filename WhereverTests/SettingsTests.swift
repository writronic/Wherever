import AppKit
import Carbon
import Combine
import CoreText
import Foundation
import ServiceManagement
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Wherever
import WhereverInterface

private struct Refused: Error {}

private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "com.writronic.wherever.tests.settings.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private final class LoginFixture {
    var status: SMAppService.Status
    var registerFails = false
    var unregisterFails = false
    var holdUnregister = false
    var releaseUnregister: CheckedContinuation<Void, Never>?
    var holdRead = false
    var releaseRead: CheckedContinuation<Void, Never>?
    private(set) var reads = 0
    private(set) var events: [String] = []
    private(set) var registers = 0
    private(set) var unregisters = 0
    private(set) var loginItemsOpened = 0

    init(_ status: SMAppService.Status = .notRegistered) { self.status = status }

    func model() -> LaunchAtLoginModel {
        LaunchAtLoginModel(
            readStatus: { [self] in
                reads += 1
                let answer = status
                if holdRead { await withCheckedContinuation { releaseRead = $0 } }
                return answer
            },
            register: { [self] in
                events.append("register")
                registers += 1
                if registerFails { throw Refused() }
                status = .enabled
            },
            unregister: { [self] in
                events.append("unregister")
                unregisters += 1
                if holdUnregister { await withCheckedContinuation { releaseUnregister = $0 } }
                if unregisterFails { throw Refused() }
                status = .notRegistered
            },
            openLoginItems: { [self] in loginItemsOpened += 1 }
        )
    }
}

@Suite struct LaunchAtLoginModelTests {
    @Test func theModelStartsOffWithoutRegistering() {
        let fixture = LoginFixture()
        let model = fixture.model()
        #expect(!model.isOn && !model.failed && !model.busy)
        #expect(fixture.events.isEmpty)
    }

    @Test func enablingThenDisablingReadsTheSystemAfterEachCall() async {
        let fixture = LoginFixture()
        let model = fixture.model()
        await model.setEnabled(true)
        #expect(fixture.events == ["register"])
        #expect(model.status == .enabled && model.isOn)
        await model.setEnabled(false)
        #expect(fixture.events == ["register", "unregister"])
        #expect(model.status == .notRegistered && !model.isOn)
    }

    @Test func aFailedRegisterStaysFailedThroughRefreshUntilTheNextTry() async {
        let fixture = LoginFixture()
        fixture.registerFails = true
        let model = fixture.model()
        await model.setEnabled(true)
        await model.refresh().value
        #expect(model.failed && !model.isOn && !model.busy)
        fixture.registerFails = false
        await model.setEnabled(true)
        #expect(model.isOn && !model.failed && fixture.registers == 2)
    }

    @Test func notFoundStillAllowsRegistration() async {
        let fixture = LoginFixture(.notFound)
        let model = fixture.model()
        await model.setEnabled(true)
        #expect(fixture.events == ["register"])
        #expect(model.isOn && !model.failed)
    }

    @Test func approvalCanBeDisabledWithoutRegisteringAgain() async {
        let fixture = LoginFixture(.requiresApproval)
        let model = fixture.model()
        await model.refresh().value
        #expect(model.isOn)
        model.openLoginItemsSettings()
        #expect(fixture.loginItemsOpened == 1)
        await model.setEnabled(false)
        #expect(fixture.events == ["unregister"])
        #expect(!model.isOn)
    }

    @Test func aFailedUnregisterKeepsTheSwitchOnAndCanRetry() async {
        let fixture = LoginFixture(.enabled)
        fixture.unregisterFails = true
        let model = fixture.model()
        await model.setEnabled(false)
        #expect(model.failed && model.isOn && !model.busy)
        fixture.unregisterFails = false
        await model.setEnabled(false)
        #expect(fixture.unregisters == 2 && !model.isOn && !model.failed)
    }

    @Test func aSystemChangeIsReadBeforeApplyingTheRequestedValue() async {
        let fixture = LoginFixture()
        let model = fixture.model()
        fixture.status = .enabled
        await model.setEnabled(true)
        #expect(model.isOn && fixture.events.isEmpty)
        fixture.status = .notRegistered
        await model.setEnabled(true)
        #expect(model.isOn && fixture.events == ["register"])
        fixture.status = .notRegistered
        await model.refresh().value
        #expect(!model.isOn)
    }

    @Test func makingTheModelReadsNothingAndARefreshPublishesTheRead() async {
        let fixture = LoginFixture(.requiresApproval)
        let model = fixture.model()
        #expect(fixture.reads == 0)
        #expect(model.status == .notRegistered && !model.isOn)
        await model.refresh().value
        #expect(fixture.reads == 1)
        #expect(model.status == .requiresApproval && model.isOn)
    }

    @Test func activationStartsTheReadWithoutWaitingForIt() async throws {
        let fixture = LoginFixture(.enabled)
        fixture.holdRead = true
        let model = fixture.model()
        let delegate = AppDelegate()
        delegate.refreshLoginStatus = { model.refresh() }
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(model.status == .notRegistered)
        try await untilTrue(waitingFor: "the held read") { fixture.releaseRead != nil }
        #expect(model.status == .notRegistered && fixture.reads == 1)
        fixture.releaseRead?.resume()
        try await untilTrue(waitingFor: "the published read") { model.status == .enabled }
    }

    @Test func anOlderReadLandingLastNeverOverwritesANewerOne() async throws {
        let fixture = LoginFixture()
        fixture.holdRead = true
        let model = fixture.model()
        let older = model.refresh()
        try await untilTrue(waitingFor: "the held read") { fixture.releaseRead != nil }
        let held = fixture.releaseRead
        fixture.holdRead = false
        fixture.status = .enabled
        await model.refresh().value
        #expect(model.status == .enabled)
        held?.resume()
        await older.value
        #expect(model.status == .enabled && fixture.reads == 2)
    }

    @Test func theInertModelTheTestHostGetsRegistersNothingAndStaysOff() async {
        #expect(WhereverApp.usesPreviewServices)
        let model = LaunchAtLoginModel.inert()
        await model.setEnabled(true)
        #expect(model.status == .notRegistered)
        #expect(!model.isOn && !model.failed && !model.busy)
    }
}
private final class ActivateSpy {
    private(set) var calls = 0
    var urls: [URL] = []
    var panels = 0
    func activate() { calls += 1 }
}

private func local(_ key: String, _ table: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: table)
}

private func keyEvent(_ characters: String, _ code: Int, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: UInt16(code)
    ))
}

private let downArrow = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
private let upArrow = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)

private struct SettingsRig {
    let window: SettingsWindow
    let spy: ActivateSpy
    let login: LoginFixture
    let client: FakeSearchClient
    let defaults: UserDefaults
    let locations: LocationsModel
    let hotkeys: HelperStarterSpy
    let hotkey: HotkeyModel

    init(name: String) {
        let spy = ActivateSpy()
        self.spy = spy
        login = LoginFixture()
        let client = FakeSearchClient()
        self.client = client
        defaults = freshDefaults("\(name).store")
        locations = LocationsModel(client: client, defaults: freshDefaults("\(name).locations"), chooseFolder: { spy.panels += 1; return nil })
        hotkeys = HelperStarterSpy()
        hotkey = hotkeys.model(freshDefaults("\(name).hotkey"))
        window = SettingsWindow(
            launchAtLogin: login.model(), locations: locations, hotkey: hotkey,
            client: client, defaults: defaults, open: { spy.urls.append($0) }, activate: { spy.activate() }
        )
    }

    var visibleSettingsWindows: [NSWindow] { NSApp.windows.filter { $0.identifier?.rawValue == "settings" && $0.isVisible } }
    var selection: SettingsWindow.Selection { window.selection }
    var split: NSSplitViewController { window.split }
    var sidebarView: NSView { split.splitViewItems[0].viewController.view }
    var detailView: NSView { split.splitViewItems[1].viewController.view }
    var detailTexts: [String] { ([detailView] + descendants(of: detailView)).flatMap { texts(in: $0) } }

    func shows(_ pane: SettingsPane) -> Bool { AXTree.element(pane.paneID, in: detailView) != nil }

    func until(
        _ description: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        try await untilTrue(waitingFor: description(), sourceLocation: sourceLocation) {
            split.view.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    func outline() async throws -> NSTableView {
        let table = { descendants(of: sidebarView).compactMap { $0 as? NSTableView }.first }
        try await until("the sidebar's rows") { table()?.numberOfRows == SettingsPane.allCases.count }
        return try #require(table())
    }

    func escape() throws {
        let window = try #require(self.window.window)
        (window.firstResponder ?? window).keyDown(with: try keyEvent("\u{1b}", kVK_Escape, in: window))
    }

    func focusInDetail() throws {
        let window = try #require(self.window.window)
        let detail = detailView
        try #require(([detail] + descendants(of: detail)).contains { view in
            window.makeFirstResponder(view) && (window.firstResponder as? NSView)?.isDescendant(of: detail) == true
        }, "no view in the detail took first responder")
    }

    func record() async throws {
        selection.pane = .general
        try await until("the recorder button") { AXTree.control("Launcher shortcut", in: detailView) != nil }
        let recorder = try #require(AXTree.control("Launcher shortcut", in: detailView))
        try #require(AXTree.press(recorder))
        try await until("the recorder to listen") { hotkey.isRecording }
    }
}

@Suite(.serialized) struct SettingsWindowTests {
    @Test func launchLeavesSettingsUnbuiltUntilTheFirstOpenAndReusesIt() throws {
        let existing = Set(NSApp.windows.filter { $0.identifier?.rawValue == "settings" }.map(ObjectIdentifier.init))
        let rig = SettingsRig(name: "window.lazy")
        defer { rig.window.close() }
        let launch = Launch()
        launch.start {
            let index = IndexModel(client: rig.client)
            return AppServices(
                client: rig.client, archiveClient: PreviewArchiveClient(),
                archives: ArchiveWindows(client: PreviewArchiveClient(), index: index, actions: ActionRecorder().actions, cache: FileManager.default.temporaryDirectory.appending(path: "archive-\(UUID().uuidString)", directoryHint: .isDirectory)), index: index, settings: rig.window,
                launcher: Launcher(index: index, actions: ActionRecorder().actions, defaults: rig.defaults)
            )
        }
        let settings = try #require(launch.services?.settings)
        func windows() -> [NSWindow] {
            NSApp.windows.filter { $0.identifier?.rawValue == "settings" && !existing.contains(ObjectIdentifier($0)) }
        }
        #expect(windows().isEmpty)
        settings.show()
        let first = try #require(settings.window)
        #expect(windows().count == 1)
        #expect(first.isVisible)
        settings.close()
        settings.show()
        #expect(settings.window === first)
        #expect(windows().count == 1)
        #expect(first.isVisible)
    }

    @Test func showingTwiceFrontsOneWindowAndActivatesBothTimes() throws {
        let rig = SettingsRig(name: "window.twice")
        defer { rig.window.close() }
        rig.window.show()
        let first = try #require(rig.window.window)
        rig.selection.pane = .locations
        rig.window.show()
        #expect(rig.window.window === first)
        #expect(first.isVisible)
        #expect(rig.visibleSettingsWindows.count == 1)
        #expect(rig.spy.calls == 2)
        #expect(rig.selection.pane == .locations)
    }

    @Test func closingThenShowingBringsBackTheSameWindow() throws {
        let rig = SettingsRig(name: "window.reopen")
        defer { rig.window.close() }
        rig.window.show()
        let first = try #require(rig.window.window)
        rig.window.close()
        #expect(!first.isVisible)
        rig.window.show()
        #expect(rig.window.window === first)
        #expect(first.isVisible)
        #expect(rig.visibleSettingsWindows.count == 1)
    }

    @Test func theWindowIsASplitViewWithAFixed240Sidebar() throws {
        let rig = SettingsRig(name: "window.split")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        #expect(window is EscapeClosingWindow)
        let split = try #require(window.contentViewController as? NSSplitViewController)
        try #require(split.splitViewItems.count == 2)
        let sidebar = split.splitViewItems[0]
        #expect(sidebar.behavior == .sidebar)
        #expect(sidebar.minimumThickness == 240)
        #expect(sidebar.maximumThickness == 240)
        #expect(!sidebar.canCollapse)
        #expect(sidebar.allowsFullHeightLayout)
        window.layoutIfNeeded()
        #expect(window.frame.size == NSSize(width: 978, height: 604))
        #expect(SettingsWindow.Metrics.minSize == NSSize(width: 850, height: 525))
        #expect(window.minSize == NSSize(width: 850, height: 525))
        #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]))
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.identifier?.rawValue == "settings")
        #expect(window.autorecalculatesKeyViewLoop)
        let items = window.toolbar?.items ?? []
        #expect(items.count == 1)
        #expect((items.first as? NSTrackingSeparatorToolbarItem)?.dividerIndex == 0)
    }

    @Test func theSidebarListsExactlyGeneralLocationsAndAbout() async throws {
        let rig = SettingsRig(name: "window.rows")
        defer { rig.window.close() }
        rig.window.show()
        let table = try await rig.outline()
        #expect(SettingsPane.allCases == [.general, .locations, .about])
        #expect(table.numberOfRows == 3)
        #expect(AXTree.element("settings-sidebar", in: rig.sidebarView) != nil)
        let names = ["General", "Locations", "About"].map { local($0, "Settings") }
        for (row, pane) in SettingsPane.allCases.enumerated() {
            let view = try #require(table.rowView(atRow: row, makeIfNecessary: true))
            #expect(texts(in: view).contains(names[row]), "row \(row) reads \(texts(in: view))")
            #expect(AXTree.elements(in: view).contains { AXTree.identifier(of: $0) == pane.rowID }, "row \(row) has no \(pane.rowID)")
        }
    }

    @Test func choosingEachRowShowsItsPaneAndNamesTheWindow() async throws {
        let rig = SettingsRig(name: "window.choose")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        let table = try await rig.outline()
        let frame = window.frame
        let minSize = window.minSize
        let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        try #require(!version.isEmpty)
        let names = ["General", "Locations", "About"].map { local($0, "Settings") }
        for (row, pane) in SettingsPane.allCases.enumerated() {
            table.selectRowIndexes([row], byExtendingSelection: false)
            try await rig.until("the \(pane) pane and its content") {
                guard rig.selection.pane == pane, rig.shows(pane) else { return false }
                switch pane {
                case .general: return AXTree.control(local("Open at Login", "Settings"), in: rig.detailView) != nil
                case .locations: return AXTree.control(local("Add excluded path", "Settings"), in: rig.detailView) != nil
                case .about:
                    return rig.detailTexts.contains(String(format: local("Version %@", "Settings"), version))
                        && AXTree.control(local("Donate", "Settings"), in: rig.detailView) != nil
                }
            }
            for other in SettingsPane.allCases where other != pane { #expect(!rig.shows(other), "\(pane) also shows \(other)") }
            #expect(window.title == names[row])
            #expect(window.frame == frame, "\(pane) moved the window to \(window.frame)")
            #expect(window.minSize == minSize, "\(pane) changed the minimum to \(window.minSize)")
        }
    }

    @Test func escapeClosesTheWindowFromTheSidebarAControlAndNoResponder() async throws {
        let rig = SettingsRig(name: "window.escape")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        let table = try await rig.outline()
        #expect(window.makeFirstResponder(table))
        try rig.escape()
        #expect(!window.isVisible, "Escape from the sidebar")

        rig.window.show()
        #expect(window.isVisible)
        try rig.focusInDetail()
        try rig.escape()
        #expect(!window.isVisible, "Escape from the detail")

        rig.window.show()
        #expect(window.makeFirstResponder(nil))
        try rig.escape()
        #expect(!window.isVisible, "Escape with no responder")

        rig.window.show()
        rig.selection.pane = .about
        try await rig.until("the About pane") { AXTree.element("about-donate", in: rig.detailView) != nil }
        try rig.focusInDetail()
        try rig.escape()
        #expect(!window.isVisible, "Escape from the About pane")

        rig.window.show()
        #expect(rig.window.window === window)
        #expect(window.isVisible)
    }

    @Test func theMinimumSizeKeepsTheSidebarAt240AndGivesThePaneTheRest() throws {
        let rig = SettingsRig(name: "window.minimum")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
        rig.split.view.layoutSubtreeIfNeeded()
        #expect(window.frame.size == NSSize(width: 850, height: 525))
        let splitView = rig.split.splitView
        let sidebar = rig.sidebarView.convert(rig.sidebarView.bounds, to: splitView), detail = rig.detailView.convert(rig.detailView.bounds, to: splitView)
        #expect(splitView.bounds.width == window.frame.width)
        let plain = Self.plainSidebarFrame(in: window)
        #expect(sidebar.minX == plain.minX, "a plain NSSplitViewController sidebar in the same window shape starts at \(plain.minX)")
        #expect(sidebar.width == 240)
        let gap = detail.minX - sidebar.maxX
        #expect((0...splitView.dividerThickness).contains(gap), "gap between the sidebar and the pane: \(gap)")
        #expect(detail.maxX == splitView.bounds.maxX)
    }

    private static func plainSidebarFrame(in window: NSWindow) -> NSRect {
        let plain = NSWindow(contentRect: window.contentRect(forFrameRect: window.frame), styleMask: window.styleMask, backing: .buffered, defer: false)
        defer { plain.close() }
        plain.isReleasedWhenClosed = false
        plain.titlebarAppearsTransparent = window.titlebarAppearsTransparent
        plain.toolbar = NSToolbar(identifier: "plain-settings-toolbar")
        plain.toolbarStyle = window.toolbarStyle
        let sidebar = NSViewController(), detail = NSViewController()
        sidebar.view = NSView()
        detail.view = NSView()
        let item = NSSplitViewItem(sidebarWithViewController: sidebar)
        item.canCollapse = false
        item.minimumThickness = SettingsWindow.Metrics.sidebarWidth
        item.maximumThickness = SettingsWindow.Metrics.sidebarWidth
        item.allowsFullHeightLayout = true
        let split = NSSplitViewController()
        split.splitViewItems = [item, NSSplitViewItem(viewController: detail)]
        plain.contentViewController = split
        plain.setFrame(window.frame, display: false)
        plain.orderFront(nil)
        split.view.layoutSubtreeIfNeeded()
        return sidebar.view.convert(sidebar.view.bounds, to: split.splitView)
    }

    @Test func theBundleCopyrightLineMatchesTheAboutPane() async throws {
        let line = "Copyright © 2026 Writronic. All rights reserved."
        #expect(Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String == line)
        let rig = SettingsRig(name: "window.aboutcopyright")
        defer { rig.window.close() }
        rig.window.show()
        rig.selection.pane = .about
        try await rig.until("the copyright line among \(rig.detailTexts)") { rig.detailTexts.contains(line) }
    }

    @Test func theAboutPaneShowsTheBundlesVersionAndDonateOpensTheDonatePageOnce() async throws {
        let rig = SettingsRig(name: "window.about")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        rig.selection.pane = .about
        let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        try #require(!version.isEmpty)
        let lines = [
            "Wherever", String(format: local("Version %@", "Settings"), version), local("Wherever it is, find it.", "Welcome"),
            local("Made with ❤️", "Settings"), local("Copyright © 2026 Writronic. All rights reserved.", "Settings"), "GPL-3.0-or-later",
        ]
        try await rig.until("the About lines among \(rig.detailTexts)") { lines.allSatisfy(rig.detailTexts.contains) }
        #expect(!rig.detailTexts.contains("Find any file on your Mac, instantly."), "the old line still shows")
        let donate = try #require(AXTree.element("about-donate", in: rig.detailView))
        #expect(AXTree.names(of: donate).contains(local("Donate", "Settings")), "Donate reads \(AXTree.names(of: donate))")
        #expect(!AXTree.names(of: donate).contains(local("Donate…", "MenuBar")), "Donate still reads the menu title")
        #expect(rig.spy.urls.isEmpty)
        #expect(AXTree.press(donate))
        try await rig.until("the donate page") { !rig.spy.urls.isEmpty }
        #expect(rig.spy.urls == [AppLinks.donate])
        #expect(AppLinks.donate.absoluteString == "https://writronic.com/donate")
        #expect(window.isVisible)
        #expect(rig.selection.pane == .about)
    }

    @Test func visitWebsiteInTheAboutPaneOpensTheWebsiteOnce() async throws {
        let rig = SettingsRig(name: "window.aboutwebsite")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        rig.selection.pane = .about
        try await rig.until("the Visit Website button") { AXTree.element("about-website", in: rig.detailView) != nil }
        let website = try #require(AXTree.element("about-website", in: rig.detailView))
        #expect(AXTree.names(of: website).contains(local("Visit Website", "Settings")), "Visit Website reads \(AXTree.names(of: website))")
        #expect(rig.spy.urls.isEmpty)
        #expect(AXTree.press(website))
        try await rig.until("the website") { !rig.spy.urls.isEmpty }
        #expect(rig.spy.urls == [AppLinks.website])
        #expect(window.isVisible)
        #expect(rig.selection.pane == .about)
    }

    @Test func theGeneralPaneHoldsStartupShortcutAppearanceLanguageAndOpenHistory() async throws {
        let rig = SettingsRig(name: "window.general")
        defer { rig.window.close() }
        rig.window.show()
        rig.selection.pane = .general
        let pane = rig.detailView
        try await rig.until("the General rows") {
            AXTree.element("general-open-at-login", in: pane) != nil && AXTree.control("Clear Open History…", in: pane) != nil
                && AXTree.element(ThemePicker.id, in: pane) != nil && AXTree.control("Show inspector", in: pane) != nil
                && AXTree.control("Launcher shortcut", in: pane) != nil && AXTree.control("Typo-Tolerant Search", in: pane) != nil
                && AXTree.element(AppearanceRow.id, in: pane) != nil && AXTree.element(LanguageRow.id, in: pane) != nil
        }
        for title in ["Startup", "Menu Bar", "Shortcut", "Command-Line Tool", "Search", "Appearance", "Language", "Open History", "Software Updates"] {
            #expect(rig.detailTexts.contains(local(title, "Settings")), "no \(title) header")
        }
        #expect(!rig.detailTexts.contains("Text Search"), "a Text Search header in \(rig.detailTexts)")
        #expect(!rig.detailTexts.contains("Import and Export"), "an Import and Export header in \(rig.detailTexts)")
        #expect(AXTree.control("Index text inside files", in: pane) == nil)
        #expect(AXTree.control("Keep the text index on disk", in: pane) == nil)
        #expect(AXTree.element("general-index-text", in: pane) == nil)
        let dockIds = AXTree.elements(in: pane).compactMap { AXTree.value("accessibilityIdentifier", of: $0) as String? }.filter { $0.contains("dock") }
        #expect(dockIds.isEmpty, "a Dock row came back: \(dockIds)")
        #expect(!rig.detailTexts.contains { $0.contains("Dock") }, "a Dock row in \(rig.detailTexts)")
    }

    @Test func arrowKeysInTheSidebarWalkThePanes() async throws {
        let rig = SettingsRig(name: "window.arrows")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        let table = try await rig.outline()
        #expect(window.makeFirstResponder(table))
        let down = try keyEvent(downArrow, kVK_DownArrow, [.numericPad, .function], in: window)
        let up = try keyEvent(upArrow, kVK_UpArrow, [.numericPad, .function], in: window)
        for _ in 0..<2 { table.keyDown(with: down) }
        try await rig.until("About after two Downs") { rig.selection.pane == .about && rig.shows(.about) }
        table.keyDown(with: up)
        try await rig.until("Locations after one Up") { rig.selection.pane == .locations && rig.shows(.locations) }
        table.keyDown(with: down)
        table.keyDown(with: down)
        try await rig.until("About after two more Downs") { rig.selection.pane == .about && rig.shows(.about) }
        #expect(table.selectedRow == 2)
    }

    @Test func arrowsWhileRecordingStayWithTheRecorder() async throws {
        let rig = SettingsRig(name: "window.recordarrows")
        defer { rig.hotkey.stopRecording(); rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        try await rig.record()
        try send(downArrow, kVK_DownArrow, [.numericPad, .function], to: window)
        #expect(rig.hotkey.refusal == .needsModifier)
        #expect(rig.hotkey.isRecording)
        #expect(rig.selection.pane == .general)
    }

    @Test func choosingAnotherRowWhileRecordingEndsTheRecording() async throws {
        let rig = SettingsRig(name: "window.recordrow")
        defer { rig.hotkey.stopRecording(); rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        let table = try await rig.outline()
        try await rig.record()
        table.selectRowIndexes([2], byExtendingSelection: false)
        try await rig.until("the recording to end on About") { !rig.hotkey.isRecording }
        #expect(rig.selection.pane == .about)
        rig.hotkeys.notes = []
        try send("k", kVK_ANSI_K, [.control, .option], to: window)
        #expect(rig.hotkey.hotkey == .summon)
        #expect(rig.hotkeys.notes.isEmpty)
    }

    @Test func closingWhileRecordingEndsTheRecording() async throws {
        let rig = SettingsRig(name: "window.recordclose")
        defer { rig.hotkey.stopRecording(); rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        try await rig.record()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        window.close()
        try await rig.until("the recording to end") { !rig.hotkey.isRecording }
    }

    @Test func theMenuBarIconSwitchWritesTheSuiteAndFollowsARemoval() async throws {
        let rig = SettingsRig(name: "window.menubaricon")
        defer { rig.window.close() }
        rig.window.show()
        rig.selection.pane = .general
        try await rig.until("the menu bar icon switch") { AXTree.element("general-show-menu-bar-icon", in: rig.detailView) != nil }
        let toggle = try #require(AXTree.element("general-show-menu-bar-icon", in: rig.detailView))
        rig.window.window?.displayIfNeeded()
        #expect(rig.defaults.object(forKey: MenuBarIcon.key) == nil)
        #expect(AXTree.value("accessibilityValue", of: toggle) as Int? == 1)
        try #require(AXTree.press(toggle))
        try await rig.until("the suite to hold off") { rig.defaults.object(forKey: MenuBarIcon.key) as? Bool == false }
        try #require(AXTree.press(toggle))
        try await rig.until("the suite to hold on") { rig.defaults.object(forKey: MenuBarIcon.key) as? Bool == true }
        rig.defaults.set(false, forKey: MenuBarIcon.key)
        try await rig.until("the switch to follow a removal") {
            AXTree.element("general-show-menu-bar-icon", in: rig.detailView).flatMap { AXTree.value("accessibilityValue", of: $0) as Int? } == 0
        }
    }

    @Test func theTypoSwitchReachesTheEngineClient() async throws {
        let rig = SettingsRig(name: "window.typo")
        defer { rig.window.close() }
        rig.window.show()
        rig.selection.pane = .general
        try await rig.until("the typo switch") { AXTree.control("Typo-Tolerant Search", in: rig.detailView) != nil }
        let toggle = try #require(AXTree.control("Typo-Tolerant Search", in: rig.detailView))
        rig.window.window?.displayIfNeeded()
        #expect(rig.client.typos.isEmpty)
        try #require(AXTree.press(toggle))
        try await rig.until("the client to hear it") { rig.client.typos == [true] }
        #expect(rig.defaults.bool(forKey: TypoSearchRow.key))
        try #require(AXTree.press(toggle))
        try await rig.until("the client to hear it off") { rig.client.typos == [true, false] }
        #expect(!rig.defaults.bool(forKey: TypoSearchRow.key))
    }

    @Test func escapeOnTheClearAlertClosesOnlyTheAlert() async throws {
        let rig = SettingsRig(name: "window.clearescape")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        try await rig.until("the clear button") { AXTree.control("Clear Open History…", in: rig.detailView) != nil }
        let button = try #require(AXTree.control("Clear Open History…", in: rig.detailView))
        try #require(AXTree.press(button))
        try await rig.until("the alert") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        #expect(sheet.performKeyEquivalent(with: try keyEvent("\u{1b}", kVK_Escape, in: sheet)))
        try await rig.until("the alert to close") { window.attachedSheet == nil }
        #expect(window.isVisible)
        #expect(rig.client.clears == 0)
        try rig.escape()
        #expect(!window.isVisible)
    }

    @Test func cancellingTheFolderPanelLeavesSettingsOpenAndStoresNothing() async throws {
        let rig = SettingsRig(name: "window.panel")
        defer { rig.window.close() }
        let excluded = rig.locations.excluded
        rig.window.show()
        let window = try #require(rig.window.window)
        rig.selection.pane = .locations
        try await rig.until("the plus button") { AXTree.control("Add excluded path", in: rig.detailView) != nil }
        let button = try #require(AXTree.control("Add excluded path", in: rig.detailView))
        try #require(AXTree.press(button))
        try await rig.until("the folder panel") { rig.spy.panels == 1 }
        #expect(window.isVisible)
        #expect(rig.locations.excluded == excluded)
        #expect(rig.selection.pane == .locations)
    }

    @Test func performCloseHidesTheWindowAndShowBringsItBackOnTheSamePane() async throws {
        let rig = SettingsRig(name: "window.performclose")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        let table = try await rig.outline()
        table.selectRowIndexes([1], byExtendingSelection: false)
        try await rig.until("the Locations pane") { rig.selection.pane == .locations && rig.shows(.locations) }
        window.performClose(nil)
        #expect(!window.isVisible)
        rig.window.show()
        #expect(rig.window.window === window)
        #expect(window.isVisible)
        #expect(rig.selection.pane == .locations)
        try await rig.until("the Locations pane again") { table.selectedRow == 1 && rig.shows(.locations) }
    }

    @Test func aThemePickKeepsThePaneAndTheSystemColors() async throws {
        let rig = SettingsRig(name: "window.theme")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        let standardBefore = UserDefaults.standard.object(forKey: Theme.key) as? String
        try await rig.until("the theme picker") { themeTileRow(in: rig.detailView) != nil }
        try #require(themeTileRow(in: rig.detailView)).tiles[1].performClick(nil)
        try await rig.until("Ink and Glass in the rig's store") { rig.defaults.string(forKey: Theme.key) == Theme.inkAndGlass.rawValue }
        #expect(rig.selection.pane == .general)
        #expect(rig.shows(.general))
        #expect(window.backgroundColor == .windowBackgroundColor)
        #expect(UserDefaults.standard.object(forKey: Theme.key) as? String == standardBefore)
    }

    @Test func tabFromTheSidebarReachesTheExcludedFoldersList() async throws {
        let rig = SettingsRig(name: "window.tab")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        let table = try await rig.outline()
        rig.selection.pane = .locations
        try await rig.until("the excluded folders list") { descendants(of: rig.detailView).contains { $0 is NSTableView } }
        window.recalculateKeyViewLoop()
        #expect(window.makeFirstResponder(table))
        window.selectNextKeyView(nil)
        let responder = window.firstResponder as? NSView
        #expect(responder is NSTableView && responder?.isDescendant(of: rig.detailView) == true, "Tab went to \(String(describing: responder))")
    }

    @Test func theFirstOpenCentresTheWindowAndALaterOpenKeepsWhereTheUserLeftIt() throws {
        let rig = SettingsRig(name: "window.place")
        defer { rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        let visible = try #require(window.screen?.visibleFrame)
        let scale = window.backingScaleFactor
        let centred = NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2)
        #expect((window.frame.origin.x - (centred.x * scale).rounded() / scale) * scale == 0, "x \(window.frame.origin.x), centred \(centred.x)")
        #expect((window.frame.origin.y - (centred.y * scale).rounded() / scale) * scale == 0, "y \(window.frame.origin.y), centred \(centred.y)")
        let moved = NSPoint(x: window.frame.origin.x + 40, y: window.frame.origin.y - 40)
        window.setFrameOrigin(moved)
        rig.window.close()
        rig.window.show()
        #expect(window.frame.origin == moved)
    }

    @Test func closingSettingsLeavesTheSearchWindowOpenWithItsFieldTakingKeys() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let search = SearchHost(index: index, model: model)
        defer { search.close() }
        try await search.until("the field to hold focus") { search.fieldHasFocus }
        let rig = SettingsRig(name: "window.next")
        rig.window.show()
        rig.window.close()
        #expect(search.window.isVisible)
        try await search.until("the field to hold focus after Settings closed") { search.fieldHasFocus }
        try search.sendKeys("s")
        #expect(model.query == "s")
        #expect(fake.queries == ["s"])
    }

    @Test func theSidebarRowsFollowTheTextSize() async throws {
        #expect(SettingsWindow.Metrics.rowHeight(.standard) == SettingsWindow.Metrics.standardRowHeight)
        #expect(SettingsWindow.Metrics.rowHeight(.maximum) == 29)
        var heights: [CGFloat] = []
        for size in [TextSize.standard, .maximum] {
            let rig = SettingsRig(name: "window.textsize.\(size.rawValue)")
            rig.defaults.set(size.rawValue, forKey: TextSize.key)
            defer { rig.window.close() }
            rig.window.show()
            let table = try await rig.outline()
            let row = try #require(table.rowView(atRow: 0, makeIfNecessary: true))
            let label = { AXTree.elements(in: row).first { AXTree.identifier(of: $0) == SettingsPane.general.rowID } }
            try await rig.until("the General row's label at \(size.rawValue) pt") { label().flatMap(AXTree.frame) != nil }
            heights.append(table.rect(ofRow: 0).height)
        }
        #expect(
            heights[1] - heights[0] == SettingsWindow.Metrics.rowHeight(.maximum) - SettingsWindow.Metrics.rowHeight(.standard), "\(heights)"
        )
    }
}
private func descendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendants(of: $0) }
}

private func texts(in object: NSObject) -> [String] {
    var found = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { key in
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) as? String : nil
    }
    if object.responds(to: NSSelectorFromString("accessibilityChildren")) {
        for child in object.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] { found += texts(in: child) }
    }
    return found
}

private final class PaneHost {
    let window: KeyedWindow
    let view: NSView

    init(_ pane: some View) {
        let controller = NSHostingController(
            rootView: pane.environment(\.locale, Locale(identifier: "en")).frame(width: SettingsWindow.Metrics.detailWidth)
        )
        window = KeyedWindow(contentViewController: controller)
        view = controller.view
        window.setContentSize(NSSize(width: SettingsWindow.Metrics.detailWidth, height: SettingsWindow.Metrics.size.height))
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

    func control(_ title: String) -> NSObject? { AXTree.control(title, in: view) }

    func shows(_ text: String) -> Bool {
        ([view] + descendants(of: view)).flatMap { texts(in: $0) }.contains { $0.contains(text) }
    }

    func click(_ title: String) async throws {
        try await until("a control named \(title) among \(AXTree.nodeCount(in: view)) accessibility nodes") { control(title) != nil }
        let found = try #require(control(title))
        try #require(AXTree.press(found), "\(title) took no press")
    }
}

private nonisolated struct ClearFails: SearchClient {
    struct Refused: Error {}
    var events: AsyncStream<SearchEvent> { AsyncStream { _ in } }
    func makeSession() throws -> any SearchSessionClient { throw Refused() }
    func recordOpen(_ path: String) throws {}
    func clearOpens() throws { throw Refused() }
    func flushOpens() throws {}
    func isSettling() throws -> Bool { false }
    func setExcludedFolders(_ paths: [String]) throws {}
    func setTypoSearch(_ on: Bool) throws {}
    func setLiveUpdates(_ on: Bool) throws {}
    func setIndexedVolumes(_ ids: Set<String>) throws {}
    func volumes() throws -> [IndexedVolume] { [] }
}

private func generalPane(
    _ model: LaunchAtLoginModel, client: any SearchClient = FakeSearchClient(),
    store: UserDefaults = freshDefaults("pane.general.store"), hotkey: HotkeyModel = HelperStarterSpy().model(freshDefaults("pane.general.hotkey")),
    reset: @escaping @MainActor () async throws -> Void = {},
    files: SettingsFileIO = SettingsFileIO(saveURL: { nil }, openURL: { nil }, defaults: freshDefaults("pane.general.files")),
    updates: UpdatesModel = .idle, commandLine: CommandLineToolModel = .inert()
) -> some View {
    GeneralPane(launchAtLogin: model, hotkey: hotkey, reset: reset, files: files, updates: updates, commandLine: commandLine)
        .environment(\.searchClient, client).defaultAppStorage(store)
}

extension PaneHost {
    var sheet: NSWindow? { window.attachedSheet }

    var sheetTexts: [String] { sheet?.contentView.map { descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } } ?? [] }

    private var sheetButtons: [NSButton] { sheet?.contentView.map { descendants(of: $0).compactMap { $0 as? NSButton } } ?? [] }

    func sheetButton(_ title: String) -> NSButton? {
        sheetButtons.first { $0.isEnabled && ($0.title == title || texts(in: $0).contains(title)) }
    }

    func clickSheet(_ title: String) async throws {
        try await untilTrue(waitingFor: "the \(title) button in the alert") { sheetButton(title) != nil }
        try #require(sheetButton(title)).performClick(nil)
    }

    func scroll(toEnd: Bool) async throws {
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(descendants(of: view).compactMap { $0 as? NSScrollView }.max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        let document = try #require(scroll.documentView)
        let room = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let y = toEnd == document.isFlipped ? room : 0
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await until("the pane laid out at its \(toEnd ? "end" : "start")") { true }
    }
}

@Suite(.serialized) struct GeneralPaneTests {
    @Test func theMenuBarIconSwitchWritesThenSyncsTheHelper() async throws {
        let suite = "com.writronic.wherever.tests.settings.helpersync"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AccessModel.completedKey)
        defaults.set(Data(), forKey: HotkeyModel.defaultsKey)
        let spy = HelperStarterSpy()
        let host = PaneHost(MenuBarIconRow(sync: spy.starter(defaults: defaults).sync).defaultAppStorage(defaults))
        defer { host.close() }
        try await host.until("the switch") { AXTree.element("general-show-menu-bar-icon", in: host.view) != nil }
        let toggle = try #require(AXTree.element("general-show-menu-bar-icon", in: host.view))
        try #require(AXTree.press(toggle))
        try await host.until("the sync after the switch goes off") { spy.syncs.count == 1 }
        #expect(defaults.object(forKey: MenuBarIcon.key) as? Bool == false)
        #expect(spy.opens.isEmpty)
        try #require(AXTree.press(toggle))
        try await host.until("the helper to open after the switch goes on") { spy.opens.count == 1 }
        #expect(defaults.object(forKey: MenuBarIcon.key) as? Bool == true)
        #expect(spy.opens.allSatisfy { !$0.activates })
        #expect(spy.syncs.count == 1)
    }

    @Test func theSwitchRegistersThenUnregistersWithoutOpeningAWindow() async throws {
        let fixture = LoginFixture()
        let model = fixture.model()
        let host = PaneHost(generalPane(model))
        defer { host.close() }
        try await host.until("the enabled login switch") { host.control("Open at Login").flatMap(AXTree.isEnabled) == true }
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        #expect(!model.isOn)
        try await host.click("Open at Login")
        try await host.until("login enabled") {
            model.isOn && !model.busy && host.control("Open at Login").flatMap { AXTree.value("accessibilityValue", of: $0) as Int? } == 1
                && host.control("Open at Login").flatMap(AXTree.isEnabled) == true
        }
        #expect(fixture.events == ["register"])
        #expect(AXTree.value("accessibilityValue", of: try #require(host.control("Open at Login"))) as Int? == 1)
        try await host.click("Open at Login")
        let login = { host.control("Open at Login") }
        try await host.until(
            "login disabled; isOn \(model.isOn), busy \(model.busy), events \(fixture.events), value \(String(describing: login().flatMap { AXTree.value("accessibilityValue", of: $0) as Int? })), enabled \(String(describing: login().flatMap(AXTree.isEnabled)))"
        ) {
            !model.isOn && !model.busy && host.control("Open at Login").flatMap { AXTree.value("accessibilityValue", of: $0) as Int? } == 0
        }
        #expect(fixture.events == ["register", "unregister"])
        #expect(AXTree.value("accessibilityValue", of: try #require(host.control("Open at Login"))) as Int? == 0)
        #expect(NSApp.windows.filter { !windows.contains(ObjectIdentifier($0)) }.isEmpty, "a window opened")
    }

    @Test func aRefusedRegisterKeepsTheSwitchUsable() async throws {
        let fixture = LoginFixture()
        fixture.registerFails = true
        let model = fixture.model()
        let host = PaneHost(generalPane(model))
        defer { host.close() }
        try await host.click("Open at Login")
        try await host.until("the failure line and enabled switch") {
            host.shows("Wherever could not change this.") && host.control("Open at Login").flatMap(AXTree.isEnabled) == true
        }
        #expect(!model.isOn)
        try await host.click("Open Login Items")
        #expect(fixture.loginItemsOpened == 1)
        fixture.registerFails = false
        try await host.click("Open at Login")
        try await host.until("the retry succeeds") { model.isOn && !model.busy && host.control("Open Login Items") == nil }
        #expect(fixture.registers == 2 && !model.failed)
        #expect(host.control("Open Login Items") == nil)
    }

    @Test func notFoundStillLeavesTheSwitchUsable() async throws {
        let fixture = LoginFixture(.notFound)
        let model = fixture.model()
        let host = PaneHost(generalPane(model))
        defer { host.close() }
        try await host.until("the enabled switch") { host.control("Open at Login").flatMap(AXTree.isEnabled) == true }
        try await host.click("Open at Login")
        try await host.until("login enabled") { model.isOn && !model.busy }
        #expect(fixture.events == ["register"])
    }

    @Test func approvalShowsTheLineAndOpensLoginItemsThenCanBeDisabled() async throws {
        let fixture = LoginFixture(.requiresApproval)
        let model = fixture.model()
        let host = PaneHost(generalPane(model))
        defer { host.close() }
        try await host.until("the approval line") { host.shows("Allow Wherever in Login Items in System Settings.") }
        #expect(model.isOn)
        try await host.click("Open Login Items")
        #expect(fixture.loginItemsOpened == 1)
        #expect(AXTree.element("general-login-items", in: host.view) != nil)
        try await host.click("Open at Login")
        try await host.until("login disabled") { !model.isOn && !model.busy && host.control("Open Login Items") == nil }
        #expect(fixture.events == ["unregister"])
        #expect(host.control("Open Login Items") == nil)
    }

    @Test func activationRereadsTheStatus() async throws {
        let fixture = LoginFixture()
        let model = fixture.model()
        let host = PaneHost(generalPane(model))
        defer { host.close() }
        try await host.until("the login switch") { host.control("Open at Login") != nil }
        fixture.status = .requiresApproval
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await host.until("the changed status") { host.shows("Allow Wherever in Login Items in System Settings.") }
        #expect(model.isOn)
    }

    @Test func aSecondPressWhileBusyDoesNothing() async throws {
        let fixture = LoginFixture(.enabled)
        fixture.holdUnregister = true
        let model = fixture.model()
        await model.refresh().value
        let host = PaneHost(generalPane(model))
        defer { fixture.releaseUnregister?.resume(); host.close() }
        try await host.click("Open at Login")
        try await host.until("the pending unregister") { fixture.releaseUnregister != nil }
        try await host.until("the disabled switch") { host.control("Open at Login").flatMap(AXTree.isEnabled) == false }
        await model.setEnabled(false)
        #expect(fixture.unregisters == 1 && fixture.registers == 0)
        fixture.releaseUnregister?.resume()
        fixture.releaseUnregister = nil
        try await host.until("the enabled switch") { host.control("Open at Login").flatMap(AXTree.isEnabled) == true }
        #expect(!model.busy && !model.isOn)
    }

    @Test func clearOpenHistoryThenClearCallsClearOpensOnceAndClosesTheAlert() async throws {
        let client = FakeSearchClient()
        let host = PaneHost(generalPane(LoginFixture().model(), client: client))
        defer { host.close() }
        try await host.click("Clear Open History…")
        try await host.until("the alert") { host.sheet != nil }
        #expect(client.clears == 0)
        try await host.clickSheet("Clear")
        try await host.until("the alert to close") { host.sheet == nil }
        #expect(client.clears == 1)
        #expect(!host.shows("Wherever could not clear the open history."))
    }

    @Test func clearOpenHistoryThenCancelClearsNothingAndClosesTheAlert() async throws {
        let client = FakeSearchClient()
        let host = PaneHost(generalPane(LoginFixture().model(), client: client))
        defer { host.close() }
        try await host.click("Clear Open History…")
        try await host.until("the alert") { host.sheet != nil }
        try await host.clickSheet("Cancel")
        try await host.until("the alert to close") { host.sheet == nil }
        #expect(client.clears == 0)
    }

    @Test func clearOpenHistoryThenEscapeClearsNothingAndClosesTheAlert() async throws {
        let client = FakeSearchClient()
        let host = PaneHost(generalPane(LoginFixture().model(), client: client))
        defer { host.close() }
        try await host.click("Clear Open History…")
        try await host.until("the alert") { host.sheet != nil }
        let sheet = try #require(host.sheet)
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: UInt16(kVK_Escape)
        ))
        #expect(sheet.performKeyEquivalent(with: escape))
        try await host.until("the alert to close") { host.sheet == nil }
        #expect(client.clears == 0)
    }

    @Test func aClearThatThrowsShowsTheOneErrorLineAndClosesTheAlert() async throws {
        let host = PaneHost(generalPane(LoginFixture().model(), client: ClearFails()))
        defer { host.close() }
        try await host.click("Clear Open History…")
        try await host.clickSheet("Clear")
        try await host.until("the error line") { host.shows("Wherever could not clear the open history.") }
        try await host.until("the alert to close") { host.sheet == nil }
        #expect(host.control("Clear Open History…") != nil)
    }

    @Test func softwareUpdatesFollowsOpenHistoryAndIsOneSwitch() async throws {
        let updates = UpdatesModel(canCheckForUpdates: Just(true), automaticallyChecks: Just(true), check: {}, setAutomaticallyChecks: { _ in })
        let host = PaneHost(generalPane(LoginFixture().model(), updates: updates))
        defer { host.close() }
        let frame = { (id: String) in AXTree.element(id, in: host.view).flatMap(AXTree.frame(of:)) }
        try await host.until("the Software Updates switch") {
            frame("general-automatic-updates") != nil && frame("general-export") != nil
                && host.control("Clear Open History…").flatMap(AXTree.frame(of:)) != nil
        }
        #expect(host.shows("Software Updates"))
        #expect(!host.shows("Checks about once a day. Nothing installs until you say so."))
        #expect(AXTree.element("general-check-for-updates", in: host.view) == nil)
        #expect(host.control("Check for Updates…") == nil)
        let toggle = try #require(AXTree.element("general-automatic-updates", in: host.view))
        #expect(AXTree.isOn(toggle) == true)
        #expect(AXTree.names(of: toggle).contains("Automatically check for updates"), "the switch reads \(AXTree.names(of: toggle))")
        let history = try #require(host.control("Clear Open History…").flatMap(AXTree.frame(of:)))
        let automatic = try #require(frame("general-automatic-updates"))
        let export = try #require(frame("general-export"))
        #expect(history.minY > automatic.minY && automatic.minY > export.minY)
    }

    @Test func resetAsksAndCancelDoesNothing() async throws {
        var resets = 0
        let host = PaneHost(generalPane(LoginFixture().model(), reset: { resets += 1 }))
        defer { host.close() }
        try await host.until("the reset button") { AXTree.element("general-reset", in: host.view) != nil }
        let button = try #require(AXTree.element("general-reset", in: host.view))
        #expect(AXTree.names(of: button).contains("Reset"), "the button reads \(AXTree.names(of: button))")
        #expect(host.shows("Reset Settings"))
        #expect(host.shows("Reset all settings, saved indexes and open history (cannot be undone)"))
        #expect(!host.shows("Reset Wherever"))
        try #require(AXTree.press(button))
        try await host.until("the alert") { host.sheet != nil }
        try await host.until("the alert title, the alert reading \(host.sheetTexts)") { host.sheetTexts.contains("Reset All Settings?") }
        #expect(resets == 0)
        try await host.clickSheet("Cancel")
        try await host.until("the alert to close") { host.sheet == nil }
        #expect(resets == 0)
        #expect(!host.shows("Wherever could not reset. Try again."))
    }

    @Test func resetConfirmCallsResetOnce() async throws {
        var resets = 0
        let host = PaneHost(generalPane(LoginFixture().model(), reset: { resets += 1; throw Refused() }))
        defer { host.close() }
        try await host.until("the reset button") { AXTree.element("general-reset", in: host.view) != nil }
        try #require(AXTree.press(try #require(AXTree.element("general-reset", in: host.view))))
        try await host.until("the alert") { host.sheet != nil }
        #expect(resets == 0)
        try await host.clickSheet("Reset")
        try await host.until("the alert to close and the failure line") { host.sheet == nil && host.shows("Wherever could not reset. Try again.") }
        #expect(resets == 1)
        #expect(AXTree.element("general-reset", in: host.view) != nil)
    }

    @Test func exportCancelWritesNoFile() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var asks = 0
        let files = SettingsFileIO(saveURL: { asks += 1; return nil }, openURL: { nil }, defaults: freshDefaults("pane.export.cancel"))
        let host = PaneHost(generalPane(LoginFixture().model(), files: files))
        defer { host.close() }
        try await host.click("Export Settings…")
        try await host.until("the save panel") { asks == 1 }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!host.shows("Wherever could not export the settings."))
    }

    @Test func exportWritesTheChosenFile() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = freshDefaults("pane.export.write")
        defaults.set(Theme.midnightTeal.rawValue, forKey: Theme.key)
        let url = folder.appendingPathComponent("Wherever Settings.json")
        let host = PaneHost(generalPane(LoginFixture().model(), files: SettingsFileIO(saveURL: { url }, openURL: { nil }, defaults: defaults)))
        defer { host.close() }
        try await host.click("Export Settings…")
        try await host.until("the file") { FileManager.default.fileExists(atPath: url.path) }
        #expect(try SettingsFile.read(url)[Theme.key] as? String == "midnightTeal")
        #expect(!host.shows("Wherever could not export the settings."))
    }

    @Test func anExportThatCannotWriteShowsTheLine() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("missing/Wherever Settings.json")
        let host = PaneHost(generalPane(LoginFixture().model(), files: SettingsFileIO(saveURL: { url }, openURL: { nil }, defaults: freshDefaults("pane.export.fail"))))
        defer { host.close() }
        try await host.click("Export Settings…")
        try await host.until("the failure line") { host.shows("Wherever could not export the settings.") }
    }

    @Test func importCancelChangesNothing() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try settingsFile(#"{"format": 1, "theme": "warmPaper"}"#, in: folder)
        let defaults = freshDefaults("pane.import.cancel")
        defaults.set(Theme.midnightTeal.rawValue, forKey: Theme.key)
        var reopens = 0
        let host = PaneHost(generalPane(LoginFixture().model(), files: SettingsFileIO(saveURL: { nil }, openURL: { url }, defaults: defaults, reopen: { reopens += 1 })))
        defer { host.close() }
        try await host.click("Import Settings…")
        try await host.until("the alert") { host.sheet != nil }
        try await host.clickSheet("Cancel")
        try await host.until("the alert to close") { host.sheet == nil }
        #expect(defaults.string(forKey: Theme.key) == "midnightTeal" && reopens == 0)
    }

    @Test func importAsksThenWritesThenRelaunches() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try settingsFile(#"{"format": 1, "theme": "warmPaper", "mode": "normal"}"#, in: folder)
        let defaults = freshDefaults("pane.import.apply")
        defaults.set(Theme.midnightTeal.rawValue, forKey: Theme.key)
        var themeAtReopen: [String?] = []
        let files = SettingsFileIO(saveURL: { nil }, openURL: { url }, defaults: defaults, reopen: { themeAtReopen.append(defaults.string(forKey: Theme.key)) })
        let host = PaneHost(generalPane(LoginFixture().model(), files: files))
        defer { host.close() }
        try await host.click("Import Settings…")
        try await host.until("the alert") { host.sheet != nil }
        #expect(defaults.string(forKey: Theme.key) == "midnightTeal" && themeAtReopen.isEmpty)
        try await host.clickSheet("Import")
        try await host.until("the reopen") { themeAtReopen.count == 1 }
        #expect(themeAtReopen == ["warmPaper"])
        #expect(defaults.string(forKey: WindowMode.key) == "normal")
    }

    @Test func aFailedReopenSaysSoAndKeepsTheSettings() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try settingsFile(#"{"format": 1, "theme": "warmPaper"}"#, in: folder)
        let defaults = freshDefaults("pane.import.reopenfail")
        var reopens = 0
        let files = SettingsFileIO(saveURL: { nil }, openURL: { url }, defaults: defaults, reopen: { reopens += 1; if reopens == 1 { throw Refused() } })
        let host = PaneHost(generalPane(LoginFixture().model(), files: files))
        defer { host.close() }
        let line = "Wherever could not reopen."
        try await host.click("Import Settings…")
        try await host.until("the alert") { host.sheet != nil }
        try await host.clickSheet("Import")
        try await host.until("the reopen line") { host.shows(line) }
        #expect(defaults.string(forKey: Theme.key) == "warmPaper")
        try await host.click("Import Settings…")
        try await host.until("the alert") { host.sheet != nil }
        try await host.clickSheet("Import")
        try await host.until("the line to go") { !host.shows(line) }
    }

    @Test func aRefusedImportSaysWhyAndStays() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let newer = try settingsFile(#"{"format": 2, "theme": "warmPaper"}"#, in: folder, named: "newer.json")
        let broken = try settingsFile(#"{"format": 1, "theme": "warmPaper", "mode": "expert"}"#, in: folder, named: "broken.json")
        let defaults = freshDefaults("pane.import.refused")
        defaults.set(Theme.midnightTeal.rawValue, forKey: Theme.key)
        var chosen = newer
        var reopens = 0
        let files = SettingsFileIO(saveURL: { nil }, openURL: { chosen }, defaults: defaults, reopen: { reopens += 1 })
        let host = PaneHost(generalPane(LoginFixture().model(), files: files))
        defer { host.close() }
        try await host.click("Import Settings…")
        try await host.until("the newer line") { host.shows("This file is from a newer version of Wherever.") }
        #expect(host.sheet == nil)
        chosen = broken
        try await host.click("Import Settings…")
        try await host.until("the unreadable line") { host.shows("Wherever could not read this settings file.") }
        #expect(!host.shows("This file is from a newer version of Wherever."))
        #expect(host.sheet == nil)
        #expect(defaults.string(forKey: Theme.key) == "midnightTeal" && defaults.object(forKey: WindowMode.key) == nil && reopens == 0)
    }

    @Test func importAndExportAreTwoEqualUntitledCardsImportFirst() async throws {
        let host = PaneHost(generalPane(LoginFixture().model()))
        defer { host.close() }
        host.window.setContentSize(NSSize(width: SettingsWindow.Metrics.detailWidth, height: 1200))
        let frame = { (id: String) in AXTree.element(id, in: host.view).flatMap(AXTree.frame) }
        try await host.until("both buttons, the updates row and Reset") {
            ["general-export", "general-import", "general-reset", "general-automatic-updates"].allSatisfy { frame($0) != nil }
        }
        let exportButton = try #require(frame("general-export"))
        let importButton = try #require(frame("general-import"))
        let check = try #require(frame("general-automatic-updates"))
        let reset = try #require(frame("general-reset"))
        let titled = AXTree.elements(in: host.view).filter { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { AXTree.value($0, of: element) as String? == "Import and Export" }
        }
        #expect(titled.isEmpty, "an element titled Import and Export: \(titled)")
        #expect(importButton.midY == exportButton.midY, "the buttons share a row: import \(importButton), export \(exportButton)")
        #expect(importButton.maxX <= exportButton.minX, "import \(importButton) is left of export \(exportButton)")
        let exportCard = try #require(frame("general-export-card"))
        let importCard = try #require(frame("general-import-card"))
        #expect(importCard.maxX <= exportCard.minX && importCard.contains(importButton) && exportCard.contains(exportButton))
        #expect((exportCard.width - importCard.width) * host.window.backingScaleFactor == 0, "cards \(importCard) and \(exportCard)")
        #expect(importCard.minX < reset.minX, "card \(importCard), Reset \(reset)")
        let cardNames = ["general-export-card", "general-import-card"].flatMap { id in
            AXTree.element(id, in: host.view).map { AXTree.elements(in: $0).flatMap(AXTree.names(of:)) } ?? []
        }
        #expect(!cardNames.contains("Export Settings") && !cardNames.contains("Import Settings"), "VoiceOver reads each action once: \(cardNames)")
        #expect(check.minY > importCard.maxY && check.minY > exportCard.maxY, "the cards sit under Software Updates")
        #expect(importCard.minY > reset.maxY && exportCard.minY > reset.maxY, "the cards sit above Reset")
        let ids = AXTree.elements(in: host.view).compactMap(AXTree.identifier(of:))
        let importIndex = try #require(ids.firstIndex(of: "general-import"))
        let exportIndex = try #require(ids.firstIndex(of: "general-export"))
        #expect(importIndex < exportIndex, "VoiceOver reaches Export first: \(ids)")
        #expect(host.control("Export Settings…").flatMap(AXTree.identifier(of:)) == "general-export")
        #expect(host.control("Import Settings…").flatMap(AXTree.identifier(of:)) == "general-import")
    }

    @Test func theGeneralGroupsAndTheirRowsRunInTheDocumentedOrderFromTopToBottom() async throws {
        let host = PaneHost(generalPane(LoginFixture().model()))
        defer { host.close() }
        host.window.setContentSize(NSSize(width: SettingsWindow.Metrics.detailWidth, height: 1600))
        let elements = { AXTree.elements(in: host.view) }
        let header = { (title: String) in
            elements().filter { (AXTree.value("accessibilityRole", of: $0) as String?) == "AXHeading" && AXTree.names(of: $0).contains(title) }
                .compactMap(AXTree.frame(of:)).max { $0.maxY < $1.maxY }
        }
        let row = { (id: String) in AXTree.element(id, in: host.view).flatMap(AXTree.frame(of:)) }
        let anchors: [(name: String, frame: () -> NSRect?)] = [
            ("Startup", { header("Startup") }), ("Open at Login", { row("general-open-at-login") }),
            ("Menu Bar", { header("Menu Bar") }), ("Show Menu Bar Icon", { row("general-show-menu-bar-icon") }),
            ("Shortcut", { header("Shortcut") }), ("Launcher shortcut", { host.control("Launcher shortcut").flatMap(AXTree.frame(of:)) }),
            ("Command-Line Tool", { header("Command-Line Tool") }), ("the command-line tool button", { row(CommandLineToolRow.id) }),
            ("Search", { header("Search") }), ("Typo-Tolerant Search", { row("general-typo-tolerant-search") }),
            ("Appearance", { header("Appearance") }), ("the appearance row", { row(AppearanceRow.id) }), ("the theme picker", { row(ThemePicker.id) }),
            ("the opacity slider", { row(LauncherOpacityRow.id) }), ("Show inspector", { host.control("Show inspector").flatMap(AXTree.frame(of:)) }),
            ("Language", { header("Language") }), ("the language row", { row(LanguageRow.id) }),
            ("Open History", { header("Open History") }), ("Clear Open History…", { host.control("Clear Open History…").flatMap(AXTree.frame(of:)) }),
            ("Software Updates", { header("Software Updates") }), ("the automatic updates switch", { row("general-automatic-updates") }),
            ("Import Settings…", { row("general-import") }),
            ("Reset Settings", { header("Reset Settings") }), ("the Reset button", { row("general-reset") }),
        ]
        try await host.until("every anchor of the General pane") { anchors.allSatisfy { $0.frame() != nil } }
        let placed = anchors.map { ($0.name, $0.frame()?.midY ?? .nan) }
        for (above, below) in zip(placed, placed.dropFirst()) {
            #expect(above.1 > below.1, "\(above.0) at \(above.1) is not above \(below.0) at \(below.1); order: \(placed.map { "\($0.0) \($0.1)" })")
        }
    }

    @Test func theAppearanceGroupHoldsTheBackgroundOpacitySlider() async throws {
        let store = freshDefaults("pane.general.opacity")
        let host = PaneHost(generalPane(LoginFixture().model(), store: store))
        defer { host.close() }
        try await host.until("the opacity slider") { AXTree.element(LauncherOpacityRow.id, in: host.view) != nil }
        let slider = try #require(AXTree.element(LauncherOpacityRow.id, in: host.view))
        #expect(AXTree.names(of: slider).contains("Wherever search background opacity"), "the slider reads \(AXTree.names(of: slider))")
        #expect(AXTree.isEnabled(slider) == true)
        let increment = NSSelectorFromString("accessibilityPerformIncrement")
        try #require(slider.responds(to: increment), "the slider takes no accessibility increment")
        _ = slider.perform(increment)
        try await host.until("the stored opacity rises above \(Launcher.standardOpacity)") {
            (store.object(forKey: Launcher.opacityKey) as? Int).map { $0 > Launcher.standardOpacity } == true
        }
    }

    @Test func reduceTransparencyDisablesTheOpacitySliderAndSaysWhy() async throws {
        let host = PaneHost(generalPane(LoginFixture().model(), store: freshDefaults("pane.general.opacity.solid"))
            .environment(\._accessibilityReduceTransparency, true))
        defer { host.close() }
        try await host.until("the opacity slider") { AXTree.element(LauncherOpacityRow.id, in: host.view) != nil }
        let slider = try #require(AXTree.element(LauncherOpacityRow.id, in: host.view))
        #expect(AXTree.isEnabled(slider) == false)
        #expect(host.shows("Wherever search stays solid while Reduce transparency is on in System Settings > Accessibility."))
    }

    @Test func theCommandLineToolButtonSitsAfterTheShortcutAndBeforeTheTypoSwitch() async throws {
        let host = PaneHost(generalPane(LoginFixture().model()))
        defer { host.close() }
        try await host.until("the command-line tool button") { AXTree.element(CommandLineToolRow.id, in: host.view) != nil }
        let elements = AXTree.elements(in: host.view)
        let shortcut = try #require(elements.firstIndex { AXTree.names(of: $0).contains("Launcher shortcut") })
        let tool = try #require(elements.firstIndex { AXTree.identifier(of: $0) == CommandLineToolRow.id })
        let typo = try #require(elements.firstIndex { AXTree.identifier(of: $0) == "general-typo-tolerant-search" })
        #expect(shortcut < tool && tool < typo, "Launcher shortcut at \(shortcut), the tool at \(tool), the typo switch at \(typo)")
        #expect(AXTree.names(of: elements[tool]).contains("Install"), "the button reads \(AXTree.names(of: elements[tool]))")
        #expect(AXTree.isEnabled(elements[tool]) == true)
        #expect(AXTree.value("accessibilityHelp", of: elements[tool]) as String? == "Search from the command line with the wherever command.")
        #expect(host.shows("Command-Line Tool"))
    }

    @Test func theCommandLineRowShowsUninstallThenMissingAfterTheLinkGoesAndAFailedRelink() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wherever-cli-pane-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "bin")
        let tool = root.appending(path: "Wherever.app/Contents/Helpers/wherever")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: tool)
        let link = folder.appending(path: "wherever").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tool.path(percentEncoded: false))
        let defaults = freshDefaults("pane.general.commandline")
        defaults.set(true, forKey: CommandLineToolModel.key)
        let model = CommandLineToolModel(linkFolder: folder, profile: root.appending(path: ".zshenv"), tool: tool, defaults: defaults)
        let host = PaneHost(generalPane(LoginFixture().model(), commandLine: model))
        defer { host.close() }
        let button = { AXTree.element(CommandLineToolRow.id, in: host.view) }
        let hint = { button().flatMap { AXTree.value("accessibilityHelp", of: $0) as String? } }
        try await host.until("Uninstall and the link's path") {
            button().map { AXTree.names(of: $0).contains("Uninstall") } == true
                && hint() == "Installed at \u{2066}\(link)\u{2069}. Open a new Terminal window to use it."
        }
        try FileManager.default.removeItem(atPath: link)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await host.until("the missing line and Install") {
            button().map { AXTree.names(of: $0).contains("Install") } == true && hint() == "The wherever command is missing. Install it again."
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false)) }
        try #require(AXTree.press(try #require(button())))
        try await host.until("the failure after the refused link") { !model.busy && model.notice == .installFailed && button().flatMap(AXTree.isEnabled) == true }
        #expect(model.isOn && !model.linked)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".zshenv").path(percentEncoded: false)))
    }

    @Test func theArabicInstalledCaptionDrawsTheLinkPathWithItsSlashFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wherever-cli-arabic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "bin")
        let tool = root.appending(path: "Wherever.app/Contents/Helpers/wherever")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: tool)
        let link = folder.appending(path: "wherever").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tool.path(percentEncoded: false))
        let defaults = freshDefaults("pane.general.commandline.arabic")
        defaults.set(true, forKey: CommandLineToolModel.key)
        let model = CommandLineToolModel(linkFolder: folder, profile: root.appending(path: ".zshenv"), tool: tool, defaults: defaults)
        let pane = generalPane(LoginFixture().model(), commandLine: model)
            .environment(\.locale, Locale(identifier: "ar")).environment(\.layoutDirection, .rightToLeft)
        let host = PaneHost(pane)
        defer { host.close() }
        let template = try arabicTemplate("Installed at %@.")
        let sides = template.components(separatedBy: "%@")
        try #require(sides.count == 2, "the Arabic template holds one %@: \(template)")
        let isolated = "\u{2066}\(link)\u{2069}"
        let terminal = try arabicTemplate("Open a new Terminal window to use it.")
        let hint = { AXTree.element(CommandLineToolRow.id, in: host.view).flatMap { AXTree.value("accessibilityHelp", of: $0) as String? } }
        try await host.until("the Arabic caption with the isolated path, read \(hint() ?? "nothing")") {
            hint().map { $0.hasPrefix(sides[0]) && $0.hasSuffix(sides[1] + " " + terminal) && $0.contains(isolated) } == true
        }
        #expect(drawsSlashFirst(try #require(hint()), path: link) == true)
        #expect(drawsSlashFirst(String(format: template, link), path: link) == false)
    }

    @Test(arguments: [
        "Installed at %@.", "Another program already uses %@. Remove it, then try again.",
        "Exclude “%@”?", "Remove “%@” to index this disk",
    ]) func anArabicSentenceDrawsAnIsolatedPathWithItsSlashFirst(_ key: String) throws {
        let template = try arabicTemplate(key)
        let path = "/Volumes/Backup"
        #expect(drawsSlashFirst(String(format: template, Bidi.path(path)), path: path) == true)
        #expect(drawsSlashFirst(String(format: template, path), path: path) == false)
    }

    @Test func theTextSizeSliderSitsAfterColorThemeAndStoresNothingUntilItMoves() async throws {
        let store = freshDefaults("pane.general.textsize")
        let host = PaneHost(generalPane(LoginFixture().model(), store: store))
        defer { host.close() }
        try await host.until("the text size slider") { AXTree.element(TextSizeRow.id, in: host.view) != nil }
        let ids = AXTree.elements(in: host.view).compactMap(AXTree.identifier(of:))
        let theme = try #require(ids.firstIndex(of: ThemePicker.id))
        let size = try #require(ids.firstIndex(of: TextSizeRow.id))
        let opacity = try #require(ids.firstIndex(of: LauncherOpacityRow.id))
        #expect(theme < size && size < opacity, "Color theme, Text size, then the opacity: \(ids)")
        let element = try #require(AXTree.element(TextSizeRow.id, in: host.view))
        #expect(AXTree.names(of: element).contains("Text size"), "the slider reads \(AXTree.names(of: element))")
        let slider = try textSizeSlider(in: host)
        #expect(slider.integerValue == 13 && slider.numberOfTickMarks == 8 && slider.allowsTickMarkValuesOnly)
        #expect(slider.accessibilityValueDescription() == "13 pt")
        #expect(store.object(forKey: TextSize.key) == nil)
    }

    @Test func aRightArrowOnTheFocusedTextSizeSliderStoresFourteen() async throws {
        let store = freshDefaults("pane.general.textsize.arrow")
        let host = PaneHost(generalPane(LoginFixture().model(), store: store))
        defer { host.close() }
        try await host.until("the text size slider") { AXTree.element(TextSizeRow.id, in: host.view) != nil }
        let slider = try textSizeSlider(in: host)
        try #require(host.window.makeFirstResponder(slider))
        let arrow = String(try #require(UnicodeScalar(NSRightArrowFunctionKey)))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window.windowNumber, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
            isARepeat: false, keyCode: UInt16(kVK_RightArrow)
        ))
        host.window.sendEvent(event)
        try await host.until("the stored size 14") { store.object(forKey: TextSize.key) as? Int == 14 }
        try await host.until("the slider to read 14 pt") { slider.accessibilityValueDescription() == "14 pt" }
        #expect(slider.integerValue == 14)
    }

    @Test(arguments: [false, true]) func tabAndShiftTabLeaveTheFocusedTextSizeSlider(_ backwards: Bool) async throws {
        let store = freshDefaults("pane.general.textsize.tab.\(backwards)")
        let host = PaneHost(generalPane(LoginFixture().model(), store: store))
        defer { host.close() }
        try await host.until("the text size slider") { AXTree.element(TextSizeRow.id, in: host.view) != nil }
        let slider = try textSizeSlider(in: host)
        try #require(host.window.makeFirstResponder(slider))
        let target = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        host.view.addSubview(target)
        host.window.autorecalculatesKeyViewLoop = false
        if backwards { target.nextKeyView = slider } else { slider.nextKeyView = target }
        try #require(target.canBecomeKeyView && (backwards ? slider.previousKeyView : slider.nextKeyView) === target)
        let key = backwards ? "\u{19}" : "\t"
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: backwards ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: UInt16(kVK_Tab)
        ))
        host.window.sendEvent(event)
        try await host.until("the focus to leave the slider for \(target)") { host.window.firstResponder !== slider }
        #expect(host.window.firstResponder === target || (host.window.firstResponder as? NSView)?.isDescendant(of: target) == true)
        #expect(store.object(forKey: TextSize.key) == nil && slider.integerValue == 13)
    }

    @Test(arguments: [
        (kVK_RightArrow, NSRightArrowFunctionKey, 12), (kVK_LeftArrow, NSLeftArrowFunctionKey, 14),
        (kVK_UpArrow, NSUpArrowFunctionKey, 14), (kVK_DownArrow, NSDownArrowFunctionKey, 12),
    ]) func anArrowOnTheRightToLeftTextSizeSliderMovesTheKnobItsWay(_ code: Int, _ key: Int, _ stored: Int) async throws {
        let store = freshDefaults("pane.general.textsize.rtl.\(code)")
        let pane = generalPane(LoginFixture().model(), store: store)
            .environment(\.locale, Locale(identifier: "ar")).environment(\.layoutDirection, .rightToLeft)
        let host = PaneHost(pane)
        defer { host.close() }
        try await host.until("the text size slider") { AXTree.element(TextSizeRow.id, in: host.view) != nil }
        let slider = try textSizeSlider(in: host)
        slider.userInterfaceLayoutDirection = .rightToLeft
        #expect(slider.integerValue == 13)
        try #require(host.window.makeFirstResponder(slider))
        let arrow = String(try #require(UnicodeScalar(key)))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window.windowNumber, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
            isARepeat: false, keyCode: UInt16(code)
        ))
        host.window.sendEvent(event)
        try await host.until("the stored size \(stored)") { store.object(forKey: TextSize.key) as? Int == stored }
        #expect(slider.integerValue == stored)
    }

    @Test func anAccessibilityIncrementAtTheLargestSizeStoresNothingNew() async throws {
        let store = freshDefaults("pane.general.textsize.largest")
        store.set(18, forKey: TextSize.key)
        let host = PaneHost(generalPane(LoginFixture().model(), store: store))
        defer { host.close() }
        try await host.until("the text size slider") { AXTree.element(TextSizeRow.id, in: host.view) != nil }
        let slider = try textSizeSlider(in: host)
        #expect(slider.integerValue == 18)
        #expect(!slider.accessibilityPerformIncrement())
        #expect(store.object(forKey: TextSize.key) as? Int == 18 && slider.integerValue == 18)
        #expect(slider.accessibilityPerformDecrement())
        try await host.until("the stored size 17") { store.object(forKey: TextSize.key) as? Int == 17 }
    }

    @Test func theLargestTextSizeGrowsHeadersLabelsCaptionsAndButtons() async throws {
        let names = ["Startup", "Launcher shortcut", "Press it in any app to search your files."]
        let button = "Clear Open History…"
        var heights: [[CGFloat]] = []
        for size in [TextSize.standard, .maximum] {
            let store = freshDefaults("pane.general.textsize.grow.\(size.rawValue)")
            store.set(size.rawValue, forKey: TextSize.key)
            let host = PaneHost(generalPane(LoginFixture().model(), store: store))
            defer { host.close() }
            try await host.until("the texts and the \(button) button at \(size.rawValue) pt") {
                names.allSatisfy { textHeight($0, in: host.view) != nil } && host.control(button) != nil
            }
            let buttonHeight = try #require(host.control(button).flatMap(AXTree.frame)).height
            heights.append(names.compactMap { textHeight($0, in: host.view) } + [buttonHeight])
        }
        for (index, name) in (names + [button]).enumerated() {
            #expect(heights[1][index] > heights[0][index], "\(name): \(heights[0][index]) at 13 pt, \(heights[1][index]) at 18 pt")
        }
    }

    @Test(arguments: ["ar", "vi", "en"]) func noHeaderLabelOrCaptionIsShorterAtALargerTextSize(_ language: String) async throws {
        let names = ["Startup", "Launcher shortcut", "Press it in any app to search your files."]
        var heights: [[CGFloat]] = []
        for size in TextSize.allCases {
            let form = Form {
                Section {
                    LabeledContent { Text(verbatim: "⌃⇧F") } label: { Text(verbatim: names[1]).font(size.formLabel) }
                    Text(verbatim: names[2]).font(size.caption)
                } header: { Text(verbatim: names[0]).font(size.formHeader) }
            }
            let host = PaneHost(form.formStyle(.grouped).typesettingLanguage(.explicit(Locale.Language(identifier: language))))
            defer { host.close() }
            try await host.until("the texts at \(size.rawValue) pt in \(language)") { names.allSatisfy { textHeight($0, in: host.view) != nil } }
            heights.append(names.compactMap { textHeight($0, in: host.view) })
        }
        for (index, name) in names.enumerated() {
            let column = heights.map { $0[index] }
            #expect(zip(column, column.dropFirst()).allSatisfy { $0 <= $1 }, "\(name) in \(language) from 11 to 18 pt: \(column)")
        }
    }

    @Test func theHeadersAndLabelsKeepTheBodyTextStyleAtTheLargestSize() async throws {
        let names = ["Startup", "Launcher shortcut"]
        let store = freshDefaults("pane.general.textsize.style")
        store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        let host = PaneHost(generalPane(LoginFixture().model(), store: store))
        defer { host.close() }
        func reference(_ font: Font) -> PaneHost {
            PaneHost(Form {
                Section { LabeledContent { Text(verbatim: "⌃⇧F") } label: { Text(verbatim: names[1]).font(font) } } header: { Text(verbatim: names[0]).font(font) }
            }.formStyle(.grouped))
        }
        let style = reference(Font(TextSize.maximum.font(.preferredFont(forTextStyle: .body)) as CTFont))
        defer { style.close() }
        let system = reference(.system(size: TextSize.maximum.points(NSFont.systemFontSize)))
        defer { system.close() }
        for pane in [host, style, system] {
            try await pane.until("the header and the label at 18 pt") { names.allSatisfy { textHeight($0, in: pane.view) != nil } }
        }
        for name in names {
            let expected = try #require(textHeight(name, in: style.view))
            try #require(expected != textHeight(name, in: system.view), "\(name): the body text style and the system font are both \(expected) high")
            #expect(textHeight(name, in: host.view) == expected, "\(name) at 18 pt")
        }
    }

    private static let resetSentence = "Reset all settings, saved indexes and open history (cannot be undone)"

    private func tallPane(
        _ name: String, size: TextSize = .standard, reset: @escaping @MainActor () async throws -> Void = {}
    ) -> PaneHost {
        let store = freshDefaults("pane.general.look.\(name).\(size.rawValue)")
        store.set(size.rawValue, forKey: TextSize.key)
        let host = PaneHost(generalPane(LoginFixture().model(), store: store, reset: reset))
        host.window.appearance = NSAppearance(named: .aqua)
        host.window.setContentSize(NSSize(width: SettingsWindow.Metrics.detailWidth, height: 1600))
        return host
    }

    @Test func theResetButtonIsAsHighAsThePushButtonsAndItsSentenceIsARowLabel() async throws {
        var widths: [CGFloat] = []
        for size in [TextSize.standard, .maximum] {
            let host = tallPane("reset.height", size: size)
            defer { host.close() }
            let reset = { AXTree.element("general-reset", in: host.view).flatMap(AXTree.frame(of:)) }
            let clear = { host.control("Clear Open History…").flatMap(AXTree.frame(of:)) }
            try await host.until("Reset, Clear Open History… and the two labels at \(size.rawValue) pt") {
                reset() != nil && clear() != nil && textFrame(Self.resetSentence, in: host.view) != nil && textFrame("Launcher shortcut", in: host.view) != nil
            }
            let button = try #require(reset()), push = try #require(clear())
            #expect((button.height - push.height) * host.window.backingScaleFactor == 0, "at \(size.rawValue) pt: Reset \(button), Clear Open History… \(push)")
            widths.append(button.width)
            if size == .standard {
                let sentence = try #require(textFrame(Self.resetSentence, in: host.view))
                let label = try #require(textFrame("Launcher shortcut", in: host.view))
                #expect((sentence.height - label.height) * host.window.backingScaleFactor == 0, "the Reset sentence \(sentence), Launcher shortcut \(label)")
            }
        }
        #expect(widths[1] > widths[0], "Reset is \(widths[0]) wide at 13 pt and \(widths[1]) at 18 pt")
    }

    @Test func theResetButtonIsFilledRedAcrossThePushButtonHeight() async throws {
        let host = tallPane("reset.red")
        defer { host.close() }
        let reset = { AXTree.element("general-reset", in: host.view).flatMap(AXTree.frame(of:)) }
        let clear = { host.control("Clear Open History…").flatMap(AXTree.frame(of:)) }
        try await host.until("Reset and Clear Open History…") { reset() != nil && clear() != nil }
        try await host.scroll(toEnd: true)
        let shot = try PaneShot(host)
        let resetFrame = try #require(reset()), clearFrame = try #require(clear())
        let button = shot.pixels(resetFrame), push = shot.pixels(clearFrame)
        let middle = (button.minY + button.maxY) / 2
        let fill = try #require(shot.pixel(button.minX + 3, middle))
        #expect(fill[0] > 204 && fill[1] < 128 && fill[2] < 128, "the Reset fill 3 px inside its left edge reads \(fill)")
        let inset = Int(((ResetRow.cornerRadius + 1) * shot.scale).rounded())
        let red = shot.rows(x: button.minX + inset, within: button.minY - 8...button.maxY + 8) { $0[0] - max($0[1], $0[2]) > 100 }
        let card = try #require(shot.pixel(push.minX - 4, (push.minY + push.maxY) / 2))
        let bezel = shot.rows(x: push.minX + inset, within: push.minY - 8...push.maxY + 8) { $0 != card }
        #expect(!red.isEmpty && red.count == bezel.count, "Reset is red over \(red.count) px rows, the Clear Open History… bezel spans \(bezel.count)")
    }

    @Test func everyGapBetweenGroupsIsTheTitledGapAroundImportAndExport() async throws {
        let host = tallPane("gaps")
        defer { host.close() }
        let card = { AXTree.element("general-import-card", in: host.view).flatMap(AXTree.frame(of:)) }
        try await host.until("the Import card and Reset") { card() != nil && AXTree.element("general-reset", in: host.view) != nil }
        try await host.scroll(toEnd: true)
        let shot = try PaneShot(host)
        let importCard = try #require(card())
        let column = shot.pixels(importCard).midX
        let cards = shot.runs(x: column, longerThan: Int(30 * shot.scale))
        try #require(cards.count >= 4, "cards along x \(column): \(cards)")
        let gaps = zip(cards, cards.dropFirst()).map { $1.lowerBound - $0.upperBound - 1 }
        #expect(Set(gaps).count == 1, "the gaps between groups along x \(column), in px: \(gaps)")
    }

    @Test func theActionButtonsEndAtOneTrailingInset() async throws {
        let host = tallPane("trailing")
        defer { host.close() }
        let frames = {
            [host.control("Clear Open History…"), AXTree.element(CommandLineToolRow.id, in: host.view),
             AXTree.element("general-export", in: host.view), AXTree.element("general-reset", in: host.view)].map { $0.flatMap(AXTree.frame(of:)) }
        }
        try await host.until("the four action buttons") { frames().allSatisfy { $0 != nil } }
        let ends = frames().compactMap { $0?.maxX }
        #expect(ends.allSatisfy { ($0 - ends[0]) * host.window.backingScaleFactor == 0 }, "Clear Open History…, Install, Export… and Reset end at \(ends)")
    }

    @Test func eachCaptionSitsOneCaptionSpacingUnderItsControl() async throws {
        let pairs: [(name: String, control: (PaneHost) -> NSRect?, caption: String)] = [
            ("Open at Login", { AXTree.element("general-open-at-login", in: $0.view).flatMap(AXTree.frame(of:)) }, "Starts the menu bar icon and the launcher shortcut when you log in, as you set them below."),
            ("Show Menu Bar Icon", { AXTree.element("general-show-menu-bar-icon", in: $0.view).flatMap(AXTree.frame(of:)) },
             "Shows a Wherever icon in the menu bar. Click it to open the launcher, or right-click it for a menu. If it does not appear, open System Settings and look in the Menu Bar section."),
            ("Launcher shortcut", { $0.control("Launcher shortcut").flatMap(AXTree.frame(of:)) }, "Press it in any app to search your files."),
            ("Typo-Tolerant Search", { AXTree.element("general-typo-tolerant-search", in: $0.view).flatMap(AXTree.frame(of:)) },
             "When no name holds your letters side by side, also shows close matches, such as names with a typo."),
        ]
        for size in TextSize.allCases {
            let host = tallPane("captions", size: size)
            defer { host.close() }
            let reference = captionReference(size)
            defer { reference.close() }
            for pane in [host, reference] {
                try await pane.until("four controls and their captions at \(size.rawValue) pt") {
                    pairs.allSatisfy { $0.control(pane) != nil && textFrame($0.caption, in: pane.view) != nil }
                }
            }
            let scale = host.window.backingScaleFactor
            for pair in pairs {
                let control = try #require(pair.control(host)), caption = try #require(textFrame(pair.caption, in: host.view))
                let built = try #require(pair.control(reference)), builtCaption = try #require(textFrame(pair.caption, in: reference.view))
                let gap = control.minY - caption.maxY, expected = built.minY - builtCaption.maxY
                #expect(
                    (gap - expected) * scale == 0,
                    "at \(size.rawValue) pt, \(pair.name): pane control \(control), caption \(caption), gap \(gap); one VStack of spacing \(SettingsWindow.Metrics.captionSpacing): control \(built), caption \(builtCaption), gap \(expected)"
                )
                let pixel = caption.minY * scale
                #expect(pixel == pixel.rounded(), "at \(size.rawValue) pt, the \(pair.name) caption \(caption) sits off the \(scale)x pixel grid")
            }
        }
    }

    @Test func everyHeadingOfThePaneSitsOnTheDevicePixelGrid() async throws {
        let headings = ["Startup", "Menu Bar", "Shortcut", "Command-Line Tool", "Search", "Appearance", "Language", "Open History", "Software Updates", "Reset Settings"]
        for size in TextSize.allCases {
            let host = tallPane("headings", size: size)
            defer { host.close() }
            let heading = { (title: String) in
                AXTree.elements(in: host.view).filter { (AXTree.value("accessibilityRole", of: $0) as String?) == "AXHeading" && AXTree.names(of: $0).contains(title) }
                    .compactMap(AXTree.frame(of:)).max { $0.maxY < $1.maxY }
            }
            try await host.until("the ten headings at \(size.rawValue) pt") { headings.allSatisfy { heading($0) != nil } }
            let scale = host.window.backingScaleFactor
            for title in headings {
                let frame = try #require(heading(title))
                let pixel = frame.minY * scale
                #expect(pixel == pixel.rounded(), "at \(size.rawValue) pt, the \(title) heading \(frame) sits off the \(scale)x pixel grid")
            }
        }
    }

    private func captionReference(_ size: TextSize) -> PaneHost {
        let row = { (control: AnyView, caption: String) in
            VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
                control
                Text(verbatim: caption).font(size.caption).foregroundStyle(.secondary)
            }
        }
        let toggle = { (label: String, id: String) in
            AnyView(Toggle(isOn: .constant(false)) { Text(verbatim: label).font(size.formLabel) }.toggleStyle(.switch).accessibilityIdentifier(id))
        }
        let store = freshDefaults("pane.general.look.captions.reference.\(size.rawValue)")
        store.set(size.rawValue, forKey: TextSize.key)
        let recorder = HotkeyRecorder(model: HelperStarterSpy().model(freshDefaults("pane.general.look.captions.hotkey.\(size.rawValue)")))
        let host = PaneHost(Form {
            Section {
                row(toggle("Open at Login", "general-open-at-login"), "Starts the menu bar icon and the launcher shortcut when you log in, as you set them below.")
            } header: { Text(verbatim: "Startup").font(size.formHeader) }
            Section {
                row(toggle("Show Menu Bar Icon", "general-show-menu-bar-icon"),
                    "Shows a Wherever icon in the menu bar. Click it to open the launcher, or right-click it for a menu. If it does not appear, open System Settings and look in the Menu Bar section.")
            } header: { Text(verbatim: "Menu Bar").font(size.formHeader) }
            Section {
                row(AnyView(LabeledContent { recorder } label: { Text(verbatim: "Launcher shortcut").font(size.formLabel) }), "Press it in any app to search your files.")
            } header: { Text(verbatim: "Shortcut").font(size.formHeader) }
            Section {
                row(toggle("Typo-Tolerant Search", "general-typo-tolerant-search"),
                    "When no name holds your letters side by side, also shows close matches, such as names with a typo.")
            } header: { Text(verbatim: "Search").font(size.formHeader) }
        }.formStyle(.grouped).defaultAppStorage(store))
        host.window.appearance = NSAppearance(named: .aqua)
        host.window.setContentSize(NSSize(width: SettingsWindow.Metrics.detailWidth, height: 1600))
        return host
    }

    @Test func aFailureLineIsRedAndACaptionIsNot() async throws {
        let host = tallPane("failure", reset: { throw Refused() })
        defer { host.close() }
        try await host.until("the reset button") { AXTree.element("general-reset", in: host.view) != nil }
        try #require(AXTree.press(try #require(AXTree.element("general-reset", in: host.view))))
        try await host.clickSheet("Reset")
        let failure = "Wherever could not reset. Try again.", caption = "Starts the menu bar icon and the launcher shortcut when you log in, as you set them below."
        try await host.until("the failure line") { host.sheet == nil && textFrame(failure, in: host.view) != nil }
        try await host.scroll(toEnd: true)
        let failureFrame = try #require(textFrame(failure, in: host.view))
        let line = try PaneShot(host).darkest(in: failureFrame)
        try await host.scroll(toEnd: false)
        let captionFrame = try #require(textFrame(caption, in: host.view))
        let secondary = try PaneShot(host).darkest(in: captionFrame)
        let red = { (pixel: [Int]) in pixel[0] - max(pixel[1], pixel[2]) > 60 }
        #expect(red(try #require(line)), "the failure line's darkest pixel reads \(String(describing: line))")
        #expect(!red(try #require(secondary)), "the Open at Login caption's darkest pixel reads \(String(describing: secondary))")
    }

    @Test func theTwoSlidersShareOneTrackColumn() async throws {
        for size in [TextSize.standard, .maximum] {
            let host = tallPane("sliders", size: size)
            defer { host.close() }
            let frames = { () -> [NSRect]? in
                guard let slider = descendants(of: host.view).compactMap({ $0 as? NSSlider }).first(where: { $0.identifier?.rawValue == TextSizeRow.id }),
                      let window = slider.window,
                      let opacity = AXTree.element(LauncherOpacityRow.id, in: host.view).flatMap(AXTree.frame(of:)) else { return nil }
                return [window.convertToScreen(slider.convert(slider.bounds, to: nil)), opacity]
            }
            var last: [NSRect]?
            var settled: [NSRect]?
            try await host.until("both sliders at \(size.rawValue) pt, read alike twice in a row") {
                let now = frames()
                defer { last = now }
                if now != nil, now == last { settled = now }
                return settled != nil
            }
            let pair = try #require(settled)
            let text = pair[0], opacity = pair[1]
            let scale = host.window.backingScaleFactor
            #expect((text.minX - opacity.minX) * scale == 0, "at \(size.rawValue) pt: the Text size slider view \(text), the opacity slider \(opacity)")
            #expect((text.maxX - opacity.maxX) * scale == 0, "at \(size.rawValue) pt: the Text size slider view \(text), the opacity slider \(opacity)")
        }
    }
}

private func textFrame(_ text: String, in view: NSView) -> NSRect? {
    let roles = [NSAccessibility.Role.staticText.rawValue, "AXHeading"]
    return AXTree.elements(in: view).first { element in
        (AXTree.value("accessibilityRole", of: element) as String?).map(roles.contains) == true && AXTree.names(of: element).contains(text)
    }.flatMap(AXTree.frame)
}

private func textHeight(_ text: String, in view: NSView) -> CGFloat? { textFrame(text, in: view)?.height }

private struct PaneShot {
    struct Box { let minX, minY, maxX, maxY: Int; var midX: Int { (minX + maxX) / 2 } }

    let rep: NSBitmapImageRep
    let scale: CGFloat
    private let view: NSView

    init(_ host: PaneHost) throws {
        view = host.view
        view.layoutSubtreeIfNeeded()
        rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        scale = CGFloat(rep.pixelsWide) / view.bounds.width
    }

    func pixels(_ screen: NSRect) -> Box {
        guard let window = view.window else { return Box(minX: 0, minY: 0, maxX: 0, maxY: 0) }
        let local = view.convert(window.convertFromScreen(screen), from: nil)
        let top = view.isFlipped ? local.minY : view.bounds.height - local.maxY
        let px = { (value: CGFloat) in Int((value * scale).rounded()) }
        return Box(minX: px(local.minX), minY: px(top), maxX: px(local.maxX) - 1, maxY: px(top + local.height) - 1)
    }

    func pixel(_ x: Int, _ y: Int) -> [Int]? {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        return srgbPixel(rep, x: x, y: y)
    }

    func rows(x: Int, within range: ClosedRange<Int>? = nil, _ test: ([Int]) -> Bool) -> [Int] {
        (range ?? 0...(rep.pixelsHigh - 1)).filter { y in pixel(x, y).map(test) == true }
    }

    func runs(x: Int, longerThan length: Int) -> [ClosedRange<Int>] {
        var found: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0...rep.pixelsHigh {
            let filled = y < rep.pixelsHigh && pixel(x, y) != pixel(0, y)
            if filled, start == nil { start = y }
            if !filled, let first = start {
                if y - first > length { found.append(first...(y - 1)) }
                start = nil
            }
        }
        return found
    }

    func darkest(in screen: NSRect) -> [Int]? {
        let box = pixels(screen)
        return (box.minY...box.maxY).flatMap { y in (box.minX...box.maxX).compactMap { pixel($0, y) } }.min { $0.reduce(0, +) < $1.reduce(0, +) }
    }
}

private func arabicTemplate(_ key: String) throws -> String {
    let arabic = try #require(Bundle.main.url(forResource: "ar", withExtension: "lproj").flatMap(Bundle.init(url:)), "no ar.lproj")
    let template = arabic.localizedString(forKey: key, value: "\u{1}", table: "Settings")
    try #require(template != "\u{1}" && template != key, "the Arabic Settings table holds no \(key)")
    return template
}

private func drawsSlashFirst(_ text: String, path: String) -> Bool? {
    let start = (text as NSString).range(of: path).location
    guard start != NSNotFound else { return nil }
    let style = NSMutableParagraphStyle()
    style.baseWritingDirection = .rightToLeft
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .paragraphStyle: style]))
    var origins: [CFIndex: CGFloat] = [:]
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
        let count = CTRunGetGlyphCount(run)
        var indices = [CFIndex](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for (index, position) in zip(indices, positions) { origins[index] = position.x }
    }
    guard let slash = origins[start], let letter = origins[start + 1] else { return nil }
    return slash < letter
}

private func textSizeSlider(in host: PaneHost) throws -> NSSlider {
    try #require(descendants(of: host.view).compactMap { $0 as? NSSlider }.first { $0.identifier?.rawValue == TextSizeRow.id })
}

private func tempFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("settingsfile-pane-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func settingsFile(_ json: String, in folder: URL, named name: String = "Wherever Settings.json") throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data(json.utf8).write(to: url)
    return url
}
private func send(_ characters: String, _ code: Int, _ flags: NSEvent.ModifierFlags, to window: NSWindow) throws {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: UInt16(code)
    ))
    NSApp.sendEvent(event)
}

private let controlOptionK = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), character: "K")

@Suite(.serialized) struct ShortcutGroupTests {
    @Test func recordingControlOptionKFromThePaneChangesTheKeyAndTellsTheHelper() async throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("pane.record"))
        let host = PaneHost(generalPane(.inert(), hotkey: model))
        defer { model.stopRecording(); host.close() }
        try await host.click("Launcher shortcut")
        try await host.until("the recorder to listen") { model.isRecording }
        try send("k", kVK_ANSI_K, [.control, .option], to: host.window)
        #expect(model.hotkey == controlOptionK)
        #expect(spy.notes == [HelperLink.Note.pause, HelperLink.Note.sync, HelperLink.Note.resume])
        #expect(!model.isRecording)
    }

    @Test func escapeWhileRecordingCancelsAndASecondEscapeClosesSettings() async throws {
        let rig = SettingsRig(name: "pane.escape")
        defer { rig.hotkey.stopRecording(); rig.window.close() }
        rig.window.show()
        let window = try #require(rig.window.window)
        try await rig.record()
        rig.hotkeys.notes = []
        try send("\u{1b}", kVK_Escape, [], to: window)
        #expect(!rig.hotkey.isRecording)
        #expect(rig.hotkey.hotkey == .summon)
        #expect(rig.hotkeys.notes == [HelperLink.Note.resume])
        #expect(window.isVisible)
        try rig.escape()
        #expect(!window.isVisible)
    }

    @Test func aRefusedKeyShowsItsReasonAndKeepsRecording() async throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("pane.refused"))
        let host = PaneHost(generalPane(.inert(), hotkey: model))
        defer { model.stopRecording(); host.close() }
        try await host.click("Launcher shortcut")
        try await host.until("the recorder to listen") { model.isRecording }
        try send("k", kVK_ANSI_K, [.shift], to: host.window)
        try await host.until("the refusal line") { host.shows("Hold Control, Option or Command with the key.") }
        #expect(model.isRecording)
        #expect(model.hotkey == .summon)
    }
}

private nonisolated let archive = IndexedVolume(id: "A", name: "Archive", path: "/Volumes/Archive", indexed: true)
private nonisolated let backup = IndexedVolume(id: "B", name: "Backup", path: "/Volumes/Backup", indexed: true)

private final class PanelSpy {
    var next: String?
    private(set) var shown = 0

    func choose() -> String? {
        shown += 1
        return next
    }
}

private nonisolated struct ChangeFails: SearchClient {
    struct Refused: Error {}
    var events: AsyncStream<SearchEvent> { AsyncStream { _ in } }
    func makeSession() throws -> any SearchSessionClient { throw Refused() }
    func recordOpen(_ path: String) throws {}
    func clearOpens() throws {}
    func flushOpens() throws {}
    func isSettling() throws -> Bool { false }
    func setExcludedFolders(_ paths: [String]) throws { throw Refused() }
    func setTypoSearch(_ on: Bool) throws {}
    func setLiveUpdates(_ on: Bool) throws {}
    func setIndexedVolumes(_ ids: Set<String>) throws { throw Refused() }
    func volumes() throws -> [IndexedVolume] { [archive, backup] }
}

private struct LocationsRig {
    let fake = FakeSearchClient()
    let defaults: UserDefaults
    let panel = PanelSpy()
    let model: LocationsModel
    let host: PaneHost

    init(_ name: String, folders: [String]? = [], indexed: [String] = [], disks: [IndexedVolume] = [archive, backup], failing: Bool = false) {
        defaults = freshDefaults("locations.\(name)")
        if let folders { defaults.set(folders, forKey: LocationsModel.Key.excluded) }
        defaults.set(indexed, forKey: LocationsModel.Key.indexedVolumes)
        fake.setVolumes(.success(disks))
        let client: any SearchClient = failing ? ChangeFails() : fake
        let panel = panel
        model = LocationsModel(client: client, defaults: defaults, chooseFolder: { panel.choose() })
        host = PaneHost(LocationsPane(model: model))
    }

    var storedFolders: [String] { defaults.stringArray(forKey: LocationsModel.Key.excluded) ?? [] }
    var storedIndexed: [String] { defaults.stringArray(forKey: LocationsModel.Key.indexedVolumes) ?? [] }

    func click(_ title: String) async throws {
        try await host.click(title)
        await model.change?.value
    }
}

private func secondLine(_ rig: LocationsRig, row: Int, path: String) -> [String]? {
    let table = descendants(of: rig.host.view).compactMap { $0 as? NSTableView }.first { $0.numberOfRows == rig.model.rows.count }
    let line = table?.view(atColumn: 0, row: row, makeIfNecessary: true).flatMap { cell in
        ([cell] + descendants(of: cell)).compactMap { AXTree.element("locations-path-\(path)", in: $0) }.first
    }
    return line.map { AXTree.names(of: $0) }
}

@Suite(.serialized) struct LocationsPaneTests {
    private var defaultPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/CloudStorage", "\(home)/Library/Biome", "\(home)/Library/Caches",
            "\(home)/Library/Logs", "\(home)/Library/Metadata", "/Library/Caches",
            "/System/Library/Caches", "/private/var", "/private/tmp"
        ]
    }

    @Test func theDefaultListFitsItsRowsAndKeepsControlsAboveTheFooter() async throws {
        let rig = LocationsRig("layout.defaults", folders: nil)
        defer { rig.host.close() }
        rig.host.window.setContentSize(NSSize(width: SettingsWindow.Metrics.detailWidth, height: 900))
        try await rig.host.until("eleven full rows and the footer") {
            descendants(of: rig.host.view).compactMap { $0 as? NSTableView }.contains { $0.numberOfRows == 11 } &&
                AXTree.element("locations-footer", in: rig.host.view) != nil
        }
        let table = try #require(descendants(of: rig.host.view).compactMap { $0 as? NSTableView }.first { $0.numberOfRows == 11 })
        let scroll = try #require(table.enclosingScrollView)
        let rows = table.rect(ofRow: 0).union(table.rect(ofRow: 10))
        #expect(scroll.contentView.bounds.height >= rows.height, "the inner list must fit all eleven rows")
        let box = try #require(AXTree.element("locations-list", in: rig.host.view).flatMap(AXTree.frame))
        let footer = try #require(AXTree.element("locations-footer", in: rig.host.view).flatMap(AXTree.frame))
        let plus = try #require(rig.host.control("Add excluded path").flatMap(AXTree.frame))
        let minus = try #require(rig.host.control("Remove excluded path").flatMap(AXTree.frame))
        let bottomRow = rig.host.window.convertToScreen(table.convert(table.rect(ofRow: 10), to: nil))
        #expect(plus.midY == minus.midY)
        #expect(plus.maxX <= minus.minX)
        #expect(plus.maxY <= bottomRow.minY && minus.maxY <= bottomRow.minY)
        #expect(box.contains(plus) && box.contains(minus))
        #expect(footer.maxY < box.minY, "the explanations belong below the grouped box")
        #expect(!box.intersects(footer))
        rig.host.window.setContentSize(NSSize(width: SettingsWindow.Metrics.detailWidth, height: SettingsWindow.Metrics.minSize.height))
        try await rig.host.until("the outer form to scroll at the minimum window height") {
            guard let outer = scroll.enclosingScrollView, let document = outer.documentView else { return false }
            return document.frame.height > outer.contentView.bounds.height
        }
        #expect(scroll.contentView.bounds.height >= rows.height)
    }

    @Test func theNewDiskPopUpSitsAboveTheExcludedPaths() async throws {
        let rig = LocationsRig("layout.newdisk", folders: nil)
        defer { rig.host.close() }
        rig.host.window.setContentSize(NSSize(width: SettingsWindow.Metrics.detailWidth, height: 900))
        let frame = { (id: String) in AXTree.element(id, in: rig.host.view).flatMap(AXTree.frame) }
        try await rig.host.until("the pop-up and the list") { frame(LocationsPane.newDiskID) != nil && frame("locations-list") != nil }
        let popUp = try #require(frame(LocationsPane.newDiskID))
        let list = try #require(frame("locations-list"))
        #expect(popUp.minY > list.maxY, "pop-up \(popUp), list \(list)")
    }

    @Test func selectingAVisibleRowThenRemovingItKeepsTheNextSelectionWorking() async throws {
        let rig = LocationsRig("layout.selection", folders: ["/Users/test/A"], disks: [archive])
        defer { rig.host.close() }
        try await rig.host.until("the disk and folder table") {
            descendants(of: rig.host.view).compactMap { $0 as? NSTableView }.contains { $0.numberOfRows == 2 }
        }
        let table = try #require(descendants(of: rig.host.view).compactMap { $0 as? NSTableView }.first { $0.numberOfRows == 2 })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await rig.host.until("the disk selection from the table") { rig.model.selection == .disk("A") }
        try await rig.click("Remove excluded path")
        #expect(rig.storedIndexed == ["A"] && rig.model.selection == nil)
        try await rig.host.until("only the folder row") { table.numberOfRows == 1 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await rig.host.until("the folder selection from the table") { rig.model.selection == .folder("/Users/test/A") }
        try await rig.click("Remove excluded path")
        #expect(rig.storedFolders.isEmpty && rig.model.selection == nil)
        rig.panel.next = "/Users/test/Next"
        try await rig.click("Add excluded path")
        #expect(rig.storedFolders == ["/Users/test/Next"])
    }

    @Test func aFreshStoreShowsTheNineDefaultPaths() async throws {
        let rig = LocationsRig("defaults", folders: nil)
        defer { rig.host.close() }
        #expect(LocationsModel.stored(rig.defaults).excluded == defaultPaths)
        #expect(rig.model.excluded == defaultPaths)
        #expect(rig.model.excluded.allSatisfy { $0.hasPrefix("/") && !$0.hasPrefix("~") })
        try await rig.host.until("two ignored disks followed by nine paths") {
            rig.model.rows == [.disk("A"), .disk("B")] + defaultPaths.map { .folder($0) }
        }
        try await rig.host.until("eleven list rows") {
            descendants(of: rig.host.view).compactMap { $0 as? NSTableView }.contains { $0.numberOfRows == 11 }
        }
        #expect(rig.defaults.object(forKey: LocationsModel.Key.excluded) == nil)
    }

    @Test func theLaunchSendsTheDefaultPaths() throws {
        let defaults = freshDefaults("locations.defaults.launch")
        let stored = LocationsModel.stored(defaults)
        let client = FakeSearchClient()
        try client.setExcludedFolders(stored.excluded)
        #expect(client.excluded == [defaultPaths])
        #expect(stored.indexedVolumes.isEmpty)
    }

    @Test func aRemovedDefaultStaysRemoved() async throws {
        let rig = LocationsRig("defaults.remove", folders: nil)
        defer { rig.host.close() }
        #expect(rig.model.excluded == defaultPaths)
        rig.model.selection = .folder("/private/tmp")
        try await rig.host.until("Remove enabled") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == true }
        try await rig.click("Remove excluded path")
        let remaining = Array(defaultPaths.dropLast())
        #expect(rig.fake.excluded == [remaining])
        #expect(rig.storedFolders == remaining)
        #expect(LocationsModel.stored(rig.defaults).excluded == remaining)
        let reopened = LocationsModel(client: rig.fake, defaults: rig.defaults)
        #expect(reopened.excluded == remaining)
        #expect(rig.model.selection == nil)
    }

    @Test func anEmptiedListStaysEmpty() async throws {
        let rig = LocationsRig("defaults.empty", folders: nil)
        defer { rig.host.close() }
        #expect(rig.model.excluded == defaultPaths)
        for path in defaultPaths {
            rig.model.selection = .folder(path)
            try await rig.host.until("Remove enabled") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == true }
            try await rig.click("Remove excluded path")
        }
        #expect(rig.fake.excluded.count == 9)
        #expect(rig.fake.excluded.last == [])
        #expect(rig.defaults.stringArray(forKey: LocationsModel.Key.excluded) == [])
        #expect(LocationsModel.stored(rig.defaults).excluded.isEmpty)
        let reopened = LocationsModel(client: rig.fake, defaults: rig.defaults)
        #expect(reopened.excluded.isEmpty)
    }

    @Test func anAddedFolderFollowsTheDefaults() async throws {
        let rig = LocationsRig("defaults.add", folders: nil)
        defer { rig.host.close() }
        rig.panel.next = "/Users/test/More"
        try await rig.click("Add excluded path")
        let expected = defaultPaths + ["/Users/test/More"]
        #expect(rig.fake.excluded == [expected])
        #expect(rig.storedFolders == expected)
        #expect(rig.model.excluded == expected)
        #expect(LocationsModel.stored(rig.defaults).excluded == expected)
    }

    @Test func theFirstIconStartsUnderTheExcludedPathsHeader() async throws {
        let rig = LocationsRig("inset", folders: nil)
        defer { rig.host.close() }
        let header = {
            AXTree.elements(in: rig.host.view).filter {
                (AXTree.value("accessibilityRole", of: $0) as String?) == "AXHeading" && AXTree.names(of: $0).contains("Excluded Paths")
            }.compactMap(AXTree.frame(of:)).first
        }
        let icon = { () -> NSRect? in
            guard let table = descendants(of: rig.host.view).compactMap({ $0 as? NSTableView }).first(where: { $0.numberOfRows > 0 }),
                  let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) else { return nil }
            return ([cell] + descendants(of: cell)).flatMap { AXTree.elements(in: $0) }
                .first { AXTree.identifier(of: $0)?.hasPrefix("locations-icon-") == true }.flatMap(AXTree.frame(of:))
        }
        try await rig.host.until("the Excluded Paths header and the first icon") { header() != nil && icon() != nil }
        let heading = try #require(header()), first = try #require(icon())
        #expect((first.minX - heading.minX) * rig.host.window.backingScaleFactor == 0, "the first icon \(first), the header \(heading)")
    }

    @Test func theListIsCalledExcludedPaths() async throws {
        let rig = LocationsRig("defaults.labels", folders: nil)
        defer { rig.host.close() }
        try await rig.host.until("the Excluded Paths heading") { rig.host.shows("Excluded Paths") }
        try await rig.host.until("the named list and buttons") {
            AXTree.elements(in: rig.host.view).flatMap { AXTree.names(of: $0) }.contains("Excluded Paths") &&
                rig.host.control("Add excluded path") != nil && rig.host.control("Remove excluded path") != nil
        }
        #expect(rig.host.shows("Wherever skips these paths and everything inside them. Search Content still reads one, or a folder inside it, when you choose it as the Search folder."))
    }

    @Test func missingLocationsKeepTheirDiskOrFolderIconAndExistingPathsKeepTheirOwn() throws {
        func pixels(_ image: NSImage) throws -> Data {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32))
            let buffer = try #require(bitmap.bitmapData)
            buffer.update(repeating: 0, count: 4096)
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
            return Data(bytes: buffer, count: 4096)
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("wherever-location-icon-\(UUID().uuidString)").path
        #expect(!FileManager.default.fileExists(atPath: missing))
        let workspace = NSWorkspace.shared
        let blank = try pixels(workspace.icon(forFile: missing))
        for type in [UTType.volume, .folder] {
            let expected = try pixels(workspace.icon(for: type))
            #expect(expected != blank)
            #expect(try pixels(LocationsPane.icon(for: missing, type: type)) == expected)
            for path in ["/", FileManager.default.homeDirectoryForCurrentUser.path] {
                #expect(FileManager.default.fileExists(atPath: path))
                #expect(try pixels(LocationsPane.icon(for: path, type: type)) == pixels(workspace.icon(forFile: path)))
            }
        }
    }

    @Test func aMissingPathIsSentAndShown() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wherever-excludedpaths-\(UUID().uuidString)").path
        #expect(!FileManager.default.fileExists(atPath: path))
        let rig = LocationsRig("defaults.missing", folders: defaultPaths + [path], disks: [])
        defer { rig.host.close() }
        let stored = LocationsModel.stored(rig.defaults)
        try rig.fake.setExcludedFolders(stored.excluded)
        #expect(rig.fake.excluded == [defaultPaths + [path]])
        #expect(rig.model.rows == (defaultPaths + [path]).map { .folder($0) })
        try await rig.host.until("ten paths in the pane") {
            descendants(of: rig.host.view).compactMap { $0 as? NSTableView }.contains { $0.numberOfRows == 10 }
        }
    }

    @Test func anIgnoredDiskIsARowAndMinusIndexesIt() async throws {
        let rig = LocationsRig("row", folders: ["/Users/test/Old"], indexed: ["A"])
        defer { rig.host.close() }
        try await rig.host.until("the Backup row") { rig.model.rows == [.disk("B"), .folder("/Users/test/Old")] }
        #expect(rig.host.shows("Other disks start in this list. Remove a disk to index it."))
        #expect(rig.host.control("Archive") == nil)
        #expect(rig.host.control("Backup") == nil)
        #expect(!rig.host.shows("The startup disk is always searched."))
        #expect(!rig.host.shows("No other disks are connected."))
        rig.model.selection = .disk("B")
        try await rig.host.until("Remove enabled") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == true }
        try await rig.click("Remove excluded path")
        #expect(rig.fake.switchedOn.last == ["A", "B"])
        #expect(rig.storedIndexed == ["A", "B"])
        #expect(rig.fake.excluded.isEmpty)
        #expect(rig.model.rows == [.folder("/Users/test/Old")])
        #expect(rig.model.selection == nil)
    }

    @Test func aDiskWithoutAVolumeIDShowsTheCantBeIndexedRow() async throws {
        let card = IndexedVolume(id: "/Volumes/CARD", name: "CARD", path: "/Volumes/CARD", indexed: false, indexable: false)
        let rig = LocationsRig("nouuid", folders: ["/Users/test/Old"], indexed: ["A", "B"], disks: [archive, card, backup])
        defer { rig.host.close() }
        try await rig.host.until("the card row") { rig.model.rows == [.disk(card.id), .folder("/Users/test/Old")] }
        try await rig.host.until("the card's note in its path's line") {
            let table = descendants(of: rig.host.view).compactMap { $0 as? NSTableView }.first { $0.numberOfRows == 2 }
            let note = table?.view(atColumn: 0, row: 0, makeIfNecessary: true).flatMap { cell in
                ([cell] + descendants(of: cell)).compactMap { AXTree.element("locations-path-\(card.path)", in: $0) }.first
            }
            return note.map { AXTree.names(of: $0).contains("Can’t be indexed: this disk has no UUID") } == true
        }
        rig.model.selection = .folder("/Users/test/Old")
        try await rig.host.until("Remove enabled on the folder") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == true }
        rig.model.selection = .disk(card.id)
        try await rig.host.until("Remove disabled on the card") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == false }
        rig.model.removeSelected()
        await rig.model.change?.value
        #expect(rig.fake.switchedOn.isEmpty)
        #expect(rig.storedIndexed == ["A", "B"])
        #expect(rig.model.rows == [.disk(card.id), .folder("/Users/test/Old")])
        #expect(rig.model.selection == .disk(card.id))
    }

    @Test func plusOnADiskRootIgnoresTheDisk() async throws {
        let rig = LocationsRig("ignore", indexed: ["A", "B"])
        defer { rig.host.close() }
        try await rig.host.until("the disks") { !rig.model.volumes.isEmpty }
        #expect(rig.model.rows.isEmpty)
        rig.panel.next = "/Volumes/Archive"
        try await rig.click("Add excluded path")
        #expect(rig.fake.switchedOn.last == ["B"])
        #expect(rig.storedIndexed == ["B"])
        #expect(rig.model.rows == [.disk("A")])
        #expect(rig.fake.excluded.isEmpty)
        rig.panel.next = "/Volumes/Backup/Photos"
        try await rig.click("Add excluded path")
        #expect(rig.fake.excluded == [["/Volumes/Backup/Photos"]])
        #expect(rig.model.rows == [.disk("A"), .folder("/Volumes/Backup/Photos")])
        #expect(rig.fake.switchedOn.count == 1)
        #expect(rig.storedIndexed == ["B"])
    }

    @Test func plusOnADiskRootWithASlashIgnoresTheDiskAndMinusIndexesItAgain() async throws {
        let rig = LocationsRig("ignore.slash", indexed: ["A", "B"])
        defer { rig.host.close() }
        try await rig.host.until("the disks") { !rig.model.volumes.isEmpty }
        rig.panel.next = "/Volumes/Archive/"
        try await rig.click("Add excluded path")
        #expect(rig.fake.switchedOn.last == ["B"])
        #expect(rig.model.rows == [.disk("A")])
        #expect(rig.fake.excluded.isEmpty)
        try await rig.click("Add excluded path")
        #expect(rig.fake.switchedOn.count == 1)
        #expect(rig.fake.excluded.isEmpty)
        rig.model.selection = .disk("A")
        try await rig.host.until("Remove enabled") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == true }
        try await rig.click("Remove excluded path")
        #expect(rig.fake.switchedOn.last == ["A", "B"])
        #expect(rig.model.rows.isEmpty)
    }

    @Test func aFolderPickedWithATrailingSlashIsStoredWithoutItOnce() async throws {
        let rig = LocationsRig("slash.folder")
        defer { rig.host.close() }
        rig.panel.next = "/Users/test/Big/"
        try await rig.click("Add excluded path")
        #expect(rig.fake.excluded == [["/Users/test/Big"]])
        #expect(rig.storedFolders == ["/Users/test/Big"])
        #expect(rig.model.excluded == ["/Users/test/Big"])
        rig.panel.next = "/Users/test/Big"
        try await rig.click("Add excluded path")
        #expect(rig.fake.excluded.count == 1)
        rig.panel.next = "/private/tmp/x/"
        try await rig.click("Add excluded path")
        #expect(rig.storedFolders == ["/Users/test/Big", "/private/tmp/x"])
        rig.panel.next = "/Users/test/My Files/"
        try await rig.click("Add excluded path")
        #expect(rig.storedFolders.last == "/Users/test/My Files")
    }

    @Test func theRootAndDoubleSlashKeepOneSlash() async throws {
        let rig = LocationsRig("slash.root")
        defer { rig.host.close() }
        rig.panel.next = "/"
        try await rig.click("Add excluded path")
        try await rig.host.clickSheet("Exclude")
        await rig.model.change?.value
        try await rig.host.until("the alert to close") { rig.host.sheet == nil }
        #expect(rig.storedFolders == ["/"])
        rig.panel.next = "//"
        try await rig.click("Add excluded path")
        #expect(rig.storedFolders == ["/"])
        rig.panel.next = nil
        try await rig.click("Add excluded path")
        #expect(rig.storedFolders == ["/"])
    }

    @Test func aRowAboveTwoSwitchedOnDisksAsksOnceNamingBothThenExcludeAddsIt() async throws {
        let rig = LocationsRig("nest.confirm", indexed: ["A", "B"])
        defer { rig.host.close() }
        try await rig.host.until("the disks") { !rig.model.volumes.isEmpty }
        rig.panel.next = "/Volumes"
        try await rig.click("Add excluded path")
        try await rig.host.until("the alert") { rig.host.sheet != nil }
        #expect(rig.model.pending == LocationsModel.PendingRow(path: "/Volumes", disks: ["Archive", "Backup"]))
        let words = try texts(in: #require(rig.host.sheet?.contentView))
        #expect(words.contains("Exclude “\u{2066}/Volumes\u{2069}”?"))
        #expect(words.contains { $0.contains("Archive") && $0.contains("Backup") })
        #expect(rig.fake.excluded.isEmpty)
        #expect(rig.storedFolders.isEmpty)
        try await rig.host.clickSheet("Exclude")
        await rig.model.change?.value
        try await rig.host.until("the alert to close") { rig.host.sheet == nil }
        #expect(rig.fake.excluded == [["/Volumes"]])
        #expect(rig.storedFolders == ["/Volumes"])
        #expect(rig.fake.switchedOn.isEmpty)
        #expect(rig.storedIndexed == ["A", "B"])
        #expect(rig.model.rows == [.folder("/Volumes")])
        rig.model.selection = .folder("/Volumes")
        try await rig.host.until("Remove enabled") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == true }
        try await rig.click("Remove excluded path")
        #expect(rig.fake.excluded.last == [])
        #expect(rig.storedFolders.isEmpty)
        #expect(rig.fake.switchedOn.isEmpty)
        #expect(rig.storedIndexed == ["A", "B"])
    }

    @Test func cancelOnTheAlertAddsNothingAndChangesNothing() async throws {
        let rig = LocationsRig("nest.cancel", folders: ["/Users/test/Old"], indexed: ["A"])
        defer { rig.host.close() }
        try await rig.host.until("the disks") { !rig.model.volumes.isEmpty }
        rig.panel.next = "/Volumes/"
        try await rig.click("Add excluded path")
        try await rig.host.until("the alert") { rig.host.sheet != nil }
        #expect(rig.model.pending?.disks == ["Archive"])
        try await rig.host.clickSheet("Cancel")
        try await rig.host.until("the alert to close") { rig.host.sheet == nil }
        #expect(rig.model.pending == nil)
        #expect(rig.fake.excluded.isEmpty)
        #expect(rig.fake.switchedOn.isEmpty)
        #expect(rig.storedFolders == ["/Users/test/Old"])
        #expect(rig.storedIndexed == ["A"])
        #expect(rig.model.rows == [.disk("B"), .folder("/Users/test/Old")])
    }

    @Test func aFolderAboveNoSwitchedOnDiskAsksNothing() async throws {
        let rig = LocationsRig("nest.none", indexed: ["A"])
        defer { rig.host.close() }
        try await rig.host.until("the disks") { !rig.model.volumes.isEmpty }
        for path in ["/Users/test", "/Volumes/Archive/Photos", "/Volumes/Backup/Old", "/Volumes/Arch"] {
            rig.panel.next = path
            try await rig.click("Add excluded path")
            #expect(rig.host.sheet == nil, "\(path)")
            #expect(rig.model.pending == nil, "\(path)")
            #expect(rig.fake.excluded.last?.last == path)
        }
        #expect(rig.fake.excluded.count == 4)
    }

    @Test func anIgnoredDiskUnderAnExcludedFolderNamesTheRowAndMinusLeavesItBe() async throws {
        let rig = LocationsRig("nest.next", folders: ["/Volumes"], indexed: ["A"])
        defer { rig.host.close() }
        try await rig.host.until("the Backup row") { rig.model.rows == [.disk("B"), .folder("/Volumes")] }
        try await rig.host.until("the row's note") {
            secondLine(rig, row: 0, path: "/Volumes/Backup")?.contains("Remove “\u{2066}/Volumes\u{2069}” to index this disk") == true
        }
        rig.model.selection = .folder("/Volumes")
        try await rig.host.until("Remove enabled on the folder") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == true }
        rig.model.selection = .disk("B")
        try await rig.host.until("Remove disabled on the disk") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == false }
        rig.model.removeSelected()
        await rig.model.change?.value
        #expect(rig.fake.switchedOn.isEmpty)
        #expect(rig.storedIndexed == ["A"])
        #expect(rig.model.selection == .disk("B"))
    }

    @Test func theRootNamesTheStartupDisk() async throws {
        let rig = LocationsRig("nest.root", indexed: ["B"])
        defer { rig.host.close() }
        try await rig.host.until("the disks") { !rig.model.volumes.isEmpty }
        rig.panel.next = "/"
        try await rig.click("Add excluded path")
        try await rig.host.until("the alert") { rig.host.sheet != nil }
        #expect(rig.model.pending?.disks == [FileManager.default.displayName(atPath: "/"), "Backup"])
        try await rig.host.clickSheet("Cancel")
        try await rig.host.until("the alert to close") { rig.host.sheet == nil }
        #expect(rig.storedFolders.isEmpty)
    }

    @Test func aDiskIndexedFromNormalSurvivesASettingsChange() async throws {
        let rig = LocationsRig("fresh", indexed: ["A"])
        defer { rig.host.close() }
        try await rig.host.until("the Backup row") { rig.model.rows == [.disk("B")] }
        try LocationsModel.setIndexed("B", true, client: rig.fake, defaults: rig.defaults)
        try await rig.host.until("Backup's row to leave") { rig.model.rows.isEmpty }
        rig.panel.next = "/Volumes/Archive"
        try await rig.click("Add excluded path")
        #expect(rig.fake.switchedOn.last == ["B"])
        #expect(rig.storedIndexed == ["B"])
    }

    @Test func plusWithAFolderFromThePanelSendsTheFullListAndStoresItAndTheSameFolderAgainAddsNothing() async throws {
        let rig = LocationsRig("add", folders: ["/Users/test/Old"])
        defer { rig.host.close() }
        rig.panel.next = "/Users/test/Big"
        try await rig.click("Add excluded path")
        #expect(rig.panel.shown == 1)
        #expect(rig.fake.excluded == [["/Users/test/Old", "/Users/test/Big"]])
        #expect(rig.storedFolders == ["/Users/test/Old", "/Users/test/Big"])
        try await rig.click("Add excluded path")
        #expect(rig.panel.shown == 2)
        #expect(rig.fake.excluded.count == 1)
        rig.panel.next = nil
        try await rig.click("Add excluded path")
        #expect(rig.fake.excluded.count == 1)
        #expect(rig.storedFolders.count == 2)
    }

    @Test func minusRemovesTheSelectedFolderSendsTheRestAndStoresIt() async throws {
        let rig = LocationsRig("remove", folders: ["/Users/test/A", "/Users/test/B"])
        defer { rig.host.close() }
        try await rig.host.until("the Remove button") { rig.host.control("Remove excluded path") != nil }
        #expect(rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == false)
        rig.model.selection = .folder("/Users/test/A")
        try await rig.host.until("Remove enabled") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == true }
        try await rig.click("Remove excluded path")
        #expect(rig.fake.excluded == [["/Users/test/B"]])
        #expect(rig.storedFolders == ["/Users/test/B"])
        #expect(rig.model.selection == nil)
        try await rig.host.until("Remove disabled again") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == false }
    }

    @Test func anExcludedListThatTheEngineRefusesStaysAsStoredAndShowsOneLine() async throws {
        let rig = LocationsRig("refused", folders: ["/Users/test/A"], failing: true)
        defer { rig.host.close() }
        rig.panel.next = "/Users/test/B"
        #expect(!rig.host.shows("Wherever could not change the locations."))
        try await rig.click("Add excluded path")
        try await rig.host.until("the failure line") { rig.host.shows("Wherever could not change the locations.") }
        #expect(rig.storedFolders == ["/Users/test/A"])
        #expect(rig.model.excluded == ["/Users/test/A"])
    }

    @Test func aDiskChangeTheEngineRefusesKeepsTheRowTheStoredSetAndShowsOneLine() async throws {
        let rig = LocationsRig("row.refused", failing: true)
        defer { rig.host.close() }
        try await rig.host.until("both rows") { rig.model.rows == [.disk("A"), .disk("B")] }
        rig.model.selection = .disk("A")
        try await rig.host.until("Remove enabled") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == true }
        try await rig.click("Remove excluded path")
        try await rig.host.until("the failure line") { rig.host.shows("Wherever could not change the locations. Try again.") }
        #expect(rig.storedIndexed.isEmpty)
        #expect(rig.model.indexed.isEmpty)
        #expect(rig.model.rows == [.disk("A"), .disk("B")])
    }

    @Test func aDiskThatLeavesDropsItsRowAndKeepsItsStoredChoice() async throws {
        let rig = LocationsRig("gone")
        defer { rig.host.close() }
        try await rig.host.until("both rows") { rig.model.rows == [.disk("A"), .disk("B")] }
        rig.model.selection = .disk("B")
        rig.fake.setVolumes(.success([archive]))
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await rig.host.until("Backup to leave") { rig.model.rows == [.disk("A")] }
        #expect(rig.model.selection == nil)
        #expect(rig.storedIndexed.isEmpty)
    }

    @Test func anOpenPaneShowsADiskThatArrivesAndDropsItWhenItLeaves() async throws {
        let rig = LocationsRig("follow", disks: [])
        defer { rig.host.close() }
        let index = IndexModel(client: rig.fake, defaults: rig.defaults)
        rig.model.follow(index.$volumes)
        try await rig.host.until("an empty list") { rig.model.rows.isEmpty && !rig.host.shows("Backup") }
        rig.fake.setVolumes(.success([backup]))
        rig.fake.send(.volumesChanged)
        try await rig.host.until("Backup's row") { rig.model.rows == [.disk("B")] && rig.host.shows("Backup") }
        rig.model.selection = .disk("B")
        rig.fake.setVolumes(.success([IndexedVolume(id: "B", name: "Spare", path: "/Volumes/Spare", indexed: true)]))
        rig.fake.send(.volumesChanged)
        try await rig.host.until("the new name") { rig.host.shows("Spare") && !rig.host.shows("Backup") }
        #expect(rig.model.rows == [.disk("B")])
        #expect(rig.model.selection == .disk("B"))
        rig.fake.setVolumes(.success([]))
        rig.fake.send(.volumesChanged)
        try await rig.host.until("the row to leave") { rig.model.rows.isEmpty && !rig.host.shows("Spare") }
        #expect(rig.model.selection == nil)
        #expect(!rig.model.canRemoveSelection)
        #expect(rig.storedIndexed.isEmpty)
        withExtendedLifetime(index) {}
    }

    @Test func withNoOtherDisksTheListHoldsOnlyFoldersAndTheNoteStays() async throws {
        let rig = LocationsRig("nodisks", folders: ["/Users/test/Old"], disks: [])
        defer { rig.host.close() }
        try await rig.host.until("the note") { rig.host.shows("Other disks start in this list. Remove a disk to index it.") }
        #expect(rig.model.rows == [.folder("/Users/test/Old")])
        #expect(!rig.host.shows("No other disks are connected."))
    }

    @Test func theStoredReaderReturnsWhatAPaneStoredAndDefaultsForAFreshSuite() async throws {
        let rig = LocationsRig("reader", folders: ["/Users/test/A", "/Users/test/B"], indexed: ["A"])
        defer { rig.host.close() }
        let stored = LocationsModel.stored(rig.defaults)
        #expect(stored.excluded == ["/Users/test/A", "/Users/test/B"])
        #expect(stored.indexedVolumes == ["A"])
        let empty = LocationsModel.stored(freshDefaults("locations.reader.empty"))
        #expect(empty.excluded == defaultPaths)
        #expect(empty.indexedVolumes.isEmpty)
    }

    @Test func aPaneChangeIsWhatTheReaderReturnsAtTheNextLaunch() async throws {
        let rig = LocationsRig("launch")
        defer { rig.host.close() }
        rig.panel.next = "/Users/test/Big"
        try await rig.click("Add excluded path")
        try await rig.host.until("the Backup row") { rig.model.rows.contains(.disk("B")) }
        rig.model.selection = .disk("B")
        try await rig.host.until("Remove to take the selection \(String(describing: rig.model.selection))") {
            rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == true
        }
        try await rig.click("Remove excluded path")
        let stored = LocationsModel.stored(rig.defaults)
        #expect(stored.excluded == ["/Users/test/Big"])
        #expect(stored.indexedVolumes == ["B"])
    }

    @Test func aFolderOnADiskIsStoredByVolumeID() async throws {
        let media = IndexedVolume(id: "5F2A6C3E-0B1D-4C7A-9E58-2D4B7A91C0E3", name: "Media", path: "/Volumes/Media", indexed: true)
        let second = IndexedVolume(id: "0B0B0B0B-0000-4000-8000-00000000000B", name: "Media 1", path: "/Volumes/Media 1", indexed: true)
        let old = "/Volumes/Media/Footage/Proxies"
        let rig = LocationsRig("diskrow", folders: [old], indexed: [media.id, second.id], disks: [media, second])
        defer { rig.host.close() }
        try await rig.host.until("the disks") { rig.model.volumes.count == 2 }
        rig.panel.next = "/Volumes/Media 1/Cache/"
        try await rig.click("Add excluded path")
        rig.panel.next = old
        try await rig.click("Add excluded path")
        let rows = ["\(second.id)/Cache", "\(media.id)/Footage/Proxies"]
        #expect(rig.fake.excluded == [[old, rows[0]], rows])
        #expect(rig.storedFolders == rows)
        #expect(LocationsModel.stored(rig.defaults).excluded == rows)
        let renamed = "/Volumes/Archive/Footage/Proxies"
        rig.fake.setVolumes(.success([IndexedVolume(id: media.id, name: "Archive", path: "/Volumes/Archive", indexed: true), second]))
        await rig.model.refresh().value
        try await rig.host.until("the row at the disk's new path") { secondLine(rig, row: 1, path: renamed)?.contains(renamed) == true }
        rig.model.selection = .folder(rows[1])
        rig.model.removeSelected()
        await rig.model.change?.value
        #expect(rig.fake.excluded.last == [rows[0]])
        #expect(rig.storedFolders == [rows[0]])
    }

    @Test func aRowOnAnUnmountedDiskShowsItsLine() async throws {
        let away = "0D0D0D0D-0000-4000-8000-00000000000D/Photos/Raw"
        let rig = LocationsRig("unmounted", folders: [away, "Library/Caches", "/Users/test/Old"], indexed: ["A", "B"])
        defer { rig.host.close() }
        try await rig.host.until("the disks") { rig.model.volumes.count == 2 }
        #expect(rig.model.rows == [.folder(away), .folder("Library/Caches"), .folder("/Users/test/Old")])
        #expect(LocationsModel.stored(rig.defaults).excluded == [away, "/Users/test/Old"])
        let id = "0D0D0D0D-0000-4000-8000-00000000000D"
        for refused in ["\(id.lowercased())/Photos", "\(id)/", "\(id)//Photos", "\(id)/Photos/../x", "\(id)/a\u{0600}/../b", "Photos/\(id)"] {
            #expect(!LocationsModel.accepts(refused), "\(refused)")
        }
        #expect(LocationsModel.accepts("\(id)/Photos/Raw 2"))
        try await rig.host.until("the unmounted disk's line") { secondLine(rig, row: 0, path: away)?.contains("The disk isn’t connected") == true }
        try await rig.host.until("the refused row's line") { secondLine(rig, row: 1, path: "Library/Caches")?.contains("This path isn’t valid") == true }
        rig.model.selection = .folder("Library/Caches")
        try await rig.host.until("Remove enabled") { rig.host.control("Remove excluded path").flatMap(AXTree.isEnabled) == true }
        try await rig.click("Remove excluded path")
        #expect(rig.fake.excluded == [[away, "/Users/test/Old"]])
        #expect(rig.storedFolders == [away, "/Users/test/Old"])
    }

    @Test func theLocationsPaneHoldsTheListAndBothButtons() async throws {
        let rig = SettingsRig(name: "window.locations")
        defer { rig.window.close() }
        rig.window.show()
        rig.selection.pane = .locations
        let pane = rig.detailView
        try await rig.until("the Locations rows") {
            AXTree.control("Add excluded path", in: pane) != nil && AXTree.control("Remove excluded path", in: pane) != nil
        }
    }

    @Test func theRowsFollowTheTextSize() async throws {
        #expect(LocationsPane.Metrics.rowHeight(.standard) == 44 && LocationsPane.Metrics.rowHeight(.maximum) == 54)
        #expect(LocationsPane.Metrics.nameFont(.maximum).pointSize == 18 && LocationsPane.Metrics.pathFont(.maximum).pointSize == 15)
        #expect(LocationsPane.Metrics.nameFont(.standard).pointSize == NSFont.systemFontSize)
        var heights: [CGFloat] = []
        for size in [TextSize.standard, .maximum] {
            let store = freshDefaults("locations.textsize.\(size.rawValue)")
            store.set(size.rawValue, forKey: TextSize.key)
            store.set(["/Users/test/A"], forKey: LocationsModel.Key.excluded)
            store.set([String](), forKey: LocationsModel.Key.indexedVolumes)
            let fake = FakeSearchClient()
            fake.setVolumes(.success([archive]))
            let panel = PanelSpy()
            let model = LocationsModel(client: fake, defaults: store, chooseFolder: { panel.choose() })
            let host = PaneHost(LocationsPane(model: model).defaultAppStorage(store))
            defer { host.close() }
            let table = { descendants(of: host.view).compactMap { $0 as? NSTableView }.first { $0.numberOfRows == 2 } }
            try await host.until("the disk and folder rows at \(size.rawValue) pt") { table() != nil }
            heights.append(try #require(table()).rect(ofRow: 0).height)
        }
        #expect(heights[1] - heights[0] == LocationsPane.Metrics.rowHeight(.maximum) - LocationsPane.Metrics.rowHeight(.standard), "\(heights)")
    }
}
