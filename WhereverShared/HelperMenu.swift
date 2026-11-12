import AppKit
import Foundation

enum HelperMenu {
    enum Click: Equatable { case launcher, menu }

    enum Item: String, CaseIterable {
        case liveUpdates, openWherever, settings, shortcuts, quit

        var id: String { "menubar-\(rawValue)" }

        func title(in bundle: Bundle) -> String {
            switch self {
            case .liveUpdates: NSLocalizedString("Live Updates", tableName: "MenuBar", bundle: bundle, comment: "")
            case .openWherever: NSLocalizedString("Open Wherever", tableName: "MenuBar", bundle: bundle, comment: "")
            case .settings: NSLocalizedString("Settings…", tableName: "MenuBar", bundle: bundle, comment: "")
            case .shortcuts: NSLocalizedString("Keyboard Shortcuts", tableName: "Help", bundle: bundle, comment: "")
            case .quit: NSLocalizedString("Quit Wherever", tableName: "MenuBar", bundle: bundle, comment: "")
            }
        }
    }

    static let buttonID = "menubar-icon"

    static let layout: [Item?] = [.liveUpdates, nil, .openWherever, .settings, .shortcuts, nil, .quit]

    static func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Click {
        switch type {
        case .rightMouseUp, .rightMouseDown: .menu
        case .leftMouseUp where modifiers.contains(.control): .menu
        default: .launcher
        }
    }

    static func languages(in defaults: UserDefaults, domain: String = HelperLink.whereverID) -> [String] {
        let stored = defaults.persistentDomain(forName: domain)?[HelperLink.Key.appleLanguages] as? [String] ?? []
        return stored.isEmpty ? Locale.preferredLanguages : stored
    }

    static func localization(of parent: URL, languages: [String]) -> Bundle {
        guard let app = Bundle(url: parent) else { return .main }
        return Bundle.preferredLocalizations(from: app.localizations, forPreferences: languages).lazy
            .compactMap { app.url(forResource: $0, withExtension: "lproj").flatMap(Bundle.init(url:)) }.first ?? app
    }

    static func direction(of bundle: Bundle) -> NSUserInterfaceLayoutDirection {
        let folder = bundle.bundleURL
        let language = folder.pathExtension == "lproj" ? folder.deletingPathExtension().lastPathComponent : bundle.developmentLocalization ?? "en"
        return Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    static func label(in bundle: Bundle) -> String {
        NSLocalizedString("Wherever", tableName: "MenuBar", bundle: bundle, comment: "")
    }

    static func icon(of parent: URL) -> NSImage? {
        let image = Bundle(url: parent)?.image(forResource: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }

    static func isLive(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: HelperLink.Key.liveUpdatesPaused)
    }

    static func wantsItem(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: HelperLink.Key.showMenuBarIcon) as? Bool ?? true
    }

    static func exitOnQuit(parent: URL, exit: @escaping () -> Void) -> HelperObservation {
        HelperLink.observe(HelperLink.Note.helperQuit, object: parent.path, handler: exit)
    }
}

final class HelperMenuActions: NSObject {
    private let sender: HelperSender
    private let defaults: UserDefaults
    private let exit: () -> Void

    init(sender: HelperSender, defaults: UserDefaults, exit: @escaping () -> Void) {
        self.sender = sender
        self.defaults = defaults
        self.exit = exit
    }

    func menu(languages: [String]) -> NSMenu {
        let bundle = HelperMenu.localization(of: sender.parent, languages: languages)
        let menu = NSMenu()
        menu.userInterfaceLayoutDirection = HelperMenu.direction(of: bundle)
        for item in HelperMenu.layout {
            guard let item else {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: item.title(in: bundle), action: #selector(fire(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.rawValue
            entry.identifier = NSUserInterfaceItemIdentifier(item.id)
            if item == .liveUpdates { entry.state = HelperMenu.isLive(in: defaults) ? .on : .off }
            menu.addItem(entry)
        }
        return menu
    }

    @objc func fire(_ menuItem: NSMenuItem) {
        guard let item = (menuItem.representedObject as? String).flatMap(HelperMenu.Item.init(rawValue:)) else { return }
        switch item {
        case .liveUpdates:
            defaults.set(menuItem.state == .on, forKey: HelperLink.Key.liveUpdatesPaused)
            HelperLink.synchronize()
            sender.send(.liveUpdates)
        case .openWherever: sender.openWherever()
        case .settings: sender.send(.settings)
        case .shortcuts: sender.send(.shortcuts)
        case .quit: if !sender.send(.quit) { exit() }
        }
    }
}

final class HelperItemController {
    private let defaults: UserDefaults
    private let install: () -> Void
    private let remove: () -> Void
    private let exit: () -> Void
    private(set) var installed = false

    init(defaults: UserDefaults, install: @escaping () -> Void, remove: @escaping () -> Void, exit: @escaping () -> Void) {
        self.defaults = defaults
        self.install = install
        self.remove = remove
        self.exit = exit
    }

    func refresh() {
        let wanted = HelperMenu.wantsItem(in: defaults)
        guard wanted != installed else { return }
        installed = wanted
        if wanted { install() } else { remove() }
    }

    func removedByUser() {
        guard installed else { return }
        defaults.set(false, forKey: HelperLink.Key.showMenuBarIcon)
        HelperLink.synchronize()
        refresh()
        if !HelperLink.shouldRun(in: defaults) { exit() }
    }
}
