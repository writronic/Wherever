import AppKit
import ObjectiveC

private final class StatusButton: NSStatusBarButton {
    override func accessibilityPerformShowMenu() -> Bool {
        (target as? HelperStatusItem)?.showMenu() ?? false
    }
}

final class HelperStatusItem: NSObject {
    private var defaults: UserDefaults?
    private var sender: HelperSender?
    private var actions: HelperMenuActions?
    private var controller: HelperItemController?
    private var item: NSStatusItem?
    private var visibility: NSKeyValueObservation?
    private var observations: [HelperObservation] = []

    func start() {
        let own = Bundle.main.bundleURL
        guard let parent = HelperLink.parent(ofHelperAt: own), let defaults = UserDefaults(suiteName: HelperLink.whereverID) else {
            NSApp.terminate(nil)
            return
        }
        let sender = HelperSender.live(parent: parent)
        let quit = { NSApp.terminate(nil) }
        self.defaults = defaults
        self.sender = sender
        actions = HelperMenuActions(sender: sender, defaults: defaults, exit: quit)
        controller = HelperItemController(
            defaults: defaults,
            install: { [unowned self] in self.installItem(parent: parent) },
            remove: { [unowned self] in self.removeItem() },
            exit: quit
        )
        observations = [
            HelperMenu.exitOnQuit(parent: parent, exit: quit),
            HelperLink.observe(HelperLink.Note.sync, object: own.path) { [unowned self] in
                HelperLink.synchronize()
                self.controller?.refresh()
            },
        ]
        HelperLink.synchronize()
        controller?.refresh()
    }

    private func installItem(parent: URL) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "WhereverHelper"
        item.behavior = .removalAllowed
        item.isVisible = true
        if let button = item.button, type(of: button) == NSStatusBarButton.self { object_setClass(button, StatusButton.self) }
        item.button?.image = HelperMenu.icon(of: parent)
        item.button?.setAccessibilityIdentifier(HelperMenu.buttonID)
        let bundle = HelperMenu.localization(of: parent, languages: defaults.map { HelperMenu.languages(in: $0) } ?? [])
        item.button?.setAccessibilityLabel(HelperMenu.label(in: bundle))
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        visibility = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor in self?.controller?.removedByUser() }
        }
        self.item = item
    }

    private func removeItem() {
        visibility = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent, let sender else { return }
        switch HelperMenu.click(event.type, modifiers: event.modifierFlags) {
        case .launcher: sender.send(.launcher)
        case .menu: showMenu()
        }
    }

    @discardableResult
    fileprivate func showMenu() -> Bool {
        guard let defaults, let actions, let item else { return false }
        HelperLink.synchronize()
        item.menu = actions.menu(languages: HelperMenu.languages(in: defaults))
        item.button?.performClick(nil)
        Task { @MainActor in item.menu = nil }
        return true
    }
}
