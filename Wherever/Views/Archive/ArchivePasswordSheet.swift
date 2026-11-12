import AppKit
import SwiftUI
import WhereverInterface

struct ArchivePasswordSheet: View {
    static let sheetID = "archive-password-sheet"
    static let fieldID = "archive-password-field"
    static let okID = "archive-password-ok"
    static let cancelID = "archive-password-cancel"
    static let wrongID = "archive-password-wrong"

    @ObservedObject var model: ArchiveWindowModel
    let name: String
    @State private var password = ""
    @FocusState private var focused: Bool
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        VStack(alignment: .leading, spacing: SearchMetrics.inspectorSpacing) {
            Text("Enter the password for “\(Bidi.name(name))”.", tableName: "Archive")
                .bold()
                .fixedSize(horizontal: false, vertical: true)
            SecureField(String(localized: "Password", table: "Archive"), text: $password)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityIdentifier(Self.fieldID)
            if model.misses > 0 {
                Text("The password is incorrect. Try again.", tableName: "Archive")
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(Self.wrongID)
            }
            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "Cancel", table: "Normal"), action: model.cancelPassword)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(Self.cancelID)
                Button(String(localized: "OK", table: "Archive"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.unlocking)
                    .accessibilityIdentifier(Self.okID)
            }
        }
        .font(textSize.body)
        .padding(SearchMetrics.inspectorPadding)
        .frame(width: (ResultsTable.font(textSize).pointSize * 28).rounded())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.sheetID)
        .onAppear { focused = true }
        .onChange(of: model.misses) { _ in
            password = ""
            focused = true
        }
    }

    private func submit() {
        guard !model.unlocking else { return }
        let typed = password
        focused = false
        password = ""
        model.submitPassword(typed)
    }
}
