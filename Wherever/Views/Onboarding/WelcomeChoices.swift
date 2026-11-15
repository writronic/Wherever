import Foundation

struct WelcomeChoices: Equatable {
    var mode: WindowMode
    var launcher: Bool
    var menuBarIcon: Bool
    var menuBarIconMoved = false
    var theme: Theme
}

struct WelcomeTools {
    let commandLine: CommandLineToolModel
    let launcherIsOn: @MainActor () -> Bool
    let shortcut: @MainActor () -> String
    let applyLauncher: @MainActor (Bool) -> Void

    static func inert() -> WelcomeTools {
        WelcomeTools(commandLine: .inert(), launcherIsOn: { true }, shortcut: { Hotkey.summon.displayString }, applyLauncher: { _ in })
    }

    static func live(commandLine: CommandLineToolModel, hotkey: HotkeyModel) -> WelcomeTools {
        WelcomeTools(
            commandLine: commandLine,
            launcherIsOn: { hotkey.hotkey != nil },
            shortcut: { (hotkey.hotkey ?? .summon).displayString },
            applyLauncher: { on in
                if !on {
                    hotkey.set(nil)
                } else if hotkey.hotkey == nil {
                    hotkey.set(.summon)
                }
            }
        )
    }
}
