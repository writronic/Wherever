import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import WhereverInterface

final class ArchiveWindows {
    static let windowID = "archive-window"
    static let stopAlertID = "archive-stop-expanding-alert"
    static let stopContinueID = "archive-stop-expanding-continue"
    static let stopStopID = "archive-stop-expanding-stop"
    static let unsavedAlertID = "archive-unsaved-alert"
    static let unsavedSaveID = "archive-unsaved-save"
    static let unsavedCancelID = "archive-unsaved-cancel"
    static let unsavedDontSaveID = "archive-unsaved-dont-save"
    static let autosaveName = "ArchiveWindow"
    static let defaultSize = NSSize(width: 960, height: 600)

    private let client: any ArchiveClient
    private let index: IndexModel
    private let actions: ResultActions
    private let defaults: UserDefaults
    private let columnPreferences: ColumnPreferences
    private let extensions: [String]
    private let cache: URL
    private let access: @Sendable (String) -> ArchiveAccess
    private let activate: @MainActor () -> Void
    private(set) static var all: [ArchiveWindowController] = []

    init(
        client: any ArchiveClient, index: IndexModel, actions: ResultActions, defaults: UserDefaults = .standard,
        columnPreferences: ColumnPreferences = .shared, cache: URL, center: NotificationCenter = .default,
        access: @escaping @Sendable (String) -> ArchiveAccess = ArchiveAccess.read, activate: @escaping @MainActor () -> Void = Availability.activateApp
    ) {
        self.client = client
        self.activate = activate
        self.cache = cache
        self.access = access
        self.index = index
        self.actions = actions
        self.defaults = defaults
        self.columnPreferences = columnPreferences
        extensions = ((try? client.archiveExtensions()) ?? []).map { $0.lowercased() }
        _ = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quit() }
        }
    }

    func quit() {
        for controller in Self.all { controller.model.quitExpanding() }
    }

    var inside: ResultActions.Inside {
        let extensions = extensions
        return ResultActions.Inside(allows: { Self.allows($0, extensions: extensions) }, enter: { [weak self] in self?.open($0) })
    }

    static func allows(_ hit: SearchHit, extensions: [String]) -> Bool {
        hit.kind != .folder && allows(name: hit.name, extensions: extensions)
    }

    static func allows(name: String, extensions: [String]) -> Bool {
        let name = name.lowercased()
        return extensions.contains { name.count > $0.count + 1 && name.hasSuffix("." + $0) }
    }

    static func showContents(in window: NSWindow? = NSApp.keyWindow, beep: () -> Void = { NSSound.beep() }) {
        let action = #selector(ThemedTable.showInside(_:))
        guard let first = window?.firstResponder,
              let target = sequence(first: first, next: \.nextResponder).first(where: { $0.responds(to: action) }) else { return beep() }
        _ = NSApp.sendAction(action, to: target, from: nil)
    }

    static func expandArchive(in window: NSWindow? = NSApp.keyWindow, beep: () -> Void = { NSSound.beep() }) {
        guard let controller = window?.windowController as? ArchiveWindowController else { return beep() }
        controller.expandArchive(nil)
    }

    static func addFiles(in window: NSWindow? = NSApp.keyWindow, beep: () -> Void = { NSSound.beep() }) {
        guard let controller = window?.windowController as? ArchiveWindowController else { return beep() }
        controller.addFiles(nil)
    }

    func open(_ hit: SearchHit) {
        let shownAs = hit.path
        let path = Self.resolved(shownAs)
        let identity = Self.identity(path)
        if let found = Self.all.first(where: { $0.holds(identity, path: path) }) { return found.show() }
        let client = client
        let model = ArchiveWindowModel(
            shownAs: shownAs, session: try? client.openArchive(path: path, shownAs: shownAs), index: index, actions: actions,
            defaults: defaults, columnPreferences: columnPreferences, root: Self.cacheKey(path).map { cache.appending(path: $0, directoryHint: .isDirectory) },
            client: client, extensions: extensions, access: access
        )
        let controller = ArchiveWindowController(model: model, identity: identity, path: path, defaults: defaults)
        controller.activate = activate
        controller.closed = { [weak controller] in Self.all.removeAll { $0 === controller } }
        let previous = Self.all.last?.window
        Self.all.append(controller)
        controller.place(after: previous)
        controller.show()
    }

    nonisolated static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    static func cacheKey(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(info.st_dev)-\(info.st_ino)-\(info.st_size)-\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    static func identity(_ path: String) -> (any NSObjectProtocol)? {
        (try? URL(filePath: path).resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    }

    static func escapeClicks(_ button: NSButton, in alert: NSAlert) {
        alert.layout()
        let key = EscapeKey()
        key.press = { [weak button] in button?.performClick(nil) }
        alert.window.contentView?.addSubview(key)
    }

    static func unsavedAlert(name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save the changes made to the archive “\(Bidi.name(name))”?", table: "Archive")
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.", table: "Archive")
        alert.addButton(withTitle: String(localized: "Save", table: "Archive")).setAccessibilityIdentifier(unsavedSaveID)
        let cancel = alert.addButton(withTitle: String(localized: "Cancel", table: "Normal"))
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        cancel.setAccessibilityIdentifier(unsavedCancelID)
        let dontSave = alert.addButton(withTitle: String(localized: "Don’t Save", table: "Archive"))
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        dontSave.setAccessibilityIdentifier(unsavedDontSaveID)
        alert.window.identifier = NSUserInterfaceItemIdentifier(unsavedAlertID)
        alert.window.setAccessibilityIdentifier(unsavedAlertID)
        return alert
    }
}

final class ArchiveWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: ArchiveWindowModel
    var closed: () -> Void = {}
    var activate: @MainActor () -> Void = Availability.activateApp
    private var answered = false
    private var shut = false
    private var identity: (any NSObjectProtocol)?
    private var path: String
    private var watch: AnyCancellable?

    init(model: ArchiveWindowModel, identity: (any NSObjectProtocol)?, path: String, defaults: UserDefaults) {
        self.model = model
        self.identity = identity
        self.path = path
        let host = NSHostingView(rootView: ArchiveView(model: model).defaultAppStorage(defaults))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let window = ArchiveHostWindow(
            contentRect: NSRect(origin: .zero, size: ArchiveWindows.defaultSize), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.setContentSize(window.contentRect(forFrameRect: NSRect(origin: .zero, size: ArchiveWindows.defaultSize)).size)
        window.contentView = container
        window.contentMinSize = NSSize(width: SearchMetrics.windowMinWidth, height: SearchMetrics.windowMinHeight)
        window.title = model.name
        window.subtitle = model.location
        window.identifier = NSUserInterfaceItemIdentifier(ArchiveWindows.windowID)
        window.setAccessibilityIdentifier(ArchiveWindows.windowID)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.commandUp = { [weak model, weak window] in
            guard let model else { return false }
            if model.searching {
                model.clearSearch()
                return true
            }
            let typing = window.map { $0.firstResponder != nil && $0.firstResponder === $0.searchField?.currentEditor() } ?? false
            guard model.blocked != nil ? model.depth > 0 : typing && model.canGoUp else { return false }
            model.goEnclosing()
            return true
        }
        model.stop = { [weak window] in window?.performClose(nil) }
        model.place = { [weak window] panel, done in
            guard let window else { return done(nil) }
            panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
        }
        model.choose = { [weak window] panel, done in
            guard let window else { return done(nil) }
            panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
        }
        model.pick = { [weak window] panel, done in
            guard let window else { return done([]) }
            panel.beginSheetModal(for: window) { done($0 == .OK ? panel.urls : []) }
        }
        model.controller = self
        wire()
        watch = model.objectWillChange.sink { [weak self] in
            let controller = self
            DispatchQueue.main.async { MainActor.assumeIsolated { controller.map { ArchiveSaveMenu.shared.refresh($0) } } }
        }
    }

    private func wire() {
        model.edits?.undoManager = { [weak window] in window?.undoManager }
        model.edits?.changed = { [weak self] in self?.showEdited() }
    }

    func rekey(path: String) {
        self.path = path
        identity = ArchiveWindows.identity(path)
        window?.title = model.name
        wire()
        showEdited()
    }

    private func showEdited() {
        defer {
            ArchiveSaveMenu.shared.refresh(self)
            ArchiveEdits.refresh()
        }
        guard let window else { return }
        let edited = model.edits?.edited == true
        window.isDocumentEdited = edited
        window.subtitle = edited ? String(localized: "Edited", table: "Archive") : model.location
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func holds(_ other: (any NSObjectProtocol)?, path otherPath: String) -> Bool {
        if let identity, let other { return identity.isEqual(other) }
        return path == otherPath
    }

    func place(after previous: NSWindow?) {
        guard let window else { return }
        if !window.setFrameUsingName(ArchiveWindows.autosaveName) { window.center() }
        if let previous {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        }
        _ = window.setFrameAutosaveName(ArchiveWindows.autosaveName)
    }

    func show() {
        showWindow(nil)
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        if let table = content.descendant(ThemedTable.self), window.firstResponder !== table { window.makeFirstResponder(table) }
    }

    @objc func expandArchive(_ sender: Any?) {
        model.expandArchive()
    }

    @objc func addFiles(_ sender: Any?) {
        model.addFiles()
    }

    @objc func saveArchive(_ sender: Any?) {
        model.save()
    }

    @objc func saveArchiveAs(_ sender: Any?) {
        model.saveAs()
    }

    @objc func expandSelected(_ sender: Any?) {
        guard let table = window?.contentView?.descendant(ThemedTable.self) else { return model.base.refuse() }
        let rows = table.selectedRowIndexes
        guard rows.count > ThemedTable.actionLimit else { return model.expandSelected(table.hits(rows)) }
        let read = table.readHits(rows)
        Task { [model] in
            do { model.expandSelected(try await read.value) } catch { model.base.refuse() }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(expandArchive(_:)) || item.action == #selector(expandSelected(_:)) else { return true }
        return model.canExpand
    }

    var unsaved: Bool { model.saveJob != nil || model.waitingSave != nil || model.edits?.edited == true }

    func settle(_ done: @escaping (Bool) -> Void) {
        guard model.saveJob == nil, model.waitingSave == nil else { return model.afterSaving(done) }
        guard model.edits?.edited == true, let window else { return done(true) }
        activate()
        window.makeKeyAndOrderFront(nil)
        guard window.attachedSheet == nil else {
            model.base.refuse()
            return done(false)
        }
        ArchiveWindows.unsavedAlert(name: (model.outermost as NSString).lastPathComponent).beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                guard let model = self?.model else { return done(false) }
                model.saveWhenFree(done: done)
            case .alertThirdButtonReturn:
                done(true)
            default:
                done(false)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if answered {
            answered = false
        } else if unsaved {
            settle { [weak self] saved in
                guard saved else { return }
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.closeAnswered() } }
            }
            return false
        }
        guard case let .running(name, _)? = model.expansion else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Stop expanding “\(Bidi.name(name))”?", table: "Archive")
        alert.informativeText = String(localized: "The items expanded so far will be removed.", table: "Archive")
        let keep = alert.addButton(withTitle: String(localized: "Continue", table: "Archive"))
        keep.setAccessibilityIdentifier(ArchiveWindows.stopContinueID)
        alert.addButton(withTitle: String(localized: "Stop Expanding", table: "Archive")).setAccessibilityIdentifier(ArchiveWindows.stopStopID)
        ArchiveWindows.escapeClicks(keep, in: alert)
        alert.window.identifier = NSUserInterfaceItemIdentifier(ArchiveWindows.stopAlertID)
        alert.window.setAccessibilityIdentifier(ArchiveWindows.stopAlertID)
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.model.stopExpanding()
            sender?.close()
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ArchiveSaveMenu.shared.follow(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        ArchiveSaveMenu.shared.leave(self)
    }

    private func closeAnswered() {
        guard !shut else { return }
        answered = true
        window?.performClose(nil)
        answered = false
    }

    func windowWillClose(_ notification: Notification) {
        shut = true
        ArchiveSaveMenu.shared.leave(self)
        model.close()
        closed()
        ArchiveEdits.refresh()
    }
}

final class EscapeKey: NSView {
    var press: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.charactersIgnoringModifiers == "\u{1b}",
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return false }
        press()
        return true
    }
}

final class ArchiveHostWindow: NSWindow {
    var commandUp: () -> Bool = { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, event.specialKey == .upArrow, flags == .command, commandUp() { return true }
        return super.performKeyEquivalent(with: event)
    }
}
