import SwiftUI
import WhereverInterface

struct MenuBarActions {
    var summon: () -> Void
    var newWindow: () -> Void
    var showSettings: () -> Void
    var open: (URL) -> Void
    var quit: () -> Void
    var about: () -> Void = {}
    var keyboardShortcuts: () -> Void = {}

    func donate() { open(AppLinks.donate) }
}

struct DonateItems: View {
    let actions: MenuBarActions
    var updates: UpdatesModel = .idle

    var body: some View {
        Button(action: actions.donate) { Text("Donate…", tableName: "MenuBar") }
        CheckForUpdatesButton(model: updates)
    }
}

struct QuitItems: View {
    let actions: MenuBarActions

    var body: some View {
        Button(action: actions.quit) { Text("Quit Wherever", tableName: "MenuBar") }
            .keyboardShortcut("q")
    }
}

struct LiveUpdatesItems: View {
    let index: IndexModel?

    var body: some View {
        if let index {
            LiveUpdatesButton(index: index)
        } else {
            Button {} label: { Text("Pause Live Updates", tableName: "MenuBar") }
                .disabled(true)
                .accessibilityIdentifier(LiveUpdatesButton.id)
        }
    }
}

private struct LiveUpdatesButton: View {
    static let id = "app-menu-live-updates"
    @ObservedObject var index: IndexModel

    var body: some View {
        Button(action: index.toggleLiveUpdates) {
            index.liveUpdatesPaused ? Text("Resume Live Updates", tableName: "MenuBar") : Text("Pause Live Updates", tableName: "MenuBar")
        }
        .disabled(!StatusBarView.hasLiveControl(index.indexState?.bootPhase, paused: index.liveUpdatesPaused))
        .accessibilityIdentifier(Self.id)
    }
}
