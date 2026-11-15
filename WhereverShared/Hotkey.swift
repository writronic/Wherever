import AppKit
import Carbon

nonisolated struct Hotkey: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let character: String

    @MainActor static var layoutCharacter: @MainActor (UInt32) -> String = characterForKeyCode

    @MainActor static var summon: Hotkey {
        let code = (UInt32(0)...127).first { layoutCharacter($0).lowercased() == "f" } ?? UInt32(kVK_ANSI_F)
        return Hotkey(keyCode: code, modifiers: UInt32(controlKey | shiftKey), character: "F")
    }

    @MainActor private static func characterForKeyCode(_ keyCode: UInt32) -> String {
        guard let code = UInt16(exactly: keyCode),
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "" }
        var dead: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 255)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate(
                $0, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, characters.count, &length, &characters
            )
        }
        return status == noErr ? String(utf16CodeUnits: characters, count: length) : ""
    }

    @MainActor static func stored(in defaults: UserDefaults) -> (hotkey: Hotkey?, followsLayout: Bool) {
        guard let data = defaults.data(forKey: HelperLink.Key.summonHotkey) else { return (.summon, true) }
        if data.isEmpty { return (nil, false) }
        guard let stored = try? JSONDecoder().decode(Hotkey.self, from: data), stored.refusal == nil else { return (.summon, true) }
        return (stored, false)
    }

    init(keyCode: UInt32, modifiers: UInt32, character: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.character = character
    }

    init(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var bits = 0
        if flags.contains(.control) { bits |= controlKey }
        if flags.contains(.option) { bits |= optionKey }
        if flags.contains(.shift) { bits |= shiftKey }
        if flags.contains(.command) { bits |= cmdKey }
        let base = event.characters(byApplyingModifiers: []).flatMap { $0.isEmpty ? nil : $0 } ?? event.charactersIgnoringModifiers ?? ""
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(bits), character: base.uppercased())
    }

    @MainActor var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        if keyCode == UInt32(kVK_Space) { return text + String(localized: "Space", table: "Hotkey") }
        let translated = Self.layoutCharacter(keyCode)
        return text + (translated.isEmpty ? character : translated.uppercased())
    }

    enum Refusal: Equatable {
        case needsModifier, systemKey, appKey, unsupportedKey
    }

    var refusal: Refusal? {
        let strong = UInt32(controlKey | optionKey | cmdKey)
        guard modifiers & strong != 0 else { return .needsModifier }
        if keyCode == UInt32(kVK_Space), Self.systemSpaceModifiers.contains(modifiers) { return .systemKey }
        if Self.appKeys.contains(where: { $0.code == keyCode && $0.modifiers == modifiers }) { return .appKey }
        guard let scalar = character.unicodeScalars.first, scalar.value >= 0x20, !(0xE000...0xF8FF).contains(scalar.value) else {
            return .unsupportedKey
        }
        return nil
    }

    private static let systemSpaceModifiers: Set<UInt32> = [
        UInt32(cmdKey), UInt32(optionKey | cmdKey), UInt32(controlKey), UInt32(controlKey | optionKey), UInt32(shiftKey | cmdKey),
    ]
    private static let appKeys: [(code: UInt32, modifiers: UInt32)] = ([
        (kVK_ANSI_N, cmdKey), (kVK_ANSI_W, cmdKey), (kVK_ANSI_Q, cmdKey), (kVK_ANSI_Comma, cmdKey), (kVK_ANSI_C, cmdKey), (kVK_Return, cmdKey),
        (kVK_ANSI_I, optionKey | cmdKey), (kVK_ANSI_Period, shiftKey | cmdKey),
        (kVK_ANSI_S, cmdKey), (kVK_ANSI_S, shiftKey | cmdKey),
        (kVK_ANSI_H, cmdKey), (kVK_ANSI_H, optionKey | cmdKey), (kVK_ANSI_M, cmdKey),
        (kVK_ANSI_A, cmdKey), (kVK_ANSI_X, cmdKey), (kVK_ANSI_V, cmdKey), (kVK_ANSI_Z, cmdKey), (kVK_ANSI_Z, shiftKey | cmdKey),
    ] as [(Int, Int)]).map { (UInt32($0.0), UInt32($0.1)) }
}
