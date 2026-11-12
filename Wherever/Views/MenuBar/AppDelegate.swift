import AppKit
import Combine
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var setRegular: () -> Void = { NSApp.setActivationPolicy(.regular) }
    var summon: () -> Void = {}
    var refreshLoginStatus: () -> Void = {}
    var terminate: () -> Void = { NSApp.terminate(nil) }
    var reply: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    @Published private(set) var didFinishLaunching = false
    var finishLaunch: () -> Void = {}
    var launchCommand = HelperLink.command(in: ProcessInfo.processInfo.arguments)
    var launchMounted = HelperLink.mounted(in: ProcessInfo.processInfo.arguments)
    var postHelperQuit: () -> Void = {}
    var flushOpens: () -> Void = {}
    private var quitByHelper = false
    private var asking = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        if !HelperCommands.startsHidden(launchCommand) { setRegular() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishLaunch()
        didFinishLaunching = true
        refreshLoginStatus()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        summon()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshLoginStatus()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !asking else { return .terminateCancel }
        guard ArchiveEdits.unsaved else { return .terminateNow }
        asking = true
        ArchiveEdits.resolve { [self] saved in
            if !saved { quitByHelper = false }
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.answer(saved) } }
        }
        return .terminateLater
    }

    private func answer(_ quits: Bool) {
        asking = false
        reply(quits)
    }

    func quitFromHelper() {
        quitByHelper = true
        terminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        flushOpens()
        if quitByHelper { postHelperQuit() }
    }
}
