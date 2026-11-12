import AppKit
import Carbon
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Wherever

private let optionCommandK = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey | cmdKey), character: "K")
private let controlOptionK = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), character: "K")

private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "com.writronic.wherever.tests.hotkey.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func helperURL() -> URL {
    HelperLink.embeddedHelper(in: URL(fileURLWithPath: "/tmp/hotkeytests-\(UUID().uuidString)/Wherever.app"))
}

private let pauseThenResume = [HelperLink.Note.pause, HelperLink.Note.resume]
private let recordedTrace = [HelperLink.Note.pause, HelperLink.Note.sync, HelperLink.Note.resume]

@Suite(.serialized) struct HotkeyModelTests {
    @Test func anEmptySuiteShowsControlShiftFAndTellsTheHelperNothing() {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("default"))
        #expect(spy.notes.isEmpty)
        #expect(model.hotkey == .summon)
        #expect(Hotkey.summon.keyCode == UInt32(kVK_ANSI_F))
        #expect(Hotkey.summon.modifiers == UInt32(controlKey | shiftKey))
        #expect(!model.registrationFailed)
    }

    @Test func aStoredKeyIsTheOneShown() throws {
        let defaults = freshDefaults("stored")
        defaults.set(try JSONEncoder().encode(optionCommandK), forKey: HotkeyModel.defaultsKey)
        let spy = HelperStarterSpy()
        let model = spy.model(defaults)
        #expect(spy.notes.isEmpty)
        #expect(model.hotkey == optionCommandK)
    }

    @Test func aChangeWritesTheKeyBeforeItSyncsAndSurvivesARelaunch() {
        let defaults = freshDefaults("change")
        let spy = HelperStarterSpy()
        var storedAtSync: Hotkey?
        spy.onPost = { if $0 == HelperLink.Note.sync { storedAtSync = Hotkey.stored(in: defaults).hotkey } }
        let model = spy.model(defaults)
        model.set(optionCommandK)
        #expect(spy.notes == [HelperLink.Note.sync])
        #expect(storedAtSync == optionCommandK)
        #expect(model.hotkey == optionCommandK)

        let relaunched = HelperStarterSpy()
        let again = relaunched.model(defaults)
        #expect(relaunched.notes.isEmpty)
        #expect(again.hotkey == optionCommandK)
    }

    @Test func settingTheKeyThatIsAlreadySetStillSyncsSoTheHelperStopsFollowingTheLayout() {
        let defaults = freshDefaults("same")
        #expect(Hotkey.stored(in: defaults).followsLayout)
        let spy = HelperStarterSpy()
        let model = spy.model(defaults)
        model.set(.summon)
        #expect(spy.notes == [HelperLink.Note.sync])
        #expect(!Hotkey.stored(in: defaults).followsLayout)
    }

    @Test func clearingSyncsOnceAndStaysClearedAfterARelaunch() {
        let defaults = freshDefaults("clear")
        let spy = HelperStarterSpy()
        let model = spy.model(defaults)
        model.set(nil)
        #expect(spy.notes == [HelperLink.Note.sync])
        #expect(model.hotkey == nil)
        #expect(defaults.data(forKey: HotkeyModel.defaultsKey) == Data())

        let relaunched = HelperStarterSpy()
        let again = relaunched.model(defaults)
        #expect(relaunched.notes.isEmpty)
        #expect(again.hotkey == nil)
    }

    @Test func aKeySetWithTheIconOffAndNoHelperOpensTheHelper() {
        let defaults = freshDefaults("opens")
        defaults.set(true, forKey: AccessModel.completedKey)
        defaults.set(false, forKey: MenuBarIcon.key)
        defaults.set(Data(), forKey: HotkeyModel.defaultsKey)
        let spy = HelperStarterSpy()
        let model = spy.model(defaults)
        model.set(controlOptionK)
        #expect(spy.opens.count == 1)
        #expect(spy.opens.allSatisfy { !$0.activates })
        #expect(spy.notes.isEmpty)
    }

    @Test func anUnreadableValueFallsBackToControlShiftF() throws {
        let shiftOnly = Hotkey(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(shiftKey), character: "F")
        let inspector = Hotkey(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(optionKey | cmdKey), character: "I")
        let garbage: [String: Any] = [
            "text": "garbage", "bytes": Data("not json".utf8), "number": 7, "shift only": try JSONEncoder().encode(shiftOnly),
            "show inspector": try JSONEncoder().encode(inspector),
        ]
        for (label, value) in garbage {
            let defaults = freshDefaults("garbage")
            defaults.set(value, forKey: HotkeyModel.defaultsKey)
            #expect(HelperStarterSpy().model(defaults).hotkey == .summon, "\(label)")
        }
    }

    @Test func aStoredSaveKeyFallsBackToControlShiftF() throws {
        let save = Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey), character: "S")
        let saveAs = Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(shiftKey | cmdKey), character: "S")
        for (label, value) in [("save", save), ("save as", saveAs)] {
            let defaults = freshDefaults("stored-save")
            defaults.set(try JSONEncoder().encode(value), forKey: HotkeyModel.defaultsKey)
            #expect(HelperStarterSpy().model(defaults).hotkey == .summon, "\(label)")
        }
    }

    @Test func aFailureAlreadyStoredShowsAtLaunch() {
        let own = freshDefaults("failure.stored.own")
        own.set(true, forKey: HelperLink.Key.shortcutFailed)
        #expect(HelperStarterSpy().model(freshDefaults("failure.stored"), own: own).registrationFailed)
    }

    @Test func aFailureNoteShowsTheFailureAndALaterSuccessNoteClearsIt() async throws {
        let own = freshDefaults("failure.note.own")
        let helper = helperURL()
        let model = HelperStarterSpy().model(freshDefaults("failure.note"), own: own, helper: helper)
        #expect(!model.registrationFailed)
        own.set(true, forKey: HelperLink.Key.shortcutFailed)
        HelperLink.post(HelperLink.Note.shortcutFailed, object: helper.path)
        try await untilTrue(waitingFor: "the failure to show") { model.registrationFailed }
        own.set(false, forKey: HelperLink.Key.shortcutFailed)
        HelperLink.post(HelperLink.Note.shortcutFailed, object: helper.path)
        try await untilTrue(waitingFor: "the failure to clear") { !model.registrationFailed }
    }

    @Test func aFailureNoteFromAnotherHelperIsIgnored() async throws {
        let own = freshDefaults("failure.other.own")
        let helper = helperURL()
        let model = HelperStarterSpy().model(freshDefaults("failure.other"), own: own, helper: helper)
        own.set(true, forKey: HelperLink.Key.shortcutFailed)
        HelperLink.post(HelperLink.Note.shortcutFailed, object: helper.path + "-other")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.registrationFailed)
    }

    @Test func aClearedShortcutNeverShowsAFailure() {
        let own = freshDefaults("failure.cleared.own")
        own.set(true, forKey: HelperLink.Key.shortcutFailed)
        let model = HelperStarterSpy().model(freshDefaults("failure.cleared"), own: own)
        #expect(model.registrationFailed)
        model.set(nil)
        #expect(!model.registrationFailed)
    }

    @Test func recordingWithATestHostStarterPostsNothing() {
        let defaults = freshDefaults("host")
        let spy = HelperStarterSpy()
        let model = HotkeyModel(defaults: defaults, helper: spy.starter(defaults: defaults, previews: true), windows: { [] }, unhide: {}, activate: {})
        model.startRecording()
        model.set(optionCommandK)
        model.stopRecording()
        #expect(spy.notes.isEmpty && spy.opens.isEmpty)
    }

    @Test func stoppingWithNoRecordingPostsNoResume() {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("idle"))
        model.stopRecording()
        #expect(spy.notes.isEmpty)
    }

    @Test func startingThenStoppingPostsPauseThenResume() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("escape"))
        model.startRecording()
        #expect(spy.notes == [HelperLink.Note.pause])
        model.stopRecording()
        #expect(spy.notes == pauseThenResume)
    }

    @Test func aRefusedKeyKeepsTheKeyPaused() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("refused"))
        model.startRecording()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "F", charactersIgnoringModifiers: "F", isARepeat: false, keyCode: UInt16(kVK_ANSI_F)
        ))
        model.record(event)
        #expect(spy.notes == [HelperLink.Note.pause])
        #expect(model.isRecording)
        model.stopRecording()
    }

    @Test func aRecordedKeyPausesThenWritesAndSyncsThenResumes() throws {
        let defaults = freshDefaults("trace")
        let spy = HelperStarterSpy()
        var storedAtSync: Hotkey?
        spy.onPost = { if $0 == HelperLink.Note.sync { storedAtSync = Hotkey.stored(in: defaults).hotkey } }
        let model = spy.model(defaults)
        model.startRecording()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{0B}", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K)
        ))
        model.record(event)
        #expect(spy.notes == recordedTrace)
        #expect(storedAtSync == controlOptionK)
        #expect(!model.isRecording)
    }
}

@Suite(.serialized) struct HotkeyLayoutTests {
    private func withLayout(_ body: () throws -> Void) rethrows {
        let original = Hotkey.layoutCharacter
        defer { Hotkey.layoutCharacter = original }
        try body()
    }

    private func layoutChanged(_ center: NotificationCenter) {
        center.post(name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
    }

    @Test func theDefaultFollowsTheLetterFOnDvorakColemakAndTurkishF() {
        withLayout {
            for code in [kVK_ANSI_Y, kVK_ANSI_E, kVK_ANSI_Q] {
                Hotkey.layoutCharacter = { $0 == UInt32(code) ? "f" : "" }
                let model = HelperStarterSpy().model(freshDefaults("layout.default"))
                #expect(Hotkey.summon.keyCode == UInt32(code))
                #expect(Hotkey.summon.displayString == "⌃⇧F")
                #expect(model.hotkey == .summon)
            }
        }
    }

    @Test func aRecordedPhysicalKeyUsesItsCurrentLayoutCharacter() {
        withLayout {
            let key = Hotkey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | shiftKey), character: "J")
            Hotkey.layoutCharacter = { $0 == UInt32(kVK_ANSI_J) ? "h" : "" }
            #expect(key.displayString == "⌃⇧H")
            #expect(key.character == "J")
            #expect(key.keyCode == UInt32(kVK_ANSI_J))
        }
    }

    @Test func missingTranslationsKeepTheStoredCharacterAndDefaultPhysicalKey() {
        withLayout {
            Hotkey.layoutCharacter = { _ in "" }
            let key = Hotkey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey), character: "J")
            #expect(key.displayString == "⌃J")
            #expect(Hotkey.summon.keyCode == UInt32(kVK_ANSI_F))
            #expect(Hotkey.summon.displayString == "⌃⇧F")
            Hotkey.layoutCharacter = { _ in "wrong" }
            let space = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey), character: " ")
            #expect(space.displayString == "⌃⇧" + String(localized: "Space", table: "Hotkey"))
        }
    }

    @Test func layoutNotificationsMoveOnlyTheUnrecordedDefaultAndWriteNothing() {
        withLayout {
            Hotkey.layoutCharacter = { $0 == UInt32(kVK_ANSI_F) ? "f" : "" }
            let defaults = freshDefaults("layout.change")
            let center = NotificationCenter()
            let spy = HelperStarterSpy()
            let model = spy.model(defaults, layoutNotifications: center)
            for code in [kVK_ANSI_Y, kVK_ANSI_E, kVK_ANSI_Q] {
                Hotkey.layoutCharacter = { $0 == UInt32(code) ? "f" : "" }
                layoutChanged(center)
                #expect(model.hotkey?.keyCode == UInt32(code))
            }
            #expect(spy.notes.isEmpty)
            #expect(defaults.object(forKey: HotkeyModel.defaultsKey) == nil)
        }
    }

    @Test func aStoredKeyPublishesItsNewLabelWithoutChangingStorage() throws {
        try withLayout {
            Hotkey.layoutCharacter = { $0 == UInt32(kVK_ANSI_J) ? "j" : "" }
            let key = Hotkey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | shiftKey), character: "J")
            let defaults = freshDefaults("layout.stored")
            let data = try JSONEncoder().encode(key)
            defaults.set(data, forKey: HotkeyModel.defaultsKey)
            let center = NotificationCenter()
            let spy = HelperStarterSpy()
            let model = spy.model(defaults, layoutNotifications: center)
            var changes = 0
            let observation = model.objectWillChange.sink { changes += 1 }
            defer { observation.cancel() }
            Hotkey.layoutCharacter = { $0 == UInt32(kVK_ANSI_J) ? "h" : "" }
            layoutChanged(center)
            #expect(changes > 0)
            #expect(model.hotkey == key)
            #expect(model.hotkey?.displayString == "⌃⇧H")
            #expect(KeyboardShortcuts.sections(hotkey: model.hotkey)[1].rows[0].keys == "⌃⇧H")
            #expect(spy.notes.isEmpty)
            #expect(defaults.data(forKey: HotkeyModel.defaultsKey) == data)
        }
    }

    @Test func recordingTheCurrentDefaultPinsItsPhysicalKeyAcrossLayoutsAndRelaunches() throws {
        try withLayout {
            Hotkey.layoutCharacter = { $0 == UInt32(kVK_ANSI_F) ? "f" : "" }
            let defaults = freshDefaults("layout.record.default")
            let center = NotificationCenter()
            let spy = HelperStarterSpy()
            let model = spy.model(defaults, layoutNotifications: center)
            let original = try #require(model.hotkey)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0, windowNumber: 0, context: nil,
                characters: "F", charactersIgnoringModifiers: "F", isARepeat: false, keyCode: UInt16(kVK_ANSI_F)
            ))
            model.record(event)
            let saved = try #require(defaults.data(forKey: HotkeyModel.defaultsKey))
            #expect(try JSONDecoder().decode(Hotkey.self, from: saved) == original)
            #expect(spy.notes == [HelperLink.Note.sync])
            Hotkey.layoutCharacter = { code in
                if code == UInt32(kVK_ANSI_Y) { return "f" }
                return code == UInt32(kVK_ANSI_F) ? "u" : ""
            }
            layoutChanged(center)
            #expect(model.hotkey == original)
            #expect(model.hotkey?.displayString == "⌃⇧U")
            #expect(HelperStarterSpy().model(defaults).hotkey == original)
        }
    }

    @Test func changingLayoutKeepsAClearedShortcutDisabled() {
        withLayout {
            Hotkey.layoutCharacter = { $0 == UInt32(kVK_ANSI_F) ? "f" : "" }
            let defaults = freshDefaults("layout.clear")
            let center = NotificationCenter()
            let spy = HelperStarterSpy()
            let model = spy.model(defaults, layoutNotifications: center)
            model.set(nil)
            Hotkey.layoutCharacter = { $0 == UInt32(kVK_ANSI_Y) ? "f" : "" }
            layoutChanged(center)
            #expect(model.hotkey == nil)
            #expect(defaults.data(forKey: HotkeyModel.defaultsKey) == Data())
            let again = spy.model(defaults, layoutNotifications: center)
            layoutChanged(center)
            #expect(again.hotkey == nil)
        }
    }
}

@Suite struct HotkeyPolicyTests {
    private func key(_ code: Int, _ modifiers: Int, _ character: String) -> Hotkey {
        Hotkey(keyCode: UInt32(code), modifiers: UInt32(modifiers), character: character)
    }

    @Test func aKeyNeedsControlOptionOrCommand() {
        #expect(key(kVK_ANSI_F, shiftKey, "F").refusal == .needsModifier)
        #expect(key(kVK_ANSI_F, 0, "F").refusal == .needsModifier)
        #expect(key(kVK_Space, 0, " ").refusal == .needsModifier)
        #expect(key(kVK_ANSI_F, controlKey | shiftKey, "F").refusal == nil)
        #expect(key(kVK_ANSI_K, controlKey | optionKey, "K").refusal == nil)
        #expect(key(kVK_ANSI_K, optionKey, "K").refusal == nil)
        #expect(key(kVK_ANSI_K, cmdKey, "K").refusal == nil)
        #expect(Hotkey.summon.refusal == nil)
    }

    @Test func theSystemSpaceKeysAreRefused() {
        let taken = [cmdKey, optionKey | cmdKey, controlKey, controlKey | optionKey, shiftKey | cmdKey]
        for modifiers in taken {
            #expect(key(kVK_Space, modifiers, " ").refusal == .systemKey, "space with \(modifiers)")
        }
        #expect(key(kVK_Space, controlKey | shiftKey, " ").refusal == nil)
        #expect(key(kVK_Space, controlKey | cmdKey, " ").refusal == nil)
    }

    @Test func theAppsOwnCommandKeysAreRefused() {
        let own = [kVK_ANSI_N, kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_Comma, kVK_ANSI_C]
        for code in own {
            #expect(key(code, cmdKey, "x").refusal == .appKey, "command with \(code)")
            #expect(key(code, cmdKey | shiftKey, "x").refusal == nil, "command shift with \(code)")
        }
        #expect(key(kVK_Return, cmdKey, "\r").refusal == .appKey)
    }

    @Test func theAppsOwnMenuKeysWithOtherModifiersAreRefused() {
        #expect(key(kVK_ANSI_I, optionKey | cmdKey, "I").refusal == .appKey)
        #expect(key(kVK_ANSI_Period, shiftKey | cmdKey, ".").refusal == .appKey)
        #expect(key(kVK_ANSI_I, cmdKey, "I").refusal == nil)
        #expect(key(kVK_ANSI_I, controlKey | optionKey | cmdKey, "I").refusal == nil)
        #expect(key(kVK_ANSI_Period, cmdKey, ".").refusal == nil)
        #expect(key(kVK_ANSI_Period, controlKey | shiftKey | cmdKey, ".").refusal == nil)
        #expect(key(kVK_ANSI_N, shiftKey | cmdKey, "N").refusal == nil)
    }

    @Test func theSaveKeysOfTheArchiveWindowAreRefused() {
        #expect(key(kVK_ANSI_S, cmdKey, "S").refusal == .appKey)
        #expect(key(kVK_ANSI_S, shiftKey | cmdKey, "S").refusal == .appKey)
        #expect(key(kVK_ANSI_S, optionKey | cmdKey, "S").refusal == nil)
        #expect(key(kVK_ANSI_S, controlKey | cmdKey, "S").refusal == nil)
        #expect(key(kVK_ANSI_S, controlKey | optionKey, "S").refusal == nil)
        #expect(key(kVK_ANSI_S, controlKey | shiftKey | cmdKey, "S").refusal == nil)
    }

    @Test func theStandardAppAndEditMenuKeysAreRefused() {
        let own: [(code: Int, modifiers: Int)] = [
            (kVK_ANSI_H, cmdKey), (kVK_ANSI_H, optionKey | cmdKey), (kVK_ANSI_M, cmdKey), (kVK_ANSI_A, cmdKey), (kVK_ANSI_X, cmdKey),
            (kVK_ANSI_V, cmdKey), (kVK_ANSI_Z, cmdKey), (kVK_ANSI_Z, shiftKey | cmdKey),
        ]
        for (code, modifiers) in own {
            #expect(key(code, modifiers, "x").refusal == .appKey, "key \(code) with \(modifiers)")
            #expect(key(code, modifiers | controlKey, "x").refusal == nil, "key \(code) with \(modifiers) and control")
        }
        #expect(key(kVK_ANSI_V, shiftKey | cmdKey, "V").refusal == nil)
        #expect(key(kVK_ANSI_H, shiftKey | cmdKey, "H").refusal == nil)
    }

    @Test func aKeyWithNothingToShowIsRefused() {
        #expect(key(kVK_LeftArrow, controlKey | optionKey, "\u{F702}").refusal == .unsupportedKey)
        #expect(key(kVK_F5, controlKey, "\u{F708}").refusal == .unsupportedKey)
        #expect(key(kVK_Tab, controlKey, "\t").refusal == .unsupportedKey)
        #expect(key(kVK_ANSI_K, controlKey, "").refusal == .unsupportedKey)
    }

    @Test func everyRefusalHasAReadableReason() {
        for refusal in [Hotkey.Refusal.needsModifier, .systemKey, .appKey, .unsupportedKey] {
            #expect(!refusal.message.isEmpty, "\(refusal)")
        }
    }

    @Test func theDisplayStringFollowsTheMacOSOrder() {
        #expect(Hotkey.summon.displayString == "⌃⇧F")
        #expect(key(kVK_ANSI_K, cmdKey | shiftKey | optionKey | controlKey, "K").displayString == "⌃⌥⇧⌘K")
        #expect(optionCommandK.displayString == "⌥⌘K")
    }

    @Test func aKeyEventBecomesCarbonBitsAndAnUppercaseCharacter() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{0B}", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K)
        ))
        #expect(Hotkey(event) == controlOptionK)
    }

    @Test func aShiftedDigitKeepsTheDigit() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "!", charactersIgnoringModifiers: "!", isARepeat: false, keyCode: UInt16(kVK_ANSI_1)
        ))
        let hotkey = Hotkey(event)
        #expect(hotkey.displayString == "⌃⇧1")
        #expect(hotkey.keyCode == UInt32(kVK_ANSI_1))
        #expect(hotkey.modifiers == UInt32(controlKey | shiftKey))
        #expect(hotkey.refusal == nil)
    }

    @Test func aKeySurvivesTheStoredFormat() throws {
        let stored = try JSONEncoder().encode(optionCommandK)
        #expect(try JSONDecoder().decode(Hotkey.self, from: stored) == optionCommandK)
    }
}

private final class SpyWindow: NSWindow {
    var minimized = false
    var shown = false
    var log: [String] = []
    var name = ""

    convenience init(_ identifier: String, minimized: Bool = false, visible: Bool = false) {
        self.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        self.minimized = minimized
        shown = visible
        name = identifier
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        isReleasedWhenClosed = false
    }

    override var isMiniaturized: Bool { minimized }
    override var isVisible: Bool { shown }

    override func deminiaturize(_ sender: Any?) {
        log.append("deminiaturize \(name)")
        minimized = false
        shown = true
    }

    override func makeKeyAndOrderFront(_ sender: Any?) { log.append("front \(name)") }
}

@Suite struct HotkeySummonTests {
    private final class Trace {
        var events: [String] = []
    }

    private func model(_ windows: [SpyWindow], _ trace: Trace, name: String) -> HotkeyModel {
        let model = HotkeyModel(
            defaults: freshDefaults("summon.\(name)"),
            windows: { windows }, unhide: { trace.events.append("unhide") }, activate: { trace.events.append("activate") }
        )
        model.configure { trace.events.append("open") }
        return model
    }

    @Test func aMinimizedMainWindowIsRestoredAndFrontedWithNothingOpened() {
        let trace = Trace()
        let minimized = SpyWindow("main-AppWindow-1", minimized: true)
        model([minimized], trace, name: "minimized").summon()
        #expect(minimized.log == ["deminiaturize main-AppWindow-1", "front main-AppWindow-1"])
        #expect(trace.events == ["unhide", "activate"])
    }

    @Test func aVisibleMainWindowIsFrontedNotRestored() {
        let trace = Trace()
        let visible = SpyWindow("main-AppWindow-1", visible: true)
        model([visible], trace, name: "visible").summon()
        #expect(visible.log == ["front main-AppWindow-1"])
        #expect(trace.events == ["unhide", "activate"])
    }

    @Test func aMainWindowHiddenByAlphaDoesNotAnswerTheSummon() {
        let trace = Trace()
        let hidden = SpyWindow("main-AppWindow-1", visible: true)
        hidden.alphaValue = 0
        model([hidden], trace, name: "hidden").summon()
        #expect(hidden.log.isEmpty)
        #expect(trace.events == ["unhide", "open", "activate"])
    }

    @Test func theFirstVisibleMainWindowIsTheOneFronted() {
        let trace = Trace()
        let first = SpyWindow("main-AppWindow-2", visible: true)
        let second = SpyWindow("main-AppWindow-1", visible: true)
        let minimized = SpyWindow("main-AppWindow-3", minimized: true)
        model([first, second, minimized], trace, name: "order").summon()
        #expect(first.log == ["front main-AppWindow-2"])
        #expect(second.log.isEmpty)
        #expect(minimized.log.isEmpty)
    }

    @Test func withNoMainWindowExactlyOneIsOpened() {
        let trace = Trace()
        model([], trace, name: "none").summon()
        #expect(trace.events == ["unhide", "open", "activate"])
    }

    @Test func aSettingsWindowIsNotAMainWindow() {
        let trace = Trace()
        let settings = SpyWindow("com_apple_SwiftUI_Settings_window", visible: true)
        let other = SpyWindow("mainframe", visible: true)
        let unnamed = SpyWindow("")
        model([settings, other, unnamed], trace, name: "settings").summon()
        #expect(trace.events == ["unhide", "open", "activate"])
        #expect(settings.log.isEmpty && other.log.isEmpty && unnamed.log.isEmpty)
    }

    @Test func aMainWindowThatIsNeitherVisibleNorMinimizedCountsAsClosed() {
        let trace = Trace()
        let closed = SpyWindow("main-AppWindow-1")
        model([closed], trace, name: "closed").summon()
        #expect(trace.events == ["unhide", "open", "activate"])
        #expect(closed.log.isEmpty)
    }
}

@Suite struct HotkeyHostTests {
    @Test func theAppBinaryImportsNoCarbonHotKeyCall() throws {
        #expect(WhereverApp.usesPreviewServices)
        let folder = try #require(Bundle.main.executableURL).deletingLastPathComponent()
        let binaries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map { try Data(contentsOf: $0) }
        let holds = { (symbol: String) in binaries.contains { $0.range(of: Data(symbol.utf8)) != nil } }
        #expect(holds("_CFPreferencesAppSynchronize"), "the scan read no binary with the app's code")
        #expect(!holds("_RegisterEventHotKey"))
        #expect(!holds("_InstallEventHandler"))
    }

    @Test func theAppsMainWindowIdentifierIsTheGroupsId() {
        #expect(MainWindow.id == "main")
        let window = SpyWindow("main-AppWindow-1")
        #expect(MainWindow.isMain(window))
        window.identifier = NSUserInterfaceItemIdentifier("main")
        #expect(MainWindow.isMain(window))
    }
}

private final class RecorderHost {
    let window: KeyedWindow
    let view: NSView

    init(model: HotkeyModel, post: @escaping Announcer.Post = { _, _ in }) {
        let controller = NSHostingController(rootView: HotkeyRecorder(model: model, post: post).environment(\.locale, Locale(identifier: "en")))
        window = KeyedWindow(contentViewController: controller)
        view = controller.view
        window.setContentSize(NSSize(width: 320, height: 120))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            window.reportsKey = true
            window.becomeKey()
        }
    }

    func close() {
        window.contentViewController = nil
        window.close()
    }

    func send(_ characters: String, _ code: Int, _ flags: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(code)
        ))
        NSApp.sendEvent(event)
    }

    func until(
        _ description: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        try await untilTrue(waitingFor: description(), sourceLocation: sourceLocation) {
            view.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    var buttonValue: String? {
        AXTree.control("Launcher shortcut", in: view).flatMap { AXTree.value("accessibilityValue", of: $0) as String? }
    }

    func shows(_ text: String) -> Bool {
        ([view] + descendants(in: view)).flatMap { texts(in: $0) }.contains { $0.contains(text) }
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func texts(in object: NSObject) -> [String] {
        var found = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { key in
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) as? String : nil
        }
        if object.responds(to: NSSelectorFromString("accessibilityChildren")) {
            for child in object.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] { found += texts(in: child) }
        }
        return found
    }
}

private func mainWindowCount() -> Int { NSApp.windows.filter(MainWindow.isMain).count }

@Suite(.serialized) struct HotkeyRecorderTests {
    private let shift: NSEvent.ModifierFlags = [.shift]
    private let command: NSEvent.ModifierFlags = [.command]
    private let controlOption: NSEvent.ModifierFlags = [.control, .option]

    @Test func aRecordedKeyReachesTheModelAndEndsTheRecording() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("rec.accept"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        model.startRecording()
        try host.send("k", kVK_ANSI_K, controlOption)
        #expect(model.hotkey == controlOptionK)
        #expect(spy.notes == recordedTrace)
        #expect(!model.isRecording)
        #expect(model.refusal == nil)
    }

    @Test func refusedKeysChangeNothingAndNeverReachTheMenu() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("rec.refuse"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        model.startRecording()
        try host.send("k", kVK_ANSI_K, controlOption)
        try #require(model.hotkey == controlOptionK)

        let refused: [(String, Int, NSEvent.ModifierFlags, Hotkey.Refusal)] = [
            ("F", kVK_ANSI_F, shift, .needsModifier), ("f", kVK_ANSI_F, [], .needsModifier),
            (" ", kVK_Space, command, .systemKey), ("n", kVK_ANSI_N, command, .appKey),
        ]
        model.startRecording()
        let windowsBefore = mainWindowCount()
        for (character, code, flags, reason) in refused {
            spy.notes = []
            try host.send(character, code, flags)
            #expect(model.refusal == reason, "\(reason)")
            #expect(model.hotkey == controlOptionK, "\(reason)")
            #expect(spy.notes.isEmpty, "\(reason)")
            #expect(model.isRecording, "\(reason)")
        }
        #expect(mainWindowCount() == windowsBefore)
    }

    @Test func theSaveKeysNeverBecomeTheShortcutAndTheNextKeyStillDoes() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("rec.save"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        model.startRecording()
        for (character, flags) in [("s", command), ("S", [.command, .shift] as NSEvent.ModifierFlags)] {
            spy.notes = []
            try host.send(character, kVK_ANSI_S, flags)
            #expect(model.refusal == .appKey, "Command\(flags.contains(.shift) ? "-Shift" : "")-S")
            #expect(model.hotkey == .summon)
            #expect(spy.notes.isEmpty)
            #expect(model.isRecording)
        }
        try host.send("s", kVK_ANSI_S, controlOption)
        #expect(model.hotkey?.keyCode == UInt32(kVK_ANSI_S) && model.hotkey?.modifiers == UInt32(controlKey | optionKey))
        #expect(model.refusal == nil)
        #expect(!model.isRecording)
    }

    @Test func aRefusedKeyThenAnAcceptedOneRecordsTheSecond() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("rec.retry"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        model.startRecording()
        try host.send("F", kVK_ANSI_F, shift)
        #expect(model.refusal == .needsModifier)
        try host.send("k", kVK_ANSI_K, controlOption)
        #expect(model.hotkey == controlOptionK)
        #expect(model.refusal == nil)
        #expect(!model.isRecording)
    }

    @Test func escapeCancelsKeepsTheOldKeyAndRemovesTheMonitor() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("rec.escape"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        model.startRecording()
        try host.send("\u{1b}", kVK_Escape)
        #expect(!model.isRecording)
        #expect(model.hotkey == .summon)
        #expect(spy.notes == pauseThenResume)
        try host.send("k", kVK_ANSI_K, controlOption)
        #expect(model.hotkey == .summon)
        #expect(spy.notes == pauseThenResume)
    }

    @Test func deleteClearsTheKeyForGood() throws {
        let defaults = freshDefaults("rec.delete")
        let spy = HelperStarterSpy()
        let model = spy.model(defaults)
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        model.startRecording()
        try host.send("\u{7f}", kVK_Delete)
        #expect(model.hotkey == nil)
        #expect(spy.notes == recordedTrace)
        #expect(!model.isRecording)

        let relaunched = HelperStarterSpy()
        #expect(relaunched.model(defaults).hotkey == nil)
        #expect(relaunched.notes.isEmpty)
    }

    @Test func theForwardDeleteKeyClearsToo() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("rec.forwarddelete"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        model.startRecording()
        try host.send("\u{F728}", kVK_ForwardDelete)
        #expect(model.hotkey == nil)
    }

    @Test func recordingAgainRightAfterARefusalStartsClean() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("rec.again"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        model.startRecording()
        try host.send("F", kVK_ANSI_F, shift)
        #expect(model.refusal == .needsModifier)
        try host.send("\u{1b}", kVK_Escape)
        #expect(model.refusal == nil)
        #expect(!model.isRecording)

        model.startRecording()
        #expect(model.isRecording)
        #expect(model.refusal == nil)
        try host.send("k", kVK_ANSI_K, controlOption)
        #expect(model.hotkey == controlOptionK)
    }

    @Test func startingTwiceKeepsOneMonitor() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("rec.twice"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        model.startRecording()
        model.startRecording()
        spy.notes = []
        try host.send("k", kVK_ANSI_K, controlOption)
        #expect(spy.notes == [HelperLink.Note.sync, HelperLink.Note.resume])
        #expect(!model.isRecording)
    }

    @Test func theWindowLosingKeyEndsTheRecording() async throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("rec.resign"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        model.startRecording()
        try await host.until("the recording to end when the window resigns key") {
            host.window.resignKey()
            return !model.isRecording
        }
        #expect(spy.notes == pauseThenResume)
        try host.send("k", kVK_ANSI_K, controlOption)
        #expect(model.hotkey == .summon)
        #expect(spy.notes == pauseThenResume)
    }

    @Test func closingTheViewEndsTheRecording() async throws {
        let model = HelperStarterSpy().model(freshDefaults("rec.disappear"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        try await host.until("the recorder to appear") { host.shows("Launcher shortcut") }
        model.startRecording()
        host.close()
        try await untilTrue(waitingFor: "the recording to end when the view disappears") { !model.isRecording }
    }

    @Test func theViewShowsTheKeyTheRecordingTheRefusalAndNoKey() async throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("rec.view"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        try await host.until("the idle key") { host.shows("⌃⇧F") && host.shows("Launcher shortcut") }

        model.startRecording()
        try await host.until("the recording prompt") { host.shows("Press a shortcut…") }

        try host.send("F", kVK_ANSI_F, shift)
        try await host.until("the refusal reason") { host.shows(Hotkey.Refusal.needsModifier.message) }

        try host.send("\u{7f}", kVK_Delete)
        try await host.until("the empty state") { host.shows("Record Shortcut") }
        #expect(!host.shows(Hotkey.Refusal.needsModifier.message))
    }

    @Test func aFailedRegistrationShowsItsReason() async throws {
        let own = freshDefaults("rec.failure.own")
        let helper = helperURL()
        let model = HelperStarterSpy().model(freshDefaults("rec.failure"), own: own, helper: helper)
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        let reason = String(localized: "Wherever could not register this shortcut. Try another.", table: "Hotkey")
        try await host.until("the idle key") { host.shows("⌃⇧F") }
        #expect(!host.shows(reason))
        own.set(true, forKey: HelperLink.Key.shortcutFailed)
        HelperLink.post(HelperLink.Note.shortcutFailed, object: helper.path)
        try await host.until("the failure reason") { host.shows(reason) }

        own.set(false, forKey: HelperLink.Key.shortcutFailed)
        HelperLink.post(HelperLink.Note.shortcutFailed, object: helper.path)
        try await host.until("the reason to go") { !host.shows(reason) }
    }

    @Test func aRefusedKeyIsAnnouncedOnceAndJoinsTheButtonValue() async throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("rec.announce.refusal"))
        var posts: [String] = []
        let host = RecorderHost(model: model) { _, text in posts.append(text) }
        defer { model.stopRecording(); host.close() }
        let wherever = Hotkey.Refusal.appKey.message
        let modifier = Hotkey.Refusal.needsModifier.message
        try await host.until("the idle key") { host.shows("⌃⇧F") }
        #expect(posts.isEmpty)

        model.startRecording()
        try host.send("w", kVK_ANSI_W, command)
        try await host.until("the refusal to be announced, not \(posts)") { posts == [wherever] }
        #expect(host.buttonValue?.contains(wherever) == true, "\(String(describing: host.buttonValue))")

        try host.send("F", kVK_ANSI_F, shift)
        try await host.until("the next refusal to be announced, not \(posts)") { posts == [wherever, modifier] }
        #expect(host.buttonValue?.contains(modifier) == true && host.buttonValue?.contains(wherever) == false)

        try host.send("\u{1b}", kVK_Escape)
        try await host.until("the refusal to go from the value") { host.buttonValue?.contains(modifier) == false }
        #expect(posts == [wherever, modifier])

        model.startRecording()
        try host.send("w", kVK_ANSI_W, command)
        try await host.until("the refusal to be announced again once it shows again, not \(posts)") { posts == [wherever, modifier, wherever] }
    }

    @Test func aFailedRegistrationIsAnnouncedAndJoinsTheButtonValue() async throws {
        let own = freshDefaults("rec.announce.failure.own")
        let helper = helperURL()
        let model = HelperStarterSpy().model(freshDefaults("rec.announce.failure"), own: own, helper: helper)
        var posts: [String] = []
        let host = RecorderHost(model: model) { _, text in posts.append(text) }
        defer { model.stopRecording(); host.close() }
        let reason = String(localized: "Wherever could not register this shortcut. Try another.", table: "Hotkey")
        try await host.until("the idle key") { host.shows("⌃⇧F") }

        model.startRecording()
        try host.send("k", kVK_ANSI_K, controlOption)
        own.set(true, forKey: HelperLink.Key.shortcutFailed)
        HelperLink.post(HelperLink.Note.shortcutFailed, object: helper.path)
        try await host.until("the failure to be announced, not \(posts)") { posts == [reason] }
        let value = try #require(host.buttonValue)
        #expect(value.contains(reason) && value.contains(controlOptionK.displayString), "\(value)")

        own.set(false, forKey: HelperLink.Key.shortcutFailed)
        HelperLink.post(HelperLink.Note.shortcutFailed, object: helper.path)
        try await host.until("the failure to go from the value") { host.buttonValue?.contains(reason) == false }
        #expect(posts == [reason])
    }
}

private final class ClickProbe: NSView {
    var keys: [String] = []
    var clicks = 0

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        clicks += 1
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) { keys.append(event.characters ?? "") }
}

private final class ClickAwayRig {
    let window: KeyedWindow
    let recorder = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let probe = ClickProbe(frame: NSRect(x: 150, y: 0, width: 100, height: 100))

    init() {
        window = KeyedWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(recorder)
        window.contentView?.addSubview(probe)
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            window.reportsKey = true
            window.becomeKey()
        }
    }

    func click(at point: NSPoint) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        NSApp.sendEvent(event)
    }

    func press(_ characters: String, _ code: Int) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(code)
        ))
        NSApp.sendEvent(event)
    }

    func close() { window.close() }
}

@Suite(.serialized) struct HotkeyClickAwayTests {
    @Test func aMouseDownOutsideTheRecorderStopsRecordingAndTheNextKeyReachesTheClickedControl() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("clickaway.outside"))
        let rig = ClickAwayRig()
        defer { model.stopRecording(); rig.close() }
        model.recorderArea = rig.recorder
        model.startRecording()
        try rig.press("a", kVK_ANSI_A)
        #expect(model.isRecording && rig.probe.keys.isEmpty)

        try rig.click(at: NSPoint(x: 200, y: 50))
        #expect(!model.isRecording)
        #expect(rig.probe.clicks == 1)
        #expect(spy.notes == pauseThenResume)

        try rig.press("a", kVK_ANSI_A)
        #expect(rig.probe.keys == ["a"])
        #expect(model.hotkey == .summon)
    }

    @Test func aMouseDownInsideTheRecorderKeepsRecording() throws {
        let model = HelperStarterSpy().model(freshDefaults("clickaway.inside"))
        let rig = ClickAwayRig()
        defer { model.stopRecording(); rig.close() }
        model.recorderArea = rig.recorder
        model.startRecording()
        try rig.click(at: NSPoint(x: 50, y: 50))
        #expect(model.isRecording)
        try rig.press("a", kVK_ANSI_A)
        #expect(rig.probe.keys.isEmpty)
    }

    @Test func aMouseDownAfterRecordingEndedChangesNothing() throws {
        let spy = HelperStarterSpy()
        let model = spy.model(freshDefaults("clickaway.after"))
        let rig = ClickAwayRig()
        defer { rig.close() }
        model.recorderArea = rig.recorder
        model.startRecording()
        model.stopRecording()
        try rig.click(at: NSPoint(x: 200, y: 50))
        #expect(!model.isRecording)
        #expect(rig.probe.clicks == 1)
        #expect(spy.notes == pauseThenResume)
    }

    @Test func theHostedRecorderRegistersItsAreaSoAClickBesideItStopsRecording() async throws {
        let model = HelperStarterSpy().model(freshDefaults("clickaway.hosted"))
        let host = RecorderHost(model: model)
        defer { model.stopRecording(); host.close() }
        try await host.until("the recorder area") { model.recorderArea?.window === host.window }
        let area = try #require(model.recorderArea)
        let corner = NSPoint(x: 1, y: 1)
        try #require(!area.bounds.contains(area.convert(corner, from: nil)))

        model.startRecording()
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: corner, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        NSApp.sendEvent(event)
        #expect(!model.isRecording)
    }
}
