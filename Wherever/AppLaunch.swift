import Combine
import WhereverInterface

struct AppServices {
    let client: any SearchClient
    let archiveClient: any ArchiveClient
    let archives: ArchiveWindows
    let index: IndexModel
    let settings: SettingsWindow
    let launcher: Launcher
}

final class Launch: ObservableObject {
    @Published private(set) var services: AppServices?
    @Published private(set) var windowless: Bool

    init(windowless: Bool = false) { self.windowless = windowless }

    func showWindows() { windowless = false }

    func start(_ make: () throws -> AppServices) rethrows {
        if services == nil { services = try make() }
    }
}

final class BuiltOnce<Value> {
    private let make: @MainActor () throws -> Value
    private var built: Value?

    init(make: @escaping @MainActor () throws -> Value) { self.make = make }

    func value() throws -> Value {
        if let built { return built }
        let made = try make()
        built = made
        return made
    }
}
