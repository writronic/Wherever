import Foundation

final class HelperCommands {
    var run: (HelperCommand, Bool) -> Void = { _, _ in }
    var mounted: ([String]) -> Void = { _ in }
    private var finished = false
    private var early: [HelperCommand] = []
    private var observations: [HelperObservation] = []

    static func startsHidden(_ command: HelperCommand?) -> Bool {
        command == .launcher || command == .serve || command == .wake
    }

    func observe(path: String) {
        observations = [HelperCommand.launcher, .settings, .shortcuts, .quit, .liveUpdates].map { command in
            HelperLink.observe(command.notification, object: path) { [weak self] in self?.receive(command) }
        } + [HelperLink.observeMounted(object: path) { [weak self] in self?.mounted($0) }]
    }

    func receive(_ command: HelperCommand) {
        if finished { run(command, false) } else { early.append(command) }
    }

    func finishLaunch(argument: HelperCommand?) {
        finished = true
        if let argument { run(argument, true) }
        early.forEach { run($0, false) }
        early = []
    }

    static func route(
        access: AccessModel, launch: Launch, menu: MenuBarActions, hotkey: @escaping @MainActor () -> Void,
        stop: @escaping () -> Void, activate: @escaping () -> Void, synchronize: @escaping () -> Void
    ) -> (HelperCommand, Bool) -> Void {
        { command, cold in
            switch command {
            case .launcher:
                let welcome = access.showsWelcome
                if cold {
                    access.openOrWelcome { launch.services?.launcher.show() }
                } else {
                    hotkey()
                }
                if welcome { activate() }
            case .settings:
                menu.showSettings()
                activate()
            case .shortcuts:
                menu.keyboardShortcuts()
                activate()
            case .quit:
                stop()
            case .liveUpdates:
                synchronize()
                launch.services?.index.followStoredPause()
            case .serve, .wake:
                break
            }
        }
    }
}
