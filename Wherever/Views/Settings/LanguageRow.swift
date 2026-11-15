import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable {
    case system, en, tr, de, fr, es, ru, nl, ja, zhHans = "zh-Hans", ar, pl

    static let key = "appLanguage"
    static let appleKey = HelperLink.Key.appleLanguages
    static let launched = stored(.standard)

    static func stored(_ defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var name: Text {
        switch self {
        case .system: Text("System Default", tableName: "Settings")
        case .en: Text(verbatim: "English")
        case .tr: Text(verbatim: "Türkçe")
        case .de: Text(verbatim: "Deutsch")
        case .fr: Text(verbatim: "Français")
        case .es: Text(verbatim: "Español")
        case .ru: Text(verbatim: "Русский")
        case .nl: Text(verbatim: "Nederlands")
        case .ja: Text(verbatim: "日本語")
        case .zhHans: Text(verbatim: "简体中文")
        case .ar: Text(verbatim: "العربية")
        case .pl: Text(verbatim: "Polski")
        }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.key)
        if self == .system {
            defaults.removeObject(forKey: Self.appleKey)
        } else {
            defaults.set([rawValue], forKey: Self.appleKey)
        }
    }
}

struct LanguageRow: View {
    static let id = "general-language"

    let defaults: UserDefaults
    let launched: AppLanguage
    let reopen: @MainActor () throws -> Void
    @State private var selection: AppLanguage
    @State private var asking = false
    @State private var failed = false
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    init(defaults: UserDefaults, launched: AppLanguage = .launched, reopen: @escaping @MainActor () throws -> Void) {
        self.defaults = defaults
        self.launched = launched
        self.reopen = reopen
        _selection = State(initialValue: AppLanguage.stored(defaults))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
            Picker(selection: Binding(get: { selection }, set: { new in
                selection = new
                new.save(to: defaults)
                asking = new != launched
            })) {
                ForEach(AppLanguage.allCases, id: \.self) { $0.name.font(textSize.formText).tag($0) }
            } label: {
                Text("Language", tableName: "Settings").font(textSize.formLabel)
            }
            .pickerStyle(.menu)
            .accessibilityLabel(Text("Language", tableName: "Settings"))
            .accessibilityIdentifier(Self.id)
            if selection != launched {
                Text("The language change will take effect after restarting Wherever.", tableName: "Settings")
                    .font(textSize.caption).foregroundStyle(.secondary)
            }
            if failed {
                Text("Wherever could not reopen. The settings are saved and take effect when you quit and reopen Wherever.", tableName: "Settings")
                    .font(textSize.caption).foregroundStyle(Color(nsColor: Theme.problem))
            }
        }
        .alert(Text("Restart Wherever?", tableName: "Settings"), isPresented: $asking) {
            Button { restart() } label: { Text("Restart Now", tableName: "Settings") }
                .accessibilityIdentifier("general-language-restart")
            Button(role: .cancel) {} label: { Text("Later", tableName: "Settings") }
                .accessibilityIdentifier("general-language-later")
        } message: {
            Text("The language change will take effect after restarting Wherever.", tableName: "Settings")
        }
    }

    private func restart() {
        ArchiveEdits.resolve { saved in
            guard saved else { return }
            do {
                try reopen()
                failed = false
            } catch {
                failed = true
            }
        }
    }
}
