import AppKit

final class HelperHotkey {
    private let registrar = HotkeyRegistrar()
    private let shortcut: HelperShortcut

    init(sender: HelperSender, helper: URL) {
        let registrar = registrar
        let shortcut = HelperShortcut(
            sender: sender,
            helperPath: helper.path,
            defaults: UserDefaults(suiteName: HelperLink.whereverID) ?? .standard,
            own: .standard,
            register: { registrar.register($0) },
            unregister: { registrar.unregister() },
            report: { HelperLink.post($0, object: helper.path) }
        )
        registrar.onPress = { shortcut.pressed() }
        self.shortcut = shortcut
    }
}
