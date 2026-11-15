import Foundation
import SwiftUI
import WhereverInterface

private let fixture: [SearchHit] = [
    SearchHit(name: "Ünïcode Résumé.pdf", folder: "/Users/me/Documents/Applications and letters/2026", size: 184_320,
              modified: Date(timeIntervalSince1970: 1_790_000_000), created: .distantPast, opened: .distantPast, kind: .file),
    SearchHit(name: "Résumé template.docx", folder: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Templates/Work",
              size: 52_224, modified: Date(timeIntervalSince1970: 1_780_000_000), created: .distantPast, opened: .distantPast, kind: .file),
    SearchHit(name: "résumé photos", folder: "/Volumes/Disk 1/Photos", size: 0, modified: Date(timeIntervalSince1970: 1_770_000_000), created: .distantPast, opened: .distantPast, kind: .folder),
    SearchHit(name: "resume.sh", folder: "/usr/local/bin", size: 912, modified: Date(timeIntervalSince1970: 1_760_000_000), created: .distantPast, opened: .distantPast, kind: .link),
]

private let client = PreviewSearchClient(catalog: fixture)
private let index = IndexModel(client: client)

#Preview("Results") {
    let model = index.makeModel()
    model.query = "s"
    return ResultsTable(model: model).frame(width: SearchMetrics.windowMinWidth, height: SearchMetrics.windowMinHeight / 2)
        .previewEnvironment(search: client)
}
