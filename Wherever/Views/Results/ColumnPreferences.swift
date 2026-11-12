import Combine
import Foundation

final class ColumnPreferences: ObservableObject {
    static let shownKey = "resultColumns"
    static let foldersFirstKey = "foldersFirst"
    static let shared: ColumnPreferences = {
        guard WhereverApp.usesPreviewServices else { return ColumnPreferences(defaults: .standard) }
        let name = "com.writronic.wherever.preview.columns"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ColumnPreferences(defaults: defaults)
    }()

    private let defaults: UserDefaults
    @Published var shown: Set<ResultsTable.Column> {
        didSet { defaults.set(ResultsTable.Column.allCases.filter { shown.contains($0) }.map(\.rawValue), forKey: Self.shownKey) }
    }
    @Published var foldersFirst: Bool {
        didSet { defaults.set(foldersFirst, forKey: Self.foldersFirstKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        shown = defaults.stringArray(forKey: Self.shownKey).map { Set($0.compactMap(ResultsTable.Column.init(rawValue:))).union([.name]) }
            ?? Set(ResultsTable.Column.defaults)
        foldersFirst = defaults.bool(forKey: Self.foldersFirstKey)
    }
}
