import SwiftUI

private let index = IndexModel(client: PreviewSearchClient())

private func normalWindow() -> some View {
    let model = index.makeModel()
    model.query = "report"
    return SearchView(model: model, mode: .normal)
        .frame(width: SearchMetrics.windowMinWidth, height: SearchMetrics.windowMinHeight)
        .previewEnvironment()
}

#Preview("Normal, Light") {
    normalWindow().preferredColorScheme(.light)
}

#Preview("Normal, Dark") {
    normalWindow().preferredColorScheme(.dark)
}
