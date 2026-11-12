import AppKit
import Foundation
import QuartzCore
import Testing
@testable import Wherever
import WhereverInterface

private let languages = ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"]

private func text(_ key: String, _ language: String = "en", table: String = "Welcome") -> String {
    AccessFixture.bundle(language).localizedString(forKey: key, value: nil, table: table)
}

private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

private func visibleLeaves(of view: NSView) -> [NSView] {
    view.subviews.flatMap { sub -> [NSView] in
        if sub.isHidden { return [] }
        if sub is NSTextField || sub is NSButton || sub is NSSwitch || sub is NSImageView || sub is ModePictureView { return [sub] }
        return visibleLeaves(of: sub)
    }
}

private func looping(_ picture: ModePictureView) -> Bool {
    picture.layer?.sublayers?.contains { $0.animationKeys() != nil } ?? false
}

private func clock(_ picture: ModePictureView) -> [CAAnimation] {
    (picture.layer?.sublayers ?? []).compactMap { $0.animation(forKey: "opacity") }
}

private func flip(_ control: NSSwitch) {
    control.state = control.state == .on ? .off : .on
    _ = control.sendAction(control.action, to: control.target)
}

private final class Heard {
    var posts: [String] = []
    var opens = 0
    var quits = 0
}

private func realPress(_ view: NSView, in window: NSWindow, clickCount: Int = 1) async throws {
    let frame = try #require(window.contentView?.superview)
    window.contentView?.layoutSubtreeIfNeeded()
    let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    let target = try #require(frame.hitTest(point))
    try #require(target.isDescendant(of: view), "the click at \(point) hit \(target)")
    func event(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0
        ))
    }
    let down = try event(.leftMouseDown)
    let up = try event(.leftMouseUp)
    await EventQueueLock.run {
        NSApp.postEvent(up, atStart: true)
        if window.isKeyWindow { NSApp.sendEvent(down) } else { target.mouseDown(with: down) }
        while let left = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            guard left.window === window else {
                NSApp.postEvent(left, atStart: true)
                break
            }
            NSApp.sendEvent(left)
        }
    }
}

private func pressDot(_ dot: WelcomeStepDot, in window: NSWindow) throws {
    let frame = try #require(window.contentView?.superview)
    window.contentView?.layoutSubtreeIfNeeded()
    let point = dot.convert(NSPoint(x: dot.bounds.midX, y: dot.bounds.midY), to: nil)
    let target = try #require(frame.hitTest(point))
    try #require(target.isDescendant(of: dot), "the click at \(point) hit \(target)")
    dot.performClick(nil)
}

private func returnKey(_ window: NSWindow) throws -> Bool {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36
    ))
    return window.performKeyEquivalent(with: event)
}

private func pixelAlpha(_ view: NSView, _ rect: CGRect) throws -> CGFloat {
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let factor = CGFloat(rep.pixelsWide) / view.bounds.width
    return try #require(rep.colorAt(x: Int(rect.midX * factor), y: Int(rect.midY * factor))).alphaComponent
}

private let previewThemes: [Theme] = [.inkAndGlass, .warmPaper, .midnightTeal]

private func words(in view: NSView) -> [NSTextField] {
    descendants(of: view).compactMap { $0 as? NSTextField }
}

private func reads(_ color: NSColor?, as token: NSColor, in view: NSView) -> Bool {
    color.map { eightBits(channels($0, appearance: view.effectiveAppearance)) } == eightBits(channels(token, appearance: view.effectiveAppearance))
}

private func expectPreview(_ theme: Theme, on controller: WelcomeWindowController, _ context: String) throws {
    let content = try #require(controller.window?.contentView)
    let page = try #require(descendants(of: content).compactMap { $0 as? WelcomePage }.first { !$0.isHidden })
    content.layoutSubtreeIfNeeded()
    #expect(viewDraws(theme.windowBackground, in: content, x: 8, y: 8), "\(context): the window is not \(theme)")
    let lines = words(in: page)
    #expect(reads(lines[0].textColor, as: theme.text, in: content), "\(context): the title is not \(theme)")
    #expect(reads(lines[1].textColor, as: theme.secondaryText, in: content), "\(context): the subtitle is not \(theme)")
    if controller.page == .access { #expect(reads(lines[2].textColor, as: theme.secondaryText, in: content), "\(context): the body is not \(theme)") }
    for card in controller.modeCards {
        let root = layerBits(card.picture.layer?.backgroundColor)
        #expect(root == eightBits(channels(theme.windowBackground, appearance: content.effectiveAppearance)), "\(context): the \(card.mode) picture is not \(theme)")
        if controller.page == .modes {
            #expect(viewDraws(theme.rowBackground, in: card, x: 198, y: card.bounds.midY), "\(context): the \(card.mode) card is not \(theme)")
        }
    }
    if controller.page == .setup {
        let box = controller.setupBox
        #expect(viewDraws(theme.rowBackground, in: box, x: 6, y: box.bounds.midY), "\(context): the setup box is not \(theme)")
    }
}

private func stepLabelInk(_ steps: WelcomeSteps) throws -> NSColor {
    let rep = try #require(steps.bitmapImageRepForCachingDisplay(in: steps.bounds))
    steps.cacheDisplay(in: steps.bounds, to: rep)
    let factor = CGFloat(rep.pixelsWide) / steps.bounds.width
    let label = steps.geometry.label
    var ink: NSColor?
    for y in Int(label.minY * factor)..<Int(label.maxY * factor) {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.alphaComponent > ink?.alphaComponent ?? 0 { ink = color }
        }
    }
    return try #require(ink)
}

private final class ToolFolder {
    let root: URL
    let bin: URL
    let tool: URL
    let suite = "com.writronic.wherever.tests.welcomepages.tool.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "wherever-welcome-\(UUID().uuidString)")
        bin = root.appending(path: "bin")
        tool = root.appending(path: "Apps/Wherever.app/Contents/Helpers/wherever")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: tool)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
    }

    var link: String { bin.appending(path: "wherever").path(percentEncoded: false) }

    var profile: URL { root.appending(path: ".zshenv") }

    func model() -> CommandLineToolModel {
        CommandLineToolModel(linkFolder: bin, profile: profile, tool: tool, defaults: defaults)
    }

    func lock() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path(percentEncoded: false))
    }

    func close() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class RecordingBox: WelcomeBox {
    var marked = false

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { marked = true }
            super.needsDisplay = newValue
        }
    }
}

private final class FillView: NSView {
    let color: NSColor

    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

private final class Rig {
    let suite = "com.writronic.wherever.tests.welcomepages.\(UUID().uuidString)"
    let defaults: UserDefaults
    let access: AccessModel
    let controller: WelcomeWindowController
    let heard = Heard()

    init(
        stage: AccessModel.Stage = .granted, language: String = "en", size: TextSize = .standard, tools: WelcomeTools = .inert(),
        completed: Bool = false, visibleHeight: CGFloat = 4000
    ) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(size.rawValue, forKey: TextSize.key)
        if completed { defaults.set(true, forKey: AccessModel.completedKey) }
        access = AccessModel(
            defaults: defaults, center: NotificationCenter(), stage: stage, probe: { .denied }, confirm: { stage != .reopen },
            start: {}, summon: {}, open: { [heard] _ in
                heard.opens += 1
                return true
            }, quit: { [heard] in heard.quits += 1 }, activate: {}, tools: tools
        )
        controller = WelcomeWindowController(
            model: access, bundle: AccessFixture.bundle(language), post: { [heard] _, text in heard.posts.append(text) }, visibleHeight: { _ in visibleHeight }
        )
        controller.show()
    }

    var window: NSWindow { controller.window! }
    var content: NSView { window.contentView! }
    var action: NSButton { descendants(of: content).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "welcome-action" }! }
    var back: NSButton { descendants(of: content).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "welcome-back" }! }
    var status: NSTextField { descendants(of: content).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "welcome-status" }! }
    var visiblePage: WelcomePage { descendants(of: content).compactMap { $0 as? WelcomePage }.first { !$0.isHidden }! }
    var scale: CGFloat { window.backingScaleFactor }
    var steps: WelcomeSteps { descendants(of: content).compactMap { $0 as? WelcomeSteps }.first! }
    var minimumTop: CGFloat { content.bounds.height - rect(of: steps).minY + WelcomeMetrics.stepsToIcon }

    func press() { action.performClick(nil) }

    func rect(of view: NSView) -> CGRect {
        view.superview!.convert(view.alignmentRect(forFrame: view.frame), to: content)
    }

    func close() {
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

private extension AccessFixture {
    var controller: WelcomeWindowController { model.welcome! }
    var action: NSButton { controller.window!.defaultButtonCell!.controlView as! NSButton }
    var back: NSButton { descendants(of: controller.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "welcome-back" }! }
    var steps: WelcomeSteps { descendants(of: controller.window!.contentView!).compactMap { $0 as? WelcomeSteps }.first! }

    func press() { action.performClick(nil) }
}

@Suite(.serialized) struct WelcomePagesTests {
    private static let otherStages: [AccessModel.Stage] = [.waiting, .stillOff, .checkFailed, .settingsFailed, .reopen, .startFailed]

    @Test func everyPageKeepsOneHeightAndOneButtonFrameInEveryLanguageSizeAndStage() throws {
        for language in languages {
            for size in [TextSize.smallest, .standard, .maximum] {
                let name = "\(language) at \(size.rawValue)"
                let rig = Rig(language: language, size: size)
                defer { rig.close() }
                let height = rig.window.frame.height
                #expect((height * rig.scale).rounded() == height * rig.scale, "whole device pixels in \(name)")
                #expect(rig.window.frame.width == WelcomeMetrics.width, "\(name)")
                let button = rig.action.frame
                for page in [WelcomeWindowController.Page.modes, .setup, .done] {
                    rig.press()
                    rig.content.layoutSubtreeIfNeeded()
                    #expect(rig.controller.page == page, "\(name)")
                    #expect(rig.window.frame.height == height, "\(page) in \(name)")
                    #expect(rig.action.frame == button, "\(page) in \(name)")
                }
                for stage in Self.otherStages {
                    let other = Rig(stage: stage, language: language, size: size)
                    defer { other.close() }
                    other.content.layoutSubtreeIfNeeded()
                    #expect(other.window.frame.height == height, "\(stage) in \(name)")
                    #expect(other.action.frame == button, "\(stage) in \(name)")
                }
            }
        }
    }

    @Test func aFailedInstallMovesNothingAndVoiceOverHearsIt() async throws {
        let folder = try ToolFolder()
        defer { folder.close() }
        try Data("other".utf8).write(to: URL(filePath: folder.link))
        let model = folder.model()
        let rig = Rig(tools: WelcomeTools(commandLine: model, launcherIsOn: { true }, shortcut: { "⌃⇧F" }, applyLauncher: { _ in }))
        defer { rig.close() }
        rig.press()
        rig.content.layoutSubtreeIfNeeded()
        let height = rig.window.frame.height
        let button = rig.action.frame
        rig.controller.toolBox.action.performClick(nil)
        try await untilTrue(waitingFor: "the failure line") { model.notice == .taken && !model.busy }
        rig.content.layoutSubtreeIfNeeded()
        #expect(rig.window.frame.height == height)
        #expect(rig.action.frame == button)
        let line = model.text(for: .taken, bundle: AccessFixture.bundle("en"))
        let field = try #require(visibleLeaves(of: rig.content).compactMap { $0 as? NSTextField }.first { $0.stringValue == line })
        #expect(field.textColor == .systemRed)
        #expect(rig.heard.posts.last == line)
        #expect(rig.rect(of: rig.visiblePage).minY >= rig.action.frame.maxY)
    }

    @Test func nothingIsClippedOrOverlapsOnAnyPage() throws {
        for language in languages {
            for size in [TextSize.standard, .maximum] {
                let rig = Rig(language: language, size: size)
                defer { rig.close() }
                for page in WelcomeWindowController.Page.allCases {
                    let name = "\(page) in \(language) at \(size.rawValue)"
                    rig.content.layoutSubtreeIfNeeded()
                    let leaves = visibleLeaves(of: rig.content).filter { !$0.isHiddenOrHasHiddenAncestor }
                    let rects = leaves.map { rig.rect(of: $0) }
                    for (index, (leaf, rect)) in zip(leaves, rects).enumerated() {
                        #expect(rig.content.bounds.contains(rect), "\(leaf) at \(rect) is cut off, \(name)")
                        if let label = leaf as? NSTextField {
                            let bounds = NSRect(x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude)
                            let needed = label.cell?.cellSize(forBounds: bounds).height ?? 0
                            #expect(needed <= label.frame.height + 0.5, "\(label.stringValue) is clipped, \(name)")
                        }
                        if let button = leaf as? NSButton {
                            #expect(button.intrinsicContentSize.width <= button.frame.width, "\(button.title) is cut short, \(name)")
                        }
                        for other in rects[(index + 1)...] {
                            let overlap = rect.intersection(other)
                            #expect(overlap.isNull || overlap.width <= 0 || overlap.height <= 0, "\(leaf) overlaps \(other), \(name)")
                        }
                    }
                    let group = rig.rect(of: rig.visiblePage)
                    let below = group.minY - rig.rect(of: rig.action).maxY
                    #expect(below >= WelcomeMetrics.textToButton - 1 / rig.scale, "\(below) under the group, \(name)")
                    if page == .access || page == .done {
                        let above = rig.content.bounds.height - group.maxY
                        #expect(abs(above - below) * rig.scale <= 1, "\(above) above and \(below) below, \(name)")
                    } else {
                        let top = rig.content.bounds.height - group.maxY
                        let visible = (rig.window.screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude
                        if rig.window.frame.height < visible {
                            #expect(top == WelcomeMetrics.iconTop, "\(name)")
                        } else {
                            #expect(top >= rig.minimumTop && top <= WelcomeMetrics.iconTop, "\(name)")
                        }
                    }
                    if page != .done { rig.press() }
                }
            }
        }
    }

    private func tick(in view: NSView) -> NSImageView? {
        descendants(of: view).compactMap { $0 as? NSImageView }.first { $0.accessibilityIdentifier() == "welcome-done-tick" }
    }

    @Test func onlyPageFourHoldsTheTickAndItIsHiddenFromVoiceOver() throws {
        let rig = Rig()
        defer { rig.close() }
        let pages = descendants(of: rig.content).compactMap { $0 as? WelcomePage }
        #expect(pages.count == 4)
        #expect(pages.map { tick(in: $0) != nil } == [false, false, false, true])
        #expect(pages.last?.heading == text("You’re All Set"))
        let tick = try #require(tick(in: rig.content))
        #expect(tick.cell?.isAccessibilityElement() == false)
        #expect(tick.image != nil)
    }

    @Test func theTickIs64PointsBetweenTwoGapsOf20AndCentredOnPageFour() throws {
        for language in languages {
            for size in [TextSize.standard, .maximum] {
                let name = "\(language) at \(size.rawValue)"
                let rig = Rig(language: language, size: size)
                defer { rig.close() }
                (0..<3).forEach { _ in rig.press() }
                rig.content.layoutSubtreeIfNeeded()
                let page = rig.visiblePage
                let tick = try #require(tick(in: page), "\(name)")
                let logo = try #require(descendants(of: page).compactMap { $0 as? NSImageView }.first { $0 !== tick }, "\(name)")
                let heading = try #require(descendants(of: page).compactMap { $0 as? NSTextField }.first, "\(name)")
                let (tickRect, logoRect, headingRect) = (rig.rect(of: tick), rig.rect(of: logo), rig.rect(of: heading))
                func off(_ actual: CGFloat, _ expected: CGFloat) -> Int { Int(((actual - expected) * rig.scale).rounded()) }
                #expect(off(tickRect.width, 64) == 0 && off(tickRect.height, 64) == 0, "tick size in \(name)")
                #expect(off(logoRect.width, 80) == 0 && off(logoRect.height, 80) == 0, "logo size in \(name)")
                #expect(off(logoRect.minY - tickRect.maxY, 20) == 0, "logo to tick in \(name)")
                #expect(off(tickRect.minY - headingRect.maxY, 20) == 0, "tick to title in \(name)")
                #expect(off(tickRect.midX, rig.content.bounds.midX) == 0, "tick centred in \(name)")
                #expect(rig.content.bounds.height - rig.rect(of: page).maxY >= rig.minimumTop, "group under the step indicator in \(name)")
            }
        }
    }

    @Test func theTickIsAWhiteCheckOnAGreenDiscInLightAndDark() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rig = Rig()
            defer { rig.close() }
            rig.window.appearance = NSAppearance(named: appearance)
            (0..<3).forEach { _ in rig.press() }
            rig.content.layoutSubtreeIfNeeded()
            let tick = try #require(tick(in: rig.content))
            let rep = try #require(tick.bitmapImageRepForCachingDisplay(in: tick.bounds))
            tick.cacheDisplay(in: tick.bounds, to: rep)
            func color(_ x: Int, _ y: Int) throws -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
                let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
            }
            let disc = try color(rep.pixelsWide * 12 / 100, rep.pixelsHigh / 2)
            #expect(disc.a > 0.9 && disc.g > disc.r + 0.2 && disc.g > disc.b + 0.2, "disc \(disc) in \(appearance.rawValue)")
            var white = false
            for y in (rep.pixelsHigh / 4)..<(rep.pixelsHigh * 3 / 4) {
                for x in (rep.pixelsWide / 4)..<(rep.pixelsWide * 3 / 4) {
                    let c = try color(x, y)
                    if c.a > 0.9 && min(c.r, c.g, c.b) > 0.9 { white = true }
                }
            }
            #expect(white, "no white check in \(appearance.rawValue)")
        }
    }

    @Test func theHeightGivesWayOnAShortScreenDownToAnIconTopOfForty() {
        let tall = WelcomeLayout(minimumIconTop: 40, tallestGroup: 400, buttonHeight: 28, tallestLine: 32, visibleHeight: 2000, scale: 2)
        #expect(tall.iconTop == 90 && tall.buttonY == 530 && tall.height == 650)
        let short = WelcomeLayout(minimumIconTop: 40, tallestGroup: 400, buttonHeight: 28, tallestLine: 32, visibleHeight: 630, scale: 2)
        #expect(short.iconTop == 70 && short.buttonY == 510 && short.height == 630)
        let tiny = WelcomeLayout(minimumIconTop: 40, tallestGroup: 400, buttonHeight: 28, tallestLine: 32, visibleHeight: 400, scale: 2)
        #expect(tiny.iconTop == 40 && tiny.buttonY == 280 && tiny.height == 400 && tiny.viewport == 240)
        let rough = WelcomeLayout(minimumIconTop: 40, tallestGroup: 400.3, buttonHeight: 28, tallestLine: 32.25, visibleHeight: 2000, scale: 2)
        #expect(rough.buttonY == 530.5 && rough.height == 651)
        #expect(tall.centredTop(ofGroup: 201) == 164.5)
        #expect(WelcomeLayout(minimumIconTop: 40, tallestGroup: 400, buttonHeight: 28, tallestLine: 32, visibleHeight: 2000, scale: 1).centredTop(ofGroup: 201) == 165)
    }

    @Test func theHeightGivesWayOnlyDownToTheStepIndicatorAndAGap() {
        let limit: CGFloat = 78.5
        let tiny = WelcomeLayout(minimumIconTop: limit, tallestGroup: 400, buttonHeight: 28, tallestLine: 32, visibleHeight: 400, scale: 2)
        #expect(tiny.iconTop == limit && tiny.buttonY == 280 && tiny.height == 400)
        let roomy = WelcomeLayout(minimumIconTop: limit, tallestGroup: 400, buttonHeight: 28, tallestLine: 32, visibleHeight: 2000, scale: 2)
        #expect(roomy.iconTop == 90 && roomy.buttonY == 530)
        #expect(roomy.centredTop(ofGroup: 201) == 164.5)
        #expect(roomy.centredTop(ofGroup: 500) == limit)
        #expect(tiny.centredTop(ofGroup: 500) == limit)
    }

    private func opening(_ language: String, _ page: Int) -> String {
        String(format: text("Step %lld of %lld", language), page + 1, 4)
    }

    @Test func theStepIndicatorKeepsOneFrameAndClearsEveryPageInEveryLanguageAndSize() throws {
        for language in languages {
            for size in [TextSize.smallest, .standard, .maximum] {
                let name = "\(language) at \(size.rawValue)"
                let rig = Rig(language: language, size: size)
                defer { rig.close() }
                rig.content.layoutSubtreeIfNeeded()
                let steps = rig.steps
                let frame = steps.frame
                #expect(frame.maxY == rig.content.bounds.height, "touches the window top in \(name)")
                #expect(abs(rig.rect(of: steps).midX - rig.content.bounds.midX) * rig.scale < 1, "centred in \(name)")
                if size == .standard { #expect(frame.height == 68, "68 pt tall in \(name)") }
                if size == .maximum { #expect(frame.height > 68, "follows Text size in \(name)") }
                #expect(steps.dots.map(\.frame) == steps.geometry.hits, "the zones hold in \(name)")
                #expect(steps.geometry.hits[0].minY == steps.geometry.label.maxY, "the zones start under the label in \(name)")
                for page in 0..<4 {
                    rig.content.layoutSubtreeIfNeeded()
                    #expect(steps.frame == frame, "page \(page + 1) in \(name)")
                    #expect(steps.page == page && rig.controller.page.rawValue == page, "\(name)")
                    #expect(steps.text == opening(language, page), "label on page \(page + 1) in \(name)")
                    #expect(rig.content.bounds.height - rig.rect(of: rig.visiblePage).maxY >= rig.minimumTop, "page \(page + 1) clears the indicator in \(name)")
                    if page < 3 { rig.press() }
                }
            }
        }
    }

    @Test func theStepIndicatorTextIsTranslatedEnglishReadsStepTwoOfFour() {
        #expect(opening("en", 1) == "Step 2 of 4")
        for language in languages where language != "en" {
            #expect(opening(language, 1) != opening("en", 1), "\(language)")
            #expect(opening(language, 1).contains("2") && opening(language, 1).contains("4"), "\(language)")
        }
    }

    @Test func theStepGeometryFollowsTheFigmaNumbers() {
        let shape = WelcomeStepsGeometry(current: 1, count: 4, width: 600, labelHeight: 16, scale: 2, rightToLeft: false)
        #expect(shape.height == 68)
        #expect(shape.hits == [228, 264, 300, 336].map { CGRect(x: $0, y: 40, width: 36, height: 28) })
        #expect(shape.label == CGRect(x: 0, y: 24, width: 600, height: 16))
        #expect(shape.dots.map(\.rect.midX) == [246, 282, 318, 354])
        #expect(shape.dots.map(\.rect.midY) == [54, 54, 54, 54])
        #expect(shape.dots.map(\.rect.width) == [8, 10, 8, 8])
        #expect(shape.dots.map(\.state) == [.done, .current, .later, .later])
        #expect(shape.ring == CGRect(x: 274, y: 46, width: 16, height: 16))
        #expect(shape.lines.map(\.rect) == [254, 290, 326].map { CGRect(x: $0, y: 53, width: 20, height: 2) })
        #expect(shape.lines.map(\.isDone) == [true, false, false])
    }

    @Test func everyStepEdgeIsAWholeDevicePixelAtOneAndTwoTimes() {
        for (scale, label) in [(CGFloat(1), CGFloat(16)), (1, 21), (2, 16), (2, 20.5), (2, 21)] {
            for page in 0..<4 {
                for rightToLeft in [false, true] {
                    let shape = WelcomeStepsGeometry(current: page, count: 4, width: 240, labelHeight: label, scale: scale, rightToLeft: rightToLeft)
                    let rects = [shape.label, shape.ring] + shape.dots.map(\.rect) + shape.lines.map(\.rect) + shape.hits
                    for rect in rects {
                        for edge in [rect.minX, rect.maxX, rect.minY, rect.maxY] {
                            #expect(edge * scale == (edge * scale).rounded(), "\(rect) at \(scale)x, label \(label), page \(page)")
                        }
                    }
                    #expect(shape.height * scale == (shape.height * scale).rounded())
                }
            }
        }
    }

    @Test func rightToLeftPutsTheFirstStepAtTheRight() {
        let left = WelcomeStepsGeometry(current: 2, count: 4, width: 240, labelHeight: 16, scale: 2, rightToLeft: false)
        let right = WelcomeStepsGeometry(current: 2, count: 4, width: 240, labelHeight: 16, scale: 2, rightToLeft: true)
        #expect(left.dots.map(\.rect.midX) == left.dots.map(\.rect.midX).sorted())
        #expect(right.dots.map(\.rect.midX) == right.dots.map(\.rect.midX).sorted(by: >))
        #expect(right.dots.map(\.rect.midX) == left.dots.map { 240 - $0.rect.midX })
        #expect(right.lines.map(\.rect.midX) == left.lines.map { 240 - $0.rect.midX })
        #expect(right.dots.map(\.state) == left.dots.map(\.state))
        #expect(right.ring.midX == right.dots[2].rect.midX)
        #expect(right.hits.map(\.midX) == left.hits.map { 240 - $0.midX })
        #expect(right.hits.map(\.midX) == right.dots.map(\.rect.midX))
    }

    @Test func theStepIndicatorIsOneGroupOfFourDotButtonsAndTakesNoFirstFocus() {
        let rig = Rig()
        defer { rig.close() }
        let steps = rig.steps
        for page in 0..<4 {
            #expect(steps.isAccessibilityElement())
            #expect(steps.accessibilityRole() == .group)
            #expect(steps.accessibilityLabel() == steps.text && steps.text == opening("en", page))
            #expect(steps.accessibilityChildren()?.count == 4)
            for (index, dot) in steps.dots.enumerated() {
                #expect(dot.superview === steps)
                #expect(dot.title.isEmpty)
                #expect(dot.accessibilityIdentifier() == "welcome-step-\(index + 1)")
                #expect(dot.accessibilityLabel() == opening("en", index))
                #expect(dot.cell?.accessibilityRole() == .button)
                #expect(dot.isEnabled == (index != page && index <= page + 1), "dot \(index + 1) on page \(page + 1)")
                #expect(rig.window.initialFirstResponder !== dot)
            }
            #expect(!steps.acceptsFirstResponder && !steps.canBecomeKeyView)
            #expect(rig.window.initialFirstResponder !== steps)
            #expect(rig.window.initialFirstResponder !== rig.back)
            if page < 3 { rig.press() }
        }
        #expect(steps.mouseDownCanMoveWindow)
        steps.userInterfaceLayoutDirection = .rightToLeft
        #expect(steps.geometry.dots[0].rect.midX > steps.geometry.dots[3].rect.midX)
    }

    @Test func theFirstDotIsGreenAndTheSecondTheAccentColorOnPageTwoInLightAndDark() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rig = Rig()
            defer { rig.close() }
            rig.window.appearance = NSAppearance(named: appearance)
            rig.press()
            rig.content.layoutSubtreeIfNeeded()
            let steps = rig.steps
            func pixel(_ view: NSView, _ rect: CGRect) throws -> NSColor {
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                let factor = CGFloat(rep.pixelsWide) / view.bounds.width
                return try #require(rep.colorAt(x: Int(rect.midX * factor), y: Int(rect.midY * factor))?.usingColorSpace(.sRGB))
            }
            func reference(_ color: NSColor) throws -> NSColor {
                let fill = FillView(color)
                fill.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
                rig.content.addSubview(fill)
                defer { fill.removeFromSuperview() }
                return try pixel(fill, fill.bounds)
            }
            func same(_ a: NSColor, _ b: NSColor) -> Bool {
                abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02 && abs(a.blueComponent - b.blueComponent) < 0.02
            }
            let dots = steps.geometry.dots
            let first = try pixel(steps, dots[0].rect)
            let second = try pixel(steps, dots[1].rect)
            let green = try reference(.systemGreen)
            let accent = try reference(.controlAccentColor)
            #expect(first.alphaComponent > 0.9 && same(first, green), "\(first) is not \(green) in \(appearance.rawValue)")
            #expect(second.alphaComponent > 0.9 && same(second, accent), "\(second) is not \(accent) in \(appearance.rawValue)")
        }
    }

    @Test func nextShowsPageTwoOnlyWhenAccessIsOn() async throws {
        let waiting = AccessFixture()
        defer { waiting.clean() }
        _ = try await waiting.open()
        waiting.press()
        #expect(waiting.opened == [AccessModel.settingsURL])
        #expect(waiting.controller.page == .access)

        let reopen = AccessFixture(confirms: false)
        defer { reopen.clean() }
        _ = try await reopen.open()
        try await reopen.enter(.reopen)
        reopen.press()
        #expect(reopen.quits == 1)
        #expect(reopen.controller.page == .access)

        let granted = AccessFixture(granted: true, confirms: true)
        defer { granted.clean() }
        _ = try await granted.open()
        #expect(granted.prepares == 1 && granted.starts == 0)
        #expect(granted.action.title == text("Next"))
        #expect(granted.controller.page == .access)
        try await granted.settle()
        #expect(granted.controller.page == .access, "the page moved by itself")
        granted.press()
        #expect(granted.controller.page == .modes)
    }

    @Test func returnGoesOnFromEachPageAndOnlyPageFourFinishes() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        let controller = fixture.controller
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        for page in [WelcomeWindowController.Page.modes, .setup, .done] {
            try #require(window.performKeyEquivalent(with: event), "no button took Return before \(page)")
            #expect(controller.page == page)
            #expect(fixture.prepares == 1)
            #expect(fixture.starts == 0 && fixture.summons == 0)
            #expect(fixture.defaults.object(forKey: AccessModel.completedKey) == nil)
            #expect((window.firstResponder as? NSView)?.isHiddenOrHasHiddenAncestor != true)
        }
        #expect(fixture.action.title == text("Let's Go!"))
        try #require(window.performKeyEquivalent(with: event), "no button took Return on the last page")
        #expect(fixture.model.stage == .ready)
        #expect(fixture.prepares == 1)
        #expect(fixture.starts == 1 && fixture.summons == 1)
        #expect(fixture.model.welcome == nil)
    }

    @Test func letsGoWritesEveryChoiceBeforeTheCompletionAndAppliesTheLauncher() async throws {
        var applied: [Bool] = []
        var completedAtApply: [Bool] = []
        var store: UserDefaults?
        let fixture = AccessFixture(granted: true, confirms: true) { defaults in
            store = defaults
            return WelcomeTools(commandLine: .inert(), launcherIsOn: { true }, shortcut: { "⌃⇧F" }, applyLauncher: {
                applied.append($0)
                completedAtApply.append(store?.bool(forKey: AccessModel.completedKey) ?? true)
            })
        }
        defer { fixture.clean() }
        _ = try await fixture.open()
        let controller = fixture.controller
        fixture.press()
        controller.modeCards[1].radio.performClick(nil)
        fixture.press()
        flip(controller.setupBox.launcher)
        flip(controller.setupBox.menuBarIcon)
        controller.setupBox.tiles.tiles[2].performClick(nil)
        #expect(fixture.defaults.object(forKey: WindowMode.key) == nil, "a pick was written before Let's Go!")
        #expect(fixture.defaults.object(forKey: Theme.key) == nil, "a pick was written before Let's Go!")
        #expect(fixture.defaults.object(forKey: MenuBarIcon.key) == nil, "a pick was written before Let's Go!")
        fixture.press()
        #expect(applied.isEmpty)
        fixture.press()
        #expect(fixture.defaults.string(forKey: WindowMode.key) == WindowMode.normal.rawValue)
        #expect(fixture.defaults.string(forKey: Theme.key) == Theme.warmPaper.rawValue)
        #expect(fixture.defaults.object(forKey: MenuBarIcon.key) as? Bool == false)
        #expect(applied == [false])
        #expect(completedAtApply == [false])
        #expect(fixture.defaults.bool(forKey: AccessModel.completedKey))
        #expect(fixture.events == ["start", "summon"])
        #expect(fixture.prepares == 1)
        #expect(fixture.model.welcome == nil)
    }

    @Test func aDragDuringARepeatWelcomeSurvivesLetsGo() async throws {
        for dragAfter in 0...3 {
            let fixture = AccessFixture(granted: true, confirms: true) { defaults in
                defaults.set(true, forKey: MenuBarIcon.key)
                return .inert()
            }
            defer { fixture.clean() }
            _ = try await fixture.open()
            let controller = fixture.controller
            let name = "a drag after \(dragAfter) presses"
            for done in 0...3 {
                if done == dragAfter { fixture.defaults.set(false, forKey: MenuBarIcon.key) }
                if done < 3 { fixture.press() }
                if done == 1, dragAfter < 2 { #expect(controller.setupBox.menuBarIcon.state == .off, "\(name)") }
            }
            #expect(controller.page == .done, "\(name)")
            fixture.press()
            #expect(fixture.model.stage == .ready, "\(name)")
            #expect(fixture.defaults.object(forKey: MenuBarIcon.key) as? Bool == false, "\(name)")
        }
    }

    @Test func aSwitchMovedAfterADragWritesItsValue() async throws {
        let fixture = AccessFixture(granted: true, confirms: true) { defaults in
            defaults.set(true, forKey: MenuBarIcon.key)
            return .inert()
        }
        defer { fixture.clean() }
        _ = try await fixture.open()
        let controller = fixture.controller
        fixture.defaults.set(false, forKey: MenuBarIcon.key)
        fixture.press()
        fixture.press()
        #expect(controller.setupBox.menuBarIcon.state == .off)
        flip(controller.setupBox.menuBarIcon)
        fixture.press()
        fixture.press()
        #expect(fixture.defaults.object(forKey: MenuBarIcon.key) as? Bool == true)
    }

    @Test(arguments: [(true, true), (false, true), (true, false), (false, false)])
    func letsGoOpensTheHelperOnceUnlessTheIconAndTheShortcutAreBothOff(iconOn: Bool, launcherOn: Bool) async throws {
        let fixture = AccessFixture(granted: true, confirms: true) { liveTools($0) }
        defer { fixture.clean() }
        let spy = HelperStarterSpy()
        fixture.syncHelper = spy.starter(defaults: fixture.defaults).sync
        _ = try await fixture.open()
        let controller = fixture.controller
        fixture.press()
        fixture.press()
        if !iconOn { flip(controller.setupBox.menuBarIcon) }
        if !launcherOn { flip(controller.setupBox.launcher) }
        fixture.press()
        #expect(spy.opens.isEmpty && spy.syncs.isEmpty, "a sync ran before Let's Go!")
        fixture.press()
        #expect(fixture.model.stage == .ready)
        let runs = iconOn || launcherOn
        #expect(spy.opens.count == (runs ? 1 : 0))
        #expect(spy.opens.allSatisfy { !$0.activates })
        #expect(spy.syncs.count == (runs ? 0 : 1))
    }

    @Test func theOnePageWelcomeSyncsNothing() {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        let spy = HelperStarterSpy()
        fixture.syncHelper = spy.starter(defaults: fixture.defaults).sync
        fixture.model.completeWelcome(choices: nil)
        #expect(fixture.model.stage == .ready)
        #expect(spy.opens.isEmpty && spy.syncs.isEmpty)
    }

    @Test func aCloseOnAnyPageWritesNothingAndReopeningStartsOnPageOneWithStoredValues() async throws {
        for route in ["close", "escape"] {
            for presses in 0...5 {
                let usesBack = presses > 3
                let forward = usesBack ? presses - 3 : presses
                var applied: [Bool] = []
                let fixture = AccessFixture(granted: true, confirms: true) { _ in
                    WelcomeTools(commandLine: .inert(), launcherIsOn: { true }, shortcut: { "⌃⇧F" }, applyLauncher: { applied.append($0) })
                }
                defer { fixture.clean() }
                let window = try await fixture.open()
                let controller = fixture.controller
                controller.modeCards[1].radio.performClick(nil)
                flip(controller.setupBox.launcher)
                flip(controller.setupBox.menuBarIcon)
                controller.setupBox.tiles.tiles[3].performClick(nil)
                for _ in 0..<forward { fixture.press() }
                if usesBack {
                    fixture.back.performClick(nil)
                    #expect(controller.page.rawValue == forward - 1)
                }
                let stored = fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]
                if route == "close" { window.performClose(nil) } else { window.cancelOperation(nil) }
                let name = "\(route) after \(presses) presses"
                #expect(fixture.model.welcome == nil, "\(name)")
                #expect(applied.isEmpty, "\(name)")
                #expect(fixture.prepares == 1, "\(name)")
                #expect(fixture.starts == 0 && fixture.summons == 0, "\(name)")
                #expect(NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]) == NSDictionary(dictionary: stored), "\(name)")
                #expect(fixture.defaults.object(forKey: WindowMode.key) == nil, "\(name)")
                #expect(fixture.defaults.object(forKey: AccessModel.completedKey) == nil, "\(name)")

                _ = try await fixture.open()
                #expect(fixture.prepares == 1 && fixture.starts == 0, "\(name)")
                #expect(fixture.controller.page == .access, "\(name)")
                #expect(fixture.action.title == text("Next"), "\(name)")
                #expect(fixture.controller.choices == WelcomeChoices(mode: .simple, launcher: true, menuBarIcon: true, theme: .systemNative), "\(name)")
                #expect(fixture.controller.modeCards[0].radio.state == .on, "\(name)")
                #expect(fixture.controller.setupBox.menuBarIcon.state == .on, "\(name)")
            }
        }
    }

    @Test func theWelcomeOpensWithTheStoredValues() async throws {
        let fixture = AccessFixture(granted: true, confirms: true) { defaults in
            defaults.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
            defaults.set(Theme.midnightTeal.rawValue, forKey: Theme.key)
            defaults.set(false, forKey: MenuBarIcon.key)
            return WelcomeTools(commandLine: .inert(), launcherIsOn: { false }, shortcut: { "⌃⇧F" }, applyLauncher: { _ in })
        }
        defer { fixture.clean() }
        _ = try await fixture.open()
        let controller = fixture.controller
        #expect(controller.choices == WelcomeChoices(mode: .normal, launcher: false, menuBarIcon: false, theme: .midnightTeal))
        #expect(controller.modeCards.map(\.isOn) == [false, true])
        #expect(controller.setupBox.launcher.state == .off)
        #expect(controller.setupBox.menuBarIcon.state == .off)
        #expect(controller.setupBox.tiles.tiles.filter { $0.state == .on }.map(\.theme) == [.midnightTeal])
    }

    private func liveTools(_ defaults: UserDefaults) -> WelcomeTools {
        let hotkey = HotkeyModel(defaults: defaults, windows: { [] }, unhide: {}, activate: {}, layoutNotifications: NotificationCenter())
        return .live(commandLine: .inert(), hotkey: hotkey)
    }

    @Test func aFreshStoreWithTheSwitchOnWritesNoShortcut() async throws {
        let fixture = AccessFixture(granted: true, confirms: true) { liveTools($0) }
        defer { fixture.clean() }
        _ = try await fixture.open()
        #expect(fixture.controller.setupBox.launcher.state == .on)
        try fixture.complete()
        #expect(fixture.model.stage == .ready)
        #expect(fixture.defaults.object(forKey: HotkeyModel.defaultsKey) == nil)
    }

    @Test func theSwitchOffStoresNoShortcut() async throws {
        let fixture = AccessFixture(granted: true, confirms: true) { liveTools($0) }
        defer { fixture.clean() }
        _ = try await fixture.open()
        flip(fixture.controller.setupBox.launcher)
        try fixture.complete()
        #expect(fixture.defaults.data(forKey: HotkeyModel.defaultsKey)?.isEmpty == true)
    }

    @Test func theSwitchOnAfterOffStoresControlShiftF() async throws {
        let fixture = AccessFixture(granted: true, confirms: true) { defaults in
            defaults.set(Data(), forKey: HotkeyModel.defaultsKey)
            return liveTools(defaults)
        }
        defer { fixture.clean() }
        _ = try await fixture.open()
        let launcher = fixture.controller.setupBox.launcher
        #expect(launcher.state == .off)
        flip(launcher)
        try fixture.complete()
        let data = try #require(fixture.defaults.data(forKey: HotkeyModel.defaultsKey))
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == Hotkey.summon)
    }

    @Test func theLauncherCaptionEndsWithTheShortcut() throws {
        let rig = Rig(tools: WelcomeTools(commandLine: .inert(), launcherIsOn: { true }, shortcut: { "⌃⌥K" }, applyLauncher: { _ in }))
        defer { rig.close() }
        let press = text("Press it in any app to search your files.", table: "Settings")
        let caption = descendants(of: rig.content).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix(press) }
        #expect(caption?.stringValue == press + "\u{2002}⌃⌥K")
        #expect(rig.controller.setupBox.launcher.accessibilityHelp() == press + " ⌃⌥K")
    }

    @Test func theTwoModeCardsReadAsOneRadioGroupNamedByTheHeading() throws {
        let rig = Rig()
        defer { rig.close() }
        let cards = rig.controller.modeCards
        let group = try #require(cards.first?.superview)
        #expect(cards.allSatisfy { $0.superview === group && $0.radio.isDescendant(of: group) })
        #expect(group.isAccessibilityElement())
        #expect(group.accessibilityRole() == .radioGroup)
        #expect(group.accessibilityLabel() == text("Choose Your Mode"))
        #expect(group.accessibilityIdentifier() == "welcome-modes")
        rig.press()
        #expect(group.accessibilityLabel() == rig.visiblePage.heading)
    }

    @Test func installInTheBoxActsAtOnceAndTheBoxFollowsTheModel() async throws {
        let folder = try ToolFolder()
        defer { folder.close() }
        let model = folder.model()
        let rig = Rig(tools: WelcomeTools(commandLine: model, launcherIsOn: { true }, shortcut: { "⌃⇧F" }, applyLauncher: { _ in }))
        defer { rig.close() }
        let box = rig.controller.toolBox
        rig.press()
        let notInstalled = text("Search from the command line with the wherever command.", table: "Settings")
        func shown(_ line: String) -> Bool { visibleLeaves(of: rig.content).contains { ($0 as? NSTextField)?.stringValue == line } }
        #expect(box.action.title == text("Install", table: "Settings"))
        #expect(box.uninstall.isHidden)
        #expect(shown(notInstalled))
        #expect(box.action.accessibilityHelp() == notInstalled)

        box.action.performClick(nil)
        try await untilTrue(waitingFor: "the install") { model.isOn && model.linked && !model.busy }
        #expect(FileManager.default.fileExists(atPath: folder.link))
        #expect(box.action.title == text("Uninstall", table: "Settings"))
        #expect(box.uninstall.isHidden)
        #expect(!shown(notInstalled))
        #expect(rig.access.stage == .granted && rig.controller.page == .modes)
        let installed = String(format: text("Installed at %@.", table: "Settings"), Bidi.path(folder.link)) + " "
            + text("Open a new Terminal window to use it.", table: "Settings")
        #expect(shown(installed))
        #expect(box.action.accessibilityHelp() == installed)

        try FileManager.default.removeItem(atPath: folder.link)
        model.refresh()
        #expect(box.action.title == text("Install", table: "Settings"))
        #expect(!box.uninstall.isHidden)
        #expect(shown(text("The wherever command is missing. Install it again.", table: "Settings")))

        box.uninstall.performClick(nil)
        try await untilTrue(waitingFor: "the uninstall") { !model.isOn && !model.busy }
        #expect(box.action.title == text("Install", table: "Settings"))
        #expect(box.uninstall.isHidden)
        #expect(shown(notInstalled))
    }

    @Test func anUnwritableFolderInTheBoxShowsTheFailureAndAddsNoPathBlock() async throws {
        let folder = try ToolFolder()
        defer { folder.close() }
        try folder.lock()
        let model = folder.model()
        let rig = Rig(tools: WelcomeTools(commandLine: model, launcherIsOn: { true }, shortcut: { "⌃⇧F" }, applyLauncher: { _ in }))
        defer { rig.close() }
        rig.press()
        let box = rig.controller.toolBox
        box.action.performClick(nil)
        try await untilTrue(waitingFor: "the run to end") { !model.busy && model.notice != nil }
        #expect(box.action.isEnabled)
        #expect(model.notice == .installFailed)
        #expect(!FileManager.default.fileExists(atPath: folder.profile.path(percentEncoded: false)))
    }

    @Test func installOnPageTwoAfterTheGrantServesAtOnceAndLetsGoAddsNoSecondServe() async throws {
        let folder = try ToolFolder()
        defer { folder.close() }
        let model = folder.model()
        var serves: [Bool] = []
        let fixture = AccessFixture(confirms: true) { _ in
            WelcomeTools(commandLine: model, launcherIsOn: { true }, shortcut: { "⌃⇧F" }, applyLauncher: { _ in })
        }
        defer { fixture.clean() }
        var attaches = 0
        let engine = BuiltOnce<NSObject> {
            attaches += 1
            model.attach { serves.append($0) }
            return NSObject()
        }
        fixture.onPrepare = WhereverApp.prepareAction(previews: false, engine: engine)
        fixture.onStart = { _ = try engine.value() }
        _ = try await fixture.open()
        fixture.spy.set(true)
        await fixture.model.tick()
        #expect(attaches == 1 && serves.isEmpty)
        fixture.press()
        #expect(fixture.controller.page == .modes)
        fixture.controller.toolBox.action.performClick(nil)
        try await untilTrue(waitingFor: "the install") { model.isOn }
        #expect(serves == [true], "the socket waited for Let's Go!")
        #expect(fixture.starts == 0 && fixture.summons == 0)
        try fixture.complete()
        #expect(fixture.model.stage == .ready)
        #expect(attaches == 1 && serves == [true])
    }

    @Test func letsGoInstallsNothing() async throws {
        let folder = try ToolFolder()
        defer { folder.close() }
        let model = folder.model()
        let fixture = AccessFixture(granted: true, confirms: true) { _ in
            WelcomeTools(commandLine: model, launcherIsOn: { true }, shortcut: { "⌃⇧F" }, applyLauncher: { _ in })
        }
        defer { fixture.clean() }
        _ = try await fixture.open()
        try fixture.complete()
        try await fixture.settle()
        #expect(fixture.model.stage == .ready)
        #expect(!model.isOn && !model.linked && !model.busy)
        #expect(!FileManager.default.fileExists(atPath: folder.profile.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: folder.link))
        #expect(folder.defaults.object(forKey: CommandLineToolModel.key) == nil)
    }

    @Test func aStageChangeBringsPageOneBackAndAReturnKeepsThePicks() async throws {
        for presses in 1...3 {
            let fixture = AccessFixture(granted: true, confirms: true)
            defer { fixture.clean() }
            let window = try await fixture.open()
            let controller = fixture.controller
            controller.modeCards[1].radio.performClick(nil)
            flip(controller.setupBox.menuBarIcon)
            for _ in 0..<presses { fixture.press() }
            let status = try #require(descendants(of: window.contentView!).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "welcome-status" })
            #expect(status.isHidden, "the status line stays hidden after \(presses) presses")
            let height = window.frame.height

            fixture.confirms = false
            fixture.model.completeWelcome(choices: controller.choices)
            #expect(fixture.model.stage == .reopen)
            #expect(controller.page == .access)
            #expect(!status.isHidden)
            #expect(status.stringValue == text("Quit and reopen Wherever so it can search every folder."))
            #expect(fixture.action.title == text("Quit Wherever", table: "MenuBar"))
            #expect(!fixture.back.isEnabled, "Back stays on after \(presses) presses")
            #expect(fixture.steps.dots.allSatisfy { !$0.isEnabled }, "a dot stays on after \(presses) presses")
            #expect(window.frame.height == height)
            #expect(fixture.defaults.object(forKey: WindowMode.key) == nil, "a failed Let's Go! wrote the mode")

            fixture.confirms = true
            fixture.model.refresh()
            #expect(fixture.model.stage == .granted)
            #expect(controller.page == .access)
            #expect(fixture.action.title == text("Next"))
            #expect(fixture.steps.dots.map(\.isEnabled) == (0..<4).map { $0 != 0 && $0 <= presses + 1 })
            #expect(!fixture.back.isEnabled)
            fixture.press()
            #expect(controller.page == .modes)
            #expect(controller.modeCards.map(\.isOn) == [false, true])
            #expect(controller.setupBox.menuBarIcon.state == .off)
            #expect(controller.choices.mode == .normal && !controller.choices.menuBarIcon)
        }

        let failing = AccessFixture(granted: true, confirms: true, startError: .io)
        defer { failing.clean() }
        _ = try await failing.open()
        try failing.complete()
        #expect(failing.model.stage == .startFailed)
        #expect(failing.controller.page == .access)
        #expect(failing.action.title == text("Quit Wherever", table: "MenuBar"))
    }

    private func click(_ card: ModeCard) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        card.mouseDown(with: event)
    }

    @Test func aClickAnywhereOnACardPicksItAndBothPicturesKeepLooping() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        let controller = fixture.controller
        let cards = controller.modeCards
        let (simple, normal) = (cards[0], cards[1])
        for card in cards {
            card.picture.reduceMotion = { false }
            card.picture.isShown = { _ in true }
        }
        #expect(!looping(simple.picture) && !looping(normal.picture), "a hidden page looped")
        fixture.press()
        let started = cards.map { clock($0.picture) }
        #expect(started.allSatisfy { !$0.isEmpty }, "a picture did not start looping on the visible page")
        func expectPicked(_ on: ModeCard, _ off: ModeCard, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(controller.choices.mode == on.mode, sourceLocation: sourceLocation)
            #expect(on.isOn && !off.isOn, sourceLocation: sourceLocation)
            #expect(on.radio.state == .on && off.radio.state == .off, sourceLocation: sourceLocation)
            #expect(looping(on.picture) && looping(off.picture), sourceLocation: sourceLocation)
            for (card, first) in zip(cards, started) {
                let now = clock(card.picture)
                #expect(now.count == first.count && zip(now, first).allSatisfy { $0 === $1 && $0.beginTime == $1.beginTime }, "a pick restarted a loop", sourceLocation: sourceLocation)
            }
        }
        expectPicked(simple, normal)

        let middle = NSPoint(x: normal.frame.midX, y: normal.frame.maxY - WelcomeMetrics.cardPadding - 10)
        #expect(normal.hitTest(middle) === normal, "the picture took the click")
        #expect(!normal.mouseDownCanMoveWindow)
        let radioFrame = normal.radio.frame
        let pictureFrame = normal.picture.frame
        try click(normal)
        expectPicked(normal, simple)
        normal.layoutSubtreeIfNeeded()
        #expect(normal.radio.frame == radioFrame && normal.picture.frame == pictureFrame, "the pick moved the content")

        try click(normal)
        expectPicked(normal, simple)
        normal.radio.performClick(nil)
        expectPicked(normal, simple)

        simple.radio.performClick(nil)
        expectPicked(simple, normal)

        if NSApp.isFullKeyboardAccessEnabled {
            let space = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49
            ))
            normal.radio.keyDown(with: space)
        } else {
            #expect(AXTree.press(normal.radio))
        }
        expectPicked(normal, simple)
        #expect(fixture.model.stage == .granted)

        fixture.press()
        #expect(!looping(simple.picture) && !looping(normal.picture), "the picture kept looping behind page 3")
    }

    private func beginTimes(_ picture: ModePictureView) -> [CFTimeInterval] {
        clock(picture).map(\.beginTime)
    }

    @Test func bothPicturesKeepOneClockAcrossARestart() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        let (simple, normal) = (fixture.controller.modeCards[0].picture, fixture.controller.modeCards[1].picture)
        for picture in [simple, normal] {
            picture.reduceMotion = { false }
            picture.isShown = { _ in true }
        }
        fixture.press()
        let shared = try #require(beginTimes(normal).first)
        #expect(shared != 0 && abs(shared - CACurrentMediaTime()) < 1, "the begin time is the arrival, not zero")
        for picture in [simple, normal] {
            let times = beginTimes(picture)
            #expect(!times.isEmpty && times.allSatisfy { abs($0 - shared) < 0.001 }, "both pictures start from one begin time")
        }

        simple.isShown = { _ in false }
        #expect(!looping(simple) && looping(normal))
        try await Task.sleep(for: .milliseconds(200))
        simple.isShown = { _ in true }
        let again = beginTimes(simple)
        #expect(!again.isEmpty && again.allSatisfy { abs($0 - shared) < 0.001 }, "the restart took a later begin time")
    }

    @Test func eachArrivalAtPageTwoStartsFromEmpty() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        let controller = fixture.controller
        let simple = controller.modeCards[0].picture
        for card in controller.modeCards {
            card.picture.reduceMotion = { false }
            card.picture.isShown = { _ in true }
        }
        fixture.press()
        let old = try #require(beginTimes(simple).first)

        fixture.confirms = false
        fixture.model.completeWelcome(choices: controller.choices)
        #expect(controller.page == .access && !looping(simple))
        try await Task.sleep(for: .milliseconds(200))
        fixture.confirms = true
        fixture.model.refresh()
        fixture.press()
        #expect(controller.page == .modes)
        let new = try #require(beginTimes(simple).first)
        #expect(new > old + 0.1, "the arrival kept the old start")
        #expect(abs(new - CACurrentMediaTime()) < 1, "the arrival did not start from now")
        for card in controller.modeCards {
            #expect(beginTimes(card.picture).allSatisfy { abs($0 - new) < 0.001 })
        }
    }

    @Test func theCardBorderIsTwoPointsOfAccentWhenOnAndFollowsAColorChange() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.press()
        let card = rig.controller.modeCards[1]
        rig.content.layoutSubtreeIfNeeded()
        func edge() throws -> NSColor {
            let rep = try #require(card.bitmapImageRepForCachingDisplay(in: card.bounds))
            card.cacheDisplay(in: card.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / card.bounds.width
            return try #require(rep.colorAt(x: Int(1.5 * scale), y: rep.pixelsHigh / 2))
        }
        let off = try edge()
        card.isOn = true
        let on = try edge()
        #expect(on != off)
        card.isOn = false
        #expect(try edge() == off)
    }

    @Test func aColorChangeMarksTheCardForDrawing() {
        let box = RecordingBox()
        box.marked = false
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        #expect(box.marked, "an accent change left the old border")
    }

    @Test func thePageThreeSwitchesAreMini() {
        let rig = Rig()
        defer { rig.close() }
        #expect(rig.controller.setupBox.launcher.controlSize == .mini)
        #expect(rig.controller.setupBox.menuBarIcon.controlSize == .mini)
    }

    @Test func theWindowMovesByItsBackgroundOnEveryPage() {
        let rig = Rig()
        defer { rig.close() }
        for page in WelcomeWindowController.Page.allCases {
            while rig.controller.page != page { rig.press() }
            #expect(rig.window.isMovableByWindowBackground, "\(page)")
        }
    }

    @Test func theTabOrderStaysInsideTheVisiblePage() throws {
        let rig = Rig()
        defer { rig.close() }
        let controller = rig.controller
        let setup = controller.setupBox
        func stops() throws -> [ObjectIdentifier] {
            let first = try #require(rig.window.initialFirstResponder)
            var views = [first]
            var next = first.nextKeyView
            while let view = next, view !== first, views.count < 20 {
                views.append(view)
                next = view.nextKeyView
            }
            #expect(next === first, "the loop does not close")
            return views.filter { !$0.isHiddenOrHasHiddenAncestor }.map { ObjectIdentifier($0) }
        }
        func ids(_ views: [NSView]) -> [ObjectIdentifier] { views.map { ObjectIdentifier($0) } }
        let radios = controller.modeCards.map { $0.radio as NSView }
        let tiles = setup.tiles.tiles.map { $0 as NSView }
        let row = [rig.back as NSView, rig.action]
        let dots = rig.steps.dots.map { $0 as NSView }
        func offRow(_ line: Int = #line) {
            let first = rig.window.firstResponder as? NSView
            #expect(first !== rig.back && !dots.contains { $0 === first }, "first focus on \(String(describing: first)) at line \(line)")
        }
        #expect(try stops() == ids([rig.action] + dots + [rig.back]))
        #expect(rig.window.initialFirstResponder === rig.action)
        offRow()
        #expect((radios + tiles).allSatisfy { $0.isHiddenOrHasHiddenAncestor })
        rig.press()
        #expect(try stops() == ids(radios + [controller.toolBox.action] + row + dots))
        offRow()
        #expect(([setup.launcher, setup.menuBarIcon] + tiles).allSatisfy { $0.isHiddenOrHasHiddenAncestor })
        rig.press()
        #expect(try stops() == ids([setup.launcher, setup.menuBarIcon] + tiles + row + dots))
        offRow()
        #expect((radios + [controller.toolBox.action]).allSatisfy { $0.isHiddenOrHasHiddenAncestor })
        rig.press()
        #expect(try stops() == ids([rig.action] + dots + [rig.back]))
        #expect(rig.window.initialFirstResponder === rig.action)
        offRow()
        #expect((radios + tiles + [setup.launcher]).allSatisfy { $0.isHiddenOrHasHiddenAncestor })
    }

    @Test func voiceOverHearsEachHeadingAndEachControlHasItsIdentifierAndName() async throws {
        let rig = Rig()
        defer { rig.close() }
        #expect(rig.heard.posts.isEmpty, "the first page spoke")
        rig.press()
        #expect(rig.heard.posts == [text("Choose Your Mode")])
        rig.press()
        #expect(rig.heard.posts == [text("Choose Your Mode"), text("Set Up Wherever")])
        rig.press()
        #expect(rig.heard.posts == [text("Choose Your Mode"), text("Set Up Wherever"), text("You’re All Set")])
        try await realPress(rig.back, in: rig.window)
        #expect(rig.heard.posts.last == text("Set Up Wherever"), "Back did not speak the heading")
        try pressDot(rig.steps.dots[0], in: rig.window)
        #expect(rig.heard.posts.last == text("Welcome to Wherever!"), "a dot did not speak the heading")
        #expect(rig.heard.posts.count == 5)
        #expect(rig.back.accessibilityIdentifier() == "welcome-back")
        #expect(rig.back.title == text("Back"))
        let controller = rig.controller
        #expect(controller.modeCards.map { $0.radio.accessibilityIdentifier() } == ["welcome-mode-simple", "welcome-mode-normal"])
        #expect(controller.modeCards.map { $0.radio.title } == [text("Simple", table: "Localizable"), text("Normal", table: "Localizable")])
        #expect(controller.modeCards.allSatisfy { $0.radio.cell?.accessibilityRole() == .radioButton })
        #expect(controller.toolBox.action.accessibilityIdentifier() == "welcome-tool")
        let setup = controller.setupBox
        #expect(setup.launcher.accessibilityIdentifier() == "welcome-launcher")
        #expect(setup.launcher.accessibilityLabel() == text("Launcher shortcut"))
        #expect(setup.launcher.accessibilityHelp() == text("Press it in any app to search your files.", table: "Settings") + " " + Hotkey.summon.displayString)
        #expect(setup.menuBarIcon.accessibilityIdentifier() == "welcome-menu-bar-icon")
        #expect(setup.menuBarIcon.accessibilityLabel() == text("Show Menu Bar Icon", table: "Settings"))
        #expect(setup.tiles.accessibilityIdentifier() == ThemePicker.id)
    }

    @Test func theLargestTextSizeScalesEveryPage() throws {
        let rig = Rig(size: .maximum)
        defer { rig.close() }
        let controller = rig.controller
        #expect(controller.modeCards.allSatisfy { $0.radio.font?.pointSize == 18 })
        #expect(controller.toolBox.action.font?.pointSize == 18)
        func fonts(_ view: NSView) -> [CGFloat] {
            descendants(of: view).compactMap { ($0 as? NSTextField)?.font?.pointSize }
        }
        #expect(fonts(controller.toolBox).contains(18))
        #expect(fonts(controller.toolBox).contains(17))
        rig.press()
        #expect(rig.visiblePage.heading == text("Choose Your Mode"))
        #expect(fonts(rig.visiblePage).prefix(2) == [39, 24])
    }

    private func expectOneRow(_ rig: Rig, back: CGRect, action: CGRect, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        rig.content.layoutSubtreeIfNeeded()
        #expect(rig.back.frame == back, "Back moved in \(name)", sourceLocation: sourceLocation)
        #expect(rig.action.frame == action, "Next moved in \(name)", sourceLocation: sourceLocation)
    }

    @Test func backAndNextShareOneRowOnEveryPageInEveryLanguageSizeAndStage() throws {
        for language in languages {
            for size in [TextSize.smallest, .standard, .maximum] {
                let name = "\(language) at \(size.rawValue)"
                let rig = Rig(language: language, size: size)
                defer { rig.close() }
                rig.content.layoutSubtreeIfNeeded()
                let (back, action) = (rig.back.frame, rig.action.frame)
                let scale = rig.scale
                #expect(back.minY == action.minY && back.height == action.height, "one height and one line in \(name)")
                #expect(back.width >= WelcomeMetrics.backMinWidth && action.width >= WelcomeMetrics.buttonMinWidth, "\(name)")
                #expect(rig.back.intrinsicContentSize.width <= back.width, "\(rig.back.title) is cut short in \(name)")
                #expect(((action.minX - back.maxX - WelcomeMetrics.buttonGap) * scale).rounded() == 0, "the gap in \(name)")
                #expect(((back.minX - (WelcomeMetrics.width - action.maxX)) * scale).rounded() == 0, "the margins differ in \(name)")
                #expect(back.minX >= WelcomeMetrics.titleMargin, "the row leaves its margins in \(name)")
                for edge in [back.minX, back.maxX, action.minX, action.maxX, back.minY, back.maxY] {
                    #expect((edge * scale).rounded() == edge * scale, "\(edge) is not a whole device pixel in \(name)")
                }
                #expect(rig.back.font?.pointSize == rig.action.font?.pointSize, "\(name)")
                #expect(rig.back.controlSize == .large && rig.back.bezelStyle == .push, "\(name)")
                #expect(rig.back.keyEquivalent.isEmpty, "\(name)")
                for page in [WelcomeWindowController.Page.modes, .setup, .done] {
                    rig.press()
                    #expect(rig.controller.page == page, "\(name)")
                    expectOneRow(rig, back: back, action: action, "\(page) in \(name)")
                }
                for stage in Self.otherStages {
                    let other = Rig(stage: stage, language: language, size: size)
                    defer { other.close() }
                    expectOneRow(other, back: back, action: action, "\(stage) in \(name)")
                }
            }
        }
    }

    @Test func backGoesToThePageBeforeAndRetitlesNext() async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.controller.modeCards[1].radio.performClick(nil)
        rig.press()
        #expect(rig.status.isHidden)
        #expect(rig.back.isEnabled)
        try await realPress(rig.back, in: rig.window)
        #expect(rig.controller.page == .access)
        #expect(rig.action.title == text("Next"))
        #expect(!rig.status.isHidden, "page 1 lost its line")
        #expect(!rig.back.isEnabled)
        #expect(rig.heard.posts.last == text("Welcome to Wherever!"))

        try #require(try returnKey(rig.window), "no button took Return")
        #expect(rig.controller.page == .modes)
        #expect(rig.heard.opens == 0, "Return opened System Settings")
        #expect(rig.controller.choices.mode == .normal)

        rig.press()
        rig.press()
        #expect(rig.controller.page == .done)
        #expect(rig.action.title == text("Let's Go!"))
        try await realPress(rig.back, in: rig.window)
        #expect(rig.controller.page == .setup)
        #expect(rig.action.title == text("Next"))
        #expect(rig.access.stage == .granted)
    }

    @Test func backIsDimmedOnPageOneInEveryStage() async throws {
        for stage in Self.otherStages + [.granted] {
            let rig = Rig(stage: stage)
            defer { rig.close() }
            let title = rig.action.title
            let posts = rig.heard.posts
            #expect(!rig.back.isEnabled, "\(stage)")
            #expect(!rig.back.isHidden, "\(stage)")
            try await realPress(rig.back, in: rig.window)
            #expect(AXTree.press(rig.back), "\(stage)")
            #expect(rig.controller.page == .access, "\(stage)")
            #expect(rig.action.title == title, "\(stage)")
            #expect(rig.heard.posts == posts && rig.heard.opens == 0 && rig.heard.quits == 0, "\(stage)")
        }
        let rig = Rig()
        defer { rig.close() }
        rig.press()
        #expect(AXTree.press(rig.back), "the positive case")
        #expect(rig.controller.page == .access, "an AX press on a live Back did nothing")
    }

    @Test func backAndNextKeepEveryPick() async throws {
        let rig = Rig()
        defer { rig.close() }
        let controller = rig.controller
        let setup = controller.setupBox
        rig.press()
        controller.modeCards[1].radio.performClick(nil)
        rig.press()
        flip(setup.launcher)
        flip(setup.menuBarIcon)
        setup.tiles.tiles[2].performClick(nil)
        let picks = controller.choices
        let tool = controller.toolBox.action.title
        #expect(picks.mode == .normal && !picks.launcher && !picks.menuBarIcon && picks.theme == .warmPaper)
        func expectKept(sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(controller.choices == picks, sourceLocation: sourceLocation)
            #expect(controller.modeCards.map(\.isOn) == [false, true], sourceLocation: sourceLocation)
            #expect(setup.launcher.state == .off && setup.menuBarIcon.state == .off, sourceLocation: sourceLocation)
            #expect(setup.tiles.tiles.filter { $0.state == .on }.map(\.theme) == [.warmPaper], sourceLocation: sourceLocation)
            #expect(controller.toolBox.action.title == tool, sourceLocation: sourceLocation)
        }
        try await realPress(rig.back, in: rig.window)
        #expect(controller.page == .modes)
        expectKept()
        rig.press()
        #expect(controller.page == .setup)
        expectKept()
        try await realPress(rig.back, in: rig.window)
        try await realPress(rig.back, in: rig.window)
        #expect(controller.page == .access)
        expectKept()
    }

    @Test func aDotJumpsForwardAndBackWithAccessOn() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        let controller = fixture.controller
        let dots = fixture.steps.dots
        for card in controller.modeCards {
            card.picture.reduceMotion = { false }
            card.picture.isShown = { _ in true }
        }
        try pressDot(dots[1], in: window)
        #expect(controller.page == .modes, "dot 2 from page 1")
        #expect(dots.map(\.isEnabled) == [true, false, true, false])
        try pressDot(dots[2], in: window)
        #expect(controller.page == .setup, "dot 3 from page 2")
        try pressDot(dots[0], in: window)
        #expect(controller.page == .access, "dot 1 from page 3")
        #expect(!fixture.back.isEnabled)
        try pressDot(dots[3], in: window)
        #expect(controller.page == .done, "dot 4 from page 1 once page 3 was shown")
        #expect(fixture.action.title == text("Let's Go!"))
        #expect(fixture.starts == 0 && fixture.model.stage == .granted, "a dot finished the welcome")
        #expect(dots.map(\.isEnabled) == [true, true, true, false])

        let before = CACurrentMediaTime()
        try pressDot(dots[1], in: window)
        #expect(controller.page == .modes, "dot 2 from page 4")
        #expect(fixture.action.title == text("Next"))
        for card in controller.modeCards {
            let times = beginTimes(card.picture)
            #expect(!times.isEmpty && times.allSatisfy { $0 >= before }, "the pictures did not start from empty")
        }
        #expect(AXTree.press(dots[2]))
        #expect(controller.page == .setup, "an AX press on a live dot did nothing")
    }

    @Test func theCurrentDotDoesNothing() async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.press()
        let posts = rig.heard.posts
        let dot = rig.steps.dots[1]
        #expect(!dot.isEnabled)
        try pressDot(dot, in: rig.window)
        #expect(AXTree.press(dot))
        #expect(rig.controller.page == .modes)
        #expect(rig.heard.posts == posts, "the current dot spoke")
        try pressDot(rig.steps.dots[2], in: rig.window)
        #expect(rig.controller.page == .setup, "the partner dot did nothing")
    }

    @Test func noDotMovesWithoutAccess() async throws {
        for stage in Self.otherStages {
            let rig = Rig(stage: stage)
            defer { rig.close() }
            let title = rig.action.title
            for dot in rig.steps.dots {
                #expect(!dot.isEnabled, "\(stage)")
                try pressDot(dot, in: rig.window)
                #expect(AXTree.press(dot), "\(stage)")
            }
            #expect(rig.controller.page == .access, "\(stage)")
            #expect(rig.action.title == title, "\(stage)")
            #expect(rig.heard.opens == 0 && rig.heard.quits == 0, "a dot acted in \(stage)")
            #expect(rig.heard.posts.isEmpty, "a dot spoke in \(stage)")
            try #require(try returnKey(rig.window), "no button took Return in \(stage)")
            #expect(rig.heard.opens + rig.heard.quits == 1, "Return in \(stage)")
            #expect(rig.heard.quits == (stage == .reopen || stage == .startFailed ? 1 : 0), "Return in \(stage)")
            #expect(rig.controller.page == .access, "\(stage)")
        }
    }

    @Test func theGrantWakesTheDotsWithoutMoving() async throws {
        let fixture = AccessFixture()
        defer { fixture.clean() }
        _ = try await fixture.open()
        let steps = fixture.steps
        #expect(steps.dots.allSatisfy { !$0.isEnabled })
        let shape = steps.geometry
        let (next, nextLine) = (shape.dots[1].rect, shape.lines[0].rect)
        let (later, laterLine) = (shape.dots[2].rect, shape.lines[1].rect)
        let (faintNext, faintNextLine) = (try pixelAlpha(steps, next), try pixelAlpha(steps, nextLine))
        let (faintDot, faintLine) = (try pixelAlpha(steps, later), try pixelAlpha(steps, laterLine))
        try await fixture.enter(.granted)
        #expect(fixture.controller.page == .access, "the grant moved the page")
        #expect(fixture.action.title == text("Next"))
        #expect(steps.dots.map(\.isEnabled) == [false, true, false, false])
        #expect(try pixelAlpha(steps, next) > faintNext, "the dot did not brighten")
        #expect(try pixelAlpha(steps, nextLine) > faintNextLine, "the line did not brighten")
        #expect(try pixelAlpha(steps, later) == faintDot, "a dead dot brightened")
        #expect(try pixelAlpha(steps, laterLine) == faintLine, "the line into a dead dot brightened")
        #expect(!fixture.back.isEnabled)
    }

    @Test func aForwardDotReachesOnlyPagesAlreadyShownAndTheNextOne() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        let steps = fixture.steps
        let (shape, dots) = (steps.geometry, steps.dots)
        #expect(fixture.controller.page == .access)
        #expect(dots.map(\.isEnabled) == [false, true, false, false])
        let faint = try pixelAlpha(steps, shape.dots[2].rect)
        #expect(try pixelAlpha(steps, shape.dots[1].rect) > faint, "the live dot looks dead")
        #expect(try pixelAlpha(steps, shape.dots[3].rect) == faint, "dot 4 looks unlike dot 3")
        let faintLine = try pixelAlpha(steps, shape.lines[1].rect)
        #expect(try pixelAlpha(steps, shape.lines[0].rect) > faintLine, "the line into the live dot looks dead")
        #expect(try pixelAlpha(steps, shape.lines[2].rect) == faintLine, "the line into dot 4 looks unlike the line into dot 3")
    }

    @Test func aDeadDotDoesNothingByMouseVoiceOverOrADirectCall() throws {
        let rig = Rig()
        defer { rig.close() }
        let dots = rig.steps.dots
        func expectStill(_ how: String) {
            #expect(rig.controller.page == .access, "\(how) moved the page")
            #expect(rig.heard.posts.isEmpty, "\(how) spoke")
            #expect(rig.action.title == text("Next"), "\(how) retitled the button")
        }
        try pressDot(dots[2], in: rig.window)
        expectStill("dot 3")
        try pressDot(dots[3], in: rig.window)
        expectStill("dot 4")
        #expect(AXTree.press(dots[3]))
        expectStill("an AX press on dot 4")
        rig.steps.onStep?(3)
        expectStill("a direct call for page 4")
        rig.steps.onStep?(2)
        expectStill("a direct call for page 3")
    }

    @Test func tabSkipsADeadDot() {
        let rig = Rig()
        defer { rig.close() }
        for dot in rig.steps.dots[2...] {
            #expect(!dot.isEnabled)
            #expect(!dot.canBecomeKeyView)
        }
    }

    @Test func aDotToTheNextPageMovesAndWidensTheReachOnePageAtATime() throws {
        let rig = Rig()
        defer { rig.close() }
        let dots = rig.steps.dots
        try pressDot(dots[1], in: rig.window)
        #expect(rig.controller.page == .modes)
        #expect(dots.map(\.isEnabled) == [true, false, true, false])
        rig.press()
        #expect(rig.controller.page == .setup)
        #expect(dots.map(\.isEnabled) == [true, true, false, true])
    }

    @Test func dotFourFromPageThreeLeadsToLetsGoAndWritesTheChoices() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        let dots = fixture.steps.dots
        #expect(dots.map(\.isEnabled) == [false, true, false, false])
        fixture.press()
        fixture.press()
        fixture.controller.modeCards[1].radio.performClick(nil)
        try pressDot(dots[3], in: window)
        #expect(fixture.controller.page == .done)
        #expect(dots.map(\.isEnabled) == [true, true, true, false])
        fixture.press()
        #expect(fixture.model.stage == .ready)
        #expect(fixture.defaults.string(forKey: WindowMode.key) == WindowMode.normal.rawValue)
        #expect(fixture.defaults.bool(forKey: AccessModel.completedKey))
    }

    @Test func backFromPageTwoKeepsTheReachSoDotThreeMovesAndDotFourDoesNot() async throws {
        let rig = Rig()
        defer { rig.close() }
        let dots = rig.steps.dots
        rig.press()
        try await realPress(rig.back, in: rig.window)
        #expect(rig.controller.page == .access)
        #expect(dots.map(\.isEnabled) == [false, true, true, false])
        let posts = rig.heard.posts
        try pressDot(dots[3], in: rig.window)
        rig.steps.onStep?(3)
        #expect(rig.controller.page == .access, "dot 4 crossed a page not yet shown")
        #expect(rig.heard.posts == posts)
        try pressDot(dots[2], in: rig.window)
        #expect(rig.controller.page == .setup, "dot 3 did nothing")
    }

    @Test func aJumpOverPagesAlreadyShownMoves() throws {
        let rig = Rig()
        defer { rig.close() }
        let dots = rig.steps.dots
        #expect(!dots[3].isEnabled)
        rig.press()
        rig.press()
        rig.press()
        try pressDot(dots[0], in: rig.window)
        #expect(rig.controller.page == .access)
        #expect(dots.map(\.isEnabled) == [false, true, true, true])
        try pressDot(dots[3], in: rig.window)
        #expect(rig.controller.page == .done, "the jump crosses only pages already shown")
    }

    @Test func aStageChangeKeepsThePagesAlreadyShown() async throws {
        for (presses, reopened) in [(1, [false, true, true, false]), (2, [false, true, true, true])] {
            let fixture = AccessFixture()
            defer { fixture.clean() }
            _ = try await fixture.open()
            try await fixture.enter(.granted)
            let dots = fixture.steps.dots
            for _ in 0..<presses { fixture.press() }

            fixture.confirms = false
            fixture.model.completeWelcome(choices: fixture.controller.choices)
            #expect(fixture.model.stage == .reopen)
            #expect(fixture.controller.page == .access)
            #expect(dots.allSatisfy { !$0.isEnabled }, "a dot stays on after \(presses) presses")

            fixture.confirms = true
            fixture.model.refresh()
            #expect(fixture.model.stage == .granted)
            #expect(fixture.controller.page == .access)
            #expect(dots.map(\.isEnabled) == reopened, "after \(presses) presses")
        }
    }

    @Test func aReopenedWelcomeStartsOverWithNothingShown() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        let old = fixture.controller
        fixture.press()
        fixture.press()
        old.modeCards[1].radio.performClick(nil)
        #expect(fixture.steps.dots.map(\.isEnabled) == [true, true, false, true])
        window.performClose(nil)
        #expect(fixture.model.welcome == nil)

        _ = try await fixture.open()
        let controller = fixture.controller
        #expect(controller !== old)
        #expect(controller.page == .access)
        #expect(fixture.steps.dots.map(\.isEnabled) == [false, true, false, false])
        #expect(controller.choices.mode == .simple)
        #expect(fixture.defaults.object(forKey: WindowMode.key) == nil)
    }

    @Test func rightToLeftTurnsOffTheSameDots() throws {
        let rig = Rig()
        defer { rig.close() }
        let steps = rig.steps
        steps.userInterfaceLayoutDirection = .rightToLeft
        steps.needsLayout = true
        steps.layoutSubtreeIfNeeded()
        #expect(steps.dots.map(\.isEnabled) == [false, true, false, false])
        #expect(steps.dots[0].frame.midX > steps.dots[3].frame.midX, "dot 1 left the right side")
        let shape = steps.geometry
        #expect(try pixelAlpha(steps, shape.dots[1].rect) > pixelAlpha(steps, shape.dots[2].rect), "the live dot looks dead")
    }

    @Test func returnIsNextAfterBackAndAfterADot() async throws {
        let rig = Rig()
        defer { rig.close() }
        let cell = try #require(rig.window.defaultButtonCell)
        #expect(cell === rig.action.cell)
        rig.press()
        try await realPress(rig.back, in: rig.window)
        #expect(rig.window.defaultButtonCell === cell)
        try #require(try returnKey(rig.window), "no button took Return after Back")
        #expect(rig.controller.page == .modes)
        try pressDot(rig.steps.dots[2], in: rig.window)
        #expect(rig.window.defaultButtonCell === cell)
        try #require(try returnKey(rig.window), "no button took Return after a dot")
        #expect(rig.controller.page == .done)
    }

    @Test func aDoubleClickOnBackMovesOnePage() async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.press()
        try await realPress(rig.back, in: rig.window)
        try await realPress(rig.back, in: rig.window, clickCount: 2)
        #expect(rig.controller.page == .access)
        #expect(!rig.back.isEnabled)
        #expect(rig.heard.opens == 0, "the second click opened System Settings")
        rig.press()
        rig.press()
        #expect(rig.controller.page == .setup)
        try await realPress(rig.back, in: rig.window)
        try await realPress(rig.back, in: rig.window, clickCount: 2)
        #expect(rig.controller.page == .modes, "the second click moved a second page")
    }

    @Test func aDoubleClickOnNextMovesOnePage() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        let controller = fixture.controller
        fixture.press()
        fixture.press()
        #expect(controller.page == .setup)
        try await realPress(fixture.action, in: window)
        try await realPress(fixture.action, in: window, clickCount: 2)
        #expect(controller.page == .done)
        #expect(fixture.starts == 0 && fixture.model.stage == .granted, "the second click finished the welcome")
        #expect(window.isVisible)

        try pressDot(fixture.steps.dots[1], in: window)
        #expect(controller.page == .modes)
        try await realPress(fixture.action, in: window)
        try await realPress(fixture.action, in: window, clickCount: 2)
        #expect(controller.page == .setup)
        try #require(try returnKey(window), "no button took Return after a double-click")
        #expect(controller.page == .done)
        try await realPress(fixture.back, in: window)
        #expect(controller.page == .setup)
        #expect(AXTree.press(fixture.action))
        #expect(controller.page == .done, "an AX press after a double-click did nothing")
    }

    @Test func aDotTakesTheClickAndTheLabelMovesTheWindow() throws {
        for stage in [AccessModel.Stage.granted, .waiting] {
            let rig = Rig(stage: stage)
            defer { rig.close() }
            rig.content.layoutSubtreeIfNeeded()
            let frame = try #require(rig.content.superview)
            let steps = rig.steps
            let safe = rig.window.contentLayoutRect
            for dot in steps.dots {
                let zone = dot.convert(dot.bounds, to: nil)
                #expect(safe.contains(zone), "the zone \(zone) reaches into the title bar \(safe) in \(stage)")
                for point in [NSPoint(x: zone.midX, y: zone.midY), NSPoint(x: zone.minX + 1, y: zone.maxY - 1), NSPoint(x: zone.maxX - 1, y: zone.minY + 1)] {
                    #expect(frame.hitTest(point) === dot, "\(point) in \(stage)")
                }
                #expect(!dot.mouseDownCanMoveWindow, "a dot moves the window in \(stage)")
            }
            let label = steps.geometry.label
            let text = steps.convert(NSPoint(x: label.midX, y: label.maxY - 2), to: nil)
            #expect(frame.hitTest(text) === steps, "the label is covered in \(stage)")
            #expect(steps.mouseDownCanMoveWindow && rig.window.isMovableByWindowBackground, "\(stage)")
        }
    }

    @Test func rightToLeftMirrorsTheRowAndTheZones() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.content.layoutSubtreeIfNeeded()
        let (back, action) = (rig.back.frame, rig.action.frame)
        let steps = rig.steps
        let zones = steps.dots.map(\.frame)
        for view in [rig.content, rig.back, rig.action, steps] { view.userInterfaceLayoutDirection = .rightToLeft }
        let all = rig.content.constraints
        NSLayoutConstraint.deactivate(all)
        NSLayoutConstraint.activate(all)
        rig.content.needsLayout = true
        steps.needsLayout = true
        rig.content.layoutSubtreeIfNeeded()
        #expect(rig.action.frame.maxX < rig.back.frame.minX, "Next stays on the right")
        #expect(rig.back.frame.maxX == WelcomeMetrics.width - back.minX)
        #expect(rig.action.frame.minX == WelcomeMetrics.width - action.maxX)
        #expect(steps.dots.map(\.frame.midX) == zones.map { WelcomeMetrics.stepsWidth - $0.midX }, "the zones stay put")
        #expect(steps.dots[0].frame.midX > steps.dots[3].frame.midX)
        #expect(steps.dots.map(\.frame.midX) == steps.geometry.dots.map(\.rect.midX), "a zone left its dot")
    }

    @Test func noDotSkipsPageThreeSoItsSwitchIsAlwaysShownBeforeLetsGo() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        let controller = fixture.controller
        try pressDot(fixture.steps.dots[3], in: window)
        #expect(controller.page == .access, "dot 4 skipped page 3")
        fixture.press()
        fixture.press()
        #expect(controller.page == .setup)
        let shown = controller.setupBox.menuBarIcon
        #expect(!shown.isHiddenOrHasHiddenAncestor, "page 3's switch was not shown")
        let value = shown.state == .on
        fixture.press()
        #expect(controller.page == .done)
        #expect(fixture.steps.geometry.dots.map(\.state) == [.done, .done, .done, .current])
        #expect(fixture.defaults.object(forKey: MenuBarIcon.key) == nil, "a move wrote a choice")
        fixture.press()
        #expect(fixture.model.stage == .ready)
        #expect(fixture.defaults.object(forKey: MenuBarIcon.key) as? Bool == value)
        #expect(fixture.defaults.string(forKey: WindowMode.key) == WindowMode.simple.rawValue)
        #expect(fixture.defaults.string(forKey: Theme.key) == Theme.systemNative.rawValue)
        #expect(fixture.defaults.bool(forKey: AccessModel.completedKey))
    }

    private func pick(_ theme: Theme, _ controller: WelcomeWindowController) throws {
        try #require(controller.setupBox.tiles.tiles.first { $0.theme == theme }).performClick(nil)
        #expect(controller.choices.theme == theme)
    }

    @Test func aThemePickRepaintsTheWindowAndWritesNothing() throws {
        for theme in previewThemes {
            for look in [Look.light, .dark] {
                let rig = Rig()
                defer { rig.close() }
                rig.window.appearance = look.appearance
                rig.press()
                rig.press()
                rig.content.layoutSubtreeIfNeeded()
                #expect(viewDraws(.windowBackgroundColor, in: rig.content, x: 8, y: 8), "\(look) before the pick")
                try pick(theme, rig.controller)
                try expectPreview(theme, on: rig.controller, "\(theme) \(look) on page 3")
                #expect(rig.defaults.object(forKey: Theme.key) == nil, "a pick was written before Let's Go!")
                rig.back.performClick(nil)
                try expectPreview(theme, on: rig.controller, "\(theme) \(look) on page 2")
                #expect(viewDraws(theme.rowBackground, in: rig.controller.toolBox, x: 6, y: rig.controller.toolBox.bounds.midY), "\(theme) \(look) tool box")
                #expect(rig.defaults.object(forKey: Theme.key) == nil, "going back wrote the pick")
            }
        }
    }

    @Test func aPickRepaintsBothPicturesAndSystemNativeKeepsItsFields() throws {
        for look in Look.allCases {
            let rig = Rig()
            defer { rig.close() }
            rig.window.appearance = look.appearance
            rig.press()
            rig.press()
            for theme in previewThemes + [.systemNative] {
                try pick(theme, rig.controller)
                let field = theme == .systemNative ? NSColor.textBackgroundColor : theme.rowBackground
                for card in rig.controller.modeCards {
                    let root = try #require(card.picture.layer)
                    let name = "\(theme) \(look) \(card.mode)"
                    #expect(layerBits(root.backgroundColor) == eightBits(channels(theme.windowBackground, look)), "\(name) root")
                    let fields = card.mode == .simple ? ["searchField"] : ["field1", "field2", "field3"]
                    for layer in root.sublayers ?? [] {
                        let isFixed = layer.name == "titleBar" || layer.name?.hasPrefix("pill") == true
                        let expected: NSColor? = fields.contains(layer.name ?? "") ? field : isFixed ? .separatorColor : nil
                        if let expected { #expect(layerBits(layer.backgroundColor) == eightBits(channels(expected, look)), "\(name) \(layer.name ?? "")") }
                    }
                }
            }
        }
    }

    @Test func aPickRepaintsTheWordsAndKeepsTheSystemParts() throws {
        for look in Look.allCases {
            for theme in previewThemes {
                let rig = Rig(tools: WelcomeTools(commandLine: .inert(), launcherIsOn: { true }, shortcut: { "⌃⌥K" }, applyLauncher: { _ in }))
                defer { rig.close() }
                rig.window.appearance = look.appearance
                rig.press()
                rig.press()
                try pick(theme, rig.controller)
                let box = rig.controller.setupBox
                let press = text("Press it in any app to search your files.", table: "Settings")
                let fields = words(in: box)
                let caption = try #require(fields.first { $0.stringValue.hasPrefix(press) })
                let labels = fields.filter { [text("Launcher shortcut"), text("Show Menu Bar Icon", table: "Settings"), text("Color theme", table: "Theme")].contains($0.stringValue) }
                #expect(labels.count == 3)
                for label in labels { #expect(reads(label.textColor, as: theme.text, in: rig.content), "\(theme) \(look) \(label.stringValue)") }
                let string = caption.attributedStringValue
                #expect(string.string == press + "\u{2002}⌃⌥K")
                #expect(reads(string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, as: theme.secondaryText, in: rig.content), "\(theme) \(look) caption")
                #expect(reads(string.attribute(.foregroundColor, at: string.length - 1, effectiveRange: nil) as? NSColor, as: theme.text, in: rig.content), "\(theme) \(look) shortcut")
                for name in box.tiles.names { #expect(reads(name.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, as: .labelColor, in: rig.content), "\(theme) \(look) tile name") }

                let tool = words(in: rig.controller.toolBox)
                #expect(reads(tool[0].textColor, as: theme.text, in: rig.content), "\(theme) \(look) tool label")
                #expect(reads(tool[1].textColor, as: theme.secondaryText, in: rig.content), "\(theme) \(look) tool caption")
                #expect(reads(tool[2].textColor, as: .systemRed, in: rig.content), "\(theme) \(look) tool notice")
            }
        }
    }

    @Test func theStepLabelFollowsThePick() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.window.appearance = Look.light.appearance
        rig.press()
        rig.press()
        rig.content.layoutSubtreeIfNeeded()
        let native = try stepLabelInk(rig.steps)
        #expect(native.redComponent < 1.1 * native.blueComponent, "System Native's secondary text is grey, read \(native)")
        try pick(.warmPaper, rig.controller)
        let warm = try stepLabelInk(rig.steps)
        #expect(warm.alphaComponent > 0.2, "the label drew nothing")
        #expect(warm.redComponent > 1.3 * warm.blueComponent, "Warm Paper's secondary text is brown, read \(warm)")
    }

    @Test func thePreviewStaysOnEveryPage() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.press()
        rig.press()
        try pick(.warmPaper, rig.controller)
        rig.back.performClick(nil)
        #expect(rig.controller.page == .modes)
        try expectPreview(.warmPaper, on: rig.controller, "Back to page 2")
        rig.steps.dots[0].performClick(nil)
        #expect(rig.controller.page == .access)
        try expectPreview(.warmPaper, on: rig.controller, "dot 1")
        rig.steps.dots[3].performClick(nil)
        #expect(rig.controller.page == .done)
        try expectPreview(.warmPaper, on: rig.controller, "dot 4")
        rig.back.performClick(nil)
        #expect(rig.controller.page == .setup)
        try expectPreview(.warmPaper, on: rig.controller, "Back to page 3")
        #expect(rig.defaults.object(forKey: Theme.key) == nil)
    }

    @Test func aCloseDropsThePreview() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        let window = try await fixture.open()
        fixture.press()
        fixture.press()
        try pick(.warmPaper, fixture.controller)
        try expectPreview(.warmPaper, on: fixture.controller, "before the close")
        window.performClose(nil)
        #expect(fixture.model.welcome == nil)
        #expect(fixture.defaults.object(forKey: Theme.key) == nil)

        _ = try await fixture.open()
        let controller = fixture.controller
        #expect(controller.choices.theme == .systemNative)
        #expect(controller.setupBox.tiles.tiles.filter { $0.state == .on }.map(\.theme) == [.systemNative])
        try expectPreview(.systemNative, on: controller, "after the reopen")
    }

    @Test func theWelcomeOpensInTheStoredTheme() async throws {
        for granted in [true, false] {
            let fixture = AccessFixture(granted: granted, confirms: granted) { defaults in
                defaults.set(Theme.midnightTeal.rawValue, forKey: Theme.key)
                return .inert()
            }
            defer { fixture.clean() }
            _ = try await fixture.open()
            #expect(fixture.controller.page == .access)
            try expectPreview(.midnightTeal, on: fixture.controller, "granted \(granted)")
        }
    }

    @Test func aStageBounceKeepsThePreview() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        let controller = fixture.controller
        fixture.press()
        fixture.press()
        try pick(.warmPaper, controller)

        fixture.confirms = false
        fixture.model.completeWelcome(choices: controller.choices)
        #expect(fixture.model.stage == .reopen)
        #expect(controller.page == .access)
        #expect(fixture.defaults.object(forKey: Theme.key) == nil, "a failed Let's Go! wrote the theme")
        try expectPreview(.warmPaper, on: controller, "after the bounce")

        fixture.confirms = true
        fixture.model.refresh()
        #expect(fixture.model.stage == .granted)
        try expectPreview(.warmPaper, on: controller, "after the grant came back")
        fixture.press()
        #expect(controller.page == .modes)
        try expectPreview(.warmPaper, on: controller, "on page 2 after the grant")
        #expect(controller.setupBox.tiles.tiles.filter { $0.state == .on }.map(\.theme) == [.warmPaper])
    }

    @Test func aLaterWelcomeShowsOnlyTheAccessPageAtTheFirstHeightWithOneCentredButton() throws {
        for language in languages {
            for size in [TextSize.smallest, .standard, .maximum] {
                let name = "\(language) at \(size.rawValue)"
                let first = Rig(stage: .waiting, language: language, size: size)
                defer { first.close() }
                for stage in [AccessModel.Stage.granted] + Self.otherStages {
                    let rig = Rig(stage: stage, language: language, size: size, completed: true)
                    defer { rig.close() }
                    rig.content.layoutSubtreeIfNeeded()
                    let context = "\(stage) in \(name)"
                    #expect(rig.controller.page == .access, "\(context)")
                    #expect(rig.steps.isHidden && rig.back.isHidden, "\(context)")
                    #expect(!rig.steps.canMove && rig.steps.dots.allSatisfy { !$0.isEnabled }, "\(context)")
                    #expect(rig.window.frame.height == first.window.frame.height, "\(context)")
                    let action = rig.action.frame
                    #expect(((action.minX - (WelcomeMetrics.width - action.maxX)) * rig.scale).rounded() == 0, "off centre in \(context)")
                    for edge in [action.minX, action.maxX, action.minY, action.maxY] {
                        #expect((edge * rig.scale).rounded() == edge * rig.scale, "\(edge) is not a whole device pixel in \(context)")
                    }
                    #expect(action.width >= WelcomeMetrics.buttonMinWidth && action.minY == first.action.frame.minY, "\(context)")
                    #expect(!visibleLeaves(of: rig.content).contains { $0 is WelcomeStepDot || $0 === rig.back }, "\(context)")
                }
            }
        }
    }

    @Test func aLaterWelcomeNeverTurnsPastPageOne() throws {
        let waiting = Rig(stage: .waiting, completed: true)
        defer { waiting.close() }
        #expect(waiting.action.title == text("Open System Settings"))
        waiting.press()
        #expect(waiting.heard.opens == 1)
        #expect(waiting.controller.page == .access)

        let rig = Rig(completed: true)
        defer { rig.close() }
        #expect(rig.action.title == text("Let's Go!"))
        #expect(rig.status.stringValue == "✓ " + text("Full Disk Access is on. Wherever is ready to start."))
        for index in 1..<4 {
            rig.steps.dots[index].performClick(nil)
            rig.steps.onStep?(index)
            #expect(rig.controller.page == .access, "dot \(index + 1)")
        }
        rig.back.performClick(nil)
        #expect(rig.controller.page == .access)
        #expect(rig.access.stage == .granted)
        #expect(rig.heard.posts.isEmpty)
        rig.press()
        #expect(rig.controller.page == .access)
        #expect(rig.access.stage == .ready)
    }

    @Test func aLaterLetsGoStartsOnceSummonsOnceAndWritesNothing() async throws {
        var applied: [Bool] = []
        let fixture = AccessFixture(confirms: true, completed: true) { defaults in
            defaults.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
            defaults.set(Theme.midnightTeal.rawValue, forKey: Theme.key)
            defaults.set(false, forKey: MenuBarIcon.key)
            return WelcomeTools(commandLine: .inert(), launcherIsOn: { false }, shortcut: { "⌃⇧F" }, applyLauncher: { applied.append($0) })
        }
        defer { fixture.clean() }
        #expect(fixture.model.stage == .waiting)
        _ = try await fixture.open()
        #expect(fixture.steps.isHidden && fixture.back.isHidden)
        #expect(fixture.action.title == text("Open System Settings"))
        try await fixture.enter(.granted)
        #expect(fixture.action.title == text("Let's Go!"))
        #expect(fixture.controller.page == .access)
        let stored = NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:])
        fixture.press()
        #expect(fixture.model.stage == .ready)
        #expect(fixture.events == ["start", "summon"])
        #expect(fixture.starts == 1 && fixture.summons == 1 && fixture.prepares == 1)
        #expect(fixture.model.welcome == nil)
        #expect(applied.isEmpty)
        #expect(NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]) == stored)
        fixture.model.completeWelcome(choices: nil)
        #expect(fixture.starts == 1 && fixture.summons == 1)
    }

    @Test func aLaterLetsGoThatLostAccessOffersReopenAndWritesNothing() async throws {
        let fixture = AccessFixture(confirms: true, completed: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        try await fixture.enter(.granted)
        let stored = NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:])
        fixture.confirms = false
        fixture.press()
        #expect(fixture.model.stage == .reopen)
        #expect(fixture.action.title == text("Quit Wherever", table: "MenuBar"))
        #expect(fixture.starts == 0 && fixture.summons == 0)
        #expect(NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]) == stored)
    }

    @Test func aFirstWelcomeStillHasFourPages() async throws {
        let fixture = AccessFixture(granted: true, confirms: true)
        defer { fixture.clean() }
        _ = try await fixture.open()
        #expect(!fixture.steps.isHidden && !fixture.back.isHidden)
        #expect(fixture.steps.dots.count == 4)
        #expect(fixture.action.title == text("Next"))
        for page in [WelcomeWindowController.Page.modes, .setup, .done] {
            fixture.press()
            #expect(fixture.controller.page == page)
        }
        #expect(fixture.action.title == text("Let's Go!"))
        #expect(fixture.starts == 0)
    }

    @Test func aRevokeOnPageThreeOfAFirstWelcomeReturnsToPageOneOfFour() async throws {
        let fixture = AccessFixture(granted: true, confirms: true, watch: .milliseconds(20))
        defer { fixture.clean() }
        let window = try await fixture.open()
        #expect(fixture.model.isWatching)
        let height = window.frame.height
        fixture.press()
        fixture.press()
        #expect(fixture.controller.page == .setup)
        fixture.spy.set(false)
        try await untilTrue(waitingFor: "the revoke") { fixture.model.stage == .stillOff }
        #expect(fixture.controller.page == .access)
        #expect(!fixture.steps.isHidden && fixture.steps.dots.count == 4)
        #expect(!fixture.steps.canMove && fixture.steps.dots.allSatisfy { !$0.isEnabled })
        #expect(!fixture.back.isHidden && !fixture.back.isEnabled)
        #expect(fixture.action.title == text("Open System Settings"))
        #expect(window.frame.height == height)
        #expect(fixture.model.isTicking && !fixture.model.isWatching)
        #expect(fixture.starts == 0 && fixture.losses == 0)
        #expect(fixture.defaults.object(forKey: AccessModel.completedKey) == nil)
        fixture.press()
        #expect(fixture.opened == [AccessModel.settingsURL])
    }

    @Test func theStringsAreTranslatedAndTheOldOnesAreGone() {
        let keys = [
            "Welcome to Wherever!", "Wherever it is, find it.", "Back", "Next", "Choose Your Mode", "You can change it later in the View menu.",
            "Set Up Wherever", "You can change these later in Settings.", "You’re All Set", "Step %lld of %lld",
        ]
        let gone = [
            "To turn on Full Disk Access you need an administrator’s name and password, so if your organization issued you this Mac, ask your administrator.",
            "Install the command-line tool", "You can install it later in Settings > General.", "Wherever could not install the command-line tool.", "Continue",
        ]
        for language in languages {
            let bundle = AccessFixture.bundle(language)
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "\u{1}", table: "Welcome")
                #expect(value != "\u{1}", "\(language) has no \(key)")
                if language != "en" { #expect(value != key, "\(key) is not translated in \(language)") }
            }
            #expect(bundle.localizedString(forKey: "Launcher shortcut", value: "\u{1}", table: "Welcome") != "\u{1}", "\(language) has no Launcher shortcut")
            #expect(bundle.localizedString(forKey: "Launcher", value: "\u{1}", table: "Welcome") == "\u{1}", "\(language) still has Launcher")
            for key in gone {
                #expect(bundle.localizedString(forKey: key, value: "\u{1}", table: "Welcome") == "\u{1}", "\(language) still has \(key)")
            }
        }
    }
}
