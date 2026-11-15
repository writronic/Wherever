import Combine
import ServiceManagement

final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var failed = false
    @Published private(set) var busy = false

    private let readStatus: @MainActor () async -> SMAppService.Status
    private let register: @MainActor () async throws -> Void
    private let unregister: @MainActor () async throws -> Void
    private let openLoginItems: @MainActor () -> Void
    private var readsStarted = 0
    private var readPublished = 0

    init(
        readStatus: @escaping @MainActor () async -> SMAppService.Status = { await HelperStarter.readLoginStatus() },
        register: @escaping @MainActor () async throws -> Void = { try await WhereverApp.helperStarter.registerLogin() },
        unregister: @escaping @MainActor () async throws -> Void = { try await WhereverApp.helperStarter.unregisterLogin() },
        openLoginItems: @escaping @MainActor () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        self.openLoginItems = openLoginItems
    }

    static func inert() -> LaunchAtLoginModel {
        LaunchAtLoginModel(readStatus: { .notRegistered }, register: {}, unregister: {}, openLoginItems: {})
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    @discardableResult func refresh() -> Task<Void, Never> {
        readsStarted += 1
        let read = readsStarted
        return Task {
            let answer = await readStatus()
            guard read > readPublished else { return }
            readPublished = read
            status = answer
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await refresh().value
        guard enabled != isOn else { return }
        failed = false
        do {
            if enabled {
                try await register()
            } else {
                try await unregister()
            }
        } catch {
            failed = true
        }
        await refresh().value
    }

    func openLoginItemsSettings() { openLoginItems() }
}
