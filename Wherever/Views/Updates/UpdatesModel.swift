import Combine
import SwiftUI

final class UpdatesModel: ObservableObject {
    static let automaticChecksKey = "SUEnableAutomaticChecks"

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    let checkForUpdates: () -> Void
    let setAutomaticallyChecks: (Bool) -> Void

    init<Source: Publisher, Automatic: Publisher>(
        canCheckForUpdates: Source, automaticallyChecks: Automatic, check: @escaping () -> Void, setAutomaticallyChecks: @escaping (Bool) -> Void
    ) where Source.Output == Bool, Source.Failure == Never, Automatic.Output == Bool, Automatic.Failure == Never {
        checkForUpdates = check
        self.setAutomaticallyChecks = setAutomaticallyChecks
        canCheckForUpdates.assign(to: &$canCheckForUpdates)
        automaticallyChecks.assign(to: &$automaticallyChecks)
    }

    static var idle: UpdatesModel { UpdatesModel(canCheckForUpdates: Just(false), automaticallyChecks: Just(false), check: {}, setAutomaticallyChecks: { _ in }) }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var model: UpdatesModel

    var body: some View {
        Button(action: model.checkForUpdates) { Text("Check for Updates…", tableName: "MenuBar") }
            .disabled(!model.canCheckForUpdates)
            .accessibilityIdentifier("app-menu-check-for-updates")
    }
}
