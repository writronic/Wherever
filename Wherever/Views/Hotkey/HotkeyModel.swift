import AppKit
import Carbon
import Combine

final class HotkeyModel: ObservableObject {
    static let defaultsKey = HelperLink.Key.summonHotkey

    @Published private(set) var hotkey: Hotkey?
    @Published private(set) var registrationFailed = false
    @Published private(set) var isRecording = false
    @Published private(set) var refusal: Hotkey.Refusal?

    private let defaults: UserDefaults
    private let helper: HelperStarter?
    private let windows: @MainActor () -> [NSWindow]
    private let unhide: @MainActor () -> Void
    private let activate: @MainActor () -> Void
    private var openWindow: @MainActor () -> Void = {}
    private var monitor: Any?
    weak var recorderArea: NSView?
    private var followsLayout: Bool
    private var layoutObservation: AnyCancellable?
    private var failureObservation: HelperObservation?

    init(
        defaults: UserDefaults = .standard,
        helper: HelperStarter? = nil,
        windows: @escaping @MainActor () -> [NSWindow] = { NSApp.orderedWindows + NSApp.windows },
        unhide: @escaping @MainActor () -> Void = { if NSApp.isHidden { NSApp.unhide(nil) } },
        activate: @escaping @MainActor () -> Void = Availability.activateApp,
        layoutNotifications: NotificationCenter = DistributedNotificationCenter.default()
    ) {
        self.defaults = defaults
        self.helper = helper
        self.windows = windows
        self.unhide = unhide
        self.activate = activate
        let stored = Hotkey.stored(in: defaults)
        hotkey = stored.hotkey
        followsLayout = stored.followsLayout
        readFailure()
        failureObservation = helper.map {
            HelperLink.observe(HelperLink.Note.shortcutFailed, object: $0.helper.path) { [weak self] in self?.readFailure() }
        }
        layoutObservation = layoutNotifications.publisher(for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.inputSourceChanged() }
            }
    }

    private func inputSourceChanged() {
        if followsLayout, hotkey != .summon {
            hotkey = .summon
        } else {
            objectWillChange.send()
        }
    }

    func set(_ new: Hotkey?) {
        followsLayout = false
        defaults.set(new.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: Self.defaultsKey)
        hotkey = new
        readFailure()
        helper?.sync()
    }

    private func readFailure() {
        registrationFailed = hotkey != nil && helper?.shortcutFailed == true
    }

    func configure(openWindow: @escaping @MainActor () -> Void) { self.openWindow = openWindow }

    func summon() {
        unhide()
        let main = windows().filter(MainWindow.isMain)
        if let window = main.first(where: { $0.isVisible && $0.alphaValue > 0 }) ?? main.first(where: \.isMiniaturized) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow()
        }
        activate()
    }

    func startRecording() {
        stopRecording()
        isRecording = true
        helper?.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event -> NSEvent? in
            MainActor.assumeIsolated { self?.swallows(event) ?? true } ? nil : event
        }
    }

    private func swallows(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else {
            record(event)
            return true
        }
        if !isInsideRecorder(event) { stopRecording() }
        return false
    }

    private func isInsideRecorder(_ event: NSEvent) -> Bool {
        guard let area = recorderArea, let window = area.window, event.window === window else { return false }
        return area.bounds.contains(area.convert(event.locationInWindow, from: nil))
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { helper?.resume() }
        isRecording = false
        refusal = nil
    }

    func record(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording()
        case kVK_Delete, kVK_ForwardDelete:
            set(nil)
            stopRecording()
        default:
            let candidate = Hotkey(event)
            if let reason = candidate.refusal {
                refusal = reason
            } else {
                set(candidate)
                stopRecording()
            }
        }
    }
}
