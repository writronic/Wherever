import Foundation

struct ContentTerms: Equatable {
    enum Match { case any, all }

    var terms: [String] = []
    var match = Match.any

    func words(draft: String) -> [String] {
        var seen = Set<String>()
        return (terms + [draft])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
