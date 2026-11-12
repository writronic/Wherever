import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications
import WhereverInterface

final class IndexModel: ObservableObject {
    static let pausedKey = HelperLink.Key.liveUpdatesPaused

    private struct Window {
        weak var model: SearchModel?
    }

    @Published private(set) var indexState: IndexState?
    @Published private(set) var waitingDisks: [IndexedVolume] = []
    @Published private(set) var notificationsOff = false
    @Published private(set) var volumes: [IndexedVolume] = []
    @Published private(set) var liveUpdatesPaused: Bool
    var nextQuery: String?
    var stateArrived: @MainActor (_ booted: Bool) -> Void = { _ in }

    private let client: any SearchClient
    private let announcer: Announcer
    private let defaults: UserDefaults
    private let pauseStore: UserDefaults?
    private let confirmIndex: @MainActor (IndexedVolume) -> Bool
    private let notices: DiskNotices
    let openLocations: @MainActor () -> Void
    private var windows: [Window] = []
    private var archives: [Window] = []
    private var plugged: Set<String> = []
    private var answer: NewDiskChoice
    private var rows: [String]
    private var unindexed: [IndexedVolume] = []
    private var inBar: Set<String> = []
    private var asking: Set<String> = []
    private lazy var permission = Task { [notices] in await notices.ask() }

    init(
        client: any SearchClient, announcer: Announcer = .shared, defaults: UserDefaults = .standard, pauseStore: UserDefaults? = nil, mounts: NotificationCenter = NotificationCenter(),
        confirmIndex: @escaping @MainActor (IndexedVolume) -> Bool = SearchFolderBox.askToIndex,
        notices: DiskNotices = .live, openLocations: @escaping @MainActor () -> Void = {}
    ) {
        self.client = client
        self.announcer = announcer
        self.defaults = defaults
        self.pauseStore = pauseStore
        liveUpdatesPaused = pauseStore?.bool(forKey: IndexModel.pausedKey) ?? false
        self.confirmIndex = confirmIndex
        self.notices = notices
        self.openLocations = openLocations
        answer = NewDiskChoice.stored(defaults)
        rows = LocationsModel.stored(defaults).excluded
        let events = client.events
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
        _ = mounts.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path(percentEncoded: false) else { return }
            MainActor.assumeIsolated { self?.notePlugged(path) }
        }
        _ = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.answerChanged()
                self?.rowsChanged()
            }
        }
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.answer == .notification else { return }
                Task { await self.readNotifications() }
            }
        }
        disksChanged()
        if answer == .notification { Task { await readNotifications() } } else { notices.withdraw([]) }
    }

    var noticeWaits: Bool { !asking.isEmpty }

    func diskMounted(at path: String) {
        notePlugged(path)
        disksChanged()
    }

    private func notePlugged(_ path: String) {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        plugged.insert(path)
    }

    func toggleLiveUpdates() {
        if apply(paused: !liveUpdatesPaused) { pauseStore?.set(liveUpdatesPaused, forKey: Self.pausedKey) }
    }

    func followStoredPause() {
        guard let pauseStore else { return }
        let paused = pauseStore.bool(forKey: Self.pausedKey)
        if paused != liveUpdatesPaused, !apply(paused: paused) { pauseStore.set(liveUpdatesPaused, forKey: Self.pausedKey) }
    }

    private func apply(paused: Bool) -> Bool {
        guard (try? client.setLiveUpdates(!paused)) != nil else { return false }
        liveUpdatesPaused = paused
        announcer.announce(StatusBarView.text(.live, paused: paused))
        stateArrived(false)
        return true
    }

    func indexDisk(_ disk: IndexedVolume) {
        guard disk.indexable, !LocationsModel.covered(disk, defaults), confirmIndex(disk) else { return }
        switchOn(disk)
    }

    func noticeAnswered(_ action: String, diskID: String) {
        defer { if asking.remove(diskID) != nil, asking.isEmpty { stateArrived(false) } }
        guard let disk = unindexed.first(where: { $0.id == diskID }) else { return }
        switch action {
        case DiskNotices.indexAction: switchOn(disk)
        case UNNotificationDefaultActionIdentifier:
            inBar.insert(disk.id)
            publish()
            notices.withdraw(noticeKeeps)
            openLocations()
        default: return
        }
    }

    func makeModel(listsAll: Bool = false, defaults: UserDefaults = .standard) -> SearchModel {
        let query = nextQuery ?? ""
        nextQuery = nil
        let model = SearchModel(
            session: try? client.makeSession(), listsAll: listsAll,
            hidesHidden: listsAll && defaults.bool(forKey: SearchFilters.hidesHiddenKey), query: query
        )
        windows.append(Window(model: model))
        return model
    }

    func makeArchiveModel(session: (any ResultsSessionClient)?, defaults: UserDefaults = .standard, columnPreferences: ColumnPreferences = .shared) -> SearchModel {
        let model = SearchModel(
            session: session, listsAll: true, hidesHidden: defaults.bool(forKey: SearchFilters.hidesHiddenKey), columnPreferences: columnPreferences
        )
        archives.append(Window(model: model))
        return model
    }

    private func handle(_ event: SearchEvent) {
        if case let .stateChanged(state) = event {
            var booted = false
            if let old = indexState?.bootPhase, [IndexPhase.loading, .crawling, .finishing].contains(old),
                [IndexPhase.ready, .live, .failed].contains(state.bootPhase) {
                announcer.announce(StatusBarView.text(state.bootPhase))
                booted = true
            }
            if !state.indexingDisks.isEmpty, state.indexingDisks != indexState?.indexingDisks {
                announcer.announce(StatusBarView.indexingText(state.indexingDisks))
            }
            indexState = state
            stateArrived(booted)
            return
        }
        if case .volumesChanged = event { disksChanged() }
        windows.removeAll { $0.model == nil }
        for window in windows { window.model?.handle(event) }
        archives.removeAll { $0.model == nil }
        switch event {
        case .resultsReady, .searchFailed: for archive in archives { archive.model?.handle(event) }
        default: break
        }
    }

    private func disksChanged() {
        guard let volumes = try? client.volumes() else { return }
        self.volumes = volumes
        unindexed = volumes.filter { !$0.indexed && $0.indexable && !LocationsModel.covered($0, defaults) }
        let arrived = unindexed.filter { plugged.contains($0.path) }
        publish()
        if NewDiskChoice.stored(defaults) == .notification { notices.withdraw(noticeKeeps) }
        plugged.subtract(volumes.map(\.path))
        guard !arrived.isEmpty else { return }
        switch NewDiskChoice.stored(defaults) {
        case .statusBar, .nothing: return
        case .index: for disk in arrived { switchOn(disk) }
        case .notification:
            asking.formUnion(arrived.map(\.id))
            Task {
                guard await readNotifications() == false else { return }
                for disk in arrived where noticeKeeps.contains(disk.id) {
                    if await notices.post(disk) == false {
                        inBar.insert(disk.id)
                        publish()
                    }
                    notices.withdraw(noticeKeeps)
                }
            }
        }
    }

    private func answerChanged() {
        let stored = NewDiskChoice.stored(defaults)
        guard stored != answer else { return }
        inBar = answer == .statusBar && stored == .notification ? Set(unindexed.map(\.id)) : []
        answer = stored
        publish()
        if stored == .notification { Task { await readNotifications() } } else { notices.withdraw([]) }
    }

    private func rowsChanged() {
        let stored = LocationsModel.stored(defaults).excluded
        guard stored != rows else { return }
        rows = stored
        disksChanged()
    }

    private func publish() {
        let notification = NewDiskChoice.stored(defaults) == .notification
        inBar.formIntersection(unindexed.map(\.id))
        let named = notification ? unindexed.filter { inBar.contains($0.id) } : unindexed
        if named != waitingDisks { waitingDisks = named }
        if notificationsOff != (notification && !inBar.isEmpty) { notificationsOff.toggle() }
        let waited = noticeWaits
        asking.formIntersection(noticeKeeps)
        if waited, !noticeWaits { stateArrived(false) }
    }

    private var noticeKeeps: Set<String> {
        NewDiskChoice.stored(defaults) == .notification ? Set(unindexed.map(\.id)).subtracting(inBar) : []
    }

    @discardableResult
    private func readNotifications() async -> Bool {
        await permission.value
        let off = await notices.isOff()
        if off, NewDiskChoice.stored(defaults) == .notification { inBar.formUnion(unindexed.map(\.id)) }
        publish()
        notices.withdraw(noticeKeeps)
        return off
    }

    private func switchOn(_ disk: IndexedVolume) {
        try? LocationsModel.setIndexed(disk.id, true, client: client, defaults: defaults)
    }
}
