import AppKit

final class Announcer {
    typealias Post = @MainActor (NSWindow, String) -> Void
    typealias Schedule = @MainActor (@escaping @MainActor () -> Void) -> Void

    static let settleDelay = Duration.milliseconds(500)

    static let voiceOver: Post = { window, text in
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    static let afterSettling: Schedule = { work in
        Task {
            try? await Task.sleep(for: settleDelay)
            work()
        }
    }

    static let shared = Announcer()

    private let post: Post
    private let schedule: Schedule
    private var latest = 0
    private let views = NSHashTable<NSView>.weakObjects()

    init(post: @escaping Post = Announcer.voiceOver, schedule: @escaping Schedule = Announcer.afterSettling) {
        self.post = post
        self.schedule = schedule
    }

    func watch(_ view: NSView) { views.add(view) }

    func announce(_ text: String, from view: NSView? = nil) {
        latest += 1
        let request = latest
        let anyWindow = view == nil
        schedule { [weak self, weak view] in
            guard let self, request == latest else { return }
            let windows = anyWindow ? views.allObjects.map(\.window) : [view?.window]
            guard let window = windows.lazy.compactMap({ $0 }).first(where: { $0.isVisible && $0.isKeyWindow }) else { return }
            post(window, text)
        }
    }

    func hush() { latest += 1 }
}
