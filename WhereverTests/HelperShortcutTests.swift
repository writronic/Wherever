import AppKit
import Carbon
import Foundation
import Testing
@testable import Wherever

private let optionCommandK = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey | cmdKey), character: "K")
private let controlOptionJ = Hotkey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey), character: "J")
private let layoutChanged = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "com.writronic.wherever.tests.helpershortcut.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func store(_ key: Hotkey?, in defaults: UserDefaults) throws {
    defaults.set(try key.map { try JSONEncoder().encode($0) } ?? Data(), forKey: HelperLink.Key.summonHotkey)
}

private func delivered(within seconds: Double = 5, _ received: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if received() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return received()
}

private final class Rig {
    let seams = FakeHelperSeams()
    let defaults: UserDefaults
    let own: UserDefaults
    let helperPath = "/tmp/helperkeycode-\(UUID().uuidString)/WhereverHelper.app"
    let layout = NotificationCenter()
    let workspace = NotificationCenter()
    var registered: [Hotkey] = []
    var unregisters = 0
    var status: OSStatus = noErr
    var reports: [Notification.Name] = []
    var syncs = 0
    var shortcut: HelperShortcut?

    init(_ name: String) {
        defaults = freshDefaults("\(name).wherever")
        own = freshDefaults("\(name).helper")
    }

    @discardableResult
    func start(sender: HelperSender? = nil) -> HelperShortcut {
        let made = HelperShortcut(
            sender: sender ?? seams.sender,
            helperPath: helperPath,
            defaults: defaults,
            own: own,
            register: { [unowned self] key in
                registered.append(key)
                return status
            },
            unregister: { [unowned self] in unregisters += 1 },
            report: { [unowned self] name in reports.append(name) },
            synchronize: { [unowned self] in syncs += 1 },
            layoutNotifications: layout,
            workspaceNotifications: workspace
        )
        shortcut = made
        return made
    }

    var failed: Bool { own.bool(forKey: HelperLink.Key.shortcutFailed) }
}

@Suite(.serialized) struct HelperShortcutTests {
    @Test func aPressSendsLauncherToARunningWherever() throws {
        let rig = Rig("press.running")
        try store(optionCommandK, in: rig.defaults)
        let shortcut = rig.start()
        rig.seams.state = .running
        shortcut.pressed()
        #expect(rig.seams.posts == [FakeHelperPost(name: HelperCommand.launcher.notification, object: rig.seams.parent.path)])
        #expect(rig.seams.opens.isEmpty)
    }

    @Test func aPressOpensAClosedWhereverWithTheLauncherCommand() throws {
        let rig = Rig("press.closed")
        try store(optionCommandK, in: rig.defaults)
        let shortcut = rig.start()
        shortcut.pressed()
        #expect(rig.seams.opens == [FakeHelperOpen(app: rig.seams.parent, arguments: ["--command", "launcher"], activates: false)])
        #expect(rig.seams.posts.isEmpty)
    }

    @Test func theStoredKeyIsRegisteredOnceAndAnEmptyStoreRegistersNothing() throws {
        let stored = Rig("register.stored")
        try store(optionCommandK, in: stored.defaults)
        stored.start()
        #expect(stored.registered == [optionCommandK])
        #expect(stored.reports.isEmpty)
        #expect(!stored.failed)

        let off = Rig("register.off")
        try store(nil, in: off.defaults)
        off.start()
        #expect(off.registered.isEmpty)
        #expect(off.unregisters == 1)
    }

    @Test func aPauseNoteReleasesTheKeyAndAResumeNoteTakesItBack() async throws {
        let rig = Rig("pause")
        try store(optionCommandK, in: rig.defaults)
        rig.start()
        HelperLink.post(HelperLink.Note.pause, object: rig.helperPath)
        #expect(await delivered { rig.unregisters == 1 })
        #expect(rig.registered == [optionCommandK])
        HelperLink.post(HelperLink.Note.resume, object: rig.helperPath)
        #expect(await delivered { rig.registered.count == 2 })
        #expect(rig.registered == [optionCommandK, optionCommandK])
    }

    @Test func aNoteForAnotherHelperIsIgnored() async throws {
        let rig = Rig("pause.other")
        try store(optionCommandK, in: rig.defaults)
        rig.start()
        HelperLink.post(HelperLink.Note.pause, object: rig.helperPath + "-other")
        HelperLink.post(HelperLink.Note.pause, object: rig.helperPath)
        #expect(await delivered { rig.unregisters == 1 })
        #expect(rig.unregisters == 1)
    }

    @Test func aResumeWithoutAPauseRegistersNothingMore() throws {
        let rig = Rig("resume.alone")
        try store(optionCommandK, in: rig.defaults)
        let shortcut = rig.start()
        shortcut.resume()
        #expect(rig.registered == [optionCommandK])
    }

    @Test func aKeyChangedWhilePausedIsRegisteredOnlyAtResume() throws {
        let rig = Rig("pause.change")
        try store(optionCommandK, in: rig.defaults)
        let shortcut = rig.start()
        shortcut.pause()
        try store(controlOptionJ, in: rig.defaults)
        shortcut.reload()
        #expect(rig.registered == [optionCommandK])
        shortcut.resume()
        #expect(rig.registered == [optionCommandK, controlOptionJ])
    }

    @Test func theParentEndingResumesAPausedKey() throws {
        let me = NSRunningApplication.current
        let parent = try #require(me.bundleURL)
        let rig = Rig("parent.end")
        try store(optionCommandK, in: rig.defaults)
        let sender = HelperSender(
            parent: parent, state: { .closed }, whenLaunched: { _ in }, post: { _, _ in }, open: { _, _, _ in }
        )
        let shortcut = rig.start(sender: sender)
        shortcut.pause()
        rig.workspace.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: me])
        #expect(rig.registered == [optionCommandK, optionCommandK])
    }

    @Test func anotherAppEndingLeavesTheKeyPaused() throws {
        let me = NSRunningApplication.current
        let rig = Rig("parent.other")
        try store(optionCommandK, in: rig.defaults)
        let shortcut = rig.start()
        shortcut.pause()
        rig.workspace.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: me])
        #expect(rig.registered == [optionCommandK])
    }

    @Test func aFailedRegistrationIsStoredAndReportedOnce() throws {
        let rig = Rig("fail")
        rig.status = OSStatus(eventHotKeyExistsErr)
        try store(optionCommandK, in: rig.defaults)
        let shortcut = rig.start()
        #expect(rig.failed)
        #expect(rig.reports == [HelperLink.Note.shortcutFailed])
        try store(controlOptionJ, in: rig.defaults)
        shortcut.reload()
        #expect(rig.failed)
        #expect(rig.reports == [HelperLink.Note.shortcutFailed])
    }

    @Test func aLaterSuccessClearsTheFailureAndReportsIt() throws {
        let rig = Rig("fail.clear")
        rig.status = OSStatus(eventHotKeyExistsErr)
        try store(optionCommandK, in: rig.defaults)
        let shortcut = rig.start()
        rig.status = noErr
        try store(controlOptionJ, in: rig.defaults)
        shortcut.reload()
        #expect(!rig.failed)
        #expect(rig.reports == [HelperLink.Note.shortcutFailed, HelperLink.Note.shortcutFailed])
        #expect(rig.registered == [optionCommandK, controlOptionJ])
    }

    @Test func turningTheShortcutOffClearsAFailure() throws {
        let rig = Rig("fail.off")
        rig.status = OSStatus(eventHotKeyExistsErr)
        try store(optionCommandK, in: rig.defaults)
        let shortcut = rig.start()
        try store(nil, in: rig.defaults)
        shortcut.reload()
        #expect(!rig.failed)
        #expect(rig.unregisters == 1)
    }

    @Test func aResumeThatSucceedsClearsAFailureFromBeforeThePause() throws {
        let rig = Rig("fail.resume")
        rig.status = OSStatus(eventHotKeyExistsErr)
        try store(optionCommandK, in: rig.defaults)
        let shortcut = rig.start()
        shortcut.pause()
        #expect(rig.failed)
        rig.status = noErr
        shortcut.resume()
        #expect(!rig.failed)
    }

    @Test func aSyncNoteReadsTheStoreAgain() async throws {
        let rig = Rig("sync")
        try store(optionCommandK, in: rig.defaults)
        rig.start()
        try store(controlOptionJ, in: rig.defaults)
        HelperLink.post(HelperLink.Note.sync, object: rig.helperPath)
        #expect(await delivered { rig.registered.count == 2 })
        #expect(rig.registered == [optionCommandK, controlOptionJ])
        #expect(rig.syncs == 1)
    }

    @Test func aLayoutChangeMovesTheDefaultKeyButNotARecordedOne() throws {
        let original = Hotkey.layoutCharacter
        defer { Hotkey.layoutCharacter = original }
        Hotkey.layoutCharacter = { $0 == UInt32(kVK_ANSI_F) ? "f" : "" }
        let followed = Rig("layout.default")
        followed.start()
        #expect(followed.registered.map(\.keyCode) == [UInt32(kVK_ANSI_F)])
        Hotkey.layoutCharacter = { $0 == UInt32(kVK_ANSI_Y) ? "f" : "" }
        followed.layout.post(name: layoutChanged, object: nil)
        #expect(followed.registered.map(\.keyCode) == [UInt32(kVK_ANSI_F), UInt32(kVK_ANSI_Y)])

        let recorded = Rig("layout.recorded")
        try store(optionCommandK, in: recorded.defaults)
        recorded.start()
        recorded.layout.post(name: layoutChanged, object: nil)
        #expect(recorded.registered == [optionCommandK])
    }
}
