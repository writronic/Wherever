import AppKit
import Carbon
import Foundation
import ServiceManagement
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private struct A11yRefused: Error {}

private final class A11yChooser {
    var shown = 0
}

private final class A11yOpened {
    var urls: [URL] = []
}

private func a11yDefaults(_ name: String) -> UserDefaults {
    let suite = "com.writronic.wherever.tests.a11ypanes.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func a11yString(_ key: String, _ table: String, _ language: String = "de") throws -> String {
    let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
    let text = bundle.localizedString(forKey: key, value: "\u{1}", table: table)
    try #require(text != "\u{1}" && !text.isEmpty, "\(table) holds no \(key) in \(language)")
    return text
}

private func a11yDescendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + a11yDescendants(of: $0) }
}

private final class A11yHost {
    let window: KeyedWindow
    let view: NSView

    init(_ content: some View, language: String = "de", size: NSSize = NSSize(width: SettingsWindow.Metrics.detailWidth, height: SettingsWindow.Metrics.size.height)) {
        let controller = NSHostingController(rootView: AnyView(content.environment(\.locale, Locale(identifier: language))))
        window = KeyedWindow(contentViewController: controller)
        view = controller.view
        window.setContentSize(size)
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

    func until(
        _ description: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        try await untilTrue(waitingFor: description(), sourceLocation: sourceLocation) {
            view.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    func control(_ name: String) async throws -> NSObject {
        try await until("a control named \(name) among \(AXTree.nodeCount(in: view)) accessibility nodes") { AXTree.control(name, in: view) != nil }
        return try #require(AXTree.control(name, in: view))
    }

    func element(_ id: String) async throws -> NSObject {
        try await until("the \(id) element") { AXTree.element(id, in: view) != nil }
        return try #require(AXTree.element(id, in: view))
    }
}

private struct A11yFilterHarness: View {
    @State var filters: SearchFilters

    var body: some View {
        FilterBar(filters: $filters, bundle: Bundle.main.url(forResource: "de", withExtension: "lproj").flatMap(Bundle.init(url:)) ?? .main)
    }
}

private func a11yFilterBar() -> A11yHost {
    A11yHost(A11yFilterHarness(filters: SearchFilters()), size: NSSize(width: 900, height: 120))
}

private func a11yAccess() -> AccessModel {
    AccessModel(
        defaults: a11yDefaults("access"), center: NotificationCenter(), stage: .waiting, probe: { .denied }, confirm: { false }, start: {}, summon: {},
        open: { _ in true }, quit: {}, activate: {}
    )
}

private func a11yHotkey(_ name: String) -> HotkeyModel {
    HotkeyModel(defaults: a11yDefaults(name), windows: { [] }, unhide: {}, activate: {})
}

@Suite(.serialized) struct AccessibilityPanesTests {
    @Test func locationsRowsRenderNamesPathsAndIconsInEveryAppearance() async throws {
        let share = URL(fileURLWithPath: "/Volumes/My Shared Files/results", isDirectory: true)
        let output = FileManager.default.fileExists(atPath: share.path) ? share
            : FileManager.default.temporaryDirectory.appendingPathComponent("wherever-locationstyle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/Library/Caches"
        let variants: [(String, ColorScheme, ColorSchemeContrast, Bool)] = [
            ("light", .light, .standard, false), ("dark", .dark, .standard, false),
            ("contrast", .dark, .increased, false), ("arabic", .light, .standard, true)
        ]
        for (name, scheme, contrast, rtl) in variants {
            let defaults = a11yDefaults("locations.\(name)")
            let fake = FakeSearchClient()
            fake.setVolumes(.success([IndexedVolume(id: "disk", name: "Disk 2", path: "/Volumes/Disk 2", indexed: false)]))
            let model = LocationsModel(client: fake, defaults: defaults, chooseFolder: { nil })
            let host = A11yHost(
                LocationsPane(model: model).environment(\.colorScheme, scheme)
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight),
                language: rtl ? "ar" : "en",
                size: NSSize(width: rtl ? SettingsWindow.Metrics.minSize.width - SettingsWindow.Metrics.sidebarWidth : SettingsWindow.Metrics.detailWidth, height: 900)
            )
            defer { host.close() }
            host.window.appearance = NSAppearance(named: contrast == .increased ? .accessibilityHighContrastDarkAqua : (scheme == .dark ? .darkAqua : .aqua))
            try await host.until("ten complete rows in \(name)") {
                a11yDescendants(of: host.view).compactMap { $0 as? NSTableView }.contains { $0.numberOfRows == 10 }
            }
            let table = try #require(a11yDescendants(of: host.view).compactMap { $0 as? NSTableView }.first { $0.numberOfRows == 10 })
            let cases = [(0, "/Volumes/Disk 2", "Disk 2", "/Volumes/Disk 2"), (3, path, "Caches", "~/Library/Caches")]
            for (index, rawPath, title, displayedPath) in cases {
                let cell = try #require(table.view(atColumn: 0, row: index, makeIfNecessary: true))
                let element: (String) -> NSObject? = { id in
                    ([cell] + a11yDescendants(of: cell)).compactMap { AXTree.element(id, in: $0) }.first
                }
                try await host.until("the icon, name and path for \(rawPath)") {
                    element("locations-icon-\(rawPath)") != nil
                        && element("locations-name-\(rawPath)") != nil && element("locations-path-\(rawPath)") != nil
                }
                let titleNode = try #require(element("locations-name-\(rawPath)"))
                let pathNode = try #require(element("locations-path-\(rawPath)"))
                #expect(AXTree.names(of: titleNode).contains(title))
                #expect(AXTree.names(of: pathNode).contains(displayedPath))
                let titleFrame = try #require(AXTree.frame(of: titleNode))
                let pathFrame = try #require(AXTree.frame(of: pathNode))
                #expect(titleFrame.minY >= pathFrame.maxY)
                #expect(rtl ? titleFrame.maxX == pathFrame.maxX : titleFrame.minX == pathFrame.minX)
                let icon = try #require(element("locations-icon-\(rawPath)").flatMap(AXTree.frame))
                let scale = host.window.backingScaleFactor
                let gap = rtl ? icon.minX - titleFrame.maxX : titleFrame.minX - icon.maxX
                #expect((gap - LocationsPane.Metrics.iconSpacing) * scale == 0)
                #expect((icon.width - LocationsPane.Metrics.iconSize) * scale == 0)
                #expect((icon.height - LocationsPane.Metrics.iconSize) * scale == 0)
                let localIcon = host.view.convert(host.window.convertFromScreen(icon), from: nil)
                let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: localIcon))
                host.view.cacheDisplay(in: localIcon, to: bitmap)
                var colors = Set<[Int]>()
                for y in stride(from: 2, to: bitmap.pixelsHigh - 2, by: 2) {
                    for x in stride(from: 2, to: bitmap.pixelsWide - 2, by: 2) {
                        if let pixel = srgbPixel(bitmap, x: x, y: y) { colors.insert(pixel) }
                    }
                }
                #expect(colors.count > 8, "\(rawPath) must draw its workspace icon, not empty padding")
            }
            let plus = try await host.control(try a11yString("Add excluded path", "Settings", rtl ? "ar" : "en"))
            let minus = try await host.control(try a11yString("Remove excluded path", "Settings", rtl ? "ar" : "en"))
            let plusFrame = try #require(AXTree.frame(of: plus))
            let minusFrame = try #require(AXTree.frame(of: minus))
            #expect(plusFrame.midY == minusFrame.midY)
            #expect(rtl ? plusFrame.minX >= minusFrame.maxX : plusFrame.maxX <= minusFrame.minX)
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let file = output.appendingPathComponent("locationstyle-\(name).png")
            try png.write(to: file)
            print("locationstyle PNG: \(file.path)")
            #expect(model.excluded.contains(path) && !model.excluded.contains("~/Library/Caches"))
        }
    }

    @Test func a1EverySettingsControlReadsItsLabelFromItsTable() async throws {
        let general = A11yHost(GeneralPane(launchAtLogin: .inert(), hotkey: a11yHotkey("a1.hotkey")))
        defer { general.close() }
        _ = try await general.control(try a11yString("Open at Login", "Settings"))
        _ = try await general.control(try a11yString("Show Menu Bar Icon", "Settings"))
        _ = try await general.control(try a11yString("Show inspector", "Inspector"))
        _ = try await general.control(try a11yString("Clear Open History…", "Settings"))
        _ = try await general.control(try a11yString("Launcher shortcut", "Hotkey"))
        _ = try await general.control(try a11yString("Typo-Tolerant Search", "Settings"))
        _ = try await general.control(try a11yString("Automatically check for updates", "Settings"))
        let picker = try await general.element(ThemePicker.id)
        let theme = try a11yString("Color theme", "Theme")
        #expect(AXTree.names(of: picker).contains(theme), "the theme picker reads \(AXTree.names(of: picker))")
        #expect(AXTree.value("accessibilityRole", of: picker) == NSAccessibility.Role.radioGroup.rawValue)
        let language = try await general.element(LanguageRow.id)
        let languageLabel = try a11yString("Language", "Settings")
        #expect(AXTree.names(of: language).contains(languageLabel), "the language pop-up reads \(AXTree.names(of: language))")
        let appearance = try await general.element(AppearanceRow.id)
        let appearanceLabel = try a11yString("Appearance", "Settings")
        #expect(AXTree.names(of: appearance).contains(appearanceLabel), "the appearance picker reads \(AXTree.names(of: appearance))")
        let opacity = try await general.element(LauncherOpacityRow.id)
        let opacityLabel = try a11yString("Wherever search background opacity", "Settings")
        #expect(AXTree.names(of: opacity).contains(opacityLabel), "the opacity slider reads \(AXTree.names(of: opacity))")
        for key in ["System", "Light", "Dark"] {
            let word = try a11yString(key, "Settings")
            try await general.until("the \(word) segment") {
                AXTree.element(AppearanceRow.id, in: general.view).map { AXTree.elements(in: $0).dropFirst().contains { AXTree.names(of: $0).contains(word) } } == true
            }
        }

        let locations = LocationsModel(client: FakeSearchClient(), defaults: a11yDefaults("a1.locations"), chooseFolder: { nil })
        let pane = A11yHost(LocationsPane(model: locations))
        defer { pane.close() }
        _ = try await pane.control(try a11yString("Add excluded path", "Settings"))
        _ = try await pane.control(try a11yString("Remove excluded path", "Settings"))

        let about = A11yHost(AboutPane(open: { _ in Issue.record("a1 opened a URL") }), language: "tr")
        defer { about.close() }
        _ = try await about.control(try a11yString("Donate", "Settings", "tr"))
        _ = try await about.control(try a11yString("Visit Website", "Settings", "tr"))
        let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let lines = [
            String(format: try a11yString("Version %@", "Settings", "tr"), version), try a11yString("Wherever it is, find it.", "Welcome", "tr"),
            try a11yString("Made with ❤️", "Settings", "tr"), try a11yString("Copyright © 2026 Writronic. All rights reserved.", "Settings", "tr"),
        ]
        let shown = { AXTree.elements(in: about.view).flatMap { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { AXTree.value($0, of: element) as String? }
        } }
        try await about.until("the Turkish About lines among \(shown())") { lines.allSatisfy(shown().contains) }
        #expect(!shown().contains("Mac’inizdeki her dosyayı anında bulun."), "the old Turkish line still shows")
    }

    @Test func a1EveryFilterControlReadsItsLabelFromTheFiltersTable() async throws {
        let host = a11yFilterBar()
        defer { host.close() }
        let labels = [
            FilterBar.extensionsID: "Extension", FilterBar.kindID: "Kind", FilterBar.sizeID: "Size", FilterBar.modifiedID: "Modified",
            FilterBar.hiddenID: "Hide invisible files",
        ]
        for (id, key) in labels {
            let expected = try a11yString(key, "Filters")
            let names = AXTree.names(of: try await host.element(id))
            #expect(names.contains(expected), "\(id) reads \(names), not \(expected)")
        }
    }

    @Test func a1TheWelcomeWindowReadsTheWelcomeTableAndHidesItsImages() async throws {
        let bundle = try #require(Bundle.main.url(forResource: "de", withExtension: "lproj").flatMap(Bundle.init(url:)))
        let welcome = WelcomeWindowController(model: a11yAccess(), bundle: bundle)
        welcome.show()
        let window = try #require(welcome.window)
        defer { window.close() }
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "the welcome's buttons") {
            a11yDescendants(of: content).contains { $0 is NSButton && !$0.isHiddenOrHasHiddenAncestor }
        }
        let title = try a11yString("Welcome to Wherever", "Welcome")
        #expect(window.title == title)
        let titles = try ["Back", "Open System Settings"].map { try a11yString($0, "Welcome") }
        let buttons = a11yDescendants(of: content).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        let dots = buttons.compactMap { $0 as? WelcomeStepDot }
        let others = buttons.filter { !($0 is WelcomeStepDot) }
        #expect(others.map(\.title).sorted() == titles.sorted(), "visible buttons \(buttons.map(\.title))")
        for button in others {
            #expect(AXTree.names(of: button).contains(button.title), "\(button.title) reads \(AXTree.names(of: button))")
        }
        #expect(dots.count == 4, "visible step dots \(dots.count)")
        for (index, dot) in dots.enumerated() {
            let label = try String(format: a11yString("Step %lld of %lld", "Welcome"), index + 1, 4)
            #expect(AXTree.names(of: dot).contains(label), "dot \(index + 1) reads \(AXTree.names(of: dot)), not \(label)")
        }
        let images = a11yDescendants(of: content).compactMap { $0 as? NSImageView }.filter { !$0.isHiddenOrHasHiddenAncestor }
        #expect(images.count == 1)
        #expect(images.allSatisfy { !$0.isAccessibilityElement() })
    }
}

private func a11yIsProxy(_ view: NSView) -> Bool { String(describing: type(of: view)) == "KeyViewProxy" }

private func a11yKeyViewLoop(in window: NSWindow) -> [NSView] {
    guard let content = window.contentView, let start = ([content] + a11yDescendants(of: content)).first(where: { $0.nextKeyView != nil }) else {
        return []
    }
    var loop: [NSView] = [start]
    while let next = loop.last?.nextKeyView, next !== start, !loop.contains(where: { $0 === next }) { loop.append(next) }
    return loop
}

private func a11yType(_ object: Any?) -> String {
    object.map { String(String(describing: type(of: $0)).prefix { $0 != "<" }) } ?? "nil"
}

private func a11yReach(_ name: String, in pane: NSView, window: NSWindow) async -> (node: NSObject?, report: String) {
    window.recalculateKeyViewLoop()
    let loop = a11yKeyViewLoop(in: window)
    let stops = loop.filter { $0.isDescendant(of: pane) || a11yIsProxy($0) }
    var lines: [String] = []
    var node: NSObject?
    for stop in stops {
        let took = window.makeFirstResponder(stop)
        pane.layoutSubtreeIfNeeded()
        let responder = window.firstResponder
        let resolved = AXTree.focusedElement(of: NSApp)
        let named = AXTree.elements(in: pane).filter { AXTree.names(of: $0).contains(name) }
        let focused = named.filter { (AXTree.value("isAccessibilityFocused", of: $0) as Bool?) == true }
        let frame = (responder as? NSView).map { NSStringFromRect(window.convertToScreen($0.convert($0.bounds, to: nil))) } ?? "not a view"
        let nodes = named.map { "\(a11yType($0)) \(AXTree.frame(of: $0).map(NSStringFromRect) ?? "no frame") focused \(focused.contains($0))" }
        lines.append(
            "\(a11yType(stop)): took \(took); responder \(a11yType(responder)) \(frame); the app resolves \(a11yType(resolved)) "
                + "\(resolved.map(AXTree.names(of:)) ?? []); the pane resolves \(a11yType(AXTree.focusedElement(of: pane))); named \(nodes)"
        )
        if took { node = focused.first ?? resolved.flatMap { AXTree.names(of: $0).contains(name) ? $0 : nil } }
        if node != nil { break }
    }
    var tabs = 0
    if node == nil {
        window.makeFirstResponder(nil)
        while node == nil, tabs < 2 * loop.count, let tab = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ) {
            window.sendEvent(tab)
            tabs += 1
            try? await Task.sleep(for: .milliseconds(100))
            let resolved = AXTree.focusedElement(of: NSApp)
            lines.append("Tab \(tabs): responder \(a11yType(window.firstResponder)); the app resolves \(a11yType(resolved)) \(resolved.map(AXTree.names(of:)) ?? [])")
            node = resolved.flatMap { AXTree.names(of: $0).contains(name) ? $0 : nil }
        }
    }
    return (node, "\(stops.count) of \(loop.count) key views and \(tabs) Tab presses tried:\n" + lines.joined(separator: "\n"))
}

private struct A11yButtonPair: View {
    static let names = ["a11y pair add", "a11y pair remove"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.names, id: \.self) { name in
                Button {} label: { Image(systemName: "plus").frame(width: 28, height: 24).contentShape(Rectangle()) }.accessibilityLabel(name)
            }
        }
        .buttonStyle(.plain)
    }
}

private func a10RequireKeyboardFocusOnSideBySideButtons() async throws {
    let host = A11yHost(A11yButtonPair(), size: NSSize(width: 120, height: 40))
    defer { host.close() }
    for name in A11yButtonPair.names {
        _ = try await host.control(name)
        if await a11yReach(name, in: host.view, window: host.window).node == nil {
            try Test.cancel(
                "Keyboard focus reaches no key view on \(name), one of two side-by-side plain SwiftUI buttons, so this Mac cannot focus such a button: macOS 14 does it only with Full Keyboard Access on, and scripts/vm-tests.sh runs this test so"
            )
        }
    }
}

enum FocusRingSign {
    case ringView
    case pixelsOutsideTheControl
}

private struct A11yRingReference: View {
    static let id = "a11y-ring-reference"
    @State var on = false

    var body: some View {
        Toggle("a11y ring reference", isOn: $on).toggleStyle(.checkbox).accessibilityIdentifier(Self.id).padding(20)
    }
}

private func a11yScreenFrame(_ view: NSView, in window: NSWindow) -> NSRect { window.convertToScreen(view.convert(view.bounds, to: nil)) }

private func a11yRingViews(over centre: NSPoint, in root: NSView, window: NSWindow) -> [NSRect] {
    a11yDescendants(of: root).filter { String(describing: type(of: $0)) == "_FocusRingView" }.map { a11yScreenFrame($0, in: window) }
        .filter { $0.contains(centre) }
}

private func a11yBand(around frame: NSRect, in window: NSWindow) -> [UInt32] {
    typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
        let image = unsafeBitCast(symbol, to: Create.self)(
            .null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber),
            CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        )?.takeRetainedValue()
    else { return [] }
    let rep = NSBitmapImageRep(cgImage: image)
    let scale = CGFloat(rep.pixelsWide) / window.frame.width
    let outer = frame.insetBy(dx: -4, dy: -4)
    let inner = frame.insetBy(dx: -1, dy: -1)
    var band: [UInt32] = []
    for row in Int((window.frame.maxY - outer.maxY) * scale)..<Int((window.frame.maxY - outer.minY) * scale) {
        for column in Int((outer.minX - window.frame.minX) * scale)..<Int((outer.maxX - window.frame.minX) * scale) {
            let point = NSPoint(x: window.frame.minX + (CGFloat(column) + 0.5) / scale, y: window.frame.maxY - (CGFloat(row) + 0.5) / scale)
            guard !inner.contains(point), let colour = rep.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { continue }
            band.append(UInt32(colour.redComponent * 255) << 16 | UInt32(colour.greenComponent * 255) << 8 | UInt32(colour.blueComponent * 255))
        }
    }
    return band
}

private func a11yTabUntilFocused(_ id: String, in root: NSView, window: NSWindow) async -> Bool {
    window.recalculateKeyViewLoop()
    window.makeFirstResponder(nil)
    for _ in 0..<(2 * a11yKeyViewLoop(in: window).count + 2) {
        guard let tab = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ) else { return false }
        window.sendEvent(tab)
        try? await Task.sleep(for: .milliseconds(100))
        if AXTree.focusedElement(of: NSApp).flatMap(AXTree.identifier(of:)) == id { return true }
    }
    return false
}

func focusRingShown(_ sign: FocusRingSign, on id: String, in root: NSView, window: NSWindow) async throws -> (shown: Bool, report: String) {
    root.layoutSubtreeIfNeeded()
    let element = try #require(AXTree.element(id, in: root), "no element \(id)")
    let frame = try #require(AXTree.frame(of: element), "\(id) has no frame")
    switch sign {
    case .ringView:
        let rings = a11yRingViews(over: NSPoint(x: frame.midX, y: frame.midY), in: root, window: window)
        return (!rings.isEmpty, "\(rings.count) _FocusRingView over the centre of \(frame)")
    case .pixelsOutsideTheControl:
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(300))
        let before = a11yBand(around: frame, in: window)
        guard await a11yTabUntilFocused(id, in: root, window: window) else { return (false, "Tab never put keyboard focus on \(id)") }
        try await Task.sleep(for: .milliseconds(300))
        let after = a11yBand(around: frame, in: window)
        try #require(!before.isEmpty && before.count == after.count, "captured \(before.count) and \(after.count) pixels around \(frame)")
        let changed = zip(before, after).filter { $0 != $1 }.count
        return (changed > 0, "\(changed) of \(before.count) pixels 1 to 4 pt outside \(frame) changed when \(id) took keyboard focus")
    }
}

func requireFocusRingSign() async throws -> FocusRingSign {
    let host = A11yHost(A11yRingReference(), size: NSSize(width: 300, height: 80))
    defer { host.close() }
    _ = try await host.element(A11yRingReference.id)
    try await Task.sleep(for: .milliseconds(300))
    for sign in [FocusRingSign.ringView, .pixelsOutsideTheControl] {
        if try await focusRingShown(sign, on: A11yRingReference.id, in: host.view, window: host.window).shown { return sign }
    }
    try Test.cancel(
        "A plain SwiftUI checkbox shows no focus ring this test can see: no _FocusRingView, and Tab puts no focus on it or draws nothing around it. macOS 14 draws that ring only with Full Keyboard Access on, and scripts/vm-tests.sh runs this test so"
    )
}

private func a10SettingsInAKeyedWindow(_ tag: String, opened: A11yOpened) throws -> (SettingsWindow, KeyedWindow, NSSplitViewController) {
    let client = FakeSearchClient()
    let settings = SettingsWindow(
        launchAtLogin: .inert(),
        locations: LocationsModel(client: client, defaults: a11yDefaults("\(tag).locations"), chooseFolder: { nil }),
        hotkey: a11yHotkey("\(tag).hotkey"), client: client, defaults: a11yDefaults("\(tag).store"), open: { opened.urls.append($0) }, activate: {}
    )
    settings.show()
    settings.close()
    let original = try #require(settings.window)
    #expect(original.autorecalculatesKeyViewLoop)
    let split = settings.split
    original.contentViewController = nil
    let window = KeyedWindow(contentViewController: split)
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    if !window.isKeyWindow {
        window.reportsKey = true
        window.becomeKey()
    }
    return (settings, window, split)
}

extension AccessibilityPanesTests {
    @Test func a10EveryPanesKeyViewLoopReachesThatPanesFirstControl() async throws {
        let opened = A11yOpened()
        let (settings, window, split) = try a10SettingsInAKeyedWindow("a10", opened: opened)
        defer {
            window.contentViewController = nil
            window.close()
        }
        let sidebar = split.splitViewItems[0].viewController.view
        let detail = split.splitViewItems[1].viewController.view
        let firsts: [(SettingsPane, String, String)] = [
            (.general, "Open at Login", "Settings"), (.locations, "When a disk that isn’t indexed is connected", "Settings"),
            (.about, "Donate", "Settings"),
        ]
        for (pane, key, table) in firsts {
            settings.selection.pane = pane
            let name = Bundle.main.localizedString(forKey: key, value: nil, table: table)
            try await untilTrue(waitingFor: "\(name) in \(pane)") {
                detail.layoutSubtreeIfNeeded()
                return AXTree.control(name, in: detail) != nil
            }
            let (node, report) = await a11yReach(name, in: detail, window: window)
            #expect(node != nil, "\(pane): no stop left VoiceOver on \(name); \(report)")
            let loop = a11yKeyViewLoop(in: window)
            #expect(loop.contains { $0 is NSTableView && $0.isDescendant(of: sidebar) }, "\(pane): the loop misses the sidebar")
            #expect(loop.contains { $0.isDescendant(of: detail) || a11yIsProxy($0) }, "\(pane): the loop has no stop in the pane")
        }
        #expect(opened.urls.isEmpty, "the focus walk opened \(opened.urls)")
    }

    @Test func a10TheSettingsFileCardsPutImportBeforeExportInTheKeyViewLoop() async throws {
        let opened = A11yOpened()
        let (settings, window, split) = try a10SettingsInAKeyedWindow("a10.cards", opened: opened)
        defer {
            window.contentViewController = nil
            window.close()
        }
        let detail = split.splitViewItems[1].viewController.view
        settings.selection.pane = .general
        try await untilTrue(waitingFor: "the import and export buttons") {
            detail.layoutSubtreeIfNeeded()
            return AXTree.element("general-import", in: detail) != nil && AXTree.element("general-export", in: detail) != nil
        }
        var reached: [String: Int] = [:]
        var reports: [String] = []
        for (id, key) in [("general-import", "Import Settings…"), ("general-export", "Export Settings…")] {
            let name = Bundle.main.localizedString(forKey: key, value: nil, table: "Settings")
            let (node, report) = await a11yReach(name, in: detail, window: window)
            reports.append("\(id): \(report)")
            if let node, AXTree.identifier(of: node) == id || AXTree.names(of: node).contains(name) { reached[id] = report.split(separator: "\n").count - 1 }
        }
        let importStop = try #require(reached["general-import"], "no stop left VoiceOver on Import Settings…; \(reports.joined(separator: "\n"))")
        let exportStop = try #require(reached["general-export"], "no stop left VoiceOver on Export Settings…; \(reports.joined(separator: "\n"))")
        #expect(importStop < exportStop, "Import at stop \(importStop), Export at stop \(exportStop); \(reports.joined(separator: "\n"))")
        #expect(opened.urls.isEmpty, "the focus walk opened \(opened.urls)")
    }

    @Test func a10TheCommandLineToolButtonLeavesVoiceOverOnInstall() async throws {
        let opened = A11yOpened()
        let (settings, window, split) = try a10SettingsInAKeyedWindow("a10.commandline", opened: opened)
        defer {
            window.contentViewController = nil
            window.close()
        }
        let detail = split.splitViewItems[1].viewController.view
        settings.selection.pane = .general
        let name = Bundle.main.localizedString(forKey: "Install", value: nil, table: "Settings")
        try await untilTrue(waitingFor: "the \(name) button") {
            detail.layoutSubtreeIfNeeded()
            return AXTree.element(CommandLineToolRow.id, in: detail) != nil
        }
        let (node, report) = await a11yReach(name, in: detail, window: window)
        let reached = try #require(node, "no stop left VoiceOver on \(name); \(report)")
        #expect(AXTree.identifier(of: reached) == CommandLineToolRow.id || AXTree.names(of: reached).contains(name), "\(report)")
        #expect(opened.urls.isEmpty, "the focus walk opened \(opened.urls)")
    }

    @Test func a10VoiceOverReachesTheModeRadiosAndTheToolBeforeNext() async throws {
        let access = AccessModel(
            defaults: a11yDefaults("a10.welcome"), center: NotificationCenter(), stage: .granted, probe: { .granted }, confirm: { true },
            start: {}, summon: {}, open: { _ in true }, quit: {}, activate: {}
        )
        let bundle = try #require(Bundle.main.url(forResource: "de", withExtension: "lproj").flatMap(Bundle.init(url:)))
        let welcome = WelcomeWindowController(model: access, bundle: bundle)
        welcome.show()
        let window = try #require(welcome.window)
        defer { window.close() }
        let content = try #require(window.contentView)
        let action = try #require(a11yDescendants(of: content).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "welcome-action" })
        action.performClick(nil)
        #expect(welcome.page == .modes)
        let simple = try a11yString("Simple", "Localizable")
        let normal = try a11yString("Normal", "Localizable")
        let install = try a11yString("Install", "Settings")
        let go = try a11yString("Next", "Welcome")
        let caption = try a11yString("Search from the command line with the wherever command.", "Settings")
        let elements = AXTree.elements(in: content)
        let report = elements.map { "\(a11yType($0)) \(AXTree.names(of: $0))" }.joined(separator: "\n")
        let first = try #require(elements.firstIndex { AXTree.names(of: $0).contains(simple) }, "no element reads \(simple):\n\(report)")
        let second = try #require(elements.firstIndex { AXTree.names(of: $0).contains(normal) }, "no element reads \(normal):\n\(report)")
        let tool = try #require(elements.firstIndex { AXTree.names(of: $0).contains(install) }, "no element reads \(install):\n\(report)")
        let button = try #require(elements.firstIndex { AXTree.names(of: $0).contains(go) }, "no element reads \(go):\n\(report)")
        #expect(first < second && second < tool && tool < button, "\(report)")
        for radio in [first, second] {
            #expect((AXTree.value("accessibilityRole", of: elements[radio]) as String?) == NSAccessibility.Role.radioButton.rawValue)
        }
        #expect((AXTree.value("accessibilityHelp", of: elements[tool]) as String?) == caption)
        #expect(!elements.contains { AXTree.names(of: $0).contains(caption) }, "\(report)")
        #expect(!elements.contains { (AXTree.value("accessibilityRole", of: $0) as String?) == NSAccessibility.Role.image.rawValue }, "\(report)")
    }

    @Test func a10BothExcludedFolderButtonsLeaveVoiceOverOnTheirNames() async throws {
        let defaults = a11yDefaults("a10.buttons")
        defaults.set(["/Users/a11y/Old"], forKey: LocationsModel.Key.excluded)
        let model = LocationsModel(client: FakeSearchClient(), defaults: defaults, chooseFolder: { nil })
        model.selection = .folder("/Users/a11y/Old")
        try await a10RequireKeyboardFocusOnSideBySideButtons()
        let host = A11yHost(LocationsPane(model: model))
        defer { host.close() }
        for key in ["Add excluded path", "Remove excluded path"] {
            let name = try a11yString(key, "Settings")
            try await host.until("\(name) enabled") { AXTree.control(name, in: host.view).flatMap(AXTree.isEnabled) == true }
            let (node, report) = await a11yReach(name, in: host.view, window: host.window)
            #expect(node != nil, "no stop left VoiceOver on \(name); \(report)")
        }
    }

    @Test func a10PressingTheFocusedPlusButtonOpensTheChooser() async throws {
        let chooser = A11yChooser()
        let model = LocationsModel(client: FakeSearchClient(), defaults: a11yDefaults("a10.press"), chooseFolder: { chooser.shown += 1; return nil })
        try await a10RequireKeyboardFocusOnSideBySideButtons()
        let host = A11yHost(LocationsPane(model: model))
        defer { host.close() }
        let name = try a11yString("Add excluded path", "Settings")
        _ = try await host.control(name)
        let (node, report) = await a11yReach(name, in: host.view, window: host.window)
        let focused = try #require(node, "no stop left VoiceOver on \(name); \(report)")
        try #require(AXTree.press(focused), "\(a11yType(focused)) took no press")
        try await host.until("the chooser after the press on \(a11yType(focused))") { chooser.shown > 0 }
        #expect(chooser.shown == 1)
    }

    @Test func a11NoFilterControlHidesItsFocusRing() async throws {
        let host = a11yFilterBar()
        defer { host.close() }
        for id in [FilterBar.extensionsID, FilterBar.kindID, FilterBar.sizeID, FilterBar.modifiedID] {
            try await host.until("the \(id) pill") { Self.pill(id, in: host.view) != nil }
            let pill = try #require(Self.pill(id, in: host.view))
            #expect(pill.focusRingType != .none, "\(id) hides its ring")
        }
        _ = try await host.element(FilterBar.hiddenID)
        let sign = try await requireFocusRingSign()
        let (shown, report) = try await focusRingShown(sign, on: FilterBar.hiddenID, in: host.view, window: host.window)
        #expect(shown, "\(FilterBar.hiddenID) has no focus ring over it: \(report)")
    }

    private static func pill(_ id: String, in root: NSView) -> NSButton? {
        a11yDescendants(of: root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }
    }
}

private final class A11yFill: NSView {
    let colour: NSColor

    init(_ colour: NSColor) {
        self.colour = colour
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        colour.setFill()
        bounds.fill()
    }
}

private func a11yPixel(_ view: NSView) -> [Int] {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
    view.cacheDisplay(in: view.bounds, to: rep)
    return srgbPixel(rep, x: 2, y: 2) ?? []
}

extension AccessibilityPanesTests {
    @Test func a14NoTextInTheWelcomeSettingsOrFilterBarIsUnderTenPoints() async throws {
        let welcome = WelcomeWindowController(model: a11yAccess(), bundle: .main)
        welcome.show()
        let window = try #require(welcome.window)
        defer { window.close() }
        let content = try #require(window.contentView)
        let fonts = a11yDescendants(of: content).compactMap { ($0 as? NSControl)?.font }
        #expect(!fonts.isEmpty)
        for font in fonts { #expect(font.pointSize >= 10, "\(font.fontName) is \(font.pointSize) pt") }
        #expect(NSFont.preferredFont(forTextStyle: .caption1).pointSize >= 10)
        #expect(NSFont.systemFontSize(for: .small) >= 10)
    }

    @Test func a15IncreaseContrastSwitchesTheThemesToTheirContrastColours() {
        let view = A11yFill(Theme.inkAndGlass.windowBackground)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        for (look, hex) in [(Look.dark, UInt32(0x0B0B24)), (Look.darkContrast, UInt32(0x05051A))] {
            window.appearance = look.appearance
            let drawn = a11yPixel(view)
            #expect(drawn.count == 3 && zip(drawn, eightBits(hex: hex)).allSatisfy { abs($0 - $1) <= 1 }, "the Ink and Glass window in \(look); drew \(drawn)")
        }
        for theme in Theme.allCases {
            for (normal, contrast) in [(Look.light, Look.lightContrast), (Look.dark, Look.darkContrast)] {
                #expect(channels(theme.secondaryText, contrast) != channels(theme.secondaryText, normal), "\(theme) secondary \(contrast)")
                #expect(channels(theme.matchText, contrast) != channels(theme.matchText, normal), "\(theme) match \(contrast)")
            }
        }
    }

    @Test func a16EveryThemeSurfaceIsOpaqueInEveryAppearance() {
        for theme in [Theme.inkAndGlass, .warmPaper, .midnightTeal] {
            let surfaces = [("window", theme.windowBackground), ("row", theme.rowBackground), ("stripe", theme.stripeBackground)]
            for (name, surface) in surfaces {
                for look in Look.allCases { #expect(channels(surface, look)[3] == 1, "\(theme) \(name) \(look)") }
            }
        }
    }

    @Test func theLoginStringsUseApplesNamesInEveryLanguage() throws {
        let names = [
            ("en", "Open at Login", "Login Items"),
            ("tr", "Oturum Açıldığında Aç", "Oturum Açma Öğeleri"),
            ("de", "Bei der Anmeldung öffnen", "Anmeldeobjekte"),
            ("fr", "Ouvrir avec la session", "Ouverture"),
            ("es", "Abrir al iniciar sesión", "Ítems de inicio"),
            ("ru", "Открывать при\u{00A0}входе", "Объекты входа"),
            ("nl", "Open bij inloggen", "Inlogonderdelen"),
            ("ja", "ログイン時に開く", "ログイン項目"),
            ("zh-Hans", "登录时打开", "登录项"),
            ("ar", "فتح عند الدخول", "عناصر الدخول"),
            ("pl", "Otwieraj podczas logowania", "Rzeczy otwierane podczas logowania"),
        ]
        for (language, label, loginItems) in names {
            #expect(try a11yString("Open at Login", "Settings", language) == label, "\(language)")
            for key in ["Open Login Items", "Wherever could not change this. Check Login Items in System Settings.",
                        "Allow Wherever in Login Items in System Settings."] {
                #expect(try a11yString(key, "Settings", language).localizedCaseInsensitiveContains(loginItems), "\(language): \(key)")
            }
        }
    }

    @Test func theShortcutRowIsCalledLauncherShortcutInEveryLanguage() throws {
        let names = [
            ("en", "Launcher shortcut"), ("tr", "Başlatıcı kestirmesi"), ("de", "Launcher-Kurzbefehl"), ("fr", "Raccourci du lanceur"),
            ("es", "Atajo del lanzador"), ("ru", "Сочетание клавиш панели поиска"), ("nl", "Launcher-toetscombinatie"), ("ja", "ランチャーのショートカット"),
            ("zh-Hans", "启动器快捷键"), ("ar", "اختصار المشغّل"), ("pl", "Skrót launchera"),
        ]
        for (language, label) in names {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            for table in ["Settings", "Hotkey"] {
                #expect(try a11yString("Launcher shortcut", table, language) == label, "\(table) in \(language)")
                for old in ["Keyboard shortcut", "Summon shortcut"] {
                    #expect(bundle.localizedString(forKey: old, value: "\u{1}", table: table) == "\u{1}", "\(table) in \(language) keeps \(old)")
                }
            }
            #expect(bundle.localizedString(forKey: "Launcher shortcut", value: "\u{1}", table: "Welcome") == label, "Welcome in \(language)")
            #expect(bundle.localizedString(forKey: "Launcher", value: "\u{1}", table: "Welcome") == "\u{1}", "Welcome in \(language) keeps Launcher")
        }
    }

    @Test func theExcludedPathsFooterNamesTheChosenFolderExceptionInEveryLanguage() throws {
        let footer = "Wherever skips these paths and everything inside them. Search Content still reads one, or a folder inside it, when you choose it as the Search folder."
        let stale = "Wherever skips these paths and everything inside them, in file names and in Search Content."
        for language in ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"] {
            let text = try a11yString(footer, "Settings", language)
            let content = try a11yString("Search Content", "Normal", language)
            let folder = try a11yString("Search folder:", "Normal", language).trimmingCharacters(in: CharacterSet(charactersIn: ":： \u{00A0}"))
            #expect(text.localizedCaseInsensitiveContains(content), "\(language): \(text) never names \(content)")
            #expect(text.localizedCaseInsensitiveContains(folder), "\(language): \(text) never names \(folder)")
            #expect(language == "en" || text != footer, "\(language) still shows the English footer")
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            #expect(bundle.localizedString(forKey: stale, value: "\u{1}", table: "Settings") == "\u{1}", "\(language) keeps the old footer")
        }
    }

    @Test func theMenuBarIconRowHasOneLabeledSwitchAndReadsItsCaptionOnce() async throws {
        let host = A11yHost(MenuBarIconRow().defaultAppStorage(a11yDefaults("menubaricon.row")))
        defer { host.close() }
        let control = try await host.element("general-show-menu-bar-icon")
        #expect(AXTree.names(of: control).contains(try a11yString("Show Menu Bar Icon", "Settings")))
        let hint: String? = AXTree.value("accessibilityHelp", of: control)
        #expect(hint == nil)
        let caption = try a11yString("Shows a Wherever icon in the menu bar. Click it to open the launcher, or right-click it for a menu. If it does not appear, open System Settings and look in the Menu Bar section.", "Settings")
        let readers = AXTree.elements(in: host.view).filter { AXTree.names(of: $0).contains(caption) }
        #expect(readers.count == 1, "the caption has \(readers.count) VoiceOver stops")
        let readerRole: String? = readers.first.flatMap { AXTree.value("accessibilityRole", of: $0) }
        #expect(readerRole == NSAccessibility.Role.staticText.rawValue)
        let role: String? = AXTree.value("accessibilityRole", of: control)
        #expect(role == NSAccessibility.Role.checkBox.rawValue)
        let value: Int? = AXTree.value("accessibilityValue", of: control)
        #expect(value == 1)
    }

    @Test func theLoginRowHasOneLabeledSwitchAndReadsItsCaptionOnce() async throws {
        let host = A11yHost(LaunchAtLoginRow(model: .inert()))
        defer { host.close() }
        let control = try await host.element("general-open-at-login")
        #expect(AXTree.names(of: control).contains(try a11yString("Open at Login", "Settings")))
        let hint: String? = AXTree.value("accessibilityHelp", of: control)
        #expect(hint == nil)
        let caption = try a11yString("Starts the menu bar icon and the launcher shortcut when you log in, as you set them below.", "Settings")
        let readers = AXTree.elements(in: host.view).filter { AXTree.names(of: $0).contains(caption) }
        #expect(readers.count == 1, "the caption has \(readers.count) VoiceOver stops")
        let readerRole: String? = readers.first.flatMap { AXTree.value("accessibilityRole", of: $0) }
        #expect(readerRole == NSAccessibility.Role.staticText.rawValue)
        let role: String? = AXTree.value("accessibilityRole", of: control)
        #expect(role == NSAccessibility.Role.checkBox.rawValue)
        let value: Int? = AXTree.value("accessibilityValue", of: control)
        #expect(value == 0)
    }

    @Test func theCommandLineToolButtonReadsItsCaptionOnceAsItsHint() async throws {
        let host = A11yHost(CommandLineToolRow(model: .inert()))
        defer { host.close() }
        let button = try await host.element(CommandLineToolRow.id)
        #expect(AXTree.names(of: button).contains(try a11yString("Install", "Settings")), "the button reads \(AXTree.names(of: button))")
        let caption = try a11yString("Search from the command line with the wherever command.", "Settings")
        let hint: String? = AXTree.value("accessibilityHelp", of: button)
        #expect(hint == caption)
        let role: String? = AXTree.value("accessibilityRole", of: button)
        #expect(role == NSAccessibility.Role.button.rawValue)
        #expect(!AXTree.elements(in: host.view).contains { AXTree.names(of: $0).contains(caption) }, "the caption is a second VoiceOver stop")
    }

    @Test func a19AFailureNoteStaysUntilTheUserActsAgain() async throws {
        let model = LaunchAtLoginModel(readStatus: { .notRegistered }, register: { throw A11yRefused() },
            unregister: {}, openLoginItems: {})
        await model.setEnabled(true)
        #expect(model.failed)
        try await Task.sleep(for: .milliseconds(500))
        await model.refresh().value
        #expect(model.failed)
    }
}
