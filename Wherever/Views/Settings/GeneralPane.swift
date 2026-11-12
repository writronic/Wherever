import AppKit
import ServiceManagement
import SwiftUI
import WhereverInterface

struct GeneralPane: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginModel
    @ObservedObject var hotkey: HotkeyModel
    var reset: @MainActor () async throws -> Void = {}
    var files = SettingsFileIO()
    var updates: UpdatesModel = .idle
    var commandLine: CommandLineToolModel = .inert()
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        Form {
            Section {
                WholeHeight { LaunchAtLoginRow(model: launchAtLogin) }
            } header: { Text("Startup", tableName: "Settings").font(textSize.formHeader) }
            Section {
                WholeHeight { MenuBarIconRow() }
            } header: { Text("Menu Bar", tableName: "Settings").font(textSize.formHeader) }
            Section {
                WholeHeight {
                    VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
                        LabeledContent {
                            HotkeyRecorder(model: hotkey)
                        } label: {
                            Text("Launcher shortcut", tableName: "Settings").font(textSize.formLabel)
                        }
                        Text("Press it in any app to search your files.", tableName: "Settings")
                            .font(textSize.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Shortcut", tableName: "Settings").font(textSize.formHeader) }
            Section {
                WholeHeight { CommandLineToolRow(model: commandLine) }
            } header: { Text("Command-Line Tool", tableName: "Settings").font(textSize.formHeader) }
            Section {
                WholeHeight { TypoSearchRow() }
            } header: { Text("Search", tableName: "Settings").font(textSize.formHeader) }
            Section {
                WholeHeight { AppearanceRow(defaults: files.defaults) }
                WholeHeight { ThemePicker() }
                WholeHeight { TextSizeRow() }
                WholeHeight { LauncherOpacityRow() }
                WholeHeight { InspectorSettingRow() }
            } header: { Text("Appearance", tableName: "Settings").font(textSize.formHeader) }
            Section {
                WholeHeight { LanguageRow(defaults: files.defaults, reopen: files.reopen) }
            } header: { Text("Language", tableName: "Settings").font(textSize.formHeader) }
            Section {
                WholeHeight { ClearOpenHistoryRow() }
            } header: { Text("Open History", tableName: "Settings").font(textSize.formHeader) }
            Section {
                WholeHeight { SoftwareUpdatesRows(model: updates) }
            } header: { Text("Software Updates", tableName: "Settings").font(textSize.formHeader) }
            Section {
                EmptyView()
            } header: {
                Text(verbatim: " ").font(textSize.formHeader).accessibilityHidden(true)
            } footer: {
                WholeHeight { SettingsFileRows(files: files) }
            }
            Section {
                WholeHeight { ResetRow(reset: reset) }
            } header: { Text("Reset Settings", tableName: "Settings").font(textSize.formHeader) }
        }
        .formStyle(.grouped)
    }
}

struct ClearOpenHistoryRow: View {
    @Environment(\.searchClient) private var client
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @State private var confirming = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
            HStack {
                Text("Files you open often rank higher in results.", tableName: "Settings").font(textSize.formLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { confirming = true } label: { Text("Clear Open History…", tableName: "Settings").font(textSize.formText) }
            }
            if failed {
                Text("Wherever could not clear the open history.", tableName: "Settings").font(textSize.caption).foregroundStyle(Color(nsColor: Theme.problem))
            }
        }
        .alert(Text("Clear open history?", tableName: "Settings"), isPresented: $confirming) {
            Button(role: .destructive) { clear() } label: { Text("Clear", tableName: "Settings") }
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "Settings") }
        } message: {
            Text("Wherever forgets which files you opened. Results no longer rank them higher.", tableName: "Settings")
        }
    }

    private func clear() {
        do {
            try client.clearOpens()
            failed = false
        } catch {
            failed = true
        }
    }
}

struct SettingsFileRows: View {
    enum Notice { case exportFailed, newer, unreadable, reopenFailed }

    let files: SettingsFileIO
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @State private var confirming = false
    @State private var pending: [String: Any] = [:]
    @State private var notice: Notice?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
            HStack(spacing: 10) {
                card(Text("Import Settings", tableName: "Settings"), id: "general-import-card") {
                    Button { choose() } label: { Text("Import…", tableName: "Settings").font(textSize.formText) }
                        .accessibilityLabel(Text("Import Settings…", tableName: "Settings"))
                        .accessibilityIdentifier("general-import")
                }
                card(Text("Export Settings", tableName: "Settings"), id: "general-export-card") {
                    Button { export() } label: { Text("Export…", tableName: "Settings").font(textSize.formText) }
                        .accessibilityLabel(Text("Export Settings…", tableName: "Settings"))
                        .accessibilityIdentifier("general-export")
                }
            }
            .font(textSize.body)
            .foregroundStyle(.primary)
            .padding(.horizontal, -10)
            switch notice {
            case .exportFailed: line { Text("Wherever could not export the settings.", tableName: "Settings") }
            case .newer: line { Text("This file is from a newer version of Wherever. Update Wherever, then try again.", tableName: "Settings") }
            case .unreadable: line { Text("Wherever could not read this settings file.", tableName: "Settings") }
            case .reopenFailed: line { Text("Wherever could not reopen. The settings are saved and take effect when you quit and reopen Wherever.", tableName: "Settings") }
            case nil: EmptyView()
            }
        }
        .alert(Text("Import settings?", tableName: "Settings"), isPresented: $confirming) {
            Button { apply() } label: { Text("Import", tableName: "Settings") }
            Button(role: .cancel) { pending = [:] } label: { Text("Cancel", tableName: "Settings") }
        } message: {
            Text("Wherever replaces your current settings with the ones in the file, then quits and reopens.", tableName: "Settings")
        }
    }

    private func card<Content: View>(_ label: Text, id: String, @ViewBuilder button: () -> Content) -> some View {
        GroupBox {
            HStack {
                label.frame(maxWidth: .infinity, alignment: .leading).accessibilityHidden(true)
                button()
            }
            .padding(5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }

    private func line(_ text: () -> Text) -> some View {
        text().font(textSize.caption).foregroundStyle(Color(nsColor: Theme.problem))
    }

    private func export() {
        guard let url = files.saveURL() else { return }
        do {
            try SettingsFile.export(from: files.defaults).write(to: url, options: .atomic)
            notice = nil
        } catch {
            notice = .exportFailed
        }
    }

    private func choose() {
        guard let url = files.openURL() else { return }
        do {
            pending = try SettingsFile.read(url)
            notice = nil
            confirming = true
        } catch SettingsFile.Refusal.newer {
            notice = .newer
        } catch {
            notice = .unreadable
        }
    }

    private func apply() {
        let chosen = pending
        pending = [:]
        Self.importSettings(chosen, files: files) { notice = .reopenFailed }
    }

    static func importSettings(_ chosen: [String: Any], files: SettingsFileIO, reopenFailed: @escaping () -> Void) {
        ArchiveEdits.resolve { saved in
            guard saved else { return }
            SettingsFile.apply(chosen, to: files.defaults)
            do { try files.reopen() } catch { reopenFailed() }
        }
    }
}

struct ResetRow: View {
    static let cornerRadius: CGFloat = 6

    let reset: @MainActor () async throws -> Void
    @State private var confirming = false
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
            HStack {
                Text("Reset all settings, saved indexes and open history (cannot be undone)", tableName: "Settings")
                    .font(textSize.formLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {} label: { label }
                    .hidden()
                    .accessibilityHidden(true)
                    .overlay {
                        Button { confirming = true } label: {
                            label.foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.red, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("general-reset")
                    }
            }
            if failed {
                Text("Wherever could not reset. Try again.", tableName: "Settings").font(textSize.caption).foregroundStyle(Color(nsColor: Theme.problem))
            }
        }
        .alert(Text("Reset All Settings?", tableName: "Settings"), isPresented: $confirming) {
            Button(role: .destructive) { Task { await run() } } label: { Text("Reset", tableName: "Settings") }
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "Settings") }
        } message: {
            Text(
                "Wherever deletes your settings, saved indexes, and open history, and turns off Open at Login. Then it quits and reopens. You can’t undo this action.",
                tableName: "Settings"
            )
        }
    }

    private var label: Text {
        Text("Reset", tableName: "Settings").font(textSize.font(size: NSFont.systemFontSize, weight: .medium))
    }

    private func run() async {
        do {
            try await reset()
            failed = false
        } catch {
            failed = true
        }
    }
}

struct LaunchAtLoginRow: View {
    @ObservedObject var model: LaunchAtLoginModel
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
            Toggle(isOn: Binding(get: { model.isOn }, set: { enabled in Task { await model.setEnabled(enabled) } })) {
                Text("Open at Login", tableName: "Settings").font(textSize.formLabel)
            }
            .toggleStyle(.switch)
            .disabled(model.busy)
            .accessibilityIdentifier("general-open-at-login")
            Text("Starts the menu bar icon and the launcher shortcut when you log in, as you set them below.", tableName: "Settings")
                .font(textSize.caption).foregroundStyle(.secondary)
            if model.failed {
                Text("Wherever could not change this. Check Login Items in System Settings.", tableName: "Settings")
                    .font(textSize.caption).foregroundStyle(Color(nsColor: Theme.problem))
            } else if model.status == .requiresApproval {
                Text("Allow Wherever in Login Items in System Settings.", tableName: "Settings")
                    .font(textSize.caption).foregroundStyle(.secondary)
            }
            if model.failed || model.status == .requiresApproval {
                Button { model.openLoginItemsSettings() } label: { Text("Open Login Items", tableName: "Settings").font(textSize.formText) }
                    .accessibilityIdentifier("general-login-items")
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }
}

struct MenuBarIconRow: View {
    var sync: () -> Void = { WhereverApp.helperStarter.sync() }
    @AppStorage(MenuBarIcon.key) private var shown = MenuBarIcon.standard
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
            Toggle(isOn: Binding(get: { shown }, set: { shown = $0; sync() })) {
                Text("Show Menu Bar Icon", tableName: "Settings").font(textSize.formLabel)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("general-show-menu-bar-icon")
            Text("Shows a Wherever icon in the menu bar. Click it to open the launcher, or right-click it for a menu. If it does not appear, open System Settings and look in the Menu Bar section.", tableName: "Settings")
                .font(textSize.caption).foregroundStyle(.secondary)
        }
    }
}

struct LauncherOpacityRow: View {
    static let id = "general-launcher-opacity"

    @AppStorage(Launcher.opacityKey) private var opacity = Launcher.standardOpacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
            LabeledContent {
                SliderColumn(minimum: SliderEnd.percent(0, textSize), maximum: SliderEnd.percent(100, textSize)) {
                    Slider(value: Binding(get: { Double(opacity) }, set: { opacity = Int($0.rounded()) }), in: 0...100) {
                        Text("Wherever search background opacity", tableName: "Settings")
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text("Wherever search background opacity", tableName: "Settings"))
                    .accessibilityValue(Text(opacity, format: .percent))
                    .accessibilityIdentifier(Self.id)
                }
            } label: {
                Text("Wherever search background opacity", tableName: "Settings").font(textSize.formLabel)
            }
            .disabled(reduceTransparency)
            if reduceTransparency {
                Text("Wherever search stays solid while Reduce transparency is on in System Settings > Accessibility.", tableName: "Settings")
                    .font(textSize.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TypoSearchRow: View {
    static let key = "typoTolerantSearch"

    @Environment(\.searchClient) private var client
    @AppStorage(TypoSearchRow.key) private var on = false
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
            Toggle(isOn: Binding(get: { on }, set: { on = $0; try? client.setTypoSearch($0) })) {
                Text("Typo-Tolerant Search", tableName: "Settings").font(textSize.formLabel)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("general-typo-tolerant-search")
            Text("When no name holds your letters side by side, also shows close matches, such as names with a typo.", tableName: "Settings")
                .font(textSize.caption).foregroundStyle(.secondary)
        }
    }
}
