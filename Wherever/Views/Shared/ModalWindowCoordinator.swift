import AppKit
import Combine

final class BlockingOverlayView: NSView {
    weak var coordinator: ModalWindowCoordinator?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        registerForDraggedTypes([.fileURL, .URL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) { coordinator?.frontDialog(beeping: true) }
    override func rightMouseDown(with event: NSEvent) { coordinator?.frontDialog(beeping: true) }
    override func otherMouseDown(with event: NSEvent) { coordinator?.frontDialog(beeping: true) }
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
}

final class ModalWindowCoordinator: NSObject, ObservableObject {
    static let shared = ModalWindowCoordinator()

    @Published private(set) var isBlocking = false

    private struct Weak {
        weak var window: NSWindow?
    }

    private let windows: @MainActor () -> [NSWindow]
    private let isActive: @MainActor () -> Bool
    private let beep: @MainActor () -> Void
    private var started = false
    private var dialogs: [Weak] = []
    private var lifted: [Weak] = []
    private var overlays: [BlockingOverlayView] = []
    private var monitor: Any?

    init(
        windows: @escaping @MainActor () -> [NSWindow] = { NSApp.orderedWindows + NSApp.windows },
        isActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        beep: @escaping @MainActor () -> Void = { NSSound.beep() }
    ) {
        self.windows = windows
        self.isActive = isActive
        self.beep = beep
    }

    var topDialog: NSWindow? { dialogs.compactMap(\.window).last }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
        center.addObserver(self, selector: #selector(windowUpdated(_:)), name: NSWindow.didUpdateNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(activationChanged(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(activationChanged(_:)), name: NSApplication.didResignActiveNotification, object: nil)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        started = false
    }

    func register(_ dialog: NSWindow) {
        guard started else { return }
        promote(dialog)
    }

    @discardableResult func frontDialog(beeping: Bool) -> Bool {
        guard let top = topDialog else { return false }
        if beeping { beep() }
        if top.isMiniaturized { top.deminiaturize(nil) }
        top.makeKeyAndOrderFront(nil)
        return true
    }

    @objc func activationChanged(_ notification: Notification) { relevel() }

    private func relevel() {
        let active = isActive()
        dialogs.compactMap(\.window).forEach { $0.level = active ? .floating : .normal }
        lifted.compactMap(\.window).forEach { $0.level = active ? .modalPanel : .normal }
    }

    private static func isBack(_ window: NSWindow) -> Bool {
        MainWindow.isMain(window) || window.windowController is WelcomeWindowController
    }

    private func owns(_ window: NSWindow) -> Bool { windows().contains(window) }

    private func isDialog(_ window: NSWindow) -> Bool { dialogs.contains { $0.window === window } }

    private func promote(_ dialog: NSWindow) {
        dialogs.removeAll { $0.window == nil || $0.window === dialog }
        dialogs.append(Weak(window: dialog))
        lifted.removeAll { $0.window == nil || $0.window === dialog }
        relevel()
        if !isBlocking { isBlocking = true }
        windows().filter(Self.isBack).forEach(overlay)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.swallows(event) == true } ? nil : event
        }
    }

    private func swallows(_ event: NSEvent) -> Bool {
        guard let window = event.window, Self.isBack(window), owns(window) else { return false }
        frontDialog(beeping: event.type != .keyDown)
        return true
    }

    private func overlay(_ window: NSWindow) {
        guard let frame = window.contentView?.superview, !frame.subviews.contains(where: { $0 is BlockingOverlayView }), owns(window) else {
            return
        }
        let overlay = BlockingOverlayView(frame: frame.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.coordinator = self
        frame.addSubview(overlay)
        overlays.append(overlay)
    }

    private func lift(_ window: NSWindow) {
        guard window.level == .normal, window.parent == nil, !window.isSheet, !lifted.contains(where: { $0.window === window }), owns(window) else {
            return
        }
        lifted.append(Weak(window: window))
        window.level = isActive() ? .modalPanel : .normal
    }

    private func unblock() {
        isBlocking = false
        overlays.forEach { $0.removeFromSuperview() }
        overlays = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windows().first { Self.isBack($0) && $0.isVisible && $0.isOnActiveSpace }?.makeKeyAndOrderFront(nil)
        for window in lifted.compactMap(\.window) {
            window.level = .normal
            if window.isVisible { window.orderFront(nil) }
        }
        lifted = []
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard isBlocking, let window = notification.object as? NSWindow else { return }
        if isDialog(window) {
            if topDialog !== window { promote(window) }
        } else if Self.isBack(window), owns(window) {
            overlay(window)
            frontDialog(beeping: false)
        } else {
            lift(window)
        }
    }

    @objc private func windowUpdated(_ notification: Notification) {
        guard isBlocking, let window = notification.object as? NSWindow, !isDialog(window) else { return }
        if Self.isBack(window) { overlay(window) } else { lift(window) }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isDialog(window) else { return }
        window.level = .normal
        dialogs.removeAll { $0.window == nil || $0.window === window }
        if !frontDialog(beeping: false) { unblock() }
    }
}
