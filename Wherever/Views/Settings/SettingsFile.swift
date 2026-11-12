import AppKit
import Foundation
import UniformTypeIdentifiers

enum SettingsFile {
    enum Refusal: Error { case newer, unreadable }

    static let format = 1
    static let maxBytes = 1_000_000

    private struct Field {
        let name: String
        let key: String
        let read: (UserDefaults) -> Any
        let parse: (Any) -> Any?
    }

    private static let fields: [Field] = [
        choice("theme", Theme.key, Theme.systemNative.rawValue) { Theme(rawValue: $0)?.rawValue },
        Field(name: "textSize", key: TextSize.key, read: { TextSize.stored($0).rawValue }, parse: { integer($0).flatMap(TextSize.init(rawValue:))?.rawValue }),
        choice("mode", WindowMode.key, WindowMode.simple.rawValue) { WindowMode(rawValue: $0)?.rawValue },
        flag("inspectorShown", InspectorPane.shownKey, false),
        flag("menuBarIcon", MenuBarIcon.key, MenuBarIcon.standard),
        flag("hidesInvisibleFiles", SearchFilters.hidesHiddenKey, false),
        list("columns", ColumnPreferences.shownKey, source: { $0.stringArray(forKey: ColumnPreferences.shownKey) ?? ResultsTable.Column.defaults.map(\.rawValue) }) {
            ResultsTable.Column(rawValue: $0)?.rawValue
        },
        flag("foldersFirst", ColumnPreferences.foldersFirstKey, false),
        shortcut,
        list("excludedPaths", LocationsModel.Key.excluded, source: { LocationsModel.stored($0).excluded }, export: homeRelative) {
            let row = expandingHome($0)
            return LocationsModel.accepts(row) && !row.contains("\0") ? row : nil
        },
        list("indexedDisks", LocationsModel.Key.indexedVolumes, source: { LocationsModel.stored($0).indexedVolumes.sorted() }) {
            UUID(uuidString: $0)?.uuidString
        },
        choice("newDisk", NewDiskChoice.key, NewDiskChoice.statusBar.rawValue) { NewDiskChoice(rawValue: $0)?.rawValue },
        flag("typoTolerantSearch", TypoSearchRow.key, false),
        percent("launcherOpacity", Launcher.opacityKey, Launcher.standardOpacity),
        choice("appearance", AppearanceMode.key, AppearanceMode.system.rawValue) { AppearanceMode(rawValue: $0)?.rawValue },
        choice("language", AppLanguage.key, AppLanguage.system.rawValue) { AppLanguage(rawValue: $0)?.rawValue },
        flag("automaticUpdateChecks", UpdatesModel.automaticChecksKey, false),
    ]

    static func export(from defaults: UserDefaults) throws -> Data {
        var root: [String: Any] = ["format": format]
        for field in fields { root[field.name] = field.read(defaults) }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func read(_ url: URL) throws -> [String: Any] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try parse(try handle.read(upToCount: maxBytes + 1) ?? Data())
    }

    static func parse(_ data: Data) throws -> [String: Any] {
        guard data.count <= maxBytes, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = integer(root["format"]) else { throw Refusal.unreadable }
        guard version <= format else { throw Refusal.newer }
        guard version == format else { throw Refusal.unreadable }
        var values: [String: Any] = [:]
        for field in fields {
            guard let raw = root[field.name] else { continue }
            guard let stored = field.parse(raw) else { throw Refusal.unreadable }
            values[field.key] = stored
        }
        return values
    }

    static func apply(_ values: [String: Any], to defaults: UserDefaults) {
        for (key, value) in values { defaults.set(value, forKey: key) }
        if values[AppLanguage.key] != nil { AppLanguage.stored(defaults).save(to: defaults) }
    }

    private static func boolean(_ raw: Any) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, boolean(number) == nil, number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    private static func flag(_ name: String, _ key: String, _ fallback: Bool) -> Field {
        Field(name: name, key: key, read: { $0.object(forKey: key).flatMap(boolean) ?? fallback }, parse: { boolean($0) })
    }

    private static func percent(_ name: String, _ key: String, _ fallback: Int) -> Field {
        let valid = { (raw: Any?) in integer(raw).flatMap { (0...100).contains($0) ? $0 : nil } }
        return Field(name: name, key: key, read: { valid($0.object(forKey: key)) ?? fallback }, parse: { valid($0) })
    }

    private static func choice(_ name: String, _ key: String, _ fallback: String, _ normalise: @escaping (String) -> String?) -> Field {
        Field(name: name, key: key, read: { $0.string(forKey: key).flatMap(normalise) ?? fallback }, parse: { ($0 as? String).flatMap(normalise) })
    }

    private static func list(
        _ name: String, _ key: String, source: @escaping (UserDefaults) -> [String], export: @escaping (String) -> String = { $0 },
        _ normalise: @escaping (String) -> String?
    ) -> Field {
        Field(
            name: name, key: key, read: { source($0).compactMap(normalise).map(export) },
            parse: { raw in
                guard let items = raw as? [Any] else { return nil }
                let kept = items.compactMap { ($0 as? String).flatMap(normalise) }
                return kept.count == items.count ? kept : nil
            }
        )
    }

    nonisolated private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    nonisolated private static func homeRelative(_ row: String) -> String {
        let home = home
        if row == home { return "~" }
        return row.hasPrefix(home + "/") ? "~" + row.dropFirst(home.count) : row
    }

    nonisolated private static func expandingHome(_ row: String) -> String {
        if row == "~" { return home }
        return row.hasPrefix("~/") ? home + row.dropFirst() : row
    }

    private static func storedHotkey(_ defaults: UserDefaults) -> Hotkey? {
        guard let data = defaults.data(forKey: HotkeyModel.defaultsKey) else { return .summon }
        if data.isEmpty { return nil }
        guard let stored = try? JSONDecoder().decode(Hotkey.self, from: data), stored.refusal == nil else { return .summon }
        return stored
    }

    private static let shortcut = Field(
        name: "shortcut", key: HotkeyModel.defaultsKey,
        read: { defaults in
            guard let hotkey = storedHotkey(defaults) else { return NSNull() }
            return ["keyCode": hotkey.keyCode, "modifiers": hotkey.modifiers, "character": hotkey.character] as [String: Any]
        },
        parse: { raw in
            if raw is NSNull { return Data() }
            guard let object = raw as? [String: Any], let json = try? JSONSerialization.data(withJSONObject: object),
                  let hotkey = try? JSONDecoder().decode(Hotkey.self, from: json), hotkey.refusal == nil else { return nil }
            return try? JSONEncoder().encode(hotkey)
        }
    )
}

struct SettingsFileIO {
    var saveURL: @MainActor () -> URL? = SettingsFileIO.savePanel
    var openURL: @MainActor () -> URL? = SettingsFileIO.openPanel
    var defaults: UserDefaults = .standard
    var reopen: @MainActor () throws -> Void = {}

    @MainActor static func savePanel() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "Wherever Settings", table: "Settings") + ".json"
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Import", table: "Settings")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
