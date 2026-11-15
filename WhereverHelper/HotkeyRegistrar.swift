import Carbon

private nonisolated func hotkeyPressed(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<HotkeyRegistrar>.fromOpaque(context)
    MainActor.assumeIsolated { registrar.takeUnretainedValue().onPress() }
    return noErr
}

final class HotkeyRegistrar {
    private static let signature = OSType(0x5748_5256)

    var onPress: () -> Void = {}
    private var handler: EventHandlerRef?
    private var key: EventHotKeyRef?

    func register(_ hotkey: Hotkey) -> OSStatus {
        unregister()
        if handler == nil {
            var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(), hotkeyPressed, 1, &kind, Unmanaged.passUnretained(self).toOpaque(), &handler
            )
            guard status == noErr else { return status }
        }
        return RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &key
        )
    }

    func unregister() {
        guard let key else { return }
        UnregisterEventHotKey(key)
        self.key = nil
    }
}
