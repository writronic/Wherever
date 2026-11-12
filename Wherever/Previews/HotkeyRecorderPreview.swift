import AppKit
import Carbon
import SwiftUI

private func recorder(_ prepare: (HotkeyModel) -> Void = { _ in }) -> some View {
    let suite = "com.writronic.wherever.previews.hotkey"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let model = HotkeyModel(defaults: defaults)
    prepare(model)
    return HotkeyRecorder(model: model).padding()
}

#Preview("Hotkey idle") { recorder() }

#Preview("Hotkey recording") { recorder { $0.startRecording() } }

#Preview("Hotkey no key") { recorder { $0.set(nil) } }

#Preview("Hotkey refused") {
    recorder { model in
        model.startRecording()
        let shiftF = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "F", charactersIgnoringModifiers: "F", isARepeat: false, keyCode: UInt16(kVK_ANSI_F)
        )
        if let shiftF { model.record(shiftF) }
    }
}

#Preview("Hotkey registration failed") {
    let suite = "com.writronic.wherever.previews.hotkey.failed"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(true, forKey: HelperLink.Key.shortcutFailed)
    let helper = HelperStarter(
        previews: false, defaults: defaults, own: defaults, helper: URL(fileURLWithPath: "/"), isRunning: { true }, open: { _, _ in }, post: { _, _ in }
    )
    return HotkeyRecorder(model: HotkeyModel(defaults: defaults, helper: helper)).padding()
}
