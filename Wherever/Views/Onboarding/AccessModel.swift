import AppKit
import Combine
import Foundation
import os
import WhereverInterface

final class AccessModel: ObservableObject {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let completedKey = HelperLink.Key.welcomeCompleted
    static let tickInterval = Duration.seconds(2)
    static let watchInterval = Duration.seconds(30)
    nonisolated static let probeTimeout: TimeInterval = 10

    nonisolated enum ProbeResult: Sendable { case granted, denied, failed }
    enum Stage { case waiting, stillOff, checkFailed, settingsFailed, granted, reopen, startFailed, ready }

    @Published private(set) var stage: Stage {
        didSet { if !isWatched { stopWatcher() } }
    }
    var lost: @MainActor () -> Void = {}

    let defaults: UserDefaults
    private let probe: @Sendable () -> ProbeResult
    private let confirm: @MainActor () -> Bool
    private let prepare: @MainActor () -> Void
    private let start: @MainActor () throws -> Void
    private let summon: @MainActor () -> Void
    private let open: @MainActor (URL) -> Bool
    private let quitApp: @MainActor () -> Void
    private let activate: @MainActor () -> Void
    let tools: WelcomeTools
    private let syncHelper: @MainActor () -> Void
    private let watchEvery: Duration?
    private var openedSettings = false
    private var returnedFromSettings = false
    private var probing = false
    private var quitting = false
    private var ticker: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var denials = 0
    private(set) var welcome: WelcomeWindowController?

    var isTicking: Bool { ticker != nil }
    var isWatching: Bool { watcher != nil }
    var showsWelcome: Bool { stage != .ready }
    private var isWaiting: Bool {
        switch stage {
        case .waiting, .stillOff, .checkFailed, .settingsFailed: true
        case .granted, .reopen, .startFailed, .ready: false
        }
    }
    private var isWatched: Bool { stage == .granted || stage == .ready }

    init(
        defaults: UserDefaults,
        center: NotificationCenter = .default,
        stage: Stage,
        probe: @escaping @Sendable () -> ProbeResult,
        confirm: @escaping @MainActor () -> Bool,
        prepare: @escaping @MainActor () -> Void = {},
        start: @escaping @MainActor () throws -> Void,
        summon: @escaping @MainActor () -> Void,
        open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
        activate: @escaping @MainActor () -> Void = Availability.activateApp,
        tools: WelcomeTools = .inert(),
        syncHelper: @escaping @MainActor () -> Void = {},
        watchInterval: Duration? = nil
    ) {
        self.defaults = defaults
        self.stage = stage
        self.probe = probe
        self.confirm = confirm
        self.prepare = prepare
        self.start = start
        self.summon = summon
        self.open = open
        quitApp = quit
        self.activate = activate
        self.tools = tools
        self.syncHelper = syncHelper
        watchEvery = watchInterval
        if stage == .ready { startServices() }
        if stage == .granted { prepare() }
        startWatcher()
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    nonisolated static let probeScript =
        #"s=2; for f do e=$({ true < "$f"; } 2>&1) && exit 0; echo "$e"; case $e in *"not permitted"*) s=1;; esac; done; exit $s"#

    nonisolated static func probeArguments(home: String) -> [String] {
        [
            "-c", probeScript, "sh",
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
    }

    nonisolated static func probeInChild() -> ProbeResult {
        run(URL(filePath: "/bin/sh"), probeArguments(home: NSHomeDirectory()), timeout: probeTimeout)
    }

    nonisolated static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> ProbeResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return .failed }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            return .failed
        }
        let lines = String(decoding: (try? output.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self).split(separator: "\n")
        for line in lines.map(String.init) where loggedProbeErrors.withLock({ $0.insert(line).inserted }) {
            Logger(subsystem: AppIdentity.bundleIdentifier, category: "access").notice("probe: \(line, privacy: .private)")
        }
        guard process.terminationReason == .exit else { return .failed }
        switch process.terminationStatus {
        case 0: return .granted
        case 1: return .denied
        default: return .failed
        }
    }

    private nonisolated static let loggedProbeErrors = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    func tick() async {
        guard let checking = welcome, isWaiting, !probing else { return }
        probing = true
        let probe = probe
        let result = await Task.detached { probe() }.value
        probing = false
        guard welcome === checking, isWaiting else { return }
        switch result {
        case .failed: stage = .checkFailed
        case .denied: stage = returnedFromSettings ? .stillOff : .waiting
        case .granted:
            stopTicker()
            if confirm() { grant() } else { stage = .reopen }
        }
    }

    private func grant() {
        stage = .granted
        denials = 0
        prepare()
        startWatcher()
    }

    func watch() async {
        guard watchEvery != nil, isWatched, !probing else { return }
        probing = true
        let probe = probe
        let result = await Task.detached { probe() }.value
        probing = false
        guard isWatched else { return }
        switch result {
        case .failed: return
        case .granted: denials = 0
        case .denied:
            denials += 1
            guard denials >= 2 else { return }
            denials = 0
            revoked()
        }
    }

    private func revoked() {
        guard stage == .granted else { return lost() }
        openedSettings = true
        returnedFromSettings = true
        stage = .stillOff
        if welcome != nil { startTicker() }
    }

    var storedChoices: WelcomeChoices {
        WelcomeChoices(
            mode: defaults.string(forKey: WindowMode.key).flatMap(WindowMode.init(rawValue:)) ?? .simple,
            launcher: tools.launcherIsOn(),
            menuBarIcon: defaults.object(forKey: MenuBarIcon.key) as? Bool ?? MenuBarIcon.standard,
            theme: defaults.string(forKey: Theme.key).flatMap(Theme.init(rawValue:)) ?? .systemNative
        )
    }

    func completeWelcome(choices: WelcomeChoices?) {
        guard stage == .granted else { return }
        guard confirm() else {
            stage = .reopen
            return
        }
        if let choices {
            defaults.set(choices.mode.rawValue, forKey: WindowMode.key)
            defaults.set(choices.theme.rawValue, forKey: Theme.key)
            if choices.menuBarIconMoved || defaults.object(forKey: MenuBarIcon.key) == nil {
                defaults.set(choices.menuBarIcon, forKey: MenuBarIcon.key)
            }
            tools.applyLauncher(choices.launcher)
            defaults.set(true, forKey: Self.completedKey)
            syncHelper()
        }
        guard startServices() else { return }
        welcome?.close()
        summon()
    }

    @discardableResult private func startServices() -> Bool {
        do {
            try start()
            stage = .ready
            denials = 0
            return true
        } catch {
            stage = .startFailed
            return false
        }
    }

    func openOrWelcome(_ action: () -> Void) {
        guard stage != .ready else { return action() }
        showWelcome()
        activate()
    }

    func refresh() {
        if openedSettings { returnedFromSettings = true }
        if stage == .reopen, confirm() { grant() }
        Task {
            if isWatched { await watch() } else { await tick() }
        }
    }

    func openSettings() {
        guard isWaiting else { return }
        openedSettings = open(Self.settingsURL)
        returnedFromSettings = false
        stage = openedSettings ? .waiting : .settingsFailed
    }

    func quit() {
        guard !quitting else { return }
        quitting = true
        quitApp()
    }

    func showWelcome(bundle: Bundle = .main) {
        Task {
            guard showsWelcome else { return }
            if let welcome {
                welcome.window?.makeKeyAndOrderFront(nil)
                return
            }
            let controller = WelcomeWindowController(model: self, bundle: bundle)
            welcome = controller
            controller.show()
            startTicker()
        }
    }

    func forgetWelcome() {
        let closing = welcome
        welcome = nil
        stopTicker()
        Task { withExtendedLifetime(closing) {} }
    }

    private func startTicker() {
        guard isWaiting, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func startWatcher() {
        guard let interval = watchEvery, isWatched, watcher == nil else { return }
        watcher = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                await self.watch()
            }
        }
    }

    private func stopWatcher() {
        watcher?.cancel()
        watcher = nil
    }
}
