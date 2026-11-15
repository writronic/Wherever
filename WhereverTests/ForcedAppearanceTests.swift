import AppKit
import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import Wherever

private func freshSuite(_ name: String) -> UserDefaults {
    let domain = "com.writronic.wherever.tests.forced.\(name)"
    let defaults = UserDefaults(suiteName: domain)!
    defaults.removePersistentDomain(forName: domain)
    return defaults
}

private final class RecordingBackground: WelcomeBackground {
    var marked = false

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { marked = true }
            super.needsDisplay = newValue
        }
    }
}

private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

private let appearanceNames: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
private let pinnedWindows = NSHashTable<NSWindow>.weakObjects()
private var unpinTimer: Timer?

private func unpin(_ window: NSWindow) {
    window.appearance = nil
    pinnedWindows.remove(window)
    stopUnpinTimerIfIdle()
}

private func stopUnpinTimerIfIdle() {
    guard pinnedWindows.allObjects.isEmpty else { return }
    unpinTimer?.invalidate()
    unpinTimer = nil
}

private func startUnpinTimer() {
    guard unpinTimer == nil else { return }
    let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
        MainActor.assumeIsolated {
            for window in pinnedWindows.allObjects where window.isVisible { unpin(window) }
            stopUnpinTimerIfIdle()
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    unpinTimer = timer
}

func setAppAppearance(_ appearance: NSAppearance?) {
    for window in NSApplication.shared.windows where !window.isVisible && window.appearance == nil {
        guard let name = window.effectiveAppearance.bestMatch(from: appearanceNames) else { continue }
        window.appearance = NSAppearance(named: name)
        pinnedWindows.add(window)
        startUnpinTimer()
    }
    NSApplication.shared.appearance = appearance
    let app = NSApplication.shared.effectiveAppearance.bestMatch(from: appearanceNames)
    for window in pinnedWindows.allObjects where window.isVisible || window.appearance?.bestMatch(from: appearanceNames) == app {
        unpin(window)
    }
}

private final class AppearanceSentinel: NSView {
    var changes = 0
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        changes += 1
    }
}

private func sentinelWindow(_ label: String, shown: Bool) -> (NSWindow, AppearanceSentinel) {
    let sentinel = AppearanceSentinel()
    let window = NSWindow(contentViewController: NSHostingController(rootView: Text(label)))
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(sentinel)
    window.orderFront(nil)
    if !shown { window.close() }
    return (window, sentinel)
}

private func settle(_ window: NSWindow) async throws {
    window.contentView?.layoutSubtreeIfNeeded()
    try await pumpEvents(for: .milliseconds(100))
    window.contentView?.layoutSubtreeIfNeeded()
}

private func otherMode() -> AppearanceMode {
    NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .light : .dark
}

func forced<T>(_ mode: AppearanceMode, _ body: @MainActor () async throws -> T) async rethrows -> T {
    let previous = NSApplication.shared.appearance
    setAppAppearance(mode.appearance)
    defer { setAppAppearance(previous) }
    return try await body()
}

@Suite(.serialized) struct ForcedAppearanceTests {
    @Test(arguments: Theme.allCases, [AppearanceMode.light, .dark])
    func everyThemeTokenResolvesToItsLightOrDarkValueUnderAForcedMode(theme: Theme, mode: AppearanceMode) async throws {
        let raw = mode.rawValue
        let dark = mode == .dark
        let look: Look = dark ? .dark : .light
        let at = dark ? 1 : 0
        try await forced(mode) {
            let app = NSApplication.shared.effectiveAppearance
            try #require(app.bestMatch(from: [.aqua, .darkAqua]) == (dark ? .darkAqua : .aqua), "the app reads \(app.name.rawValue) under \(raw)")
            let resolved = { (color: NSColor) -> [Double] in channels(color, appearance: app) }

            var hexes: [(String, NSColor, UInt32)] = [
                ("welcome warning", Theme.welcomeWarning, dark ? 0xE69F00 : 0xA04600),
                ("problem", Theme.problem, dark ? 0xFF8A80 : 0xC4161C),
                ("welcome granted", Theme.welcomeGranted, dark ? 0x32D74B : 0x006B4D),
                ("launcher selection border", Theme.launcherSelectionBorder, dark ? 0x8E8E93 : 0x6E6E73),
            ]
            if let page = themePages[theme] {
                hexes += [
                    ("window", theme.windowBackground, page.window[at]), ("row", theme.rowBackground, page.row[at]),
                    ("stripe", theme.stripeBackground, page.stripe[at]), ("text", theme.text, page.text[at]),
                    ("secondary", theme.secondaryText, page.secondary[at]), ("match", theme.matchText, page.match[at]),
                    ("live", theme.stateLive, page.live[at]), ("indexing", theme.stateIndexing, page.indexing[at]),
                ]
            } else {
                let own = systemNativeOwn
                hexes += [
                    ("secondary", theme.secondaryText, own.secondary[at]), ("match", theme.matchText, own.match[at]),
                    ("live", theme.stateLive, own.live[at]), ("indexing", theme.stateIndexing, own.indexing[at]),
                ]
                let system: [(String, NSColor, NSColor)] = [
                    ("window", theme.windowBackground, .windowBackgroundColor), ("row", theme.rowBackground, .controlBackgroundColor),
                    ("stripe", theme.stripeBackground, NSColor.alternatingContentBackgroundColors[1]), ("text", theme.text, .labelColor),
                ]
                for (name, color, expected) in system {
                    #expect(resolved(color) == channels(expected, look), "\(theme) \(name) under \(raw)")
                }
            }
            for (name, color, hex) in hexes {
                #expect(eightBits(resolved(color)) == eightBits(hex: hex), "\(theme) \(name) under \(raw)")
            }

            let selection = resolved(Theme.launcherSelection)
            #expect(eightBits(selection) == (dark ? [255, 255, 255] : [0, 0, 0]) && abs(selection[3] - (dark ? 0.10 : 0.09)) < 0.001,
                    "launcher selection under \(raw): \(selection)")

            let failures = contrastFailures(theme, resolve: resolved)
            #expect(failures.text.isEmpty, "\(theme) under \(raw): \(failures.text)")
            #expect(failures.marks.isEmpty, "\(theme) under \(raw): \(failures.marks)")
        }
    }

    @Test(arguments: Theme.allCases)
    func aWindowOpenBeforeTheSwitchRepaintsWithoutARestart(theme: Theme) async throws {
        let suite = freshSuite("window-\(theme.rawValue)")
        suite.set(theme.rawValue, forKey: Theme.key)
        let windows = ThemeWindowTests()
        try await forced(.light) {
            let (host, _) = windows.open(suite, nil)
            defer { host.close() }
            #expect(host.window.appearance == nil)
            try await host.until("\(theme) light before the switch") { windows.draws(host, theme, .light) }
            try await forced(.dark) {
                try await host.until("\(theme) dark after the switch") { windows.draws(host, theme, .dark) }
            }
            try await host.until("\(theme) light again") { windows.draws(host, theme, .light) }
        }
    }

    @Test func aPreviewFollowsAnAppearanceChange() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        try await forced(.light) {
            let window = try await fixture.open()
            let controller = try #require(fixture.model.welcome)
            let content = try #require(window.contentView)
            let steps = try #require(content.subviews.compactMap { $0 as? WelcomeSteps }.first)
            @MainActor func pick(_ theme: Theme) throws {
                steps.dots[1].performClick(nil)
                steps.dots[2].performClick(nil)
                try #require(controller.setupBox.tiles.tiles.first { $0.theme == theme }).performClick(nil)
                steps.dots[1].performClick(nil)
                content.layoutSubtreeIfNeeded()
            }
            let card = controller.modeCards[0]
            let root = try #require(card.picture.layer)
            let field = try #require(root.sublayers?.first { $0.name == "searchField" })
            @MainActor func shows(_ theme: Theme, _ look: Look) -> Bool {
                let back = eightBits(channels(theme.windowBackground, look))
                let row = eightBits(channels(theme.rowBackground, look))
                return back == eightBits(channels(theme.windowBackground, appearance: content.effectiveAppearance))
                    && viewDraws(theme.windowBackground, in: content, x: 8, y: 8)
                    && viewDraws(theme.rowBackground, in: card, x: 198, y: card.bounds.midY)
                    && layerBits(root.backgroundColor) == back && layerBits(field.backgroundColor) == row
            }

            try pick(.warmPaper)
            try await untilTrue(waitingFor: "Warm Paper light") { shows(.warmPaper, .light) }
            try await forced(.dark) {
                try await untilTrue(waitingFor: "Warm Paper dark with no new pick") { shows(.warmPaper, .dark) }
                try pick(.inkAndGlass)
                try await untilTrue(waitingFor: "Ink and Glass dark") { shows(.inkAndGlass, .dark) }
                window.appearance = Look.darkContrast.appearance
                try await untilTrue(waitingFor: "the Ink and Glass contrast window with no new pick") { shows(.inkAndGlass, .darkContrast) }
                let title = try #require(descendants(of: content).compactMap { $0 as? NSTextField }.first { !$0.isHiddenOrHasHiddenAncestor })
                #expect(title.textColor.map { eightBits(channels($0, appearance: content.effectiveAppearance)) } == [255, 255, 255])
                let inky = layerBits(root.backgroundColor)
                #expect(inky == eightBits(hex: 0x05051A) && inky != eightBits(channels(Theme.inkAndGlass.windowBackground, .dark)))
                window.appearance = nil
            }
            try await untilTrue(waitingFor: "Ink and Glass light again") { shows(.inkAndGlass, .light) }
        }
    }

    @Test func aColorChangeMarksTheWelcomeBackgroundForDrawing() {
        let background = RecordingBackground()
        background.marked = false
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        #expect(background.marked, "an Increase Contrast change left the old window color")
    }

    @Test func theLauncherPanelFollowsAForcedMode() async throws {
        let panel = LauncherPanel()
        defer { panel.close() }
        func reads(_ name: NSAppearance.Name) async throws {
            try await untilTrue(waitingFor: "the panel on \(name.rawValue), now \(panel.effectiveAppearance.name.rawValue)") {
                panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name
            }
            let selection = channels(Theme.launcherSelection, appearance: panel.effectiveAppearance)
            let dark = name == .darkAqua
            #expect(eightBits(selection) == (dark ? [255, 255, 255] : [0, 0, 0]) && abs(selection[3] - (dark ? 0.10 : 0.09)) < 0.001,
                    "launcher selection on \(name.rawValue): \(selection)")
            let border = channels(Theme.launcherSelectionBorder, appearance: panel.effectiveAppearance)
            #expect(eightBits(border) == eightBits(hex: dark ? 0x8E8E93 : 0x6E6E73), "launcher selection border on \(name.rawValue): \(border)")
        }
        panel.orderFrontRegardless()
        #expect(panel.appearance == nil)
        try await forced(.dark) {
            try await reads(.darkAqua)
            try await forced(.light) { try await reads(.aqua) }
            try await reads(.darkAqua)
        }
    }

    @Test func aForcedSwitchLeavesAClosedWindowAsItIs() async throws {
        let (window, sentinel) = sentinelWindow("closed", shown: false)
        try await settle(window)
        let before = sentinel.changes
        try await forced(otherMode()) {
            try await settle(window)
            #expect(sentinel.changes == before, "the closed window restyled \(sentinel.changes - before) times inside the switch")
        }
        #expect(window.appearance == nil, "the closed window is still pinned at \(window.appearance?.name.rawValue ?? "")")
        #expect(!pinnedWindows.contains(window))
    }

    @Test func aClosedWindowShownInsideTheSwitchTakesTheForcedMode() async throws {
        let (window, _) = sentinelWindow("reshown", shown: false)
        defer { window.close() }
        let mode = otherMode()
        try await forced(mode) {
            window.orderFront(nil)
            try await untilTrue(waitingFor: "the reshown window on \(mode.rawValue), now \(window.effectiveAppearance.name.rawValue)") {
                window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearanceName(mode)
            }
        }
        #expect(window.appearance == nil, "the reshown window is still pinned at \(window.appearance?.name.rawValue ?? "")")
    }

    @Test func aForcedSwitchStillRestylesAnOpenWindow() async throws {
        let (window, sentinel) = sentinelWindow("open", shown: true)
        defer { window.close() }
        try await settle(window)
        let before = sentinel.changes
        try await forced(otherMode()) {
            try await untilTrue(waitingFor: "the open window restyled") {
                window.contentView?.layoutSubtreeIfNeeded()
                return sentinel.changes > before
            }
            #expect(window.appearance == nil)
        }
    }

    @Test func repeatedSwitchesLeaveNoClosedWindowPinned() async throws {
        let (window, sentinel) = sentinelWindow("repeated", shown: false)
        try await settle(window)
        let before = sentinel.changes
        let other = otherMode()
        let same: AppearanceMode = other == .dark ? .light : .dark
        try await forced(other) {
            try await settle(window)
            #expect(sentinel.changes == before, "the closed window restyled \(sentinel.changes - before) times on the first switch")
            setAppAppearance(same.appearance)
            try await settle(window)
            #expect(sentinel.changes == before, "the closed window restyled \(sentinel.changes - before) times on the second switch")
        }
        #expect(window.appearance == nil, "the closed window is still pinned at \(window.appearance?.name.rawValue ?? "")")
        #expect(!pinnedWindows.contains(window))
    }

    @Test func applyStoredSetsTheRealApp() async {
        let cases: [(stored: String?, applied: NSAppearance.Name?)] = [("dark", .darkAqua), ("light", .aqua), (nil, nil), ("purple", nil)]
        await forced(.system) {
            for (stored, applied) in cases {
                let suite = freshSuite("apply")
                if let stored { suite.set(stored, forKey: AppearanceMode.key) }
                setAppAppearance(NSAppearance(named: applied == .darkAqua ? .aqua : .darkAqua))
                AppearanceMode.applyStored(from: suite)
                let name = NSApplication.shared.appearance?.name
                #expect(name == applied, "\(String(describing: stored)) applied \(String(describing: name))")
                #expect(suite.string(forKey: AppearanceMode.key) == stored, "\(String(describing: stored)) was rewritten")
            }
        }
    }
}
