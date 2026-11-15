import AppKit
import Carbon
import SwiftUI
import Testing
@testable import Wherever

private enum ClickPath: CaseIterable {
    case app, window
}

private final class Presses: NSObject {
    var count = 0

    @objc func press(_ sender: Any?) { count += 1 }
}

private final class KeyLog: NSView {
    private(set) var typed: [String] = []

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { typed.append(event.characters ?? "") }
}

private final class Back {
    let window = KeyedWindow(
        contentRect: NSRect(x: 120, y: 120, width: 420, height: 260), styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false
    )
    let button = NSButton(frame: NSRect(x: 20, y: 20, width: 160, height: 32))
    let keys = KeyLog(frame: NSRect(x: 220, y: 20, width: 160, height: 160))
    private let presses = Presses()

    var pressCount: Int { presses.count }
    var buttonPoint: NSPoint { button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil) }
    var hit: NSView? { window.contentView?.superview?.hitTest(buttonPoint) }
    var hitsButton: Bool { hit?.isDescendant(of: button) == true }

    init(_ identifier: String) {
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        button.title = "Search"
        button.target = presses
        button.action = #selector(Presses.press(_:))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        content.addSubview(button)
        content.addSubview(keys)
        window.contentView = content
    }
}

private final class SpyDialog: NSWindow {
    var reportsKey = false
    var reportsMiniaturized = false
    private(set) var fronted = 0
    private(set) var deminiaturized = 0
    private(set) var typed: [String] = []

    convenience init(_ identifier: String) {
        self.init(
            contentRect: NSRect(x: 220, y: 220, width: 300, height: 200), styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        isReleasedWhenClosed = false
    }

    override var isKeyWindow: Bool { reportsKey || super.isKeyWindow }
    @objc(_isKeyWindow) func reportsKeyToAppKit() -> Bool { isKeyWindow }
    override var isMiniaturized: Bool { reportsMiniaturized || super.isMiniaturized }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        fronted += 1
        super.makeKeyAndOrderFront(sender)
    }

    override func deminiaturize(_ sender: Any?) {
        deminiaturized += 1
        reportsMiniaturized = false
    }

    override func keyDown(with event: NSEvent) {
        typed.append(event.characters ?? "")
        if event.keyCode == UInt16(kVK_Escape) { performClose(nil) }
    }
}

private final class FloatingPanel: NSPanel {
    var reportsKey = false

    convenience init() {
        self.init(
            contentRect: NSRect(x: 260, y: 260, width: 300, height: 60), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        title = "Wherever"
        level = .floating
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { reportsKey || super.isKeyWindow }
    @objc(_isKeyWindow) func reportsKeyToAppKit() -> Bool { isKeyWindow }
}

private final class DragStub: NSObject, NSDraggingInfo {
    var numberOfValidItemsForDrop = 0
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { NSPasteboard(name: .drag) }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

private final class Rig {
    static let storeName = "com.writronic.wherever.tests.dialogs"

    var windows: [NSWindow] = []
    var active = false
    private(set) var beeps = 0
    let store: UserDefaults
    private var spies: [NSWindow] = []
    lazy var dialogs = ModalWindowCoordinator(
        windows: { [weak self] in self?.windows ?? [] }, isActive: { [weak self] in self?.active ?? false }, beep: { [weak self] in self?.beeps += 1 }
    )

    init() {
        store = UserDefaults(suiteName: Self.storeName)!
        store.removePersistentDomain(forName: Self.storeName)
        dialogs.start()
    }

    func back(_ number: Int) -> Back {
        let back = Back("main-AppWindow-\(number)")
        windows.append(back.window)
        back.window.orderFront(nil)
        back.window.makeFirstResponder(back.keys)
        back.window.reportsKey = true
        back.window.becomeKey()
        return back
    }

    func dialog(_ name: String) -> SpyDialog {
        let dialog = SpyDialog(name)
        spies.append(dialog)
        dialog.orderFront(nil)
        return dialog
    }

    func hotkey() -> HotkeyModel {
        HotkeyModel(defaults: store, windows: { [] }, unhide: {}, activate: {})
    }

    func click(_ window: NSWindow, at point: NSPoint, through path: ClickPath) async throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
        }
        let down = try event(.leftMouseDown)
        let up = try event(.leftMouseUp)
        await EventQueueLock.run {
            NSApp.postEvent(up, atStart: true)
            switch path {
            case .app: NSApp.sendEvent(down)
            case .window: window.sendEvent(down)
            }
            while let left = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                guard left.window === window else {
                    NSApp.postEvent(left, atStart: true)
                    break
                }
                NSApp.sendEvent(left)
            }
        }
    }

    func click(_ back: Back, through path: ClickPath) async throws {
        try await click(back.window, at: back.buttonPoint, through: path)
    }

    func key(_ characters: String, _ code: Int, to window: NSWindow) async throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(code)
        ))
        await EventQueueLock.run { NSApp.sendEvent(event) }
    }

    func close() {
        for window in spies + windows { window.close() }
    }
}

private func views(in view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { views(in: $0) }
}

private func escape(_ window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: UInt16(kVK_Escape)
    ))
}

private func refusesClicksUntilEscape(_ rig: Rig, show: () throws -> NSWindow) async throws {
    let back = rig.back(91)
    #expect(back.hitsButton, "the click point misses the button, so the refusals below prove nothing")
    let dialog = try show()
    #expect(rig.dialogs.topDialog === dialog, "\(dialog.title) did not register as it showed")
    #expect(rig.dialogs.isBlocking)
    #expect(back.hit is BlockingOverlayView)
    for path in ClickPath.allCases {
        try await rig.click(back, through: path)
        #expect(back.pressCount == 0, "a click through \(path) pressed the button behind \(dialog.title)")
    }
    #expect(rig.beeps == 2)
    dialog.makeFirstResponder(nil)
    dialog.keyDown(with: try escape(dialog))
    #expect(!dialog.isVisible)
    #expect(!rig.dialogs.isBlocking)
    #expect(back.hitsButton)
    try await rig.click(back, through: .app)
    #expect(back.pressCount == 1, "the click never reached the button, so the refusals above prove nothing")
    #expect(rig.beeps == 2)
}

@Suite(.serialized) struct DialogWindowTests {
    @Test func settingsBlocksTheSearchWindowBehindItUntilItCloses() async throws {
        let rig = Rig()
        defer { rig.close() }
        let client = FakeSearchClient()
        let settings = SettingsWindow(
            launchAtLogin: .inert(),
            locations: LocationsModel(client: client, defaults: rig.store, chooseFolder: { nil }), hotkey: rig.hotkey(), client: client,
            defaults: rig.store, open: { _ in }, activate: {}, dialogs: rig.dialogs
        )
        defer { settings.close() }
        try await refusesClicksUntilEscape(rig) {
            settings.show()
            return try #require(settings.window)
        }
    }

    @Test func aKeyForTheSearchWindowIsSwallowedWhileTheDialogsKeysArrive() async throws {
        let rig = Rig()
        defer { rig.close() }
        let back = rig.back(91)
        let dialog = rig.dialog("dialog-spy")
        rig.dialogs.register(dialog)
        try await rig.key("a", kVK_ANSI_A, to: back.window)
        #expect(back.keys.typed.isEmpty, "the key reached the search window behind the dialog")
        #expect(dialog.fronted == 1)
        #expect(rig.beeps == 0, "a key must not beep")

        back.window.reportsKey = false
        back.window.resignKey()
        dialog.reportsKey = true
        dialog.becomeKey()
        try await rig.key("b", kVK_ANSI_B, to: dialog)
        #expect(dialog.typed == ["b"])
        try await rig.key("\u{1b}", kVK_Escape, to: dialog)
        #expect(!dialog.isVisible, "Escape did not close the dialog")
        #expect(!rig.dialogs.isBlocking)

        dialog.reportsKey = false
        dialog.resignKey()
        back.window.reportsKey = true
        back.window.becomeKey()
        try await rig.key("a", kVK_ANSI_A, to: back.window)
        #expect(back.keys.typed == ["a"], "AppKit never routed the key to the search window, so the swallow above proves nothing")
    }

    @Test func everySearchWindowIsBlockedIncludingOneThatOpensLater() async throws {
        let rig = Rig()
        defer { rig.close() }
        let first = rig.back(91)
        let second = rig.back(92)
        let dialog = rig.dialog("dialog-spy")
        rig.dialogs.register(dialog)
        #expect(dialog.fronted == 0)
        let third = rig.back(93)
        #expect(dialog.fronted == 1, "the search window that opened under the dialog left it behind")
        let fourth = Back("main-AppWindow-94")
        rig.windows.append(fourth.window)
        fourth.window.orderFront(nil)
        rig.active = true
        fourth.window.update()
        rig.active = false
        #expect(fourth.hit is BlockingOverlayView, "the search window that ordered in under the dialog took no overlay")
        #expect(fourth.window.level == .normal, "the search window that ordered in under the dialog rose above it")
        #expect(dialog.fronted == 1)
        fourth.window.reportsKey = true
        first.window.becomeKey()
        #expect(dialog.fronted == 2, "Command-backtick to a search window left the dialog behind")
        for back in [first, second, third, fourth] {
            #expect(back.hit is BlockingOverlayView)
            for path in ClickPath.allCases {
                let fronted = dialog.fronted
                try await rig.click(back, through: path)
                #expect(dialog.fronted > fronted, "a click through \(path) did not front the dialog")
            }
            #expect(back.pressCount == 0)
        }
        #expect(rig.beeps == 8)

        dialog.close()
        for back in [first, second, third, fourth] {
            #expect(back.hitsButton)
            try await rig.click(back, through: .window)
            #expect(back.pressCount == 1)
        }
        #expect(rig.beeps == 8)
    }

    @Test func rightAndMiddleClicksAreRefusedToo() async throws {
        let rig = Rig()
        defer { rig.close() }
        let back = rig.back(91)
        let dialog = rig.dialog("dialog-spy")
        rig.dialogs.register(dialog)
        for type in [NSEvent.EventType.rightMouseDown, .otherMouseDown] {
            for path in ClickPath.allCases {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: back.buttonPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: back.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
                ))
                await EventQueueLock.run {
                    switch path {
                    case .app: NSApp.sendEvent(event)
                    case .window: back.window.sendEvent(event)
                    }
                }
            }
        }
        #expect(rig.beeps == 4)
        #expect(dialog.fronted == 4)
    }

    @Test func aDialogOverAnotherKeepsTheBlockUntilTheLastOneCloses() async throws {
        let rig = Rig()
        defer { rig.close() }
        let back = rig.back(91)
        let settings = rig.dialog("settings-spy")
        let about = rig.dialog("about-spy")
        rig.dialogs.register(settings)
        rig.dialogs.register(about)
        #expect(rig.dialogs.topDialog === about)
        settings.becomeKey()
        #expect(rig.dialogs.topDialog === settings, "a click on Settings under About left About on top")
        about.becomeKey()
        #expect(rig.dialogs.topDialog === about)

        try await rig.click(back, through: .app)
        #expect(back.pressCount == 0 && about.fronted == 1 && settings.fronted == 0)
        about.close()
        #expect(rig.dialogs.isBlocking)
        #expect(rig.dialogs.topDialog === settings)
        #expect(settings.fronted == 1, "closing About left Settings behind")
        #expect(back.hit is BlockingOverlayView)
        try await rig.click(back, through: .window)
        #expect(back.pressCount == 0 && settings.fronted == 2)

        settings.close()
        #expect(!rig.dialogs.isBlocking)
        #expect(back.hitsButton)
        try await rig.click(back, through: .app)
        #expect(back.pressCount == 1)
        #expect(rig.beeps == 2)
    }

    @Test func theDialogsFloatOnlyWhileWhereverIsActive() async throws {
        let rig = Rig()
        defer { rig.close() }
        let dialog = rig.dialog("dialog-spy")
        rig.dialogs.register(dialog)
        #expect(dialog.level == .normal)
        rig.active = true
        rig.dialogs.activationChanged(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(dialog.level == .floating)
        rig.active = false
        rig.dialogs.activationChanged(Notification(name: NSApplication.didResignActiveNotification))
        #expect(dialog.level == .normal)
        rig.active = true
        let second = rig.dialog("dialog-spy-2")
        rig.dialogs.register(second)
        #expect(second.level == .floating && dialog.level == .floating)
        second.close()
        dialog.close()
        #expect(second.level == .normal && dialog.level == .normal)
    }

    @Test func aWindowShownOverTheDialogRisesAboveItAndDropsBackAfter() async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.active = true
        let dialog = rig.dialog("dialog-spy")
        rig.dialogs.register(dialog)
        let panel = NSWindow(
            contentRect: NSRect(x: 300, y: 300, width: 240, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        rig.windows.append(panel)
        panel.orderFront(nil)
        panel.update()
        #expect(panel.level == .modalPanel)
        #expect(panel.level.rawValue > dialog.level.rawValue)
        rig.active = false
        rig.dialogs.activationChanged(Notification(name: NSApplication.didResignActiveNotification))
        #expect(panel.level == .normal)
        rig.active = true
        rig.dialogs.activationChanged(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(panel.level == .modalPanel)
        dialog.close()
        #expect(panel.level == .normal)
        #expect(panel.isVisible)
        #expect(rig.beeps == 0 && dialog.fronted == 0)
    }

    @Test func aFileDropOnABlockedSearchWindowIsRefused() async throws {
        let rig = Rig()
        defer { rig.close() }
        let back = rig.back(91)
        let dialog = rig.dialog("dialog-spy")
        rig.dialogs.register(dialog)
        let overlay = try #require(back.hit as? BlockingOverlayView)
        #expect(overlay.registeredDraggedTypes.contains(.fileURL))
        let drag = DragStub()
        #expect(overlay.draggingEntered(drag) == [])
        #expect(overlay.draggingUpdated(drag) == [])
        #expect(!overlay.prepareForDragOperation(drag))
        #expect(!overlay.performDragOperation(drag))
        dialog.close()
        #expect(overlay.superview == nil)
        #expect(back.hitsButton)
    }

    @Test func aClickBehindAMinimizedDialogBringsItBack() async throws {
        let rig = Rig()
        defer { rig.close() }
        let back = rig.back(91)
        let dialog = rig.dialog("dialog-spy")
        rig.dialogs.register(dialog)
        for (number, path) in ClickPath.allCases.enumerated() {
            dialog.reportsMiniaturized = true
            try await rig.click(back, through: path)
            #expect(dialog.deminiaturized == number + 1, "a click through \(path) left the dialog in the Dock")
            #expect(dialog.fronted == number + 1)
        }
        #expect(back.pressCount == 0 && rig.beeps == 2)
    }

    @Test func newWindowAndOpenWhereverFrontTheDialogAndOpenNothing() async throws {
        let rig = Rig()
        defer { rig.close() }
        let dialog = rig.dialog("dialog-spy")
        var opened = 0
        var summons = 0
        var activations = 0
        let access = AccessModel(
            defaults: rig.store, center: NotificationCenter(), stage: .ready, probe: { .granted }, confirm: { true }, start: {}, summon: {}, activate: {}
        )
        let routes = WhereverApp.routes(
            access: access, summon: { summons += 1 }, openWindow: { opened += 1 }, showSettings: {}, activate: { activations += 1 },
            open: { _ in }, quit: {},
            presence: AppPresence(center: NotificationCenter(), apply: { _ in }), dialogs: rig.dialogs
        )
        let delegate = AppDelegate()
        delegate.summon = routes.menu.summon
        rig.dialogs.register(dialog)

        routes.menu.newWindow()
        #expect(opened == 0 && rig.beeps == 1 && dialog.fronted == 1 && activations == 1)
        routes.menu.summon()
        #expect(summons == 0 && rig.beeps == 1 && dialog.fronted == 2 && activations == 2)
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        #expect(summons == 0 && rig.beeps == 1 && dialog.fronted == 3 && activations == 3)

        dialog.close()
        routes.menu.newWindow()
        routes.menu.summon()
        #expect(opened == 1 && summons == 1 && rig.beeps == 1)
    }

    @Test func theWelcomeIsBlockedBehindADialog() async throws {
        let rig = Rig()
        defer { rig.close() }
        var opens = 0
        let access = AccessModel(
            defaults: rig.store, center: NotificationCenter(), stage: .waiting, probe: { .denied }, confirm: { false }, start: {}, summon: {},
            open: { _ in
                opens += 1
                return true
            },
            quit: {}, activate: {}
        )
        let welcome = WelcomeWindowController(model: access, bundle: .main)
        welcome.show()
        let window = try #require(welcome.window)
        rig.windows.append(window)
        let button = try #require(views(in: window.contentView).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "welcome-action" })
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let frame = try #require(window.contentView?.superview)
        #expect(frame.hitTest(point)?.isDescendant(of: button) == true)

        let dialog = rig.dialog("dialog-spy")
        rig.dialogs.register(dialog)
        #expect(frame.hitTest(point) is BlockingOverlayView)
        try await rig.click(window, at: point, through: .app)
        #expect(rig.beeps == 1 && dialog.fronted == 1)
        #expect(opens == 0)
        dialog.close()
        #expect(frame.hitTest(point)?.isDescendant(of: button) == true)
    }

    private func state(of control: NSControl) -> NSControl.StateValue? {
        (control as? NSButton)?.state ?? (control as? NSSwitch)?.state
    }

    @Test func everyWelcomePageIsBlockedBehindADialog() async throws {
        let rig = Rig()
        defer { rig.close() }
        let access = AccessModel(
            defaults: rig.store, center: NotificationCenter(), stage: .granted, probe: { .granted }, confirm: { true }, start: {}, summon: {},
            open: { _ in true }, quit: {}, activate: {}
        )
        let welcome = WelcomeWindowController(model: access, bundle: .main)
        welcome.show()
        let window = try #require(welcome.window)
        rig.windows.append(window)
        func control(_ id: String) throws -> NSControl {
            try #require(views(in: window.contentView).compactMap { $0 as? NSControl }.first { $0.accessibilityIdentifier() == id }, "no \(id)")
        }
        let frame = try #require(window.contentView?.superview)
        let action = try control("welcome-action")
        let pages: [(WelcomeWindowController.Page, [String])] = [
            (.access, ["welcome-action", "welcome-step-2"]),
            (.modes, ["welcome-mode-normal", "welcome-back", "welcome-step-1"]),
            (.setup, ["welcome-launcher", "welcome-back", "welcome-step-4"]),
            (.done, ["welcome-action", "welcome-back", "welcome-step-2"]),
        ]
        var clicks = 0
        for (page, ids) in pages {
            for id in ids {
                #expect(welcome.page == page)
                let target = try control(id)
                let state = self.state(of: target)
                let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
                #expect(frame.hitTest(point)?.isDescendant(of: target) == true, "\(id)")

                clicks += 1
                let dialog = rig.dialog("dialog-spy-\(clicks)")
                rig.dialogs.register(dialog)
                #expect(frame.hitTest(point) is BlockingOverlayView, "\(id)")
                try await rig.click(window, at: point, through: .app)
                #expect(rig.beeps == clicks && dialog.fronted == 1, "\(id)")
                #expect(self.state(of: target) == state, "\(id)")
                #expect(welcome.page == page, "\(id)")
                #expect(access.stage == .granted)
                dialog.close()
                #expect(frame.hitTest(point)?.isDescendant(of: target) == true, "\(id)")
            }
            if page != .done { action.performClick(nil) }
        }
    }

    @Test func aFloatingPanelLikeTheLauncherKeepsItsLevelAndItsKeysPassTheMonitor() async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.active = true
        let dialog = rig.dialog("dialog-spy")
        rig.dialogs.register(dialog)
        let panel = FloatingPanel()
        rig.windows.append(panel)
        panel.orderFront(nil)
        panel.update()
        panel.reportsKey = true
        panel.becomeKey()
        #expect(panel.level == .floating)
        #expect(panel.contentView?.superview?.subviews.contains { $0 is BlockingOverlayView } == false)
        try await rig.key("r", kVK_ANSI_R, to: panel)
        #expect(rig.beeps == 0 && dialog.fronted == 0)
    }
}

extension AboutWindowTests {
    @Test func aboutBlocksTheSearchWindowBehindItUntilItCloses() async throws {
        let rig = Rig()
        defer { rig.close() }
        let about = AboutWindow(defaults: hostStore(), open: { _ in }, dialogs: rig.dialogs)
        defer { about.window?.close() }
        try await refusesClicksUntilEscape(rig) {
            about.show()
            return try #require(about.window)
        }
    }
}

extension HelpWindowTests {
    @Test func keyboardShortcutsBlocksTheSearchWindowBehindItUntilItCloses() async throws {
        let rig = Rig()
        defer { rig.close() }
        let shortcuts = KeyboardShortcutsWindow(hotkey: rig.hotkey(), defaults: hostStore(), dialogs: rig.dialogs)
        defer { shortcuts.window?.close() }
        try await refusesClicksUntilEscape(rig) {
            shortcuts.show()
            return try #require(shortcuts.window)
        }
    }
}
