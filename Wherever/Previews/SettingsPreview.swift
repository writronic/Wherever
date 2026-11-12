import ServiceManagement
import SwiftUI
import WhereverInterface

private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "com.writronic.wherever.previews.settings.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func general(_ status: SMAppService.Status, registerFails: Bool = false) -> some View {
    struct Refused: Error {}
    let model = LaunchAtLoginModel(
        readStatus: { status }, register: { if registerFails { throw Refused() } }, unregister: {},
        openLoginItems: {}
    )
    return GeneralPane(
        launchAtLogin: model,
        hotkey: HotkeyModel(defaults: freshDefaults("hotkey")),
        files: SettingsFileIO(saveURL: { nil }, openURL: { nil }, defaults: freshDefaults("files"))
    ).previewEnvironment().frame(width: SettingsWindow.Metrics.detailWidth)
        .task { if registerFails { await model.setEnabled(true) } }
}

#Preview("General off") { general(.notRegistered) }

#Preview("General on") { general(.enabled) }

#Preview("General needs approval") { general(.requiresApproval) }

#Preview("General not found") { general(.notFound) }

#Preview("General register failed") { general(.notRegistered, registerFails: true) }

private func locations(folders: [String]? = nil) -> some View {
    let defaults = freshDefaults("locations")
    if let folders { defaults.set(folders, forKey: LocationsModel.Key.excluded) }
    let model = LocationsModel(client: PreviewSearchClient(), defaults: defaults, chooseFolder: { nil })
    return LocationsPane(model: model).frame(width: SettingsWindow.Metrics.detailWidth)
}

#Preview("Locations with default paths") { locations() }
#Preview("Locations with two paths") { locations(folders: ["/Users/you/Library/Caches", "/Users/you/Movies/Raw"]) }
