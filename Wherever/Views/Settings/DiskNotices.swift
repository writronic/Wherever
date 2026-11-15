import AppKit
import Foundation
import UserNotifications
import WhereverInterface

struct DiskNotices {
    var ask: @MainActor () async -> Void
    var isOff: @MainActor () async -> Bool
    var needsSystemSettings: @MainActor () async -> Bool
    var post: @MainActor (IndexedVolume) async -> Bool
    var withdraw: @MainActor (_ waiting: Set<String>) -> Void

    static let category = "disk-notice"
    static let indexAction = "index"
    static let notNowAction = "not-now"

    static let live = WhereverApp.usesPreviewServices ? DiskNotices(ask: {}, isOff: { false }, needsSystemSettings: { false }, post: { _ in true }, withdraw: { _ in }) : DiskNotices(
        ask: { await requestAuthorization() },
        isOff: {
            let (status, alert, list) = await settings()
            return isOff(status, alert: alert, list: list)
        },
        needsSystemSettings: {
            let (status, alert, list) = await settings()
            return needsSystemSettings(status, alert: alert, list: list)
        },
        post: { volume in
            let request = request(for: volume)
            return await inOrder { await deliver(request) }.value
        },
        withdraw: { waiting in inOrder { await withdraw(keeping: waiting) } }
    )

    private static var last: Task<Void, Never>?

    @discardableResult
    private static func inOrder<Result: Sendable>(_ work: sending @escaping () async -> Result) -> Task<Result, Never> {
        let previous = last
        let next = Task {
            await previous?.value
            return await work()
        }
        last = Task { _ = await next.value }
        return next
    }

    static func isOff(_ status: UNAuthorizationStatus, alert: UNNotificationSetting = .enabled, list: UNNotificationSetting = .enabled) -> Bool {
        status != .authorized || (alert != .enabled && list != .enabled)
    }

    static func needsSystemSettings(_ status: UNAuthorizationStatus, alert: UNNotificationSetting = .enabled, list: UNNotificationSetting = .enabled) -> Bool {
        status == .denied || (status == .authorized && alert != .enabled && list != .enabled)
    }

    static func request(for volume: IndexedVolume) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Index “\(Bidi.name(volume.name))”?", table: "Normal")
        content.body = String(
            localized: "Wherever reads every file name on this disk before it can search it. A large disk can take several minutes. To ignore it again, add it to Excluded Paths in Settings.",
            table: "Normal"
        )
        content.categoryIdentifier = category
        return UNNotificationRequest(identifier: volume.id, content: content, trigger: nil)
    }

    static var categories: Set<UNNotificationCategory> {
        [UNNotificationCategory(
            identifier: category,
            actions: [
                UNNotificationAction(identifier: indexAction, title: String(localized: "Index", table: "Normal"), options: []),
                UNNotificationAction(identifier: notNowAction, title: String(localized: "Not Now", table: "Normal"), options: []),
            ],
            intentIdentifiers: [], options: [.customDismissAction]
        )]
    }

    private nonisolated static func deliver(_ request: UNNotificationRequest) async -> Bool {
        (try? await UNUserNotificationCenter.current().add(request)) != nil
    }

    private nonisolated static func withdraw(keeping waiting: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let stale = (delivered + pending).filter { !waiting.contains($0) }
        guard !stale.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        center.removeDeliveredNotifications(withIdentifiers: stale)
    }

    private nonisolated static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    private nonisolated static func settings() async -> (UNAuthorizationStatus, UNNotificationSetting, UNNotificationSetting) {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return (settings.authorizationStatus, settings.alertSetting, settings.notificationCenterSetting)
    }
}

final class DiskNoticeDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DiskNoticeDelegate()
    private weak var index: IndexModel?

    static func install(index: IndexModel) {
        shared.index = index
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(DiskNotices.categories)
        center.delegate = shared
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let (action, diskID) = (response.actionIdentifier, response.notification.request.identifier)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { DiskNoticeDelegate.shared.index?.noticeAnswered(action, diskID: diskID) }
        }
        completionHandler()
    }
}
