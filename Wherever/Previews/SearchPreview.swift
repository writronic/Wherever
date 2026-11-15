import SwiftUI

#Preview("Search") {
    let index = IndexModel(client: PreviewSearchClient())
    return ContentView(index: index, model: index.makeModel()).previewEnvironment()
}

#Preview("Filter bar, no filter") {
    FilterBar(filters: .constant(SearchFilters())).frame(width: SearchMetrics.windowMinWidth)
}

#Preview("Filter bar, every filter") {
    FilterBar(filters: .constant(SearchFilters(
        extensions: "pdf, .docx", kind: .documents, size: .medium, modified: .week, hidesHidden: true
    ))).frame(width: SearchMetrics.windowMinWidth)
}
