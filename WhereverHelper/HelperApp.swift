import AppKit
import Foundation

@main
enum HelperApp {
    static func main() {
        guard HelperLock.take(at: HelperLock.file) != nil else { exit(0) }
        UserDefaults.standard.set(HelperLink.identity(of: Bundle.main.bundleURL), forKey: HelperLink.Key.helperIdentity)
        HelperLink.synchronize(domain: HelperLink.helperID)
        let delegate = HelperDelegate()
        let application = NSApplication.shared
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class HelperDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = HelperStatusItem()
    private var hotkey: HelperHotkey?
    private var syncs: HelperObservation?
    private var wake: HelperWake?
    private var wakeTimer: Timer?
    private var mountWatch: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let defaults = UserDefaults(suiteName: HelperLink.whereverID) else {
            NSApp.terminate(nil)
            return
        }
        let endIfUnneeded = { HelperLink.endUnlessNeeded(in: defaults, exit: { NSApp.terminate(nil) }) }
        guard endIfUnneeded() else { return }
        statusItem.start()
        let own = Bundle.main.bundleURL
        if let parent = HelperLink.parent(ofHelperAt: own) {
            let sender = HelperSender.live(parent: parent)
            hotkey = HelperHotkey(sender: sender, helper: own)
            startWaking(sender: sender, wherever: defaults)
        }
        syncs = HelperLink.observe(HelperLink.Note.sync, object: own.path, handler: { _ = endIfUnneeded() })
    }

    private func startWaking(sender: HelperSender, wherever: UserDefaults) {
        let wake = HelperWake(sender: sender, wherever: wherever, own: .standard, later: { delay, work in
            Task {
                try? await Task.sleep(for: .seconds(delay))
                work()
            }
        })
        self.wake = wake
        wakeTimer = Timer.scheduledTimer(withTimeInterval: HelperWake.tick, repeats: true) { _ in
            MainActor.assumeIsolated { wake.timerFired() }
        }
        mountWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            guard let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path(percentEncoded: false) else { return }
            MainActor.assumeIsolated { wake.diskMounted(at: path) }
        }
    }
}
