import AppKit
import CoreServices
import Darwin
import Dispatch
import Foundation
import ServiceManagement

struct HelperStarter {
    let previews: Bool
    let defaults: UserDefaults
    let own: UserDefaults
    let helper: URL
    var isRunning: () -> Bool
    var open: (URL, Bool) -> Void
    var post: (Notification.Name, String) -> Void
    var registerBundle: () -> Void = {}
    var readStatus: @MainActor () async -> SMAppService.Status = { .notRegistered }
    var registerItem: @MainActor () throws -> Void = {}
    var unregisterItem: @MainActor () async throws -> Void = {}
    var running: () -> [(pid: pid_t, url: URL?)] = { [] }
    var end: @MainActor (pid_t) async -> Void = { _ in }
    var identity: () -> String? = { nil }
    var delay: @MainActor (Duration) async -> Void = { _ in }

    nonisolated static var loginItem: SMAppService { .loginItem(identifier: HelperLink.helperID) }

    static func readLoginStatus() async -> SMAppService.Status {
        await withCheckedContinuation { done in DispatchQueue.global().async { done.resume(returning: loginItem.status) } }
    }

    static func copies(of helper: URL, among apps: [(pid: pid_t, url: URL?)]) -> [pid_t] {
        apps.filter { $0.url?.path == helper.path }.map(\.pid)
    }

    private func endCopies() async {
        for pid in Self.copies(of: helper, among: running()) { await end(pid) }
    }

    private var needsRestart: Bool {
        guard HelperLink.shouldRun(in: defaults) else { return false }
        guard isRunning() else { return true }
        HelperLink.synchronize(domain: HelperLink.helperID)
        return own.string(forKey: HelperLink.Key.helperIdentity) != identity()
    }

    @discardableResult func launched() -> Task<Void, Never> {
        guard !previews else { return Task {} }
        registerBundle()
        return Task { await ensureCurrent() }
    }

    func ensureCurrent() async {
        HelperLink.synchronize()
        let status = await readStatus()
        guard needsRestart else { return sync() }
        guard status == .enabled else {
            await endCopies()
            return sync()
        }
        for wait in [Duration.zero, .seconds(10)] {
            await delay(wait)
            try? await unregisterItem()
            await endCopies()
            guard (try? registerItem()) != nil else { break }
            await delay(.seconds(3))
            if !needsRestart { return }
        }
        sync()
    }

    func registerLogin() async throws {
        guard !previews else { return }
        registerBundle()
        await endCopies()
        do {
            try registerItem()
        } catch {
            sync()
            throw error
        }
    }

    func unregisterLogin() async throws {
        guard !previews else { return }
        try await unregisterItem()
        await endCopies()
        sync()
    }

    func removeForReset() async {
        guard !previews else { return }
        try? await unregisterItem()
        await endCopies()
    }

    func sync() {
        guard !previews else { return }
        HelperLink.synchronize()
        if HelperLink.shouldRun(in: defaults), !isRunning() {
            open(helper, false)
        } else {
            post(HelperLink.Note.sync, helper.path)
        }
    }

    func pause() {
        guard !previews else { return }
        post(HelperLink.Note.pause, helper.path)
    }

    func resume() {
        guard !previews else { return }
        post(HelperLink.Note.resume, helper.path)
    }

    var shortcutFailed: Bool {
        guard !previews else { return false }
        HelperLink.synchronize(domain: HelperLink.helperID)
        return own.bool(forKey: HelperLink.Key.shortcutFailed)
    }

    static func live(previews: Bool, defaults: UserDefaults, app: URL) -> HelperStarter {
        let helper = HelperLink.embeddedHelper(in: app)
        let running = {
            NSRunningApplication.runningApplications(withBundleIdentifier: HelperLink.helperID)
                .filter { kill($0.processIdentifier, 0) == 0 }
                .map { (pid: $0.processIdentifier, url: $0.bundleURL) }
        }
        return HelperStarter(
            previews: previews, defaults: defaults, own: UserDefaults(suiteName: HelperLink.helperID) ?? .standard, helper: helper,
            isRunning: { !copies(of: helper, among: running()).isEmpty },
            open: { url, activates in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = activates
                NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
            },
            post: { HelperLink.post($0, object: $1) },
            registerBundle: { LSRegisterURL(helper as CFURL, true) },
            readStatus: readLoginStatus,
            registerItem: { try loginItem.register() },
            unregisterItem: { try await loginItem.unregister() },
            running: running,
            end: { pid in
                kill(pid, SIGTERM)
                for _ in 0..<40 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(50)) }
            },
            identity: { HelperLink.identity(of: helper) },
            delay: { try? await Task.sleep(for: $0) }
        )
    }
}
