import Foundation
import SwiftUI
import WhereverInterface

private let fixture: [SearchHit] = [
    SearchHit(name: "report.pdf", folder: "/Users/me/Documents", size: 2_412_877, modified: Date(timeIntervalSince1970: 1_790_000_000), created: .distantPast, opened: .distantPast, kind: .file),
    SearchHit(name: "Reports", folder: "/Users/me/Documents", size: 0, modified: Date(timeIntervalSince1970: 1_780_000_000), created: .distantPast, opened: .distantPast, kind: .folder),
]

private let client = PreviewSearchClient(catalog: fixture)
private let index = IndexModel(client: client)

#Preview("Inspector") {
    let model = index.makeModel()
    model.query = "re"
    let store = UserDefaults(suiteName: "com.writronic.wherever.preview.inspector") ?? .standard
    store.set(true, forKey: InspectorPane.shownKey)
    return ResultsPane(model: model)
        .defaultAppStorage(store)
        .frame(width: SearchMetrics.windowMinWidth, height: SearchMetrics.windowMinHeight)
        .previewEnvironment(search: client)
}
