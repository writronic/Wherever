import AppKit
import Foundation
import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    static let key = "appearanceMode"

    static func stored(_ defaults: UserDefaults) -> AppearanceMode {
        defaults.string(forKey: key).flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    func title(_ bundle: Bundle) -> String {
        switch self {
        case .system: String(localized: "System", table: "Settings", bundle: bundle)
        case .light: String(localized: "Light", table: "Settings", bundle: bundle)
        case .dark: String(localized: "Dark", table: "Settings", bundle: bundle)
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static func applyToApp(_ appearance: NSAppearance?) { NSApplication.shared.appearance = appearance }

    static func applyStored(from defaults: UserDefaults, apply: (NSAppearance?) -> Void = { AppearanceMode.applyToApp($0) }) {
        apply(stored(defaults).appearance)
    }
}

struct AppearanceRow: View {
    static let id = "general-appearance"

    let defaults: UserDefaults
    let apply: (NSAppearance?) -> Void
    @State private var mode: AppearanceMode
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @Environment(\.locale) private var locale

    init(defaults: UserDefaults, apply: @escaping (NSAppearance?) -> Void = { AppearanceMode.applyToApp($0) }) {
        self.defaults = defaults
        self.apply = apply
        _mode = State(initialValue: AppearanceMode.stored(defaults))
    }

    var body: some View {
        LabeledContent {
            AppearanceSegments(selection: Binding(get: { mode }, set: { new in
                mode = new
                defaults.set(new.rawValue, forKey: AppearanceMode.key)
                apply(new.appearance)
            }), textSize: textSize, bundle: Self.bundle(locale))
        } label: {
            Text("Appearance", tableName: "Settings").font(textSize.formLabel)
        }
    }

    static func bundle(_ locale: Locale) -> Bundle {
        guard locale.identifier != Locale.current.identifier,
              let name = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: [locale.identifier]).first,
              let url = Bundle.main.url(forResource: name, withExtension: "lproj"), let bundle = Bundle(url: url) else { return .main }
        return bundle
    }
}

private struct AppearanceSegments: NSViewRepresentable {
    @Binding var selection: AppearanceMode
    let textSize: TextSize
    let bundle: Bundle

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: AppearanceMode.allCases.map { $0.title(bundle) }, trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.changed(_:))
        )
        control.identifier = NSUserInterfaceItemIdentifier(AppearanceRow.id)
        control.setAccessibilityIdentifier(AppearanceRow.id)
        control.cell?.setAccessibilityIdentifier(AppearanceRow.id)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let font = textSize.font(.messageFont(ofSize: 0))
        if control.font != font { control.font = font }
        for (index, mode) in AppearanceMode.allCases.enumerated() where control.label(forSegment: index) != mode.title(bundle) {
            control.setLabel(mode.title(bundle), forSegment: index)
        }
        control.selectedSegment = AppearanceMode.allCases.firstIndex(of: selection) ?? 0
        let label = String(localized: "Appearance", table: "Settings", bundle: bundle)
        control.setAccessibilityLabel(label)
        control.cell?.setAccessibilityLabel(label)
    }

    final class Coordinator: NSObject {
        var selection: Binding<AppearanceMode>

        init(selection: Binding<AppearanceMode>) { self.selection = selection }

        @objc func changed(_ control: NSSegmentedControl) {
            guard AppearanceMode.allCases.indices.contains(control.selectedSegment) else { return }
            selection.wrappedValue = AppearanceMode.allCases[control.selectedSegment]
        }
    }
}
