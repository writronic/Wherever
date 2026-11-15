import AppKit
import CoreText
import Foundation
import Quartz
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

@objc private protocol LauncherDragMask {
    func draggingSourceOperationMaskForLocal(_ isLocal: Bool) -> NSDragOperation
}

private let reports = (0..<12).map { SearchHit.named("report-\($0)", in: "/Users/me") }

private func launcherFile(_ name: String) -> SearchHit {
    SearchHit(name: name, folder: "/Users/me", size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .file)
}

private let photosZip = launcherFile("Photos 2024.zip")
private let notesText = launcherFile("notes.txt")
private let photoEntries: [FakeArchiveClient.Entry] = [.init("Trip", kind: .folder), .init("Trip/IMG_0001.HEIC", size: 10), .init("notes.txt", size: 2_048)]

private final class Raised {
    var count = 0
}

private final class LauncherRig {
    private static let keyCodes: [Character: UInt16] = ["e": 14, "o": 31, "p": 35, "r": 15, "s": 1, "t": 17, "z": 6, ".": 47]
    static let storeName = "com.writronic.wherever.tests.launcher"

    let fake: FakeSearchClient
    let index: IndexModel
    let recorder = ActionRecorder()
    let store: UserDefaults
    let launcher: Launcher
    let archive: FakeArchiveClient
    let archives: ArchiveWindows?
    let archiveRecorder = ActionRecorder()
    let raised = Raised()
    private(set) var windows: [(host: SearchHost, model: SearchModel)] = []
    private(set) var visibleAtOpen: [Bool] = []
    private(set) var activations = 0
    private(set) var quits = 0
    private var keyGuard: Any?
    let presence = AppPresence(center: NotificationCenter()) { _ in }

    lazy var newWindow: () -> Void = WhereverApp.routes(
        access: AccessModel(defaults: store, center: NotificationCenter(), stage: .ready, probe: { .granted }, confirm: { true }, start: {}, summon: {}, activate: {}),
        summon: {}, openWindow: { [weak self] in
            guard let self else { return }
            visibleAtOpen.append(launcher.panel?.isVisible == true)
            let model = index.makeModel(listsAll: true, defaults: store)
            let host = SearchHost(root: AnyView(ContentView(index: index, model: model)
                .environment(\.searchClient, fake).defaultAppStorage(store)))
            windows.append((host, model))
        },
        showSettings: {}, activate: { [weak self] in self?.activations += 1 }, open: { _ in }, quit: {},
        closeLauncher: { [weak self] in self?.launcher.prepareHandOff() }, presence: presence
    ).menu.newWindow

    init(hits: [SearchHit] = reports, isRecording: @escaping () -> Bool = { false }, archived entries: [FakeArchiveClient.Entry]? = nil) {
        fake = FakeSearchClient(hits: hits)
        index = IndexModel(client: fake)
        store = UserDefaults(suiteName: Self.storeName)!
        store.removePersistentDomain(forName: Self.storeName)
        archive = FakeArchiveClient(search: fake, entries: entries ?? [])
        var actions = recorder.actions
        if entries != nil {
            let preferences = ColumnPreferences(defaults: store)
            preferences.foldersFirst = true
            let cache = FileManager.default.temporaryDirectory.appending(path: "launcher-archives-\(UUID().uuidString)", directoryHint: .isDirectory)
            let windows = ArchiveWindows(
                client: archive, index: index, actions: archiveRecorder.actions, defaults: store, columnPreferences: preferences, cache: cache
            )
            actions.inside = windows.inside
            archives = windows
        } else {
            archives = nil
        }
        let raised = raised
        let presence = presence
        launcher = Launcher(
            index: index, actions: actions, defaults: store, isRecording: isRecording,
            activate: {
                raised.count += 1
                presence.prepareToShowWindow()
            },
            hidden: { presence.quitIfIdle() }
        )
        presence.staysRunning = { [weak launcher] in launcher?.panel?.isVisible == true }
        presence.quit = { [weak self] in self?.quits += 1 }
        launcher.showAll = { [weak self] in self?.newWindow() }
        keyGuard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak launcher] event in
            let ours = MainActor.assumeIsolated { launcher?.panel.map { (event.window ?? NSApp.keyWindow) === $0 } ?? false }
            return ours ? nil : event
        }
    }

    func close() {
        launcher.hide()
        for controller in ArchiveWindows.all { controller.window?.close() }
        for window in windows { window.host.close() }
        if let keyGuard { NSEvent.removeMonitor(keyGuard) }
        keyGuard = nil
        launcher.panel?.contentView = nil
    }

    func panel() throws -> LauncherPanel { try #require(launcher.panel) }

    func windowField(_ index: Int = 0) async throws -> NSSearchField {
        let host = windows[index].host
        try await host.until("the new window's field") { host.field() != nil }
        return try #require(host.field())
    }

    var showAllRow: NSObject? {
        launcher.panel?.contentView.flatMap { AXTree.element("launcher-show-all", in: $0) }
    }

    var fieldHasFocus: Bool {
        guard let panel = launcher.panel, let editor = panel.searchField?.currentEditor() else { return false }
        return panel.firstResponder === editor
    }

    var listHasFocus: Bool { launcher.table.map { launcher.panel?.firstResponder === $0 } ?? false }

    var fieldText: String? { launcher.panel?.searchField?.stringValue }

    var previewPane: LauncherPreviewView? { launcher.panel?.contentView?.descendant(LauncherPreviewView.self) }

    func until(
        _ description: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        try await untilTrue(waitingFor: description(), sourceLocation: sourceLocation) {
            launcher.panel?.contentView?.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    func show() async throws {
        launcher.toggle()
        try await until("the launcher's field to hold focus") { self.fieldHasFocus }
    }

    func expectedList(_ count: Int) -> CGFloat? {
        guard count > 0 else { return LauncherMetrics.rowHeight(TextSize.stored(store)) + LauncherMetrics.listTop + LauncherMetrics.listBottom }
        guard let table = launcher.table, table.numberOfRows >= count else { return nil }
        let rows = min(count, LauncherMetrics.maxRows)
        return table.rect(ofRow: rows - 1).maxY + LauncherMetrics.listTop + LauncherMetrics.listBottom
    }

    func finish(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        fake.send(.resultsReady(fake.latest, count: count))
        try await until("\(count) rows and the panel's fit", sourceLocation: sourceLocation) {
            self.launcher.model.count == count && self.launcher.table?.numberOfRows == count
                && self.expectedList(count).map { $0 == self.launcher.listHeight } == true
        }
    }

    func type(_ text: String) throws {
        for character in text {
            try send(String(character), code: try #require(Self.keyCodes[character], "no key code for \(character)"))
        }
    }

    func escape() throws { try send("\u{1b}", code: 53) }

    func command(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> Bool {
        let panel = try panel()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags.union(.command), timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code
        ))
        return panel.performKeyEquivalent(with: event)
    }
    func space() throws { try send(" ", code: 49) }
    func pressReturn(command: Bool = false) throws { try send("\r", code: 36, flags: command ? [.command] : []) }

    func down(flags: NSEvent.ModifierFlags = []) throws {
        try send(String(Character(NSEvent.SpecialKey.downArrow.unicodeScalar)), code: 125, flags: flags.union([.numericPad, .function]))
    }

    func tab(backward: Bool = false) throws {
        try send(backward ? "\u{19}" : "\t", code: 48, flags: backward ? [.shift] : [])
    }

    private func send(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
        let panel = try panel()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: code
        ))
        if flags.contains(.command), panel.performKeyEquivalent(with: event) { return }
        panel.sendEvent(event)
    }
}

private func mainWindowCount() -> Int { NSApp.windows.filter { MainWindow.isMain($0) && $0.isVisible }.count }

private func pressReturn(in window: NSWindow) throws {
    window.sendEvent(try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
    )))
}

@Suite(.serialized) struct LauncherTests {
    @Test func theLauncherMatchesItsGlassLook() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        let panel = try rig.panel()
        let content = try #require(panel.contentView)
        let field = try #require(panel.searchField)
        let table = try #require(rig.launcher.table)
        let scroll = try #require(table.enclosingScrollView)
        let scale = panel.backingScaleFactor
        content.layoutSubtreeIfNeeded()
        let fieldFrame = try #require(field.superview).convert(field.alignmentRect(forFrame: field.frame), to: content)
        let listFrame = scroll.convert(scroll.bounds, to: content)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ResultCell)
        let icon = try #require(cell.imageView)
        let text = try #require(cell.textField)
        content.layoutSubtreeIfNeeded()
        let iconFrame = icon.alignmentRect(forFrame: icon.frame)
        let textFrame = text.alignmentRect(forFrame: text.frame)
        #expect((try #require(content.layer).cornerRadius - 26) * scale == 0)
        #expect((fieldFrame.height - field.intrinsicContentSize.height) * scale == 0)
        #expect((content.bounds.maxY - fieldFrame.midY - 10 - 44 / 2) * scale == 0)
        #expect((fieldFrame.minX - (16 + 22 + 12)) * scale == 0)
        #expect((content.bounds.maxX - fieldFrame.maxX - 16) * scale == 0)
        #expect((listFrame.minX - 8) * scale == 0)
        #expect((content.bounds.maxY - 10 - 44 - listFrame.maxY - 4) * scale == 0)
        #expect((rig.launcher.listHeight - listFrame.height - (4 + 8)) * scale == 0)
        #expect((table.rect(ofRow: 0).height - 38) * scale == 0)
        #expect((icon.frame.height - 22) * scale == 0)
        #expect((icon.frame.minY - 8) * scale == 0)
        #expect((icon.frame.minX - 8) * scale == 0)
        #expect((textFrame.minX - iconFrame.maxX - 10) * scale == 0)
        #expect(field.font?.pointSize == 20 && !field.isBezeled && !field.drawsBackground)
        table.selectRowIndexes([0], byExtendingSelection: false)
        let selected = try #require(table.rowView(atRow: 0, makeIfNecessary: true))
        #expect(selected.isSelected && selected.interiorBackgroundStyle == .normal)
        #expect(cell.backgroundStyle == .normal)
        #expect(text.font == NSFont.preferredFont(forTextStyle: .body))
        try checkSearchGeometry(rig)
    }

    @Test func aSelectedRowDrawsTheBorderInNormalContrast() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        let table = try #require(rig.launcher.table)
        table.selectRowIndexes([0], byExtendingSelection: false)
        let selected = try #require(table.rowView(atRow: 0, makeIfNecessary: true))
        let unselected = try #require(table.rowView(atRow: 1, makeIfNecessary: true))
        for look in [Look.light, .dark] {
            selected.appearance = look.appearance
            unselected.appearance = look.appearance
            #expect(viewDraws(Theme.launcherSelectionBorder, in: selected, x: 0, y: selected.bounds.midY), "\(look): no border on the selected row")
            #expect(!viewDraws(Theme.launcherSelectionBorder, in: unselected, x: 0, y: unselected.bounds.midY), "\(look): border on an unselected row")
        }
    }

    @Test func theShowAllGlyphMatchesTheFieldAndSharesTheResultIconAxis() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        let panel = try rig.panel()
        let content = try #require(panel.contentView)
        let table = try #require(rig.launcher.table)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ResultCell)
        content.layoutSubtreeIfNeeded()
        let icons = images(in: content)
        let field = try #require(icons.first { $0.identifier?.rawValue == "launcher-search-icon" })
        let showAll = try #require(icons.first { $0.identifier?.rawValue == "launcher-show-all-icon" })
        let row = try #require(cell.imageView)
        func frame(_ image: NSImageView) throws -> NSRect {
            try #require(image.superview).convert(image.alignmentRect(forFrame: image.frame), to: content)
        }
        let scale = panel.backingScaleFactor
        let fieldFrame = try frame(field)
        let showAllFrame = try frame(showAll)
        let rowFrame = try frame(row)
        #expect((showAllFrame.height - fieldFrame.height) * scale == 0)
        #expect((try #require(showAll.image).size.height - #require(field.image).size.height) * scale == 0)
        #expect(showAll.image?.tiffRepresentation == field.image?.tiffRepresentation)
        #expect((showAllFrame.midX - fieldFrame.midX) * scale == 0)
        #expect((rowFrame.midX - fieldFrame.midX) * scale == 0)
        #expect((fieldFrame.midX - 16 - 22 / 2) * scale == 0)
    }

    @Test func theSearchTextAndCaretAreCenteredAboveACompactStatusBar() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        let panel = try rig.panel()
        let content = try #require(panel.contentView)
        let field = try #require(panel.searchField)
        let editor = try #require(field.currentEditor() as? NSTextView)
        for query in ["", "rep", ""] {
            if query.isEmpty {
                if !editor.string.isEmpty { try rig.escape() }
            } else {
                try rig.type(query)
                try await rig.finish(3)
            }
            content.layoutSubtreeIfNeeded()
            try checkSearchGeometry(rig)
        }
        try rig.type("rep")
        try await rig.finish(3)
        let table = try #require(rig.launcher.table)
        for y in [12.0, 52.0] {
            try #require(panel.makeFirstResponder(table))
            let location = NSPoint(x: 100, y: panel.frame.height - y)
            let target = try #require(content.hitTest(content.convert(location, from: nil)))
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            target.mouseDown(with: event)
            #expect(rig.fieldHasFocus)
            try rig.type("o")
        }
        #expect(rig.fieldText == "repoo")
    }

    private func images(in view: NSView) -> [NSImageView] {
        view.subviews.flatMap { (($0 as? NSImageView).map { [$0] } ?? []) + images(in: $0) }
    }

    private func checkSearchGeometry(_ rig: LauncherRig) throws {
        let panel = try rig.panel()
        let content = try #require(panel.contentView)
        let field = try #require(panel.searchField)
        let icons = images(in: content)
        let searchIcons = icons.filter { $0.identifier?.rawValue == "launcher-search-icon" }
        #expect(searchIcons.count == 1)
        let icon = try #require(searchIcons.first)
        #expect(icon.identifier?.rawValue == "launcher-search-icon")
        for glyph in icons where glyph !== icon {
            #expect(glyph.identifier?.rawValue != "launcher-search-icon")
        }
        if rig.fieldText != "" {
            let showAll = try #require(icons.first { $0.identifier?.rawValue == "launcher-show-all-icon" })
            #expect(showAll !== icon)
            let table = try #require(rig.launcher.table)
            for row in 0..<table.numberOfRows {
                let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ResultCell)
                let glyph = try #require(cell.imageView)
                #expect(glyph !== icon)
            }
        }
        let iconFrame = panel.convertToScreen(try #require(icon.superview).convert(icon.alignmentRect(forFrame: icon.frame), to: nil))
        let scale = panel.backingScaleFactor
        print("launcher polish icon: frame \(icon.frame), insets \(icon.alignmentRectInsets), aligned \(iconFrame)")
        for y in [12.0, 52.0] {
            let point = content.convert(NSPoint(x: 100, y: content.bounds.maxY - y), to: content.superview)
            #expect(content.hitTest(point) === field.superview, "the entire 44 pt field must remain clickable")
        }
        let editor = try #require(field.currentEditor() as? NSTextView)
        let caret = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let barHeight = panel.frame.height - (10 + 44) - rig.launcher.listHeight - (rig.fieldText == "" ? 0 : 38)
        let line = NSHostingView(rootView: Text(verbatim: "Ready")
            .font(Font(StatusBarView.font(.standard))).fixedSize()).fittingSize.height
        print("launcher polish geometry: field \(field.frame.height), text/icon delta \((caret.midY - iconFrame.midY) * scale) px, caret gap \(caret.minX - iconFrame.maxX), status band \(barHeight), font line \(line)")
        #expect((panel.frame.maxY - iconFrame.midY - 10 - 44 / 2) * scale == 0)
        #expect((caret.midY - iconFrame.midY) * scale == 0)
        #expect((caret.minX - iconFrame.maxX - 12) * scale == 0)
        let bottom = max(SearchMetrics.statusVerticalInset, ceil(26 * (1 - 1 / sqrt(CGFloat(2)))))
        #expect((barHeight - 1 - line - SearchMetrics.statusVerticalInset - bottom) * scale == 0)
    }

    @available(macOS 14.4, *)
    @Test func renderTheLauncherInLightAndDarkWithEmptyAndFiveRows() async throws {
        let directory = URL(fileURLWithPath: "/Volumes/My Shared Files/results", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let backdrop = NSWindow(contentRect: try #require(NSScreen.main).visibleFrame,
            styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.contentView = NSHostingView(rootView: LinearGradient(colors: [.blue, .teal, .orange],
            startPoint: .leading, endPoint: .trailing))
        backdrop.orderFront(nil)
        defer { backdrop.close() }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let rig = LauncherRig()
            defer { rig.close() }
            try await rig.show()
            let panel = try rig.panel()
            panel.appearance = NSAppearance(named: appearance)
            rig.fake.send(.stateChanged(IndexState(phase: .crawling, bootPhase: .live, indexingDisks: ["Disk 1"], indexed: 2_550_850)))
            try await rig.until("the live state") { rig.index.indexState?.indexed == 2_550_850 }
            func capture(_ file: String) async throws -> NSBitmapImageRep {
                panel.contentView?.layoutSubtreeIfNeeded()
                panel.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                let url = directory.appendingPathComponent(file)
                let available = try await SCShareableContent.currentProcess
                let window = try #require(available.windows.first { $0.windowID == UInt32(panel.windowNumber) })
                #expect(window.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier)
                let configuration = SCStreamConfiguration()
                configuration.width = Int(panel.frame.width * panel.backingScaleFactor)
                configuration.height = Int(panel.frame.height * panel.backingScaleFactor)
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                configuration.includeChildWindows = false
                let shot = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
                let image = NSBitmapImageRep(cgImage: shot)
                let data = try #require(image.representation(using: .png, properties: [:]))
                try data.write(to: url)
                #expect(CGFloat(image.pixelsWide) == panel.frame.width * panel.backingScaleFactor)
                #expect(CGFloat(image.pixelsHigh) == panel.frame.height * panel.backingScaleFactor)
                print("launcher polish render: \(url.path), \(image.pixelsWide) x \(image.pixelsHigh)")
                return image
            }
            for count in [0, 5] {
                if count > 0 {
                    try rig.type("rep")
                    try await rig.finish(count)
                }
                _ = try await capture("launcherfix2-\(name)-\(count).png")
            }
            rig.store.set(Theme.inkAndGlass.rawValue, forKey: Theme.key)
            var pixels: [[Int]] = []
            for value in [0, 100] {
                rig.store.set(value, forKey: Launcher.opacityKey)
                let image = try await capture("launcheropacity-\(name)-\(value).png")
                let pixel = try #require(srgbPixel(image, x: image.pixelsWide / 2, y: Int(5 * panel.backingScaleFactor)))
                print("launcher opacity render: \(name) \(value)%, top middle \(pixel)")
                pixels.append(pixel)
            }
            #expect(pixels[0] != pixels[1], "\(name): the shown launcher kept its fill when the stored opacity changed")
        }
    }

    @Test func theSurfaceDrawsAOnePixelEdgeInEveryAppearance() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        let panel = try rig.panel()
        let content = try #require(panel.contentView)
        defer { panel.appearance = nil }
        func bits(_ color: NSColor, _ look: Look) -> [Int] {
            let resolved = channels(color, look)
            return eightBits(resolved) + [Int((resolved[3] * 255).rounded())]
        }
        for look in Look.allCases {
            panel.appearance = look.appearance
            let expected = bits(look == .lightContrast || look == .darkContrast ? .labelColor : .separatorColor, look)
            try await rig.until("the \(look) edge \(expected)") {
                guard let border = content.layer?.borderColor, let color = NSColor(cgColor: border) else { return false }
                return bits(color, look) == expected
            }
            let layer = try #require(content.layer)
            #expect(layer.borderWidth * panel.backingScaleFactor == 1, "\(look): edge \(layer.borderWidth) pt at scale \(panel.backingScaleFactor)")
        }
    }

    @Test func aHotkeyPressAfterTheGrantShowsTheLauncherAndOpensNoWindow() async throws {
        let workspace = NSWorkspace.shared
        let previous = workspace.frontmostApplication
        defer { _ = previous?.activate(options: []) }
        let host = NSRunningApplication.current
        let finderURL = try #require(workspace.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        let finder = try await workspace.openApplication(at: finderURL, configuration: .init())
        try await untilTrue(waitingFor: "Finder in front and the test host inactive (AppKit \(NSApp.isActive), process \(host.isActive), Finder \(finder.isActive), front \(workspace.frontmostApplication?.processIdentifier ?? 0))") {
            finder.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier
                && !NSApp.isActive && !NSRunningApplication.current.isActive
        }
        let mains = mainWindowCount()
        var activations = 0
        defer {
            for panel in NSApp.windows where panel.identifier?.rawValue == Launcher.id && panel.isVisible { panel.performClose(nil) }
        }
        let activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { _ in
            MainActor.assumeIsolated { activations += 1 }
            print("launcher unexpected activation: \(Thread.callStackSymbols.joined(separator: "\n"))")
        }
        defer { NotificationCenter.default.removeObserver(activation) }
        WhereverApp.helperCommands.receive(.launcher)
        let panels = NSApp.windows.filter { $0.identifier?.rawValue == Launcher.id && $0.isVisible }
        try #require(panels.count == 1)
        let panel = try #require(panels.first as? LauncherPanel)
        #expect(panel.isVisible)
        try await untilTrue(waitingFor: "the launcher's field to hold focus") {
            panel.contentView?.layoutSubtreeIfNeeded()
            return panel.searchField?.currentEditor().map { panel.firstResponder === $0 } ?? false
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(mainWindowCount() == mains)
        #expect(activations == 0)
        #expect(!NSRunningApplication.current.isActive && finder.isActive)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier)
        #expect(!MainWindow.isMain(panel))
        WhereverApp.helperCommands.receive(.launcher)
        #expect(!panel.isVisible)
    }

    @Test func theLiveLauncherHandsOffThroughBothRoutes() async throws {
        func newWindowItem(in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items {
                if item.title == String(localized: "New Window", table: "MenuBar") { return item }
                if let found = newWindowItem(in: item.submenu) { return found }
            }
            return nil
        }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: WindowMode.key)
        defaults.set(WindowMode.simple.rawValue, forKey: WindowMode.key)
        defer {
            if let previous { defaults.set(previous, forKey: WindowMode.key) } else { defaults.removeObject(forKey: WindowMode.key) }
        }
        for byRow in [false, true] {
            let known = Set(NSApp.windows.map(ObjectIdentifier.init))
            func fresh() -> [NSWindow] {
                NSApp.windows.filter { MainWindow.isMain($0) && !known.contains(ObjectIdentifier($0)) }
            }
            defer {
                for panel in NSApp.windows where panel.identifier?.rawValue == Launcher.id && panel.isVisible { panel.performClose(nil) }
                for window in fresh() { window.close() }
            }
            WhereverApp.helperCommands.receive(.launcher)
            let panels = NSApp.windows.filter { $0.identifier?.rawValue == Launcher.id && $0.isVisible }
            try #require(panels.count == 1)
            let panel = try #require(panels.first as? LauncherPanel)
            let keyGuard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
                let ours = MainActor.assumeIsolated { panel.map { (event.window ?? NSApp.keyWindow) === $0 } ?? false }
                return ours ? nil : event
            }
            defer {
                if let keyGuard { NSEvent.removeMonitor(keyGuard) }
            }
            try await untilTrue(waitingFor: "the live launcher field") {
                panel.contentView?.layoutSubtreeIfNeeded()
                return panel.searchField?.currentEditor() != nil
            }
            let editor = try #require(panel.searchField?.currentEditor() as? NSTextView)
            editor.insertText("report", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            #expect(panel.searchField?.stringValue == "report")
            if byRow {
                try await untilTrue(waitingFor: "the live Show all button") {
                    panel.contentView?.layoutSubtreeIfNeeded()
                    return AXTree.element("launcher-show-all", in: panel) != nil
                }
                #expect(AXTree.press(try #require(AXTree.element("launcher-show-all", in: panel))))
            } else {
                let item = try #require(newWindowItem(in: NSApp.mainMenu))
                #expect(item.keyEquivalent == "n" && item.keyEquivalentModifierMask == .command)
                let menu = try #require(item.menu)
                menu.performActionForItem(at: menu.index(of: item))
            }
            try await untilTrue(waitingFor: "the real handed-off window") { fresh().contains { $0.searchField != nil } }
            try await Task.sleep(for: .milliseconds(100))
            let windows = fresh()
            try #require(windows.count == 1)
            #expect(windows[0].searchField?.stringValue == "report")
            #expect(windows[0].isVisible && !panel.isVisible)
        }
    }

    @Test func theHotkeyAgainHidesTheLauncherAndEmptiesTheField() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        #expect(rig.fake.queries == ["r", "re", "rep"])
        rig.launcher.toggle()
        #expect(try !rig.panel().isVisible)
        #expect(rig.launcher.model.query.isEmpty)
        try await rig.until("an empty field") { rig.fieldText == "" }
        #expect(rig.recorder.nothingHappened)
        #expect(rig.fake.queries == ["r", "re", "rep"])
    }

    @Test func losingKeyToAnotherWindowHidesTheLauncher() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        try await rig.show()
        rig.launcher.keyMoved(to: other)
        #expect(try !rig.panel().isVisible)
        try await rig.show()
        rig.launcher.keyMoved(to: nil)
        #expect(try !rig.panel().isVisible)
        #expect(rig.recorder.nothingHappened)
        let panel = LauncherPanel()
        var told = 0
        panel.onLostKey = { _ in told += 1 }
        panel.resignKey()
        #expect(told == 0, "the rule ran before AppKit settled the new key window")
        try await rig.until("the lost-key rule one turn later") { told == 1 }
    }

    @Test func keyStayingInTheLauncherKeepsItOpen() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.launcher.keyMoved(to: rig.panel())
        #expect(try rig.panel().isVisible)
    }

    @Test func escapeClearsTheTextAndASecondEscapeCloses() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try rig.escape()
        #expect(try rig.panel().isVisible)
        #expect(rig.launcher.model.query.isEmpty)
        try await rig.until("an empty field") { rig.fieldText == "" }
        #expect(rig.fieldHasFocus)
        try rig.escape()
        #expect(try !rig.panel().isVisible)
        #expect(rig.fake.queries == ["r", "re", "rep"])
        #expect(rig.launcher.model.filters == SearchFilters())
        #expect(rig.recorder.nothingHappened)
    }

    @Test func escapeInTheListClearsThenCloses() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        try rig.escape()
        #expect(try rig.panel().isVisible)
        #expect(rig.launcher.model.query.isEmpty)
        try await rig.until("the field to hold focus") { rig.fieldHasFocus }
        try rig.escape()
        #expect(try !rig.panel().isVisible)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func commandDownInTheListKeepsTodaysTableBehaviourAndEscapeStillClears() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        try rig.down(flags: .command)
        #expect(rig.launcher.table?.selectedRowIndexes == [1])
        #expect(rig.listHasFocus)
        #expect(try rig.panel().isVisible)
        #expect(rig.windows.isEmpty)
        try rig.escape()
        #expect(try rig.panel().isVisible)
        #expect(rig.launcher.model.query.isEmpty)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func launcherCommandDownOnAnArchiveHidesAndOpensTheWindow() async throws {
        let rig = LauncherRig(hits: [photosZip, notesText], archived: photoEntries)
        defer { rig.close() }
        try await rig.show()
        try rig.type("p")
        try await rig.finish(2)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        let list = try #require(rig.launcher.table)
        let panel = try rig.panel()
        func menuTitles(row: Int) throws -> [String] {
            let rect = list.rect(ofRow: row)
            let click = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: list.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            return try #require(list.menu(for: click)).items.map(\.title)
        }
        let item = String(localized: "Show Archive Contents", table: "Results")
        let textMenu = try menuTitles(row: 1)
        let zipMenu = try menuTitles(row: 0)
        #expect(!textMenu.contains(item), "the text row's menu \(textMenu)")
        #expect(zipMenu.firstIndex(of: item) == 1, "the zip row's menu \(zipMenu)")
        try #require(list.selectedRowIndexes == [0])
        try #require(rig.listHasFocus)
        try rig.down(flags: .command)
        #expect(try !rig.panel().isVisible)
        #expect(rig.launcher.model.query.isEmpty)
        #expect(rig.raised.count == 1)
        #expect(rig.archive.opened == [FakeArchiveClient.Opened(path: photosZip.path, shownAs: photosZip.path)])
        #expect(ArchiveWindows.all.count == 1)
        let controller = try #require(ArchiveWindows.all.first)
        let window = try #require(controller.window)
        #expect(window.isVisible)
        #expect(window.identifier?.rawValue == ArchiveWindows.windowID)
        #expect(rig.recorder.nothingHappened)
        #expect(rig.windows.isEmpty)

        let model = controller.model
        func table() -> ThemedTable? {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.contentView?.descendant(ThemedTable.self)
        }
        try await untilTrue(waitingFor: "the archive's two rows with the first selected, shown \(model.results.names)") {
            !model.results.isPending && table()?.numberOfRows == 2 && table()?.selectedRowIndexes == [0]
        }
        #expect(window.firstResponder === table())
        try pressReturn(in: window)
        try await untilTrue(waitingFor: "the Trip folder entered, shown \(model.results.names)") {
            !model.results.isPending && model.results.names == ["IMG_0001.HEIC"]
        }
        #expect(model.folder == "Trip")
        #expect(rig.archiveRecorder.refused == 0 && rig.archiveRecorder.opened.isEmpty)
        #expect(ArchiveWindows.all.count == 1)
    }

    @Test func openingAResultFromTheLauncherWithNoWindowRecordsItThenQuits() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        let hit = launcherFile("opened.txt")
        rig.launcher.actions.openAndRecord(hit)
        #expect(rig.recorder.recorded == [hit.path])
        #expect(rig.recorder.opened == [hit.fileURL])
        #expect(rig.quits == 0, "the quit ran before the open was recorded")
        try await pumpEvents(for: .milliseconds(20))
        #expect(rig.quits == 1)
    }

    @Test func showAllFromTheLauncherWithNoWindowKeepsWhereverAndOpensTheWindow() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        rig.newWindow()
        try await pumpEvents(for: .milliseconds(20))
        #expect(rig.windows.count == 1)
        #expect(rig.presence.awaitingWindow)
        #expect(rig.quits == 0)
    }

    @Test func enteringAnArchiveFromTheLauncherWithNoWindowKeepsWhereverAndOpensTheArchive() async throws {
        let rig = LauncherRig(hits: [notesText, photosZip], archived: photoEntries)
        defer { rig.close() }
        try await rig.show()
        let inside = try #require(rig.launcher.actions.inside)
        inside.enter(photosZip)
        #expect(rig.presence.awaitingWindow, "the hand-off asked for no window")
        try await pumpEvents(for: .milliseconds(20))
        #expect(rig.quits == 0)
        let window = try #require(ArchiveWindows.all.first?.window)
        #expect(window.isVisible)
    }

    @Test func launcherCommandDownOnTextDoesNothing() async throws {
        let rig = LauncherRig(hits: [notesText, photosZip], archived: photoEntries)
        defer { rig.close() }
        try await rig.show()
        try rig.type("p")
        try await rig.finish(2)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        try #require(rig.launcher.table?.selectedRowIndexes == [0])
        try rig.down(flags: .command)
        #expect(try rig.panel().isVisible)
        #expect(rig.listHasFocus)
        #expect(ArchiveWindows.all.isEmpty)
        #expect(rig.archive.opened.isEmpty)
        #expect(rig.raised.count == 0)
        #expect(rig.recorder.nothingHappened)
        #expect(rig.launcher.model.query == "p")

        try #require(try rig.panel().focusSearchField() != nil)
        try await rig.until("the field to hold focus again") { rig.fieldHasFocus }
        try rig.down(flags: .command)
        #expect(rig.fieldHasFocus)
        #expect(try rig.panel().isVisible)
        #expect(ArchiveWindows.all.isEmpty)
        #expect(AXTree.press(try #require(rig.showAllRow)))
        try await rig.until("one new window") { rig.windows.count == 1 }
        #expect(rig.windows[0].model.query == "p")
        #expect(ArchiveWindows.all.isEmpty)
        #expect(rig.raised.count == 0)
    }

    @Test func launcherSpaceStillPreviewsInline() async throws {
        let rig = LauncherRig(hits: [photosZip], archived: photoEntries)
        defer { rig.close() }
        try await rig.show()
        try rig.type("p")
        try await rig.finish(1)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        try rig.space()
        #expect(rig.launcher.previewShown)
        #expect(rig.launcher.previewURL == photosZip.fileURL)
        #expect(try rig.panel().isVisible)
        #expect(ArchiveWindows.all.isEmpty)
        #expect(rig.archive.opened.isEmpty)
        #expect(rig.raised.count == 0)
        try rig.down(flags: .command)
        #expect(try !rig.panel().isVisible)
        #expect(!rig.launcher.previewShown)
        #expect(ArchiveWindows.all.count == 1)
        #expect(rig.raised.count == 1)
    }

    @Test func theLauncherListSelectsOneRow() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        let table = try #require(rig.launcher.table)
        #expect(!table.allowsMultipleSelection)
        try #require(table.selectedRowIndexes == [0])
        try rig.down(flags: .shift)
        #expect(table.selectedRowIndexes.count == 1)
        table.selectAll(nil)
        #expect(table.selectedRowIndexes.count == 1)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func returnOpensTheTopRowRecordsItAndCloses() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.pressReturn()
        #expect(rig.recorder.opened == [reports[0].fileURL])
        #expect(rig.recorder.recorded == [reports[0].path])
        #expect(try !rig.panel().isVisible)
        #expect(rig.launcher.model.query.isEmpty)
        #expect(rig.recorder.revealed.isEmpty && rig.recorder.shown.isEmpty)
    }

    @Test func theNextPressAfterReturnShowsAnEmptyField() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.pressReturn()
        try await rig.show()
        try await rig.until("an empty field and list") { rig.fieldText == "" && rig.launcher.table?.numberOfRows == 0 }
        #expect(rig.launcher.listHeight == 0)
        #expect(rig.launcher.model.count == 0)
        #expect(rig.recorder.opened.count == 1)
    }

    @Test func returnWhileASearchIsPendingOpensTheTopRowWhenItsResultsLand() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try rig.pressReturn()
        #expect(try rig.panel().isVisible)
        #expect(rig.recorder.nothingHappened)
        #expect(rig.fieldText == "rep")
        rig.fake.send(.resultsReady(rig.fake.latest, count: 3))
        try await rig.until("the top row opened, opened \(rig.recorder.opened)") { rig.recorder.opened == [reports[0].fileURL] }
        #expect(rig.recorder.recorded == [reports[0].path])
        #expect(try !rig.panel().isVisible)
        #expect(rig.launcher.model.query.isEmpty)
    }

    @Test func commandReturnWhileASearchIsPendingRevealsTheTopRowWhenItsResultsLand() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try rig.pressReturn(command: true)
        #expect(rig.recorder.nothingHappened)
        rig.fake.send(.resultsReady(rig.fake.latest, count: 3))
        try await rig.until("the top row revealed, revealed \(rig.recorder.revealed)") { rig.recorder.revealed == [reports[0].fileURL] }
        #expect(rig.recorder.opened.isEmpty && rig.recorder.recorded.isEmpty)
        #expect(try !rig.panel().isVisible)
    }

    @Test func returnTwiceWhileASearchIsPendingOpensOnce() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try rig.pressReturn()
        try rig.pressReturn()
        rig.fake.send(.resultsReady(rig.fake.latest, count: 3))
        try await rig.until("the top row opened") { !rig.recorder.opened.isEmpty }
        #expect(rig.recorder.opened == [reports[0].fileURL])
        #expect(try !rig.panel().isVisible)
    }

    @Test func aLetterAfterAPendingReturnDropsIt() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try rig.pressReturn()
        try rig.type("o")
        try await rig.finish(3)
        #expect(rig.recorder.nothingHappened)
        #expect(try rig.panel().isVisible)
        #expect(rig.fieldText == "repo")
    }

    @Test func escapeAfterAPendingReturnDropsIt() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try rig.pressReturn()
        try rig.escape()
        #expect(rig.launcher.model.query.isEmpty)
        try rig.type("r")
        try await rig.finish(3)
        #expect(rig.recorder.nothingHappened)
        #expect(try rig.panel().isVisible)
    }

    @Test func commandReturnRevealsAndCloses() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.pressReturn(command: true)
        #expect(rig.recorder.revealed == [reports[0].fileURL])
        #expect(rig.recorder.opened.isEmpty && rig.recorder.recorded.isEmpty)
        #expect(try !rig.panel().isVisible)
    }

    @Test func commandCCopiesThePathAndStays() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        let responder = try #require(try rig.panel().firstResponder)
        #expect(responder.tryToPerform(NSSelectorFromString("copy:"), with: nil))
        #expect(rig.recorder.copied == [reports[0].path])
        #expect(try rig.panel().isVisible)
    }

    @Test func commandWCloses() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try rig.panel().performClose(nil)
        #expect(try !rig.panel().isVisible)
        #expect(rig.launcher.model.query.isEmpty)
    }

    @Test func aRealCommandWKeyClosesTheLauncherAndClearsIt() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        #expect(try rig.command("w", code: 13), "the panel took Command-W as its key equivalent")
        #expect(try !rig.panel().isVisible)
        #expect(rig.launcher.model.query.isEmpty)
    }

    @Test func aRealCommandWOnAnEmptyFieldClosesToo() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        #expect(try rig.command("w", code: 13))
        #expect(try !rig.panel().isVisible)
    }

    @Test func fileCloseStaysEnabledForTheLauncherOnAnyLayout() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        let close = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        #expect(try rig.panel().validateMenuItem(close))
    }

    @Test func commandWWithAnotherModifierLeavesTheLauncherOpen() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        for flags: NSEvent.ModifierFlags in [.shift, .option, .control] {
            #expect(try !rig.command("w", code: 13, flags: flags), "Command-\(flags.rawValue)-W")
            #expect(try rig.panel().isVisible)
        }
        #expect(rig.launcher.model.query == "rep")
    }

    @Test func commandNClosesTheLauncherAndOpensOneWindow() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        let access = AccessModel(
            defaults: rig.store, center: NotificationCenter(), stage: .ready, probe: { .granted }, confirm: { true }, start: {}, summon: {}, activate: {}
        )
        var windows = 0
        var opens: [Bool] = []
        let routes = WhereverApp.routes(
            access: access, summon: {}, openWindow: {
                windows += 1
                opens.append(rig.launcher.panel?.isVisible == true)
            },
            showSettings: {}, activate: {}, open: { _ in }, quit: {},
            launcher: { rig.launcher.toggle() }, closeLauncher: { rig.launcher.prepareHandOff() }
        )
        routes.hotkey()
        try await rig.until("the launcher's field to hold focus") { rig.fieldHasFocus }
        try rig.type("rep")
        routes.menu.newWindow()
        #expect(windows == 1)
        #expect(opens == [false], "the window opened while the launcher still showed")
        #expect(rig.index.nextQuery == "rep", "the text waits for the window's model")
        #expect(try !rig.panel().isVisible)
        #expect(rig.launcher.model.query.isEmpty)
    }

    @Test func aHandedOffWindowSendsOneSearchForItsText() async throws {
        for (fromList, hidden) in [(false, false), (true, false), (false, true), (true, true)] {
            let rig = LauncherRig()
            defer { rig.close() }
            rig.store.set(hidden, forKey: SearchFilters.hidesHiddenKey)
            try await rig.show()
            try await rig.until("the hidden setting before handoff") { rig.launcher.model.filters.hidesHidden == hidden }
            try rig.type("r")
            if fromList {
                try await rig.finish(3)
                try rig.down()
                try await rig.until("the list to hold focus") { rig.listHasFocus }
            }
            rig.newWindow()
            try #require(rig.windows.count == 1)
            let window = rig.windows[0]
            let field = try await rig.windowField()
            #expect(window.model.query == "r" && field.stringValue == "r")
            #expect(window.host.window.isVisible)
            #expect(rig.visibleAtOpen == [false] && rig.activations == 1)
            #expect(rig.fake.session(rig.fake.lastSession)?.searches == [.init(query: hidden ? "r hidden:no" : "r", sort: .bestMatch)])
            #expect(rig.fake.presses.isEmpty)
            #expect(try !rig.panel().isVisible)
            #expect(rig.launcher.model.query.isEmpty)
        }
    }

    @Test func theShowAllRowOpensOneWindowWithItsText() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("report")
        try await rig.until("the handoff button while results are pending") { rig.showAllRow != nil }
        #expect(AXTree.press(try #require(rig.showAllRow)))
        try await rig.until("one new window") { rig.windows.count == 1 }
        let field = try await rig.windowField()
        #expect(rig.windows[0].model.query == "report" && field.stringValue == "report")
        #expect(rig.visibleAtOpen == [false] && rig.activations == 1)
        #expect(try !rig.panel().isVisible)
        #expect(rig.launcher.model.query.isEmpty)
    }

    @Test func commandNWithAnEmptyFieldOpensAListingWindow() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        let launcherSession = rig.fake.lastSession
        rig.newWindow()
        try #require(rig.windows.count == 1)
        let field = try await rig.windowField()
        #expect(rig.windows[0].model.query.isEmpty && field.stringValue.isEmpty)
        #expect(rig.fake.session(launcherSession)?.searches.isEmpty == true)
        #expect(rig.fake.session(rig.fake.lastSession)?.searches == [.init(query: "", sort: SearchSort(column: .name, ascending: true))])
        #expect(rig.visibleAtOpen == [false] && rig.activations == 1)
        #expect(try !rig.panel().isVisible)
    }

    @Test func theHandedTextReachesOneWindowOnly() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("report")
        rig.newWindow()
        rig.newWindow()
        try #require(rig.windows.count == 2)
        let first = try await rig.windowField()
        let second = try await rig.windowField(1)
        #expect(rig.windows.map { $0.model.query } == ["report", ""])
        #expect(first.stringValue == "report" && second.stringValue.isEmpty)
        #expect(rig.index.nextQuery == nil)
        #expect(rig.activations == 2)
    }

    @Test func inNormalModeTheHandedTextIsTheFileName() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        rig.store.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
        try await rig.show()
        try rig.type("report")
        rig.newWindow()
        try #require(rig.windows.count == 1)
        let window = rig.windows[0]
        let field = try await rig.windowField()
        try await window.host.until("the Normal form") { AXTree.element(NormalForm.id, in: window.host.view) != nil }
        #expect(field.stringValue == "report")
        #expect(field.cell?.accessibilityLabel() == String(localized: "File name:", table: "Normal"))
        #expect(window.model.query == "report" && window.model.content == ContentTerms())
        #expect(window.model.contentDraft.isEmpty && rig.fake.presses.isEmpty)
        #expect(rig.fake.session(rig.fake.lastSession)?.searches.map(\.query) == ["report"])
    }

    @Test func thePressAfterAHandOffShowsAnEmptyLauncher() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("report")
        rig.newWindow()
        try #require(rig.windows.count == 1)
        _ = try await rig.windowField()
        try await rig.show()
        try await rig.until("an empty launcher without the handoff row") {
            rig.fieldText == "" && rig.launcher.listHeight == 0 && rig.showAllRow == nil
        }
        #expect(rig.windows[0].model.query == "report")
        #expect(rig.windows[0].host.field()?.stringValue == "report")
        #expect(rig.windows.count == 1)
    }

    @Test func theShowAllRowShowsOnlyWithText() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        #expect(rig.showAllRow == nil)
        let panel = try rig.panel()
        let empty = panel.frame
        try rig.type("report")
        try await rig.until("the handoff row before results") { rig.showAllRow != nil }
        #expect((panel.frame.height - empty.height - LauncherMetrics.rowHeight(.standard)) * panel.backingScaleFactor == 0)
        try await rig.finish(0)
        let content = try #require(panel.contentView)
        try await rig.until("No results and the handoff row") {
            AXTree.element(Launcher.emptyID, in: content) != nil && rig.showAllRow != nil
        }
        let words = try #require(AXTree.element(Launcher.emptyID, in: content))
        let row = try #require(rig.showAllRow)
        #expect(try #require(AXTree.frame(of: row)).maxY <= #require(AXTree.frame(of: words)).minY)
        try rig.type("s")
        try await rig.finish(3)
        #expect(rig.showAllRow != nil)
        let table = try #require(rig.launcher.table)
        #expect(table.numberOfRows == 3 && rig.launcher.model.count == 3)
        let resultRow = try #require(rig.showAllRow)
        #expect(try #require(AXTree.frame(of: resultRow)).maxY <= table.accessibilityFrame().minY)
    }

    @Test func escapeHidesTheShowAllRowAndKeepsTheTop() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("report")
        try await rig.until("the handoff row before results") { rig.showAllRow != nil }
        let panel = try rig.panel()
        let before = panel.frame
        try rig.escape()
        try await rig.until("the handoff row gone and the panel fitted") {
            rig.showAllRow == nil && panel.frame.height == LauncherMetrics.aligned(
                LauncherMetrics.bandHeight + LauncherMetrics.barHeight(.standard), scale: panel.backingScaleFactor
            )
        }
        #expect((before.height - panel.frame.height - LauncherMetrics.rowHeight(.standard)) * panel.backingScaleFactor == 0)
        #expect((panel.frame.maxY - before.maxY) * panel.backingScaleFactor == 0)
        #expect(panel.isVisible && rig.fieldHasFocus)
    }

    @Test func theShowAllRowIsOneButtonWithItsWords() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("report")
        try await rig.until("the handoff row") { rig.showAllRow != nil }
        let content = try #require(try rig.panel().contentView)
        let rows = AXTree.elements(in: content).filter { AXTree.identifier(of: $0) == "launcher-show-all" }
        try #require(rows.count == 1)
        let row = rows[0]
        #expect(AXTree.value("accessibilityRole", of: row) as String? == NSAccessibility.Role.button.rawValue)
        #expect(Set(AXTree.names(of: row)) == [String(localized: "Show all in Wherever", table: "Results")])
        #expect(AXTree.isEnabled(row) == true)
        #expect(!AXTree.elements(in: row).flatMap { AXTree.names(of: $0) }.contains { $0.contains("⌘N") })
        let frame = try #require(AXTree.frame(of: row))
        #expect(frame.width == rig.launcher.panel?.frame.width)
        #expect(frame.height == LauncherMetrics.rowHeight(.standard))
    }

    @Test func theLauncherFollowsTheTextSize() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        rig.store.set(TextSize.extraLarge.rawValue, forKey: TextSize.key)
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        let panel = try rig.panel()
        let field = try #require(panel.searchField)
        let table = try #require(rig.launcher.table)
        #expect(field.font?.pointSize == 25)
        func bodyRow(_ size: TextSize) -> CGFloat {
            let line = NSLayoutManager().defaultLineHeight(for: size.font(.preferredFont(forTextStyle: .body)))
            return max(LauncherMetrics.iconSize, ceil(line)) + 2 * LauncherMetrics.rowInset
        }
        #expect(LauncherMetrics.rowHeight(.extraLarge) == bodyRow(.extraLarge) && LauncherMetrics.rowHeight(.maximum) == bodyRow(.maximum))
        #expect(LauncherMetrics.rowHeight(.maximum) > LauncherMetrics.rowHeight(.standard))
        #expect(table.rowHeight == LauncherMetrics.rowHeight(.extraLarge))
        let name = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ResultCell)
        let folder = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? ResultCell)
        #expect(name.textField?.font == TextSize.extraLarge.font(.preferredFont(forTextStyle: .body)))
        #expect(name.textField?.font?.pointSize == 16)
        #expect(name.textField?.font != NSFont.systemFont(ofSize: 16))
        #expect(folder.textField?.font == TextSize.extraLarge.font(.preferredFont(forTextStyle: .callout)))
        #expect(LauncherMetrics.barHeight(.extraLarge) > LauncherMetrics.barHeight(.standard))

        rig.store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        let list = 3 * LauncherMetrics.rowHeight(.maximum) + LauncherMetrics.listTop + LauncherMetrics.listBottom
        try await rig.until("\(LauncherMetrics.rowHeight(.maximum)) pt rows and the panel's fit") {
            table.rowHeight == LauncherMetrics.rowHeight(.maximum) && rig.launcher.listHeight == list
        }
        #expect(field.font?.pointSize == 28)
        let fixed = LauncherMetrics.bandHeight + LauncherMetrics.barHeight(.maximum) + LauncherMetrics.rowHeight(.maximum)
        try await rig.until("the panel at 18 pt") { panel.frame.height == LauncherMetrics.aligned(fixed + list, scale: panel.backingScaleFactor) }
        let row = try #require(rig.showAllRow)
        #expect(AXTree.frame(of: row)?.height == LauncherMetrics.rowHeight(.maximum))
        #expect(table.headerView == nil && table.style == .plain)
        #expect(try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ResultCell).textField?.font?.pointSize == 18)
        #expect(rig.fieldHasFocus)
    }

    @Test func theArrowsNeverLeaveTheTable() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("report")
        try await rig.finish(3)
        try await rig.until("the handoff row") { rig.showAllRow != nil }
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        for _ in 0..<4 { try rig.down() }
        #expect(rig.launcher.table?.selectedRow == 2)
        #expect(rig.listHasFocus)
        #expect(rig.windows.isEmpty)
    }

    @Test func aPressInTheListSelectsTheRowBeforeTheButtonGoesUp() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        let table = try #require(rig.launcher.table)
        try #require(table.selectedRow != 2)
        try await EventQueueLock.run {
            let selected = try await pressMouse(on: table, row: 2) { table.selectedRow }
            #expect(selected == 2, "row \(selected) selected while the button is down on row 2")
        }
        #expect(table.selectedRow == 2)
        #expect(try rig.panel().isVisible)
        #expect(rig.recorder.opened.isEmpty && rig.recorder.recorded.isEmpty)
    }

    @Test func returnInTheListOpensTheSelectedRowRecordsItAndCloses() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        try rig.down()
        try rig.pressReturn()
        #expect(rig.recorder.opened == [reports[1].fileURL])
        #expect(rig.recorder.recorded == [reports[1].path])
        #expect(try !rig.panel().isVisible)
    }

    @Test func spaceShowsThePreviewInsideTheLauncherAndTheArrowsMoveIt() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        let three = rig.launcher.listHeight
        try #require(rig.launcher.table != nil)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        try rig.space()
        #expect(rig.launcher.previewShown)
        #expect(rig.launcher.previewURL == reports[0].fileURL)
        #expect(rig.launcher.listHeight == CGFloat(LauncherMetrics.maxRows) * LauncherMetrics.rowHeight(.standard) + LauncherMetrics.listTop + LauncherMetrics.listBottom)
        try rig.down()
        #expect(rig.launcher.previewURL == reports[1].fileURL)
        #expect(try rig.panel().isVisible)
        #expect(rig.listHasFocus)
        try rig.space()
        #expect(!rig.launcher.previewShown)
        #expect(rig.launcher.previewURL == nil)
        #expect(rig.launcher.listHeight == three)
        try rig.escape()
        try rig.escape()
        #expect(try !rig.panel().isVisible)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func theInlinePreviewPaneHoldsTheSelectedFileBesideTheList() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        #expect(rig.previewPane == nil)
        try rig.space()
        try await rig.until("the pane to hold \(reports[0].path)") { (rig.previewPane?.previewItem as? NSURL) as URL? == reports[0].fileURL }
        let pane = try #require(rig.previewPane)
        let list = try #require(rig.launcher.table.map { $0.enclosingScrollView ?? $0 })
        let content = try #require(try rig.panel().contentView)
        #expect(!pane.isHiddenOrHasHiddenAncestor)
        #expect(pane.window === content.window)
        #expect(pane.frame.width > 0 && pane.frame.height > 0)
        #expect(pane.convert(pane.bounds, to: content).minX >= list.convert(list.bounds, to: content).maxX)
        try rig.down()
        try await rig.until("the pane to hold \(reports[1].path)") { (rig.previewPane?.previewItem as? NSURL) as URL? == reports[1].fileURL }
        try rig.space()
        try await rig.until("the pane to leave") { rig.previewPane == nil }
    }

    @Test func aClickOnThePreviewKeepsTheLaunchersKeysWorking() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        try rig.space()
        try await rig.until("the pane to show") { rig.previewPane != nil }
        let panel = try rig.panel()
        let pane = try #require(rig.previewPane)
        let center = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )))
        }
        #expect(rig.listHasFocus || rig.fieldHasFocus)
        #expect(panel.firstResponder !== pane)
        try rig.escape()
        #expect(panel.isVisible)
        #expect(rig.launcher.model.query.isEmpty)
        try await rig.until("the field to hold focus") { rig.fieldHasFocus }
        try rig.escape()
        #expect(!panel.isVisible)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func aPunctuationKeyTypedInTheLauncherListReachesItsField() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        try rig.type(".")
        try await rig.until("the field to hold focus and \"rep.\"") { rig.fieldHasFocus && rig.fieldText == "rep." }
        try rig.type("e")
        #expect(rig.fieldText == "rep.e")
        #expect(try rig.panel().isVisible)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func escapeAfterSpaceClosesThePreviewThenTheLauncher() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        try rig.down()
        try await rig.until("the list to hold focus") { rig.listHasFocus }
        try rig.space()
        #expect(rig.launcher.previewShown)
        try rig.escape()
        try await rig.until("no preview and an empty list") { !rig.launcher.previewShown && rig.launcher.listHeight == 0 }
        #expect(rig.launcher.previewURL == nil)
        #expect(try rig.panel().isVisible)
        #expect(rig.fieldHasFocus)
        try rig.escape()
        #expect(try !rig.panel().isVisible)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func aLiveUpdateGrowsThePanelDownwardWithItsTopFixed() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        let scale = try rig.panel().backingScaleFactor
        let empty = try rig.panel().frame
        try rig.type("rep")
        try await rig.finish(1)
        let one = try rig.panel().frame
        let generation = rig.fake.latest
        rig.fake.send(.resultsChanged)
        try await rig.until("a new search after the live update") { rig.fake.latest != generation }
        try await rig.finish(5)
        let five = try rig.panel().frame
        #expect((one.maxY - empty.maxY) * scale == 0)
        #expect((five.maxY - one.maxY) * scale == 0)
        #expect(five.height > one.height && one.height > empty.height)
        let fixed = LauncherMetrics.bandHeight + LauncherMetrics.barHeight(.standard) + LauncherMetrics.rowHeight(.standard)
        #expect(five.height == LauncherMetrics.aligned(fixed + rig.launcher.listHeight, scale: scale))
        #expect(rig.fake.queries == ["r", "re", "rep", "rep"])
    }

    @Test func theLauncherJoinsTheActiveSpaceAndFullScreenApps() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        let panel = try rig.panel()
        #expect(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary])
        #expect(panel.level == .floating)
        #expect(panel.styleMask == [.borderless, .nonactivatingPanel])
        #expect(panel.isFloatingPanel && !panel.hidesOnDeactivate)
        #expect(panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.isOpaque && panel.hasShadow && panel.backgroundColor == .clear)
        #expect(panel.identifier?.rawValue == Launcher.id)
        #expect(panel.title == String(localized: "Wherever", table: "MenuBar"))
        #expect(!MainWindow.isMain(panel))
    }

    @Test func theFrameFollowsTheScreenUnderThePointer() {
        for screen in NSScreen.screens {
            #expect(LauncherMetrics.screen(at: NSPoint(x: screen.frame.midX, y: screen.frame.midY), in: NSScreen.screens) === screen)
        }
        #expect(LauncherMetrics.screen(at: NSPoint(x: -100_000, y: -100_000), in: NSScreen.screens) === NSScreen.main)
        let visible = NSRect(x: 1920, y: 40, width: 2560, height: 1375)
        let frame = LauncherMetrics.frame(in: visible, scale: 2, height: 101.25)
        #expect(frame.width == LauncherMetrics.width)
        #expect(frame.midX == visible.midX)
        #expect(frame.maxY == visible.maxY - visible.height / 5)
        for edge in [frame.minX, frame.minY, frame.maxY, frame.width, frame.height] {
            #expect((edge * 2).rounded() == edge * 2, "\(edge) is off the device pixel grid")
        }
        let narrow = LauncherMetrics.frame(in: NSRect(x: 0, y: 0, width: 600, height: 800), scale: 1, height: 77)
        #expect(narrow.width == 600 - 2 * LauncherMetrics.screenMargin)
        #expect(narrow.minX == LauncherMetrics.screenMargin)
    }

    @Test func aShortScreenShowsFewerRows() {
        let row = LauncherMetrics.rowHeight(.standard)
        #expect(LauncherMetrics.rows(50, room: 1000, rowHeight: row) == LauncherMetrics.maxRows)
        #expect(LauncherMetrics.rows(3, room: 1000, rowHeight: row) == 3)
        #expect(LauncherMetrics.rows(50, room: 4.5 * row, rowHeight: row) == 4)
        #expect(LauncherMetrics.rows(50, room: 0, rowHeight: row) == 1)
        #expect(LauncherMetrics.rows(0, room: 1000, rowHeight: row) == 0)
    }

    @Test func anEmptyLauncherFieldSendsNoSearch() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        let panel = try rig.panel()
        let field = try #require(panel.searchField)
        try await rig.until("the band laid out") { field.frame.height > 0 }
        #expect(field.frame.height == field.intrinsicContentSize.height)
        #expect(rig.launcher.listHeight == 0)
        #expect(rig.launcher.table?.numberOfRows == 0)
        let fixed = LauncherMetrics.bandHeight + LauncherMetrics.barHeight(.standard)
        #expect(panel.frame.height == LauncherMetrics.aligned(fixed, scale: panel.backingScaleFactor))
        #expect(rig.fake.queries.isEmpty)
    }

    @Test func theFailedSentenceTakesItsOwnLinesInTheLauncher() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        rig.store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        try await rig.show()
        let panel = try rig.panel()
        let content = try #require(panel.contentView)
        let scale = panel.backingScaleFactor
        let sentence = StatusBarView.text(.failed)
        #expect(sentence == "Wherever could not build the index. Choose Quit Wherever from the Wherever menu, then open Wherever again.")
        func today(_ size: TextSize) -> CGFloat {
            let bar = 1 + StatusBarView.launcherLineHeight(size) + SearchMetrics.statusVerticalInset + LauncherMetrics.barBottomInset
            #expect(LauncherMetrics.barHeight(size) == bar)
            return LauncherMetrics.aligned(LauncherMetrics.bandHeight + bar, scale: scale)
        }
        func lines(_ size: TextSize) -> Int {
            let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: sentence, attributes: [.font: StatusBarView.font(size)]))
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: panel.frame.width - 2 * LauncherMetrics.fieldSide, height: 100_000), transform: nil)
            return CFArrayGetCount(CTFrameGetLines(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)))
        }
        func failed(_ size: TextSize) -> CGFloat {
            let bar = 1 + CGFloat(lines(size) + 1) * StatusBarView.launcherLineHeight(size) + SearchMetrics.statusVerticalInset + LauncherMetrics.barBottomInset
            return LauncherMetrics.aligned(LauncherMetrics.bandHeight + bar, scale: scale)
        }
        func expectUnclipped(_ size: TextSize, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let line = StatusBarView.launcherLineHeight(size)
            let inner = panel.frame.width - 2 * LauncherMetrics.fieldSide
            let wrapped = NSHostingView(rootView: Text(verbatim: sentence).font(Font(StatusBarView.font(size) as CTFont)).frame(width: inner)).fittingSize.height
            #expect(Int((wrapped / line).rounded()) == lines(size), "SwiftUI draws \(wrapped) pt of \(line) pt lines", sourceLocation: sourceLocation)
            #expect(wrapped <= CGFloat(lines(size)) * line, "the sentence needs \(wrapped) pt", sourceLocation: sourceLocation)
            let icon = try #require(images(in: content).first { $0.identifier?.rawValue == "launcher-search-icon" }, sourceLocation: sourceLocation)
            let iconFrame = panel.convertToScreen(try #require(icon.superview, sourceLocation: sourceLocation).convert(icon.alignmentRect(forFrame: icon.frame), to: nil))
            #expect((panel.frame.maxY - iconFrame.midY - LauncherMetrics.fieldTop - LauncherMetrics.fieldHeight / 2) * scale == 0, sourceLocation: sourceLocation)
            try await rig.until("the status bar inside the panel, below the band", sourceLocation: sourceLocation) {
                AXTree.element("status-bar", in: content).flatMap(AXTree.frame(of:)).map {
                    $0.minY >= panel.frame.minY && $0.maxY <= panel.frame.maxY - LauncherMetrics.bandHeight
                } == true
            }
        }

        try await rig.until("the live launcher at 18 pt") { panel.frame.height == today(.maximum) }
        rig.fake.send(.stateChanged(IndexState(phase: .failed, bootPhase: .failed, indexed: 10)))
        try await rig.until("the failed launcher at 18 pt, \(lines(.maximum)) sentence lines") { panel.frame.height == failed(.maximum) }
        #expect(lines(.maximum) > 1, "the English sentence fits \(panel.frame.width - 2 * LauncherMetrics.fieldSide) pt at 18 pt")
        #expect(rig.launcher.listHeight == 0)
        try await expectUnclipped(.maximum)

        rig.fake.send(.stateChanged(IndexState(phase: .live, bootPhase: .live, indexed: 10)))
        try await rig.until("today's height after the index goes live") { panel.frame.height == today(.maximum) }
        try await expectUnclipped(.maximum)

        rig.fake.send(.stateChanged(IndexState(phase: .failed, bootPhase: .failed, indexed: 10)))
        try await rig.until("the failed launcher again") { panel.frame.height == failed(.maximum) }
        rig.store.set(TextSize.standard.rawValue, forKey: TextSize.key)
        try await rig.until("the failed launcher at 13 pt, \(lines(.standard)) sentence lines") { panel.frame.height == failed(.standard) }
        #expect(failed(.standard) > today(.standard))
        try await expectUnclipped(.standard)
        #expect(rig.fieldHasFocus)
    }

    @Test func aLoneSpaceListsNothing() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        for blank in [" ", "\u{3000}", " \t "] {
            rig.launcher.model.query = blank
            try await Task.sleep(for: .milliseconds(50))
            #expect(rig.fake.queries.isEmpty, "\(blank.unicodeScalars.map(\.value))")
            #expect(rig.launcher.listHeight == 0)
            #expect(rig.launcher.table?.numberOfRows == 0)
        }
    }

    @Test func aLoneSpaceShowsNoShowAllRow() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        let empty = try rig.panel().frame.height
        try rig.type("r")
        try await rig.until("the Show all row") { rig.showAllRow != nil }
        #expect(try rig.panel().frame.height > empty)
        rig.launcher.model.query = " "
        try await rig.until("the Show all row to go") { rig.showAllRow == nil }
        #expect(try rig.panel().frame.height == empty)
        #expect(rig.launcher.listHeight == 0)
        try rig.escape()
        try await rig.until("the first Escape to clear the space") { rig.launcher.model.query.isEmpty }
        #expect(rig.launcher.panel?.isVisible == true)
    }

    @Test func noResultsShowsOneRowWithTheWords() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("zz")
        try await rig.finish(0)
        #expect(rig.launcher.listHeight == LauncherMetrics.rowHeight(.standard) + LauncherMetrics.listTop + LauncherMetrics.listBottom)
        let content = try #require(try rig.panel().contentView)
        try await rig.until("the No results words") { AXTree.element(Launcher.emptyID, in: content) != nil }
        let words = try #require(AXTree.element(Launcher.emptyID, in: content))
        #expect(AXTree.names(of: words).contains(ResultsTable.countText(0)))
    }

    @Test func aFailedSearchShowsARow() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        rig.fake.fail(with: .io)
        try rig.type("zz")
        let oneRow = LauncherMetrics.rowHeight(.standard) + LauncherMetrics.listTop + LauncherMetrics.listBottom
        try await rig.until("one row for the failure") { rig.launcher.listHeight == oneRow }
        let content = try #require(try rig.panel().contentView)
        try await rig.until("the failure words") { AXTree.element(Launcher.failedID, in: content) != nil }
        let words = try #require(AXTree.element(Launcher.failedID, in: content))
        #expect(AXTree.names(of: words).contains("Search failed. Try again."))
        #expect(AXTree.element(Launcher.emptyID, in: content) == nil)
        #expect(rig.fake.queries.isEmpty, "the failed search made no generation")
    }

    @Test func theLauncherFollowsHideInvisibleFiles() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        rig.store.set(true, forKey: SearchFilters.hidesHiddenKey)
        try await rig.show()
        try await rig.until("the setting in the launcher's filters") { rig.launcher.model.filters.hidesHidden }
        try rig.type("r")
        #expect(rig.fake.queries == ["r hidden:no"])
        rig.store.set(false, forKey: SearchFilters.hidesHiddenKey)
        try await rig.until("the cleared setting in the launcher's filters") { !rig.launcher.model.filters.hidesHidden }
        #expect(rig.fake.queries == ["r hidden:no", "r"])
    }

    @Test func inNormalModeTheLauncherSearchesNamesOnly() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        rig.store.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
        try await rig.show()
        try rig.type("rep")
        #expect(rig.fake.queries == ["r", "re", "rep"])
        #expect(rig.fake.presses.isEmpty)
        #expect(rig.launcher.model.content == ContentTerms())
    }

    @Test func thePressDoesNothingWhileTheRecorderListens() {
        let rig = LauncherRig(isRecording: { true })
        defer { rig.close() }
        rig.launcher.toggle()
        #expect(rig.launcher.panel == nil)
    }

    @Test func aMainWindowKeepsItsSearchWhileTheLauncherSearches() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        let model = rig.index.makeModel()
        let host = SearchHost(index: rig.index, model: model)
        defer { host.close() }
        try await host.type("sa")
        let mains = mainWindowCount()
        try await rig.show()
        try rig.type("rep")
        #expect(rig.fake.session(rig.fake.lastSession)?.searches.map(\.query) == ["r", "re", "rep"])
        #expect(rig.launcher.model.query == "rep")
        #expect(model.query == "sa")
        #expect(host.field()?.stringValue == "sa")
        rig.launcher.toggle()
        #expect(model.query == "sa")
        #expect(mainWindowCount() == mains)
    }

    @Test func tabMovesBetweenTheFieldAndTheList() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        var tabs = 0
        while !rig.listHasFocus {
            try #require(tabs < 4, "four Tabs from the field never reached the list")
            try rig.tab()
            tabs += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        var backs = 0
        while !rig.fieldHasFocus {
            try #require(backs < 4, "four Shift-Tabs from the list never reached the field")
            try rig.tab(backward: true)
            backs += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try rig.panel().isVisible)
        #expect(rig.fieldText == "rep")
    }

    @Test func aDragFromTheLauncherIsACopy() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        let table = try #require(rig.launcher.table)
        let writer = try #require(table.dataSource?.tableView?(table, pasteboardWriterForRow: 1) as? NSURL)
        #expect(writer as URL == reports[1].fileURL)
        try #require(table.responds(to: NSSelectorFromString("draggingSourceOperationMaskForLocal:")))
        #expect(unsafeBitCast(table, to: (any LauncherDragMask).self).draggingSourceOperationMaskForLocal(false) == .copy)
        #expect(try rig.panel().isVisible)
        #expect(rig.recorder.nothingHappened)
    }

    @Test func theListDrawsNoBackgroundSoTheGlassShowsThrough() async throws {
        let rig = LauncherRig()
        defer { rig.close() }
        try await rig.show()
        try rig.type("rep")
        try await rig.finish(3)
        let table = try #require(rig.launcher.table as? ThemedTable)
        #expect(table.backgroundColor == .clear)
        #expect(table.stripe == .clear)
        #expect(table.enclosingScrollView?.drawsBackground == false)
        var painted: [NSColor] = []
        table.enumerateAvailableRowViews { view, _ in painted.append(view.backgroundColor) }
        #expect(!painted.isEmpty && painted.allSatisfy { $0 == .clear })
        #expect(table.headerView == nil)
        #expect(table.tableColumns.map(\.identifier.rawValue) == [ResultsTable.Column.name.rawValue, ResultsTable.Column.folder.rawValue])
        #expect(table.tableColumns.first?.width == SearchMetrics.nameColumnWidth)
        #expect(table.accessibilityIdentifier() == Launcher.listID)
        let content = try #require(try rig.panel().contentView)
        let background = try #require(content.subviews.first)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            #expect(String(describing: type(of: background)) == "NSGlassEffectView")
        } else {
            let blur = try #require(background as? NSVisualEffectView, "macOS 13 to 25 draw the frosted blur: \(type(of: background))")
            #expect(blur.material == .popover)
            #expect(blur.blendingMode == .behindWindow)
            #expect(blur.state == .active)
        }
        #expect(content.layer?.cornerRadius == LauncherMetrics.cornerRadius)
        #expect(content.layer?.masksToBounds == true)
    }
}
