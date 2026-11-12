import AppKit
import Carbon
import Foundation
import SwiftUI
import Testing
@testable import Wherever

private final class Opened {
    var urls: [URL] = []
}

private func aboutTitle() -> String {
    Bundle.main.localizedString(forKey: "About Wherever", value: nil, table: "MenuBar")
}

private func visibleAbout() -> [NSWindow] {
    NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue == "about" }
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

private func escape(_ window: NSWindow) throws {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: UInt16(kVK_Escape)
    ))
    (window.firstResponder ?? window).keyDown(with: event)
}

@Suite(.serialized) struct AboutWindowTests {
    @Test func theAppMenuStartsWithAboutWhereverWhichOpensOneAboutWindow() async throws {
        let title = aboutTitle()
        func appMenu() -> NSMenu? {
            let menu = NSApp.mainMenu?.items.first?.submenu
            if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
            return menu
        }
        try await untilTrue(waitingFor: "the app menu to start with \(title)") { appMenu()?.items.first?.title == title }
        let menu = try #require(appMenu())
        #expect(menu.items.filter { $0.title == title }.count == 1)
        #expect(menu.items[0].action != #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        defer { visibleAbout().forEach { $0.close() } }
        menu.performActionForItem(at: 0)
        try await untilTrue(waitingFor: "the About window") { !visibleAbout().isEmpty }
        let window = try #require(visibleAbout().first)
        #expect(window.title == title)
        #expect(!MainWindow.isMain(window))
        let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let line = String(format: Bundle.main.localizedString(forKey: "Version %@", value: nil, table: "Settings"), version)
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "the Website and Donate buttons and the \(line) line") {
            AXTree.element("about-donate", in: content) != nil && AXTree.element("about-website", in: content) != nil
                && texts(in: content).contains(line)
        }
        menu.performActionForItem(at: 0)
        #expect(visibleAbout().count == 1)
        #expect(visibleAbout().first === window)
    }

    @Test func theAppMenusNewWindowIsGreyedWhileADialogIsUp() async throws {
        func newWindowItem(in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items {
                if item.title == String(localized: "New Window", table: "MenuBar") { return item }
                if let found = newWindowItem(in: item.submenu) { return found }
            }
            return nil
        }
        func newWindowIsEnabled() -> Bool? { newWindowItem(in: NSApp.mainMenu)?.isEnabled }
        ModalWindowCoordinator.shared.start()
        defer { ModalWindowCoordinator.shared.stop() }
        defer { visibleAbout().forEach { $0.close() } }
        try await untilTrue(waitingFor: "New Window to be enabled with no dialog up") { newWindowIsEnabled() == true }
        let menu = try #require(NSApp.mainMenu?.items.first?.submenu)
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.performActionForItem(at: 0)
        try await untilTrue(waitingFor: "the About window") { !visibleAbout().isEmpty }
        try await untilTrue(waitingFor: "New Window to be greyed while About is up") { newWindowIsEnabled() == false }
        visibleAbout().forEach { $0.close() }
        try await untilTrue(waitingFor: "New Window to be enabled after About closes") { newWindowIsEnabled() == true }
        #expect(!ModalWindowCoordinator.shared.isBlocking)
    }

    @Test func escapeAndCloseHideTheWindowAndShowBringsItBackWhereTheUserLeftIt() async throws {
        let opened = Opened()
        let about = AboutWindow(defaults: hostStore(), open: { opened.urls.append($0) })
        defer { about.window?.close() }
        about.show()
        let window = try #require(about.window)
        #expect(window.isVisible)

        window.makeFirstResponder(nil)
        try escape(window)
        #expect(!window.isVisible)
        about.show()
        #expect(about.window === window)
        #expect(window.isVisible)

        let hosting = try #require(window.contentViewController?.view)
        let stops = [hosting, window.contentView?.nextValidKeyView].compactMap { $0 }
        if stops.contains(where: { window.makeFirstResponder($0) && window.firstResponder === $0 }) {
            try escape(window)
            #expect(!window.isVisible)
            about.show()
            #expect(window.isVisible)
        }

        let moved = NSPoint(x: window.frame.origin.x + 40, y: window.frame.origin.y - 30)
        window.setFrameOrigin(moved)
        window.performClose(nil)
        #expect(!window.isVisible)
        about.show()
        #expect(window.isVisible)
        #expect(window.frame.origin.x - moved.x == 0)
        #expect(window.frame.origin.y - moved.y == 0)
        #expect(opened.urls.isEmpty)
    }

    @Test func theWindowShowsTheMottoAndNotTheOldLine() async throws {
        let about = AboutWindow(defaults: hostStore(), open: { _ in })
        defer { about.window?.close() }
        about.show()
        let content = try #require(about.window?.contentView)
        let motto = Bundle.main.localizedString(forKey: "Wherever it is, find it.", value: nil, table: "Welcome")
        try await untilTrue(waitingFor: "the \(motto) line") { texts(in: content).contains(motto) }
        #expect(!texts(in: content).contains("Find any file on your Mac, instantly."), "the old line still shows")
        let madeWith = Bundle.main.localizedString(forKey: "Made with ❤️", value: nil, table: "Settings")
        #expect(texts(in: content).contains(madeWith), "Made with is missing from \(texts(in: content))")
    }

    @Test func theWindowUsesTheSmallerStyleSoItIsShorterThanTheSettingsPane() async throws {
        let store = hostStore()
        let about = AboutWindow(defaults: store, open: { _ in })
        defer { about.window?.close() }
        let settings = NSHostingController(rootView: AboutPane(open: { _ in }, metrics: .settings).fixedSize().defaultAppStorage(store)).sizeThatFits(in: .zero)
        let window = NSHostingController(rootView: AboutPane(open: { _ in }, metrics: .window).fixedSize().defaultAppStorage(store)).sizeThatFits(in: .zero)
        #expect(window.height < settings.height, "window pane \(window.height), settings pane \(settings.height)")
        #expect(about.measure().height < settings.height, "window \(about.measure().height), settings pane \(settings.height)")
        #expect(AboutPane.Metrics.window.top == 20)
        #expect(AboutWindow.Metrics.side == 32)
        #expect(AboutWindow.Metrics.minWidth == 360)
    }

    @Test func theWindowKeepsMaCursorsGapsAroundTheMadeWithAndLicenceLines() {
        #expect(AboutPane.Metrics.window.descriptionToMadeWith == 38)
        #expect(AboutPane.Metrics.window.buttonsToLicence == 33)
    }

    @Test func theWindowIsFixedNamedAndSizedToItsContent() async throws {
        let opened = Opened()
        let store = hostStore()
        let about = AboutWindow(defaults: store, open: { opened.urls.append($0) })
        defer { about.window?.close() }
        about.show()
        let window = try #require(about.window)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.styleMask == [.titled, .closable])
        #expect(window.identifier?.rawValue == "about")
        #expect(window.title == aboutTitle())
        #expect(!window.isReleasedWhenClosed)
        #expect(!MainWindow.isMain(window))

        let pane = NSHostingController(rootView: AboutPane(open: { _ in }, metrics: .window).fixedSize().defaultAppStorage(store)).sizeThatFits(in: .zero)
        let scale = window.backingScaleFactor
        let width = (max(AboutWindow.Metrics.minWidth, pane.width + 2 * AboutWindow.Metrics.side) * scale).rounded(.up) / scale
        let height = ((pane.height + AboutPane.Metrics.window.top) * scale).rounded(.up) / scale
        let content = window.contentRect(forFrameRect: window.frame).size
        #expect(content.width - width == 0)
        #expect(content.height - height == 0)
        #expect(content.width >= AboutWindow.Metrics.minWidth)
        #expect(opened.urls.isEmpty)
    }

    @Test func aLiveTextSizeChangeRefitsTheWindowAndKeepsItsTopLeftCorner() async throws {
        let store = hostStore()
        let about = AboutWindow(defaults: store, open: { _ in })
        defer { about.window?.close() }
        about.show()
        let window = try #require(about.window)
        let before = window.frame
        store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        try await untilTrue(waitingFor: "the window to grow from \(before)") { window.frame.height > before.height }
        #expect(window.frame.minX - before.minX == 0)
        #expect(window.frame.maxY - before.maxY == 0)
        let pane = NSHostingController(rootView: AboutPane(open: { _ in }, metrics: .window).fixedSize().defaultAppStorage(store)).sizeThatFits(in: .zero)
        let scale = window.backingScaleFactor
        let height = ((pane.height + AboutPane.Metrics.window.top) * scale).rounded(.up) / scale
        #expect(window.contentRect(forFrameRect: window.frame).height - height == 0)
        store.removeObject(forKey: TextSize.key)
        try await untilTrue(waitingFor: "the window to shrink back to \(before), now \(window.frame)") { window.frame == before }
    }

    @Test func aRefitRightAfterTheChangeMeasuresTheNewSize() async throws {
        let store = hostStore()
        let about = AboutWindow(defaults: store, open: { _ in })
        defer { about.window?.close() }
        about.show()
        let window = try #require(about.window)
        let scale = window.backingScaleFactor
        let before = about.measure()
        store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        let grown = about.measure()
        let pane = NSHostingController(rootView: AboutPane(open: { _ in }, metrics: .window).fixedSize().defaultAppStorage(store)).sizeThatFits(in: .zero)
        let width = (max(AboutWindow.Metrics.minWidth, pane.width + 2 * AboutWindow.Metrics.side) * scale).rounded(.up) / scale
        let height = ((pane.height + AboutPane.Metrics.window.top) * scale).rounded(.up) / scale
        #expect(grown.height > before.height)
        #expect((grown.width * scale).rounded(.up) / scale - width == 0)
        #expect((grown.height * scale).rounded(.up) / scale - height == 0)
    }

    @Test func donateInTheWindowOpensTheDonatePageOnceAndKeepsTheWindow() async throws {
        let opened = Opened()
        let about = AboutWindow(defaults: hostStore(), open: { opened.urls.append($0) })
        defer { about.window?.close() }
        about.show()
        let window = try #require(about.window)
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "the Donate button") { AXTree.element("about-donate", in: content) != nil }
        let donate = try #require(AXTree.element("about-donate", in: content))
        #expect(opened.urls.isEmpty)
        #expect(AXTree.press(donate))
        try await untilTrue(waitingFor: "the donate page to open") { !opened.urls.isEmpty }
        #expect(opened.urls == [AppLinks.donate])
        #expect(window.isVisible)
        let name = Bundle.main.localizedString(forKey: "Donate", value: nil, table: "Settings")
        #expect(AXTree.names(of: donate).contains(name), "Donate reads \(AXTree.names(of: donate))")
    }

    @Test func visitWebsiteInTheWindowOpensTheWebsiteOnceAndKeepsTheWindow() async throws {
        let opened = Opened()
        let about = AboutWindow(defaults: hostStore(), open: { opened.urls.append($0) })
        defer { about.window?.close() }
        about.show()
        let window = try #require(about.window)
        let content = try #require(window.contentView)
        try await untilTrue(waitingFor: "the Visit Website button") { AXTree.element("about-website", in: content) != nil }
        let website = try #require(AXTree.element("about-website", in: content))
        #expect(opened.urls.isEmpty)
        #expect(AXTree.press(website))
        try await untilTrue(waitingFor: "the website to open") { !opened.urls.isEmpty }
        #expect(opened.urls == [AppLinks.website])
        #expect(AppLinks.website.absoluteString == "https://writronic.com")
        #expect(window.isVisible)
        let name = Bundle.main.localizedString(forKey: "Visit Website", value: nil, table: "Settings")
        #expect(AXTree.names(of: website).contains(name), "Visit Website reads \(AXTree.names(of: website))")
    }
}
