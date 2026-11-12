import AppKit
import Carbon
import Foundation
import Testing
@testable import Wherever

private func freshSuite(_ name: String) -> UserDefaults {
    let domain = "com.writronic.wherever.tests.settingsfile.\(name)"
    let defaults = UserDefaults(suiteName: domain)!
    defaults.removePersistentDomain(forName: domain)
    return defaults
}

private func languageOverride(_ name: String) -> [String]? {
    UserDefaults.standard.persistentDomain(forName: "com.writronic.wherever.tests.settingsfile.\(name)")?[AppLanguage.appleKey] as? [String]
}

private let controlOptionK = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), character: "K")
private let disk = "5F2A6C3E-0B1D-4C7A-9E58-2D4B7A91C0E3"

private func fillAwayFromDefaults(_ defaults: UserDefaults) throws {
    defaults.set(Theme.midnightTeal.rawValue, forKey: Theme.key)
    defaults.set(16, forKey: TextSize.key)
    defaults.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
    defaults.set(true, forKey: InspectorPane.shownKey)
    defaults.set(false, forKey: MenuBarIcon.key)
    defaults.set(true, forKey: SearchFilters.hidesHiddenKey)
    defaults.set(["name", "created", "opened"], forKey: ColumnPreferences.shownKey)
    defaults.set(true, forKey: ColumnPreferences.foldersFirstKey)
    defaults.set(try JSONEncoder().encode(controlOptionK), forKey: HotkeyModel.defaultsKey)
    defaults.set(["/Users/you/Movies/Raw", "/private/tmp", "\(disk)/Footage/Proxies"], forKey: LocationsModel.Key.excluded)
    defaults.set([disk], forKey: LocationsModel.Key.indexedVolumes)
    defaults.set(NewDiskChoice.notification.rawValue, forKey: NewDiskChoice.key)
    defaults.set(true, forKey: TypoSearchRow.key)
    defaults.set(80, forKey: Launcher.opacityKey)
    defaults.set(AppearanceMode.dark.rawValue, forKey: AppearanceMode.key)
    defaults.set(AppLanguage.tr.rawValue, forKey: AppLanguage.key)
    defaults.set(true, forKey: UpdatesModel.automaticChecksKey)
}

private let fileKeys = [
    Theme.key, WindowMode.key, InspectorPane.shownKey, SearchFilters.hidesHiddenKey, ColumnPreferences.shownKey,
    ColumnPreferences.foldersFirstKey, HotkeyModel.defaultsKey, LocationsModel.Key.excluded,
    LocationsModel.Key.indexedVolumes, NewDiskChoice.key, TypoSearchRow.key, AppearanceMode.key, AppLanguage.key,
    UpdatesModel.automaticChecksKey, Launcher.opacityKey, TextSize.key, MenuBarIcon.key,
]

private let home = FileManager.default.homeDirectoryForCurrentUser.path

private func json(_ text: String) -> String {
    String(decoding: (try? JSONEncoder().encode(text)) ?? Data(), as: UTF8.self)
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func parse(_ json: String) throws -> [String: Any] {
    try SettingsFile.parse(Data(json.utf8))
}

@Suite struct SettingsFileTests {
    @Test func everyKeyRoundTrips() throws {
        let source = freshSuite("roundtrip.source")
        let target = freshSuite("roundtrip.target")
        try fillAwayFromDefaults(source)
        let values = try SettingsFile.parse(SettingsFile.export(from: source))
        #expect(Set(values.keys) == Set(fileKeys))
        SettingsFile.apply(values, to: target)
        #expect(target.string(forKey: Theme.key) == "midnightTeal")
        #expect(target.object(forKey: TextSize.key) as? Int == 16)
        #expect(target.string(forKey: WindowMode.key) == "normal")
        #expect(target.object(forKey: InspectorPane.shownKey) as? Bool == true)
        #expect(target.object(forKey: "showMenuBarIcon") as? Bool == false)
        #expect(target.object(forKey: SearchFilters.hidesHiddenKey) as? Bool == true)
        #expect(target.stringArray(forKey: ColumnPreferences.shownKey) == ["name", "created", "opened"])
        #expect(target.object(forKey: ColumnPreferences.foldersFirstKey) as? Bool == true)
        let stored = try #require(target.data(forKey: HotkeyModel.defaultsKey))
        #expect(try JSONDecoder().decode(Hotkey.self, from: stored) == controlOptionK)
        #expect(target.stringArray(forKey: LocationsModel.Key.excluded) == ["/Users/you/Movies/Raw", "/private/tmp", "\(disk)/Footage/Proxies"])
        #expect(target.stringArray(forKey: LocationsModel.Key.indexedVolumes) == [disk])
        #expect(target.string(forKey: NewDiskChoice.key) == "notification")
        #expect(target.object(forKey: TypoSearchRow.key) as? Bool == true)
        #expect(target.object(forKey: Launcher.opacityKey) as? Int == 80)
        #expect(target.string(forKey: AppearanceMode.key) == "dark")
        #expect(target.string(forKey: AppLanguage.key) == "tr")
        #expect(languageOverride("roundtrip.target") == ["tr"])
        #expect(UpdatesModel.automaticChecksKey == "SUEnableAutomaticChecks")
        #expect(target.object(forKey: "SUEnableAutomaticChecks") as? Bool == true)
    }

    @Test func theSystemLanguageRemovesTheOverride() throws {
        let target = freshSuite("language.system")
        target.set(["tr"], forKey: AppLanguage.appleKey)
        SettingsFile.apply(try parse(#"{"format": 1, "language": "system"}"#), to: target)
        #expect(target.string(forKey: AppLanguage.key) == "system")
        #expect(languageOverride("language.system") == nil)
    }

    @Test func aFileWithoutALanguageLeavesTheOverrideAlone() throws {
        let target = freshSuite("language.absent")
        target.set(["de"], forKey: AppLanguage.appleKey)
        SettingsFile.apply(try parse(#"{"format": 1, "theme": "warmPaper"}"#), to: target)
        #expect(languageOverride("language.absent") == ["de"])
        #expect(target.object(forKey: AppLanguage.key) == nil)
    }

    @Test func noShortcutRoundTripsAsNull() throws {
        let source = freshSuite("null.source")
        let target = freshSuite("null.target")
        source.set(Data(), forKey: HotkeyModel.defaultsKey)
        let file = try SettingsFile.export(from: source)
        let root = try object(file)
        #expect(root["shortcut"] is NSNull)
        let values = try SettingsFile.parse(file)
        SettingsFile.apply(values, to: target)
        #expect(target.data(forKey: HotkeyModel.defaultsKey) == Data())
    }

    @Test func anEmptySuiteExportsTheDefaults() throws {
        let root = try object(SettingsFile.export(from: freshSuite("defaults")))
        #expect(root["format"] as? Int == 1)
        #expect(root["theme"] as? String == "systemNative")
        #expect(root["textSize"] as? Int == 13)
        #expect(root["mode"] as? String == "simple")
        #expect(root["inspectorShown"] as? Bool == false)
        #expect(root["menuBarIcon"] as? Bool == true)
        #expect(root["hidesInvisibleFiles"] as? Bool == false)
        #expect(root["columns"] as? [String] == ResultsTable.Column.defaults.map(\.rawValue))
        #expect(root["foldersFirst"] as? Bool == false)
        let shortcut = try #require(root["shortcut"] as? [String: Any])
        #expect(shortcut["keyCode"] as? Int == kVK_ANSI_F && shortcut["character"] as? String == "F")
        let paths = try #require(root["excludedPaths"] as? [String])
        #expect(paths == [
            "~/Library/CloudStorage", "~/Library/Biome", "~/Library/Caches", "~/Library/Logs", "~/Library/Metadata",
            "/Library/Caches", "/System/Library/Caches", "/private/var", "/private/tmp",
        ])
        #expect(!paths.contains { $0.hasPrefix(home) })
        #expect(root["indexedDisks"] as? [String] == [])
        #expect(root["newDisk"] as? String == "statusBar")
        #expect(root["typoTolerantSearch"] as? Bool == false)
        #expect(root["launcherOpacity"] as? Int == 30)
        #expect(root["appearance"] as? String == "system")
        #expect(root["language"] as? String == "system")
        #expect(root["automaticUpdateChecks"] as? Bool == false)
    }

    @Test func exportLeavesOutWelcomeFramesAndSparkle() throws {
        let defaults = freshSuite("leftout")
        try fillAwayFromDefaults(defaults)
        let left = [
            "welcomeCompleted", "NSWindow Frame main-AppWindow-1", "NSStatusItem VisibleCC Item-0", "SUHasLaunchedBefore", Relaunch.pendingKey,
            CommandLineToolModel.key,
        ]
        for key in left { defaults.set(true, forKey: key) }
        let file = try SettingsFile.export(from: defaults)
        let names = Set(try object(file).keys)
        #expect(names == [
            "format", "theme", "mode", "inspectorShown", "hidesInvisibleFiles", "columns", "foldersFirst", "shortcut",
            "excludedPaths", "indexedDisks", "newDisk", "typoTolerantSearch", "appearance", "language",
            "automaticUpdateChecks", "launcherOpacity", "textSize", "menuBarIcon",
        ])
        let text = String(decoding: file, as: UTF8.self)
        for key in left { #expect(!text.contains(key)) }
        let written = Set(try SettingsFile.parse(file).keys)
        #expect(written == Set(fileKeys))
    }

    @Test func anImportedCommandLineChoiceChangesNothing() throws {
        let target = freshSuite("commandline")
        let values = try parse(#"{"format": 1, "theme": "warmPaper", "commandLineTool": true}"#)
        #expect(values[CommandLineToolModel.key] == nil)
        SettingsFile.apply(values, to: target)
        #expect(target.object(forKey: CommandLineToolModel.key) == nil)
        #expect(target.string(forKey: Theme.key) == "warmPaper")
    }

    @Test func importAsksBeforeApplying() async throws {
        final class Calls {
            var reopens = 0
            var failures = 0
        }
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        let defaults = freshSuite("unsaved")
        defaults.set(Theme.midnightTeal.rawValue, forKey: Theme.key)
        let calls = Calls()
        let files = SettingsFileIO(saveURL: { nil }, openURL: { nil }, defaults: defaults, reopen: { calls.reopens += 1 })
        let values = try parse(#"{"format": 1, "theme": "warmPaper"}"#)

        SettingsFileRows.importSettings(values, files: files) { calls.failures += 1 }
        _ = try await rig.question(on: window)
        #expect(defaults.string(forKey: Theme.key) == "midnightTeal" && calls.reopens == 0)
        try await rig.press(ArchiveWindows.unsavedCancelID, on: window)
        try await rig.answered(window)
        try await pumpEvents(for: .milliseconds(50))
        #expect(defaults.string(forKey: Theme.key) == "midnightTeal" && calls.reopens == 0 && calls.failures == 0)
        #expect(window.isVisible && window.isDocumentEdited)

        SettingsFileRows.importSettings(values, files: files) { calls.failures += 1 }
        try await rig.press(ArchiveWindows.unsavedDontSaveID, on: window)
        try await untilTrue(waitingFor: "the import after Don’t Save") { calls.reopens == 1 }
        #expect(defaults.string(forKey: Theme.key) == "warmPaper" && calls.failures == 0)
        #expect(rig.bytes() == UnsavedArchives.original)
    }

    @Test func aNewerFormatIsRefusedAndWritesNothing() throws {
        let defaults = freshSuite("newer")
        let before = defaults.dictionaryRepresentation().keys.sorted()
        for json in [#"{"format": 2, "theme": "warmPaper"}"#, #"{"format": 2, "theme": "nonsense"}"#, #"{"format": 9007199254740}"#] {
            #expect(throws: SettingsFile.Refusal.newer) { try parse(json) }
        }
        #expect(defaults.dictionaryRepresentation().keys.sorted() == before)
    }

    @Test(arguments: [
        ("a bad theme", #"{"format": 1, "mode": "normal", "theme": "neon"}"#),
        ("a bad mode", #"{"format": 1, "theme": "warmPaper", "mode": "expert"}"#),
        ("a bad new-disk choice", #"{"format": 1, "theme": "warmPaper", "newDisk": "always"}"#),
        ("an unknown column", #"{"format": 1, "theme": "warmPaper", "columns": ["name", "weight"]}"#),
        ("a column that is not text", #"{"format": 1, "theme": "warmPaper", "columns": ["name", 3]}"#),
        ("a refused hotkey", #"{"format": 1, "theme": "warmPaper", "shortcut": {"keyCode": 3, "modifiers": 0, "character": "F"}}"#),
        ("a hotkey missing a field", #"{"format": 1, "theme": "warmPaper", "shortcut": {"keyCode": 3}}"#),
        ("a relative path", #"{"format": 1, "theme": "warmPaper", "excludedPaths": ["/ok", "Library/Caches"]}"#),
        ("a path with a NUL", #"{"format": 1, "theme": "warmPaper", "excludedPaths": ["/ok\u0000/x"]}"#),
        ("a disk path that climbs out", #"{"format": 1, "theme": "warmPaper", "excludedPaths": ["5F2A6C3E-0B1D-4C7A-9E58-2D4B7A91C0E3/../x"]}"#),
        ("a disk that is not a UUID", #"{"format": 1, "theme": "warmPaper", "indexedDisks": ["Disk 1"]}"#),
        ("a bad appearance", #"{"format": 1, "theme": "warmPaper", "appearance": "purple"}"#),
        ("a bad language", #"{"format": 1, "theme": "warmPaper", "language": "klingon"}"#),
        ("text for the update switch", #"{"format": 1, "theme": "warmPaper", "automaticUpdateChecks": "yes"}"#),
        ("text for the typo switch", #"{"format": 1, "theme": "warmPaper", "typoTolerantSearch": "yes"}"#),
        ("text for the menu bar icon", #"{"format": 1, "theme": "warmPaper", "menuBarIcon": "yes"}"#),
        ("a number for the menu bar icon", #"{"format": 1, "theme": "warmPaper", "menuBarIcon": 1}"#),
        ("text for the opacity", #"{"format": 1, "theme": "warmPaper", "launcherOpacity": "80"}"#),
        ("true for the opacity", #"{"format": 1, "theme": "warmPaper", "launcherOpacity": true}"#),
        ("an opacity above 100", #"{"format": 1, "theme": "warmPaper", "launcherOpacity": 101}"#),
        ("an opacity below 0", #"{"format": 1, "theme": "warmPaper", "launcherOpacity": -1}"#),
        ("an opacity of 1.5", #"{"format": 1, "theme": "warmPaper", "launcherOpacity": 1.5}"#),
        ("null for the opacity", #"{"format": 1, "theme": "warmPaper", "launcherOpacity": null}"#),
        ("a text size above 18", #"{"format": 1, "theme": "warmPaper", "textSize": 99}"#),
        ("text for the text size", #"{"format": 1, "theme": "warmPaper", "textSize": "16"}"#),
        ("a text size of 13.5", #"{"format": 1, "theme": "warmPaper", "textSize": 13.5}"#),
        ("true for the text size", #"{"format": 1, "theme": "warmPaper", "textSize": true}"#),
        ("text for a bool", #"{"format": 1, "theme": "warmPaper", "inspectorShown": "true"}"#),
        ("a number for a bool", #"{"format": 1, "theme": "warmPaper", "foldersFirst": 1}"#),
        ("null for a bool", #"{"format": 1, "theme": "warmPaper", "inspectorShown": null}"#),
        ("a format that is text", #"{"format": "1", "theme": "warmPaper"}"#),
        ("a format that is true", #"{"format": true, "theme": "warmPaper"}"#),
        ("a format that is 1.5", #"{"format": 1.5, "theme": "warmPaper"}"#),
        ("a format of 0", #"{"format": 0, "theme": "warmPaper"}"#),
        ("no format", #"{"theme": "warmPaper"}"#),
        ("a top-level array", #"[{"format": 1}]"#),
        ("not JSON", "format = 1"),
        ("nothing", ""),
    ])
    func oneBadValueRefusesTheWholeFile(_ name: String, _ json: String) {
        #expect(throws: SettingsFile.Refusal.unreadable, "\(name)") { try parse(json) }
    }

    @Test func aFileOverOneMegabyteIsRefused() throws {
        let padding = String(repeating: " ", count: SettingsFile.maxBytes)
        #expect(throws: SettingsFile.Refusal.unreadable) { try parse(#"{"format": 1}"# + padding) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("settingsfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("big.json")
        try Data((#"{"format": 1}"# + padding).utf8).write(to: url)
        #expect(throws: SettingsFile.Refusal.unreadable) { try SettingsFile.read(url) }
    }

    @Test func unknownKeysAreIgnored() throws {
        let values = try parse(#"{"format": 1, "theme": "warmPaper", "color": "red", "welcomeCompleted": true, "future": {"a": [1]}}"#)
        #expect(values.count == 1 && values[Theme.key] as? String == "warmPaper")
    }

    @Test func anOldFileWithTheDockSwitchStillImportsWithoutIt() throws {
        let target = freshSuite("olddock")
        let values = try parse(#"{"format": 1, "theme": "warmPaper", "showsDockIcon": false}"#)
        #expect(values.count == 1 && values[Theme.key] as? String == "warmPaper")
        SettingsFile.apply(values, to: target)
        #expect(target.object(forKey: "showsDockIcon") == nil)
        #expect(target.string(forKey: Theme.key) == "warmPaper")
    }

    @Test func aMissingKeyKeepsTheCurrentValue() throws {
        let defaults = freshSuite("missing")
        try fillAwayFromDefaults(defaults)
        SettingsFile.apply(try parse(#"{"format": 1, "theme": "warmPaper"}"#), to: defaults)
        #expect(defaults.string(forKey: Theme.key) == "warmPaper")
        #expect(defaults.string(forKey: WindowMode.key) == "normal")
        #expect(defaults.stringArray(forKey: LocationsModel.Key.indexedVolumes) == [disk])
    }

    @Test func aDiskIdIsStoredAsTheUppercaseUUID() throws {
        let values = try parse(#"{"format": 1, "indexedDisks": ["\#(disk.lowercased())"]}"#)
        #expect(values[LocationsModel.Key.indexedVolumes] as? [String] == [disk])
    }

    @Test func homeRowsTravelAsTildePathsAndComeBackUnderThisHome() throws {
        let source = freshSuite("home.source")
        let other = "/Users/someone-else-\(UUID().uuidString)/Library/Caches"
        source.set([home + "/Movies/Raw", home, home + "X/Lookalike", other, "/private/tmp", "\(disk)/Footage"], forKey: LocationsModel.Key.excluded)
        let data = try SettingsFile.export(from: source)
        let written = try #require(try object(data)["excludedPaths"] as? [String])
        #expect(written == ["~/Movies/Raw", "~", home + "X/Lookalike", other, "/private/tmp", "\(disk)/Footage"])
        let values = try SettingsFile.parse(data)
        #expect(values[LocationsModel.Key.excluded] as? [String] == [home + "/Movies/Raw", home, home + "X/Lookalike", other, "/private/tmp", "\(disk)/Footage"])
    }

    @Test func aFileFromAnotherAccountKeepsThisAccountsHomeDefaults() throws {
        let rows = ["~/Library/CloudStorage", "~/Library/Biome", "~/Library/Caches", "~/Library/Logs", "~/Library/Metadata", "/private/tmp"]
        let values = try parse(#"{"format": 1, "excludedPaths": [\#(rows.map(json).joined(separator: ", "))]}"#)
        let target = freshSuite("home.target")
        SettingsFile.apply(values, to: target)
        let stored = LocationsModel.stored(target).excluded
        #expect(stored == ["CloudStorage", "Biome", "Caches", "Logs", "Metadata"].map { "\(home)/Library/\($0)" } + ["/private/tmp"])
        #expect(Array(stored.prefix(5)) == Array(LocationsModel.stored(freshSuite("home.defaults")).excluded.prefix(5)))
    }

    @Test func anOldFileWithAbsoluteHomePathsStillImportsAsWritten() throws {
        let rows = ["/Users/someone-else/Library/Caches", home + "/Library/Logs", "/private/var"]
        let values = try parse(#"{"format": 1, "excludedPaths": [\#(rows.map(json).joined(separator: ", "))]}"#)
        #expect(values[LocationsModel.Key.excluded] as? [String] == rows)
    }

    @Test(arguments: ["~someone/Library", "~", "Library/~/x", "~~/x"])
    func onlyATildeAloneOrBeforeASlashMeansThisHome(_ row: String) throws {
        let file = #"{"format": 1, "excludedPaths": [\#(json(row))]}"#
        if row == "~" {
            #expect(try parse(file)[LocationsModel.Key.excluded] as? [String] == [home])
        } else {
            #expect(throws: SettingsFile.Refusal.unreadable, "\(row)") { try parse(file) }
        }
    }
}
