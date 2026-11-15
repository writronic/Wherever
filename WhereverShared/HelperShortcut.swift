import AppKit
import Carbon
import Combine

final class HelperShortcut {
    private let sender: HelperSender
    private let defaults: UserDefaults
    private let own: UserDefaults
    private let register: (Hotkey) -> OSStatus
    private let unregister: () -> Void
    private let report: (Notification.Name) -> Void
    private let synchronize: () -> Void
    private var hotkey: Hotkey?
    private var followsLayout: Bool
    private var paused = false
    private var observations: [HelperObservation] = []
    private var subscriptions: [AnyCancellable] = []

    init(
        sender: HelperSender,
        helperPath: String,
        defaults: UserDefaults,
        own: UserDefaults,
        register: @escaping (Hotkey) -> OSStatus,
        unregister: @escaping () -> Void,
        report: @escaping (Notification.Name) -> Void,
        synchronize: @escaping () -> Void = { HelperLink.synchronize() },
        layoutNotifications: NotificationCenter = DistributedNotificationCenter.default(),
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.sender = sender
        self.defaults = defaults
        self.own = own
        self.register = register
        self.unregister = unregister
        self.report = report
        self.synchronize = synchronize
        let stored = Hotkey.stored(in: defaults)
        hotkey = stored.hotkey
        followsLayout = stored.followsLayout
        registerCurrent()
        observations = [
            HelperLink.observe(HelperLink.Note.pause, object: helperPath) { [weak self] in self?.pause() },
            HelperLink.observe(HelperLink.Note.resume, object: helperPath) { [weak self] in self?.resume() },
            HelperLink.observe(HelperLink.Note.sync, object: helperPath) { [weak self] in self?.reload() },
        ]
        let parentPath = sender.parent.path
        subscriptions = [
            layoutNotifications.publisher(for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.inputSourceChanged() } },
            workspaceNotifications.publisher(for: NSWorkspace.didTerminateApplicationNotification)
                .sink { [weak self] note in
                    let ended = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path == parentPath
                    MainActor.assumeIsolated { if ended { self?.resume() } }
                },
        ]
    }

    func pressed() { sender.send(.launcher) }

    func pause() {
        paused = true
        unregister()
    }

    func resume() {
        guard paused else { return }
        paused = false
        registerCurrent()
    }

    func reload() {
        synchronize()
        let before = hotkey
        let stored = Hotkey.stored(in: defaults)
        hotkey = stored.hotkey
        followsLayout = stored.followsLayout
        if hotkey != before { registerCurrent() }
    }

    private func inputSourceChanged() {
        guard followsLayout, hotkey != .summon else { return }
        hotkey = .summon
        registerCurrent()
    }

    private func registerCurrent() {
        guard !paused else { return }
        guard let hotkey else {
            unregister()
            return setFailed(false)
        }
        setFailed(register(hotkey) != noErr)
    }

    private func setFailed(_ failed: Bool) {
        guard own.bool(forKey: HelperLink.Key.shortcutFailed) != failed else { return }
        own.set(failed, forKey: HelperLink.Key.shortcutFailed)
        report(HelperLink.Note.shortcutFailed)
    }
}
