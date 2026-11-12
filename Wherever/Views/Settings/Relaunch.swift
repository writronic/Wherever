import Foundation

enum Relaunch {
    static let pendingKey = "resetPending"
    static let waiterScript = "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open \"$1\""

    static func finishPendingReset(defaults: UserDefaults, domain: String, removeData: () -> Void) {
        guard defaults.bool(forKey: pendingKey) else { return }
        removeData()
        defaults.removePersistentDomain(forName: domain)
        defaults.removePersistentDomain(forName: domain + ".helper")
    }

    static func reset(defaults: UserDefaults, removeCommandLine: () throws -> Void, relaunch: () throws -> Void, unregister: @MainActor () async -> Void, stop: () -> Void) async throws {
        guard await ArchiveEdits.resolved() else { return }
        defaults.set(true, forKey: pendingKey)
        do {
            try removeCommandLine()
            try relaunch()
        } catch {
            defaults.removeObject(forKey: pendingKey)
            throw error
        }
        defaults.removeObject(forKey: AppLanguage.appleKey)
        await unregister()
        stop()
    }

    static func relaunch(run: (URL, [String]) throws -> Void = Relaunch.runDetached) throws {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        try run(URL(filePath: "/bin/sh"), ["-c", waiterScript, pid, Bundle.main.bundlePath])
    }

    nonisolated static func runDetached(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        try process.run()
    }
}
