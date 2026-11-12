import AppKit
import Foundation
import Testing
@testable import Wherever
import WhereverInterface

private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

private final class VisibleHeight {
    var points: CGFloat
    init(_ points: CGFloat) { self.points = points }
}

private final class FitRig {
    let suite = "com.writronic.wherever.tests.welcomefit.\(UUID().uuidString)"
    let defaults: UserDefaults
    let access: AccessModel
    let controller: WelcomeWindowController
    let visible: VisibleHeight

    init(language: String = "de", size: TextSize = .maximum, completed: Bool = false, visible: VisibleHeight) {
        self.visible = visible
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(size.rawValue, forKey: TextSize.key)
        if completed { defaults.set(true, forKey: AccessModel.completedKey) }
        access = AccessModel(
            defaults: defaults, center: NotificationCenter(), stage: .granted, probe: { .denied }, confirm: { true },
            start: {}, summon: {}, open: { _ in true }, quit: {}, activate: {}, tools: .inert()
        )
        controller = WelcomeWindowController(model: access, bundle: AccessFixture.bundle(language), post: { _, _ in }, visibleHeight: { [visible] _ in visible.points })
        controller.show()
    }

    var window: NSWindow { controller.window! }
    var content: NSView { window.contentView! }
    var scroll: NSScrollView { descendants(of: content).compactMap { $0 as? NSScrollView }.first! }
    var pages: [WelcomePage] { descendants(of: content).compactMap { $0 as? WelcomePage } }
    var action: NSButton { descendants(of: content).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "welcome-action" }! }
    var back: NSButton { descendants(of: content).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "welcome-back" }! }
    var status: NSTextField { descendants(of: content).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "welcome-status" }! }
    var scale: CGFloat { window.backingScaleFactor }

    func buttonTop() -> CGFloat { content.bounds.height - action.frame.maxY }

    func close() {
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

@Suite(.serialized) struct WelcomeFitTests {
    @Test(arguments: [CGFloat(640), 800])
    func theTallestPageInGermanAtTheLargestTextSizeFitsTheVisibleHeightWithNextInside(_ height: CGFloat) throws {
        let rig = FitRig(visible: VisibleHeight(height))
        defer { rig.close() }
        var scrolled = false
        for page in WelcomeWindowController.Page.allCases {
            rig.content.layoutSubtreeIfNeeded()
            let name = "\(page) at \(height)"
            #expect(rig.window.frame.height <= height, "the window is taller than the screen, \(name)")
            #expect(rig.content.bounds.contains(rig.action.frame), "Next is outside the window, \(name)")
            #expect(rig.content.bounds.contains(rig.back.frame), "Back is outside the window, \(name)")
            if page == .access { #expect(rig.content.bounds.contains(rig.status.frame), "the status line is outside the window, \(name)") }
            let shown = try #require(rig.pages.first { !$0.isHidden }, "\(name)")
            let document = try #require(rig.scroll.documentView, "\(name)")
            let viewport = rig.scroll.contentView.bounds.height
            #expect(document.frame.height >= shown.frame.maxY + WelcomeMetrics.textToButton - 1 / rig.scale, "the page bottom cannot be reached, \(name)")
            #expect(document.frame.height >= viewport, "\(name)")
            #expect(rig.scroll.frame.minY >= rig.action.frame.maxY, "the scroll area overlaps Next, \(name)")
            if document.frame.height > viewport { scrolled = true }
            if page != .done { rig.action.performClick(nil) }
        }
        #expect(scrolled, "no page needed the scroll view at \(height)")
    }

    @Test func aScrolledPageStartsAtTheTopWhenTheNextPageOpens() throws {
        let rig = FitRig(visible: VisibleHeight(640))
        defer { rig.close() }
        rig.action.performClick(nil)
        rig.content.layoutSubtreeIfNeeded()
        let clip = rig.scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: 100))
        rig.action.performClick(nil)
        #expect(clip.bounds.origin.y == 0)
    }

    @Test(arguments: [CGFloat(640), 800, 4000])
    func aReturningWelcomeKeepsTheHeightAndButtonOfTheFirstWelcome(_ height: CGFloat) throws {
        let visible = VisibleHeight(height)
        let first = FitRig(completed: true, visible: visible)
        defer { first.close() }
        let all = FitRig(visible: visible)
        defer { all.close() }
        first.content.layoutSubtreeIfNeeded()
        all.content.layoutSubtreeIfNeeded()
        #expect(first.window.frame.height == all.window.frame.height, "at \(height)")
        #expect(Int(((first.buttonTop() - all.buttonTop()) * first.scale).rounded()) == 0, "at \(height)")
    }

    @Test func aScreenChangeFitsTheWindowAgain() throws {
        let visible = VisibleHeight(4000)
        let rig = FitRig(visible: visible)
        defer { rig.close() }
        let roomy = rig.window.frame.height
        #expect(roomy > 640)
        visible.points = 640
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        #expect(rig.window.frame.height <= 640)
        visible.points = 4000
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: rig.window)
        #expect(rig.window.frame.height == roomy)
    }

    @Test func theLayoutCapsToTheVisibleHeightAndTheDocumentCoversThePage() {
        let layout = WelcomeLayout(minimumIconTop: 80, tallestGroup: 600, buttonHeight: 28, tallestLine: 32, visibleHeight: 640, scale: 2)
        #expect(layout.height == 640 && layout.iconTop == 80 && layout.buttonY == 520 && layout.viewport == 440)
        #expect(layout.documentHeight(top: 80, group: 600) == 640)
        #expect(layout.documentHeight(top: 80, group: 100) == 440)
        let roomy = WelcomeLayout(minimumIconTop: 80, tallestGroup: 600, buttonHeight: 28, tallestLine: 32, visibleHeight: 4000, scale: 2)
        #expect(roomy.height == 850 && roomy.iconTop == 90 && roomy.viewport == 650)
        #expect(roomy.documentHeight(top: 90, group: 600) == 650)
    }
}
