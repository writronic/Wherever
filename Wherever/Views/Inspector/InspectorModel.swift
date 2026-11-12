import Combine
import Darwin
import Foundation
import SwiftUI
import WhereverInterface

typealias DatalessCheck = @Sendable (String) -> Bool

nonisolated func isDataless(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
}

final class InspectorModel: ObservableObject {
    nonisolated struct Facts: Equatable, Sendable {
        var created: Date?
        var owner: String?
        var readable: Bool?
        var writable: Bool?
        var dataless = false

        nonisolated static func read(_ url: URL, path: String, dataless: DatalessCheck) -> Facts {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .isReadableKey, .isWritableKey])
            let owner = (try? FileManager.default.attributesOfItem(atPath: path))?[.ownerAccountName] as? String
            return Facts(created: values?.creationDate, owner: owner, readable: values?.isReadable, writable: values?.isWritable, dataless: dataless(path))
        }
    }

    nonisolated struct State: Equatable {
        var hit: SearchHit?
        var count = 0
        var facts: Facts?
    }

    static var datalessCheck: DatalessCheck = isDataless

    static let settle = Duration.milliseconds(100)

    @Published private(set) var state = State()
    var hit: SearchHit? { state.hit }
    var count: Int { state.count }
    var facts: Facts? { state.facts }
    var shown = false {
        didSet { if shown, !oldValue { show(selected, count: selectedCount) } }
    }
    private var selected: SearchHit?
    private var selectedCount = 0
    private var reading: Task<Void, Never>?
    private var lastShow: ContinuousClock.Instant?

    func select(_ hit: SearchHit?, count: Int = 1) {
        selected = hit
        selectedCount = hit == nil ? 0 : count
        if shown { show(selected, count: selectedCount) }
    }

    private func show(_ hit: SearchHit?, count: Int) {
        guard hit != state.hit || count != state.count else { return }
        reading?.cancel()
        let same = hit != nil && hit?.path == state.hit?.path && count == state.count
        state = State(hit: hit, count: count, facts: same ? state.facts : nil)
        guard let hit, count == 1 else { return }
        let now = ContinuousClock.now
        let waits = !same && lastShow.map { $0.duration(to: now) < Self.settle } ?? false
        lastShow = now
        let url = hit.fileURL
        let path = hit.path
        let dataless = Self.datalessCheck
        reading = Task { [weak self] in
            if waits {
                try? await Task.sleep(for: Self.settle)
                guard !Task.isCancelled else { return }
            }
            let facts = await Task.detached(priority: .userInitiated) { Facts.read(url, path: path, dataless: dataless) }.value
            guard !Task.isCancelled, let self, hit == self.state.hit else { return }
            self.state.facts = facts
        }
    }
}
