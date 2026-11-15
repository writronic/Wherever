import AppKit
import CoreFoundation
import Darwin
import Foundation

nonisolated enum HelperCommand: String, CaseIterable, Sendable {
    case launcher, settings, shortcuts, quit, liveUpdates, serve, wake

    static let argument = "--command"
    static let mountedArgument = "--mounted"

    var notification: Notification.Name { Notification.Name("com.writronic.wherever.command.\(rawValue)") }
    var opensWherever: Bool { self != .liveUpdates && self != .quit }
    var activates: Bool { self == .settings || self == .shortcuts }
    var launchArguments: [String] { [Self.argument, rawValue] }
}

nonisolated enum HelperLink {
    static let whereverID = "com.writronic.wherever"
    static let helperID = "com.writronic.wherever.helper"

    nonisolated enum Key {
        static let welcomeCompleted = "welcomeCompleted"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let summonHotkey = "summonHotkey"
        static let appleLanguages = "AppleLanguages"
        static let liveUpdatesPaused = "liveUpdatesPaused"
        static let shortcutFailed = "shortcutFailed"
        static let helperIdentity = "helperIdentity"
        static let automaticChecks = "SUEnableAutomaticChecks"
        static let lastUpdateCheck = "SULastCheckTime"
        static let newDiskChoice = "newDiskChoice"
        static let lastWake = "lastWake"
    }

    nonisolated enum Note {
        static let sync = Notification.Name("com.writronic.wherever.helper.sync")
        static let pause = Notification.Name("com.writronic.wherever.helper.pause")
        static let resume = Notification.Name("com.writronic.wherever.helper.resume")
        static let shortcutFailed = Notification.Name("com.writronic.wherever.helper.shortcutFailed")
        static let helperQuit = Notification.Name("com.writronic.wherever.helperQuit")
        static let commandDone = Notification.Name("com.writronic.wherever.commandDone")
        static let mounted = Notification.Name("com.writronic.wherever.helper.mounted")
    }

    static func shouldRun(welcomeCompleted: Bool, showMenuBarIcon: Bool?, shortcut: Data?) -> Bool {
        let shortcutOn = shortcut.map { !$0.isEmpty } ?? true
        return welcomeCompleted && (showMenuBarIcon ?? true || shortcutOn)
    }

    static func shouldRun(in defaults: UserDefaults) -> Bool {
        shouldRun(
            welcomeCompleted: defaults.bool(forKey: Key.welcomeCompleted),
            showMenuBarIcon: defaults.object(forKey: Key.showMenuBarIcon) as? Bool,
            shortcut: defaults.data(forKey: Key.summonHotkey)
        )
    }

    static func endUnlessNeeded(in defaults: UserDefaults, exit: () -> Void) -> Bool {
        synchronize()
        let needed = shouldRun(in: defaults)
        if !needed { exit() }
        return needed
    }

    static func parent(ofHelperAt helper: URL) -> URL? {
        let parent = helper
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: parent)?.bundleIdentifier == whereverID ? parent : nil
    }

    static func embeddedHelper(in app: URL) -> URL {
        app.appendingPathComponent("Contents/Library/LoginItems/WhereverHelper.app")
    }

    static func identity(of helper: URL) -> String? {
        var info = stat()
        guard stat(helper.appendingPathComponent("Contents/MacOS/WhereverHelper").path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    static func command(in arguments: [String]) -> HelperCommand? {
        guard let flag = arguments.firstIndex(of: HelperCommand.argument), flag + 1 < arguments.count else { return nil }
        return HelperCommand(rawValue: arguments[flag + 1])
    }

    static func mounted(in arguments: [String]) -> [String] {
        zip(arguments, arguments.dropFirst()).filter { $0.0 == HelperCommand.mountedArgument }.map(\.1)
    }

    static func post(_ name: Notification.Name, object: String?) {
        DistributedNotificationCenter.default().postNotificationName(name, object: object, userInfo: nil, deliverImmediately: true)
    }

    @MainActor static func observe(_ name: Notification.Name, object: String?, handler: @escaping () -> Void) -> HelperObservation {
        let observation = HelperObservation(handler)
        DistributedNotificationCenter.default().addObserver(
            observation, selector: #selector(HelperObservation.fire(_:)), name: name, object: object, suspensionBehavior: .deliverImmediately
        )
        return observation
    }

    static func postMounted(_ paths: [String], object: String) {
        DistributedNotificationCenter.default().postNotificationName(Note.mounted, object: object, userInfo: [mountedPaths: paths], deliverImmediately: true)
    }

    @MainActor static func observeMounted(object: String, handler: @escaping ([String]) -> Void) -> HelperObservation {
        let observation = HelperObservation { note in handler(note.userInfo?[mountedPaths] as? [String] ?? []) }
        DistributedNotificationCenter.default().addObserver(
            observation, selector: #selector(HelperObservation.fire(_:)), name: Note.mounted, object: object, suspensionBehavior: .deliverImmediately
        )
        return observation
    }

    private static let mountedPaths = "paths"

    static func synchronize(domain: String = whereverID) {
        CFPreferencesAppSynchronize(domain as CFString)
    }
}

final class HelperObservation: NSObject {
    private let handler: (Notification) -> Void

    init(_ handler: @escaping () -> Void) { self.handler = { _ in handler() } }

    init(_ handler: @escaping (Notification) -> Void) { self.handler = handler }

    @objc func fire(_ notification: Notification) { handler(notification) }
}

struct HelperSender {
    enum WhereverState { case closed, launching, running }

    let parent: URL
    var state: () -> WhereverState
    var whenLaunched: (@escaping () -> Void) -> Void
    var post: (Notification.Name, String) -> Void
    var open: (URL, [String], Bool) -> Void
    var postMounted: ([String], String) -> Void = { _, _ in }

    @discardableResult
    func send(_ command: HelperCommand) -> Bool {
        let announce = { post(command.notification, parent.path) }
        switch state() {
        case .running:
            announce()
            return true
        case .launching:
            whenLaunched(announce)
            return true
        case .closed:
            if command == .liveUpdates {
                announce()
            } else if command.opensWherever {
                open(parent, command.launchArguments, command.activates)
            }
            return false
        }
    }

    func wake(mounted paths: [String] = []) {
        switch state() {
        case .running:
            break
        case .launching:
            if !paths.isEmpty { whenLaunched { postMounted(paths, parent.path) } }
        case .closed:
            let mounts = paths.flatMap { [HelperCommand.mountedArgument, $0] }
            open(parent, HelperCommand.wake.launchArguments + mounts, HelperCommand.wake.activates)
        }
    }

    func openWherever() {
        open(parent, [], true)
    }

    static func live(parent: URL) -> HelperSender {
        func running() -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: HelperLink.whereverID)
                .first { $0.bundleURL?.path == parent.path }
        }
        return HelperSender(
            parent: parent,
            state: {
                guard let app = running() else { return .closed }
                return app.isFinishedLaunching ? .running : .launching
            },
            whenLaunched: { work in
                Task {
                    while let app = running(), !app.isFinishedLaunching {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    work()
                }
            },
            post: { name, object in HelperLink.post(name, object: object) },
            open: { app, arguments, activates in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = arguments
                configuration.activates = activates
                NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: nil)
            },
            postMounted: { paths, object in HelperLink.postMounted(paths, object: object) }
        )
    }
}
