import SwiftUI

private func themed<Content: View>(_ theme: Theme, @ViewBuilder _ content: () -> Content) -> some View {
    let suite = UserDefaults(suiteName: "com.writronic.wherever.preview.theme.\(theme.rawValue)")!
    suite.set(theme.rawValue, forKey: Theme.key)
    return content().defaultAppStorage(suite)
}

private func search(_ theme: Theme, _ scheme: ColorScheme) -> some View {
    themed(theme) {
        let index = IndexModel(client: PreviewSearchClient())
        ContentView(index: index, model: index.makeModel()).previewEnvironment()
    }
    .preferredColorScheme(scheme)
}

#Preview("System Native light") { search(.systemNative, .light) }
#Preview("System Native dark") { search(.systemNative, .dark) }
#Preview("Ink and Glass light") { search(.inkAndGlass, .light) }
#Preview("Ink and Glass dark") { search(.inkAndGlass, .dark) }
#Preview("Warm Paper light") { search(.warmPaper, .light) }
#Preview("Warm Paper dark") { search(.warmPaper, .dark) }
#Preview("Midnight Teal light") { search(.midnightTeal, .light) }
#Preview("Midnight Teal dark") { search(.midnightTeal, .dark) }

#Preview("Colour theme picker") {
    themed(.warmPaper) { Form { ThemePicker() }.formStyle(.grouped).frame(width: 420) }
}
