import AppKit
import Foundation

final class AppPresence: NSObject {
    var staysRunning: () -> Bool = { true }
    private var quitHolds = 0
    var quit: () -> Void = {}
    private let apply: (NSApplication.ActivationPolicy) -> Void
    private let openWindows = NSHashTable<NSWindow>.weakObjects()
    private(set) var awaitingWindow = false

    init(center: NotificationCenter = .default, apply: @escaping (NSApplication.ActivationPolicy) -> Void) {
        self.apply = apply
        super.init()
        center.addObserver(self, selector: #selector(windowOpened), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowOpened), name: NSWindow.didBecomeMainNotification, object: nil)
        center.addObserver(self, selector: #selector(windowUpdated), name: NSWindow.didUpdateNotification, object: nil)
        center.addObserver(self, selector: #selector(windowUpdated), name: NSWindow.didMiniaturizeNotification, object: nil)
        center.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: nil)
    }

    func applyPolicy() {
        apply(awaitingWindow || !openWindows.allObjects.isEmpty ? .regular : .accessory)
    }

    func prepareToShowWindow() {
        if openWindows.allObjects.isEmpty { awaitingWindow = true }
        applyPolicy()
    }

    func quitIfIdle() {
        DispatchQueue.main.async { [weak self] in
            guard let self, quitHolds == 0, !awaitingWindow, openWindows.allObjects.isEmpty, !staysRunning() else { return }
            quit()
        }
    }

    func holdQuit(for seconds: TimeInterval) {
        quitHolds += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            quitHolds -= 1
            quitIfIdle()
        }
    }

    @objc private func windowOpened(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !(window is NSPanel),
              window.styleMask.contains(.titled), window.alphaValue > 0, !openWindows.contains(window) else { return }
        openWindows.add(window)
        awaitingWindow = false
        applyPolicy()
    }

    @objc private func windowUpdated(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.isVisible || window.isMiniaturized else { return }
        windowOpened(notification)
    }

    @objc private func windowClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, openWindows.contains(window) else { return }
        openWindows.remove(window)
        applyPolicy()
        quitIfIdle()
    }
}

final class CommandLinger {
    private let seconds: TimeInterval
    private let ended: () -> Void
    private(set) var timer: Timer?
    private var observation: HelperObservation?
    private var served = false

    init(seconds: TimeInterval = 10, ended: @escaping () -> Void) {
        self.seconds = seconds
        self.ended = ended
    }

    var running: Bool { timer != nil }

    func observeDone(path: String) {
        observation = HelperLink.observe(HelperLink.Note.commandDone, object: path) { [weak self] in self?.commandDone() }
    }

    func start() {
        served = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    func commandDone() {
        if served { start() }
    }

    private func finish() {
        timer = nil
        ended()
    }
}
