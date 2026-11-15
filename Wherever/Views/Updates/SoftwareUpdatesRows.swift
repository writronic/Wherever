import SwiftUI

struct SoftwareUpdatesRows: View {
    @ObservedObject var model: UpdatesModel
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        Toggle(isOn: Binding(get: { model.automaticallyChecks }, set: { model.setAutomaticallyChecks($0) })) {
            Text("Automatically check for updates", tableName: "Settings").font(textSize.formLabel)
        }
        .toggleStyle(.switch)
        .accessibilityIdentifier("general-automatic-updates")
    }
}
