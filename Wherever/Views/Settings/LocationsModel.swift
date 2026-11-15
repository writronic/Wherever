import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WhereverInterface

final class LocationsModel: ObservableObject {
    enum ExcludedRow: Hashable {
        case disk(String), folder(String)
    }

    struct PendingRow: Equatable {
        let path: String
        let disks: [String]
    }

    struct Item: Equatable {
        enum Note: Equatable {
            case invalid, notConnected, noUUID, hiddenBy(String)
        }

        let row: ExcludedRow
        let name: String
        let path: String
        let note: Note?
        let icon: NSImage
    }

    enum Key {
        static let excluded = "excludedFolders"
        static let indexedVolumes = "indexedVolumes"
    }

    @Published private(set) var volumes: [IndexedVolume] = []
    @Published private(set) var excluded: [String]
    @Published private(set) var indexed: Set<String>
    @Published private(set) var failed = false
    @Published private(set) var notificationsOff = false
    @Published private(set) var items: [Item] = []
    @Published var selection: ExcludedRow?
    @Published var pending: PendingRow?
    private(set) var change: Task<Void, Never>?
    var shown = false {
        didSet { if shown { rebuild() } }
    }

    private let client: any SearchClient
    private let defaults: UserDefaults
    private let chooseFolder: @MainActor () -> String?
    private let notices: DiskNotices
    private var disks: AnyCancellable?
    private var watch: AnyCancellable?

    init(
        client: any SearchClient, defaults: UserDefaults = .standard, chooseFolder: @escaping @MainActor () -> String? = LocationsModel.openPanel,
        notices: DiskNotices = .live
    ) {
        self.client = client
        self.defaults = defaults
        self.chooseFolder = chooseFolder
        self.notices = notices
        excluded = Self.rows(defaults)
        indexed = Self.stored(defaults).indexedVolumes
        watch = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, Self.rows(self.defaults) != self.excluded || Self.stored(self.defaults).indexedVolumes != self.indexed else { return }
                    self.refresh()
                }
            }
    }

    static func stored(_ defaults: UserDefaults = .standard) -> (excluded: [String], indexedVolumes: Set<String>) {
        (rows(defaults).filter(accepts), Set(defaults.stringArray(forKey: Key.indexedVolumes) ?? []))
    }

    private static func rows(_ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: Key.excluded) ?? defaultPaths
    }

    static func accepts(_ row: String) -> Bool {
        row.hasPrefix("/") || diskID(row) != nil
    }

    private static func diskID(_ row: String) -> String? {
        let scalars = row.unicodeScalars
        guard let slash = scalars.firstIndex(of: "/") else { return nil }
        let id = String(Substring(scalars[..<slash]))
        let parts = scalars[scalars.index(after: slash)...].split(separator: "/", omittingEmptySubsequences: false)
        let bad = parts.contains { $0.isEmpty || $0.elementsEqual(".".unicodeScalars) || $0.elementsEqual("..".unicodeScalars) }
        return UUID(uuidString: id)?.uuidString == id && !bad ? id : nil
    }

    func path(of row: String) -> String? {
        guard let id = Self.diskID(row) else { return row }
        return volumes.first { $0.id == id }.map { $0.path + String(Substring(row.unicodeScalars.dropFirst(id.unicodeScalars.count))) }
    }

    private func row(for path: String) -> String {
        let parts = (path as NSString).pathComponents
        let disk = volumes.compactMap { v in UUID(uuidString: v.id)?.uuidString == v.id ? (id: v.id, root: (v.path as NSString).pathComponents) : nil }
            .filter { parts.count > $0.root.count && parts.starts(with: $0.root) }
            .max { $0.root.count < $1.root.count }
        guard let disk else { return path }
        return ([disk.id] + parts.dropFirst(disk.root.count)).joined(separator: "/")
    }

    private static var defaultPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["CloudStorage", "Biome", "Caches", "Logs", "Metadata"].map {
            home.appendingPathComponent("Library/\($0)").path
        } + ["/Library/Caches", "/System/Library/Caches", "/private/var", "/private/tmp"]
    }

    var rows: [ExcludedRow] {
        volumes.filter { !indexed.contains($0.id) }.map { .disk($0.id) } + excluded.map { .folder($0) }
    }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        queue { [self] in
            failed = false
            await reload()
        }
    }

    private func reload() async {
        let client = client
        let read = await Task.detached { try? client.volumes() }.value
        if let read, read != volumes { volumes = read }
        let rows = Self.rows(defaults)
        if rows != excluded { excluded = rows }
        let ids = Self.stored(defaults).indexedVolumes
        if ids != indexed { indexed = ids }
        if let selection, !self.rows.contains(selection) { self.selection = nil }
        rebuild()
    }

    @discardableResult
    private func queue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let prior = change
        let next = Task {
            await prior?.value
            await work()
        }
        change = next
        return next
    }

    private func send(_ work: @escaping @Sendable (any SearchClient) throws -> Void) async -> Bool {
        let client = client
        let sent = await Task.detached { (try? work(client)) != nil }.value
        failed = !sent
        return sent
    }

    private func rebuild() {
        guard shown else { return }
        let next = rows.compactMap { item($0) }
        if next != items { items = next }
    }

    private func item(_ row: ExcludedRow) -> Item? {
        switch row {
        case .disk(let id):
            guard let volume = volumes.first(where: { $0.id == id }) else { return nil }
            let note: Item.Note? = volume.indexable ? hidingRow(of: volume).map { Item.Note.hiddenBy($0) } : .noUUID
            return built(row, volume.name, volume.path, .volume, note)
        case .folder(let entry):
            guard Self.accepts(entry) else { return built(row, entry, entry, .folder, .invalid) }
            guard let path = self.path(of: entry) else { return built(row, (entry as NSString).lastPathComponent, entry, .folder, .notConnected) }
            return built(row, FileManager.default.displayName(atPath: path), path, .folder, nil)
        }
    }

    private func built(_ row: ExcludedRow, _ name: String, _ path: String, _ type: UTType, _ note: Item.Note?) -> Item {
        let icon = items.first { $0.row == row && $0.path == path }?.icon ?? LocationsPane.icon(for: path, type: type)
        return Item(row: row, name: name, path: path, note: note, icon: icon)
    }

    func follow(_ volumes: Published<[IndexedVolume]>.Publisher) {
        disks = volumes.sink { [weak self] _ in self?.refresh() }
    }

    func askForNotifications() {
        Task {
            await notices.ask()
            await readNotifications()
        }
    }

    func readNotifications() async {
        notificationsOff = await notices.needsSystemSettings()
    }

    static func setIndexed(_ id: String, _ on: Bool, client: any SearchClient, defaults: UserDefaults) throws {
        let current = stored(defaults).indexedVolumes
        var next = current
        if on { next.insert(id) } else { next.remove(id) }
        guard next != current else { return }
        try client.setIndexedVolumes(next)
        defaults.set(next.sorted(), forKey: Key.indexedVolumes)
    }

    @discardableResult
    private func setIndexed(_ id: String, _ on: Bool) async -> Bool {
        let current = Self.stored(defaults).indexedVolumes
        let next = on ? current.union([id]) : current.subtracting([id])
        if next == current {
            failed = false
        } else if await send({ try $0.setIndexedVolumes(next) }) {
            defaults.set(next.sorted(), forKey: Key.indexedVolumes)
        }
        await reload()
        return !failed
    }

    func addFolder() {
        guard let chosen = chooseFolder() else { return }
        var trimmed = chosen
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        let path = trimmed
        queue { [self] in
            let entry = row(for: path)
            if let disk = volumes.first(where: { $0.path == path }) {
                _ = await setIndexed(disk.id, false)
            } else if !excluded.contains(entry) {
                let hidden = entry == path ? disksHidden(by: path) : []
                if hidden.isEmpty {
                    _ = await setExcluded(excluded.filter { $0 != path } + [entry])
                } else {
                    pending = PendingRow(path: path, disks: hidden)
                }
            }
        }
    }

    var canRemoveSelection: Bool {
        guard case .disk = selection else { return selection != nil }
        return items.first { $0.row == selection }?.note == nil
    }

    func hidingRow(of volume: IndexedVolume) -> String? {
        Self.hidingRow(of: volume, in: excluded)
    }

    static func covered(_ volume: IndexedVolume, _ defaults: UserDefaults) -> Bool {
        hidingRow(of: volume, in: stored(defaults).excluded) != nil
    }

    private static func hidingRow(of volume: IndexedVolume, in rows: [String]) -> String? {
        rows.first { $0.hasPrefix("/") && holds($0, volume.path) }
    }

    private static func holds(_ row: String, _ path: String) -> Bool {
        func parts(_ p: String) -> [Substring] { p.split(separator: "/").filter { $0 != "." } }
        let real = realpath(row, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return parts(path).starts(with: parts(real ?? row))
    }

    private func disksHidden(by path: String) -> [String] {
        let disks = volumes.filter { indexed.contains($0.id) && $0.indexable && Self.holds(path, $0.path) }.map(\.name)
        return (path == "/" ? [FileManager.default.displayName(atPath: "/")] : []) + disks
    }

    func confirmPending() {
        guard let pending else { return }
        self.pending = nil
        queue { [self] in _ = await setExcluded(excluded.filter { $0 != pending.path } + [pending.path]) }
    }

    func removeSelected() {
        guard canRemoveSelection, let row = selection else { return }
        queue { [self] in
            let removed: Bool
            switch row {
            case .disk(let id): removed = await setIndexed(id, true)
            case .folder(let path): removed = await setExcluded(excluded.filter { $0 != path })
            }
            if removed, selection == row { selection = nil }
        }
    }

    @discardableResult
    private func setExcluded(_ next: [String]) async -> Bool {
        guard next != excluded else {
            failed = false
            return true
        }
        let paths = next.filter(Self.accepts)
        guard await send({ try $0.setExcludedFolders(paths) }) else { return false }
        excluded = next
        defaults.set(next, forKey: Key.excluded)
        rebuild()
        return true
    }

    static func openPanel() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Exclude", table: "Settings")
        panel.message = String(localized: "Choose a folder Wherever leaves out of the index.", table: "Settings")
        return panel.runModal() == .OK ? panel.url?.path(percentEncoded: false) : nil
    }
}

enum NewDiskChoice: String, CaseIterable {
    case statusBar, notification, index, nothing

    static let key = "newDiskChoice"

    static func stored(_ defaults: UserDefaults) -> NewDiskChoice {
        defaults.string(forKey: key).flatMap(NewDiskChoice.init(rawValue:)) ?? .statusBar
    }

    var title: Text {
        switch self {
        case .statusBar: Text("Ask in the Status Bar", tableName: "Settings")
        case .notification: Text("Ask with a Notification", tableName: "Settings")
        case .index: Text("Index Automatically", tableName: "Settings")
        case .nothing: Text("Do Nothing", tableName: "Settings")
        }
    }
}
