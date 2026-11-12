import AppKit
import Combine
import Foundation
import Sparkle
import SwiftUI
import WhereverInterface
import WhereverKit

@main
struct WhereverApp: App {
    #if DEBUG
    static let usesPreviewServices = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    #else
    static let usesPreviewServices = false
    #endif

    static let presence = launchPresence(previews: usesPreviewServices, defaults: .standard, domain: AppIdentity.bundleIdentifier) {
        WhereverServices.removeDataFolder(at: WhereverServices.dataFolder)
    }
    static let about = AboutWindow(defaults: .standard)
    static let helperStarter = HelperStarter.live(previews: usesPreviewServices, defaults: .standard, app: Bundle.main.bundleURL)
    static let helperCommands = HelperCommands()
    static let linger = CommandLinger { WhereverApp.presence.quitIfIdle() }

    private let updater: SPUStandardUpdaterController
    private let updateSessionEnd: AnyCancellable
    private let updateReminders = UpdateReminders(presence: WhereverApp.presence) { NSApp.dockTile.badgeLabel = $0 }
    @StateObject private var updates: UpdatesModel
    @StateObject private var launch: Launch
    @StateObject private var access: AccessModel
    @StateObject private var hotkey: HotkeyModel
    @StateObject private var launchAtLogin: LaunchAtLoginModel
    private let commandLine: CommandLineToolModel
    @StateObject private var dialogs = ModalWindowCoordinator.shared
    @StateObject private var archiveSaving = ArchiveSaveMenu.shared
    @AppStorage(InspectorPane.shownKey) private var inspectorShown = false
    @AppStorage(WindowMode.key) private var mode = WindowMode.simple
    @AppStorage(SearchFilters.hidesHiddenKey) private var hidesHidden = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    init() {
        Self.prepareLaunch(previews: Self.usesPreviewServices, defaults: .standard)
        if !Self.usesPreviewServices { ModalWindowCoordinator.shared.start() }
        if !Self.usesPreviewServices { WhereverServices.clearArchiveCache() }
        if !Self.usesPreviewServices { Self.helperCommands.observe(path: Bundle.main.bundlePath) }
        if !Self.usesPreviewServices { Self.linger.observeDone(path: Bundle.main.bundlePath) }
        let launchAtLogin = Self.usesPreviewServices ? LaunchAtLoginModel.inert() : LaunchAtLoginModel()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let commandLine = Self.usesPreviewServices
            ? CommandLineToolModel.inert() : CommandLineToolModel(linkFolder: home.appending(path: ".local/bin"), profile: home.appending(path: ".zshenv"))
        self.commandLine = commandLine
        _launchAtLogin = StateObject(wrappedValue: launchAtLogin)
        let hotkey = HotkeyModel(helper: Self.helperStarter)
        _hotkey = StateObject(wrappedValue: hotkey)
        let updater = SPUStandardUpdaterController(startingUpdater: !Self.usesPreviewServices, updaterDelegate: nil, userDriverDelegate: updateReminders)
        self.updater = updater
        updateSessionEnd = Self.quitsWhenSessionEnds(updater.updater.publisher(for: \.sessionInProgress, options: .new), presence: Self.presence)
        let updates = UpdatesModel(
            canCheckForUpdates: updater.updater.publisher(for: \.canCheckForUpdates),
            automaticallyChecks: updater.updater.publisher(for: \.automaticallyChecksForUpdates),
            check: { updater.updater.checkForUpdates() }, setAutomaticallyChecks: { updater.updater.automaticallyChecksForUpdates = $0 }
        )
        _updates = StateObject(wrappedValue: updates)
        let launch = Launch(windowless: true)
        _launch = StateObject(wrappedValue: launch)
        let stage = Self.launchStage(previews: Self.usesPreviewServices, defaults: .standard, probe: AccessModel.probeInChild, confirm: WhereverServices.hasFullDiskAccess)
        let engine = BuiltOnce { try Self.makeEngine(commandLine: commandLine) }
        let access = AccessModel(
            defaults: .standard, stage: stage, probe: AccessModel.probeInChild, confirm: WhereverServices.hasFullDiskAccess,
            prepare: Self.prepareAction(previews: Self.usesPreviewServices, engine: engine),
            start: { try launch.start { try Self.makeServices(engine: engine, hotkey: hotkey, launchAtLogin: launchAtLogin, updates: updates, commandLine: commandLine) } },
            summon: { Self.presence.prepareToShowWindow(); hotkey.summon() },
            tools: .live(commandLine: commandLine, hotkey: hotkey),
            syncHelper: { Self.helperStarter.sync() },
            watchInterval: Self.usesPreviewServices ? nil : AccessModel.watchInterval
        )
        _access = StateObject(wrappedValue: access)
    }

    static func prepareLaunch(
        previews: Bool, defaults: UserDefaults, applyAppearance: (NSAppearance?) -> Void = { AppearanceMode.applyToApp($0) }
    ) {
        guard !previews else { return }
        AppearanceMode.applyStored(from: defaults, apply: applyAppearance)
    }

    static func launchPresence(
        previews: Bool, defaults: UserDefaults, domain: String, center: NotificationCenter = .default, removeData: () -> Void
    ) -> AppPresence {
        if !previews { Relaunch.finishPendingReset(defaults: defaults, domain: domain, removeData: removeData) }
        return AppPresence(center: center) { policy in
            if !previews { NSApplication.shared.setActivationPolicy(policy) }
        }
    }

    static func launchStage(previews: Bool, defaults: UserDefaults, probe: () -> AccessModel.ProbeResult, confirm: () -> Bool) -> AccessModel.Stage {
        if previews { return .ready }
        switch probe() {
        case .failed: return .checkFailed
        case .denied: return .waiting
        case .granted:
            guard confirm() else { return .reopen }
            return defaults.bool(forKey: AccessModel.completedKey) ? .ready : .granted
        }
    }

    static func launchWindowless(previews: Bool, command: HelperCommand?) -> Bool {
        !previews && command != nil
    }

    static func finishLaunch(
        launch: Launch, access: AccessModel, previews: Bool, presence: AppPresence,
        command: HelperCommand? = nil, mounted: [String] = [], commands: HelperCommands? = nil, linger: CommandLinger? = nil, syncHelper: () -> Void = {},
        activate: () -> Void = {}
    ) {
        if command == .serve { linger?.start() }
        if !launchWindowless(previews: previews, command: command) {
            presence.prepareToShowWindow()
            launch.showWindows()
            if !previews { activate() }
        } else if (access.showsWelcome && command != .wake) || command == .settings || command == .shortcuts {
            presence.prepareToShowWindow()
        }
        if command == .wake {
            for path in mounted { launch.services?.index.diskMounted(at: path) }
            presence.quitIfIdle()
        } else {
            access.showWelcome()
        }
        commands?.finishLaunch(argument: command)
        syncHelper()
    }

    static func windowOpener(launch: Launch, open: @escaping () -> Void) -> () -> Void {
        {
            launch.showWindows()
            open()
        }
    }

    static func resetAction(
        previews: Bool, helper: HelperStarter, commandLine: CommandLineToolModel, defaults: UserDefaults = .standard,
        relaunch: @escaping () throws -> Void = { try Relaunch.relaunch() }, stop: @escaping () -> Void
    ) -> @MainActor () async throws -> Void {
        if previews { return {} }
        return {
            try await Relaunch.reset(
                defaults: defaults, removeCommandLine: { try commandLine.removeAll() }, relaunch: relaunch,
                unregister: { await helper.removeForReset() }, stop: stop
            )
        }
    }

    static func reopenAction(previews: Bool, stop: @escaping () -> Void) -> @MainActor () throws -> Void {
        if previews { return {} }
        return {
            try Relaunch.relaunch()
            stop()
        }
    }

    static func accessLostAction(
        previews: Bool, resolve: @escaping @MainActor (@escaping (Bool) -> Void) -> Void = ArchiveEdits.resolve(done:),
        relaunch: @escaping @MainActor () throws -> Void = { try Relaunch.relaunch() }, stop: @escaping () -> Void
    ) -> @MainActor () -> Void {
        if previews { return {} }
        return {
            resolve { saved in
                guard saved else { return }
                do {
                    try relaunch()
                    stop()
                } catch {}
            }
        }
    }

    static func prepareAction<Value>(previews: Bool, engine: BuiltOnce<Value>) -> @MainActor () -> Void {
        if previews { return {} }
        return { _ = try? engine.value() }
    }

    private static func makeEngine(commandLine: CommandLineToolModel) throws -> WhereverServices {
        let stored = LocationsModel.stored()
        let engine = try WhereverServices(excluded: stored.excluded, indexedVolumes: stored.indexedVolumes, liveUpdatesPaused: UserDefaults.standard.bool(forKey: IndexModel.pausedKey))
        commandLine.attach(serve: engine.search.setCommandLine)
        return engine
    }

    private static func makeServices(
        engine: BuiltOnce<WhereverServices>, hotkey: HotkeyModel, launchAtLogin: LaunchAtLoginModel, updates: UpdatesModel, commandLine: CommandLineToolModel
    ) throws -> AppServices {
        if usesPreviewServices {
            return services(
                client: PreviewSearchClient(), archiveClient: PreviewArchiveClient(), defaults: .standard,
                hotkey: hotkey, launchAtLogin: launchAtLogin, updates: updates, commandLine: commandLine
            )
        }
        let engine = try engine.value()
        return services(
            client: engine.search, archiveClient: engine.archive, defaults: .standard,
            hotkey: hotkey, launchAtLogin: launchAtLogin, updates: updates, commandLine: commandLine
        )
    }

    static func services(
        client: any SearchClient, archiveClient: any ArchiveClient, defaults: UserDefaults,
        hotkey: HotkeyModel, launchAtLogin: LaunchAtLoginModel, updates: UpdatesModel, commandLine: CommandLineToolModel,
        presence: AppPresence = WhereverApp.presence, linger: CommandLinger = WhereverApp.linger
    ) -> AppServices {
        try? client.setTypoSearch(defaults.bool(forKey: TypoSearchRow.key))
        try? client.setLiveUpdates(!defaults.bool(forKey: IndexModel.pausedKey))
        let locations = LocationsModel(client: client)
        let settings = SettingsWindow(
            launchAtLogin: launchAtLogin, locations: locations, hotkey: hotkey, client: client,
            updates: updates, commandLine: commandLine
        )
        let index = IndexModel(
            client: client, defaults: defaults, pauseStore: defaults, mounts: usesPreviewServices ? NotificationCenter() : NSWorkspace.shared.notificationCenter,
            openLocations: {
                presence.prepareToShowWindow()
                settings.show(.locations)
            }
        )
        index.stateArrived = { booted in
            if booted { linger.commandDone() }
            presence.quitIfIdle()
        }
        locations.follow(index.$volumes)
        if !usesPreviewServices { DiskNoticeDelegate.install(index: index) }
        let archives = ArchiveWindows(
            client: archiveClient, index: index, actions: .live(client: client),
            cache: URL(filePath: WhereverServices.archiveCacheFolder, directoryHint: .isDirectory)
        )
        let launcher = Launcher(
            index: index, actions: .live(client: client, inside: archives.inside), isRecording: { hotkey.isRecording },
            activate: {
                presence.prepareToShowWindow()
                Availability.activateApp()
            },
            hidden: { presence.holdQuit(for: NSEvent.doubleClickInterval + 1) }
        )
        return AppServices(client: client, archiveClient: archiveClient, archives: archives, index: index, settings: settings, launcher: launcher)
    }

    static func routes(
        access: AccessModel, summon: @escaping () -> Void, openWindow: @escaping () -> Void, showSettings: @escaping () -> Void,
        activate: @escaping () -> Void, open: @escaping (URL) -> Void, quit: @escaping () -> Void,
        launcher: @escaping () -> Void = {}, closeLauncher: @escaping () -> Void = {},
        about: @escaping () -> Void = {}, keyboardShortcuts: @escaping () -> Void = {}, presence: AppPresence = WhereverApp.presence,
        dialogs: ModalWindowCoordinator = .shared
    ) -> (menu: MenuBarActions, window: @MainActor () -> Void, hotkey: @MainActor () -> Void) {
        let menu = MenuBarActions(
            summon: {
                if dialogs.frontDialog(beeping: false) { return activate() }
                presence.prepareToShowWindow()
                summon()
            },
            newWindow: {
                if dialogs.frontDialog(beeping: true) { return activate() }
                presence.prepareToShowWindow()
                access.openOrWelcome {
                    closeLauncher()
                    openWindow()
                    activate()
                }
            },
            showSettings: { presence.prepareToShowWindow(); access.openOrWelcome(showSettings) },
            open: open,
            quit: quit,
            about: { presence.prepareToShowWindow(); about(); activate() },
            keyboardShortcuts: { presence.prepareToShowWindow(); keyboardShortcuts(); activate() }
        )
        return (menu, {
            presence.prepareToShowWindow()
            access.openOrWelcome(openWindow)
        }, {
            if access.showsWelcome { presence.prepareToShowWindow() }
            access.openOrWelcome(launcher)
        })
    }

    static func showAll(newWindow: @escaping () -> Void, dialogs: ModalWindowCoordinator = .shared) -> () -> Void {
        {
            if dialogs.topDialog != nil { return NSSound.beep() }
            newWindow()
        }
    }

    static func bind(
        delegate: AppDelegate, launch: Launch, presence: AppPresence, previews: Bool, linger: CommandLinger, updating: @escaping () -> Bool
    ) {
        delegate.flushOpens = { try? launch.services?.client.flushOpens() }
        guard !previews else { return }
        presence.staysRunning = { [weak delegate] in
            delegate?.didFinishLaunching != true || launch.services?.launcher.panel?.isVisible == true || updating() || linger.running
                || (try? launch.services?.client.isSettling()) == true || launch.services?.index.noticeWaits == true
        }
        presence.quit = { [weak delegate] in delegate?.terminate() }
    }

    static func quitsWhenSessionEnds(_ session: some Publisher<Bool, Never>, presence: AppPresence) -> AnyCancellable {
        session.sink { running in
            if !running { presence.quitIfIdle() }
        }
    }

    var body: some Scene {
        let routes = Self.routes(
            access: access, summon: { hotkey.summon() },
            openWindow: Self.windowOpener(launch: launch) { openWindow(id: MainWindow.id) },
            showSettings: { launch.services?.settings.show() }, activate: Availability.activateApp,
            open: { NSWorkspace.shared.open($0) }, quit: { NSApp.terminate(nil) },
            launcher: { launch.services?.launcher.toggle() }, closeLauncher: { launch.services?.launcher.prepareHandOff() },
            about: { Self.about.show() }, keyboardShortcuts: { KeyboardShortcutsWindow.show(hotkey: hotkey) }
        )
        let _ = launch.services?.launcher.showAll = Self.showAll(newWindow: routes.menu.newWindow)
        let _ = launch.services?.settings.reset = Self.resetAction(previews: Self.usesPreviewServices, helper: Self.helperStarter, commandLine: commandLine) {
            delegate.terminate()
        }
        let _ = launch.services?.settings.reopen = Self.reopenAction(previews: Self.usesPreviewServices) { delegate.terminate() }
        let _ = access.lost = Self.accessLostAction(previews: Self.usesPreviewServices) { delegate.terminate() }
        let _ = hotkey.configure(openWindow: routes.window)
        let _ = delegate.summon = routes.menu.summon
        let _ = Self.bind(
            delegate: delegate, launch: launch, presence: Self.presence, previews: Self.usesPreviewServices, linger: Self.linger,
            updating: { updater.updater.sessionInProgress }
        )
        let _ = delegate.refreshLoginStatus = { launchAtLogin.refresh() }
        let _ = delegate.finishLaunch = {
            Self.finishLaunch(
                launch: launch, access: access, previews: Self.usesPreviewServices, presence: Self.presence,
                command: delegate.launchCommand, mounted: delegate.launchMounted, commands: Self.helperCommands, linger: Self.linger,
                syncHelper: { Self.helperStarter.launched() }, activate: Availability.activateApp
            )
        }
        let _ = Self.helperCommands.run = HelperCommands.route(
            access: access, launch: launch, menu: routes.menu, hotkey: routes.hotkey,
            stop: { delegate.quitFromHelper() }, activate: Availability.activateApp, synchronize: { HelperLink.synchronize() }
        )
        let _ = Self.helperCommands.mounted = { paths in
            for path in paths { launch.services?.index.diskMounted(at: path) }
        }
        let _ = delegate.postHelperQuit = {
            if !Self.usesPreviewServices { HelperLink.post(HelperLink.Note.helperQuit, object: Bundle.main.bundlePath) }
        }
        let actions = routes.menu
        WindowGroup(id: MainWindow.id) {
            LaunchRoot(launch: launch, access: access, delegate: delegate)
        }
        .defaultSize(width: SearchMetrics.windowDefaultWidth, height: SearchMetrics.windowDefaultHeight)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(action: actions.about) { Text("About Wherever", tableName: "MenuBar") }
            }
            CommandGroup(after: .appInfo) {
                DonateItems(actions: actions, updates: updates)
            }
            CommandGroup(replacing: .newItem) {
                Button(action: actions.newWindow) { Text("New Window", tableName: "MenuBar") }
                    .keyboardShortcut("n")
                    .disabled(dialogs.isBlocking)
                Button { ArchiveWindows.showContents() } label: { Text("Show Archive Contents", tableName: "Results") }
                Button { ArchiveWindows.expandArchive() } label: { Text("Expand Archive…", tableName: "Archive") }
                    .disabled(!archiveSaving.canExpand)
                    .accessibilityIdentifier("app-menu-expand-archive")
                Button { ArchiveWindows.addFiles() } label: { Text("Add Files…", tableName: "Archive") }
                    .disabled(!archiveSaving.canAdd)
                    .accessibilityIdentifier("app-menu-add-files")
            }
            CommandGroup(after: .saveItem) {
                Button { _ = NSApp.sendAction(#selector(ArchiveWindowController.saveArchive(_:)), to: nil, from: nil) } label: {
                    Text("Save", tableName: "Archive")
                }
                .keyboardShortcut("s")
                .disabled(!archiveSaving.canSave)
                .accessibilityIdentifier("app-menu-save-archive")
                Button { _ = NSApp.sendAction(#selector(ArchiveWindowController.saveArchiveAs(_:)), to: nil, from: nil) } label: {
                    Text("Save As…", tableName: "Archive")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!archiveSaving.canSaveAs)
                .accessibilityIdentifier("app-menu-save-archive-as")
            }
            CommandGroup(replacing: .appSettings) {
                Button(action: actions.showSettings) { Text("Settings…", tableName: "Settings") }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .appTermination) {
                QuitItems(actions: actions)
            }
            CommandGroup(replacing: .toolbar) {
                Toggle(isOn: Binding(get: { mode == .simple }, set: { if $0 { pick(.simple) } })) { Text("Simple") }
                Toggle(isOn: Binding(get: { mode == .normal }, set: { if $0 { pick(.normal) } })) { Text("Normal") }
                Divider()
                Button { inspectorShown.toggle() } label: {
                    inspectorShown ? Text("Hide Inspector", tableName: "Inspector") : Text("Show Inspector", tableName: "Inspector")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Toggle(isOn: $hidesHidden) { Text("Hide Invisible Files") }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                LiveUpdatesItems(index: launch.services?.index)
            }
            CommandGroup(replacing: .help) {
                Button(action: actions.keyboardShortcuts) { Text("Keyboard Shortcuts", tableName: "Help") }
            }
        }
    }

    private func pick(_ new: WindowMode) {
        mode = new
    }
}

struct LaunchRoot: View {
    @ObservedObject var launch: Launch
    let access: AccessModel
    @ObservedObject var delegate: AppDelegate
    @State private var startsWindowless: Bool?

    init(launch: Launch, access: AccessModel, delegate: AppDelegate) {
        self.launch = launch
        self.access = access
        self.delegate = delegate
        _startsWindowless = State(initialValue: delegate.didFinishLaunching ? launch.windowless : nil)
    }

    var body: some View {
        let windowless = startsWindowless ?? (delegate.didFinishLaunching ? launch.windowless : nil)
        Group {
            if windowless == nil {
                LaunchWindowVisibility(visible: false)
            } else if windowless == true {
                LaunchGate()
            } else if let services = launch.services {
                ContentView(index: services.index, model: services.index.makeModel(listsAll: true))
                    .environment(\.searchClient, services.client)
                    .environment(\.archiveClient, services.archiveClient)
                    .environment(\.resultActions, .live(client: services.client, inside: services.archives.inside))
                    .background(LaunchWindowVisibility(visible: true))
            } else {
                LaunchGate(ask: { WhereverApp.presence.prepareToShowWindow(); access.showWelcome() })
            }
        }
        .task(id: windowless) { startsWindowless = windowless }
    }
}

private struct LaunchWindowVisibility: NSViewRepresentable {
    let visible: Bool

    func makeNSView(context: Context) -> NSView { WindowView(visible: visible) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowView: NSView {
        let visible: Bool
        init(visible: Bool) {
            self.visible = visible
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.alphaValue = visible ? 1 : 0
        }
    }
}

nonisolated final class UpdateReminders: NSObject, SPUStandardUserDriverDelegate, Sendable {
    private let presence: AppPresence
    private let badge: @MainActor @Sendable (String?) -> Void

    init(presence: AppPresence, badge: @escaping @MainActor @Sendable (String?) -> Void) {
        self.presence = presence
        self.badge = badge
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { willShow(userInitiated: state.userInitiated) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { badge(nil) }
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { finish() }
    }

    @MainActor func willShow(userInitiated: Bool) {
        guard !userInitiated else { return }
        presence.prepareToShowWindow()
        badge("1")
    }

    @MainActor func finish() {
        badge(nil)
        presence.applyPolicy()
    }
}
