import SwiftUI

struct ThemePicker: View {
    static let id = "theme-picker"

    @AppStorage(Theme.key) private var theme = Theme.systemNative
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 0) {
            Text("Color theme", tableName: "Theme").font(textSize.formLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: SettingsWindow.Metrics.labelToTiles)
            ThemeTiles(selection: $theme, textSize: textSize, bundle: AppearanceRow.bundle(locale))
        }
    }
}

private struct ThemeTiles: NSViewRepresentable {
    @Binding var selection: Theme
    let textSize: TextSize
    let bundle: Bundle

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> ThemeTileRow {
        ThemeTileRow(picked: selection, textSize: textSize, bundle: bundle) { [coordinator = context.coordinator] in
            coordinator.selection.wrappedValue = $0
        }
    }

    func updateNSView(_ row: ThemeTileRow, context: Context) {
        context.coordinator.selection = $selection
        row.update(picked: selection, textSize: textSize, bundle: bundle)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ThemeTileRow, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    final class Coordinator {
        var selection: Binding<Theme>

        init(selection: Binding<Theme>) { self.selection = selection }
    }
}
