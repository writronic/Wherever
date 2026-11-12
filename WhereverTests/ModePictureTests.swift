import AppKit
import Foundation
import QuartzCore
import Testing
@testable import Wherever

private final class HiddenWindow: NSWindow {
    var seen = false

    override var occlusionState: NSWindow.OcclusionState { seen ? .visible : [] }

    func set(seen: Bool) {
        self.seen = seen
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }
}

private enum Move { case none, fade, grow, rise }

private struct Row {
    let name: String
    let x, y, width, height, radius: CGFloat
    let fill: NSColor
    var outlined = false
    var outlinedInContrast = false
    var move = Move.none
    var start = 0.0
    var end = 0.0
}

private struct Picture {
    let layout: ModePictureLayout
    let loop: Double
    let fadeStart: Double
    let rows: [Row]
}

@Suite(.serialized) struct ModePictureTests {
    private let simple = Picture(layout: .simple, loop: 5.0, fadeStart: 4.6, rows: [
        Row(name: "titleBar", x: 0, y: 0, width: 180, height: 12, radius: 0, fill: .separatorColor),
        Row(name: "searchField", x: 8, y: 18, width: 164, height: 12, radius: 3, fill: .textBackgroundColor, outlined: true, outlinedInContrast: true, move: .grow, start: 0.30, end: 1.10),
        Row(name: "row1", x: 4, y: 38, width: 172, height: 10, radius: 3, fill: .controlAccentColor, move: .rise, start: 1.50, end: 1.80),
        Row(name: "row2", x: 8, y: 55, width: 96, height: 4, radius: 2, fill: .secondaryLabelColor, move: .rise, start: 1.70, end: 2.00),
        Row(name: "row3", x: 8, y: 69, width: 72, height: 4, radius: 2, fill: .secondaryLabelColor, move: .rise, start: 1.90, end: 2.20),
        Row(name: "row4", x: 8, y: 83, width: 110, height: 4, radius: 2, fill: .secondaryLabelColor, move: .rise, start: 2.10, end: 2.40),
        Row(name: "row5", x: 8, y: 97, width: 84, height: 4, radius: 2, fill: .secondaryLabelColor, move: .rise, start: 2.30, end: 2.60)
    ])

    private let normal = Picture(layout: .normal, loop: 5.0, fadeStart: 4.6, rows: [
        Row(name: "titleBar", x: 0, y: 0, width: 180, height: 12, radius: 0, fill: .separatorColor),
        Row(name: "field1", x: 40, y: 16, width: 132, height: 9, radius: 2, fill: .textBackgroundColor, outlined: true, outlinedInContrast: true, move: .grow, start: 0.30, end: 0.70),
        Row(name: "field2", x: 40, y: 28, width: 132, height: 9, radius: 2, fill: .textBackgroundColor, outlined: true, outlinedInContrast: true, move: .grow, start: 0.50, end: 0.90),
        Row(name: "field3", x: 40, y: 40, width: 132, height: 9, radius: 2, fill: .textBackgroundColor, outlined: true, outlinedInContrast: true, move: .grow, start: 0.70, end: 1.10),
        Row(name: "pill1", x: 8, y: 53, width: 26, height: 8, radius: 4, fill: .separatorColor, outlinedInContrast: true, move: .fade, start: 1.20, end: 1.45),
        Row(name: "pill2", x: 38, y: 53, width: 30, height: 8, radius: 4, fill: .separatorColor, outlinedInContrast: true, move: .fade, start: 1.30, end: 1.55),
        Row(name: "pill3", x: 72, y: 53, width: 24, height: 8, radius: 4, fill: .separatorColor, outlinedInContrast: true, move: .fade, start: 1.40, end: 1.65),
        Row(name: "row1", x: 4, y: 66, width: 172, height: 10, radius: 3, fill: .controlAccentColor, move: .rise, start: 1.90, end: 2.20),
        Row(name: "row2", x: 8, y: 83, width: 100, height: 4, radius: 2, fill: .secondaryLabelColor, move: .rise, start: 2.10, end: 2.40),
        Row(name: "row3", x: 8, y: 97, width: 76, height: 4, radius: 2, fill: .secondaryLabelColor, move: .rise, start: 2.30, end: 2.60)
    ])

    private var pictures: [Picture] { [simple, normal] }

    private func host(_ layout: ModePictureLayout, seen: Bool = true) -> (window: HiddenWindow, holder: NSView, view: ModePictureView) {
        let window = HiddenWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.seen = seen
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let view = ModePictureView(layout: layout)
        view.reduceMotion = { false }
        window.contentView = holder
        holder.addSubview(view)
        return (window, holder, view)
    }

    private func sublayers(_ view: ModePictureView) -> [CALayer] { view.layer?.sublayers ?? [] }

    private func keys(_ layer: CALayer) -> Set<String> { Set(layer.animationKeys() ?? []) }

    private func moving(_ view: ModePictureView) -> Bool { sublayers(view).contains { !keys($0).isEmpty } }

    private func close(_ expected: Double, _ actual: Double?) -> Bool {
        guard let actual else { return false }
        return abs(expected - actual) < 0.000_1
    }

    private func bits(_ color: NSColor, _ look: Look) -> [Int] {
        channels(color, look).map { Int(($0 * 255).rounded()) }
    }

    private func bits(_ color: CGColor?, _ look: Look) -> [Int]? {
        color.flatMap { NSColor(cgColor: $0) }.map { bits($0, look) }
    }

    private func expectRestFrame(_ view: ModePictureView, _ picture: Picture, _ context: String) {
        #expect(sublayers(view).count == picture.rows.count, "\(context)")
        for (layer, row) in zip(sublayers(view), picture.rows) {
            #expect(layer.animationKeys() == nil, "\(context) \(row.name) keeps \(keys(layer))")
            #expect(layer.opacity == 1, "\(context) \(row.name)")
            #expect(layer.bounds.width == row.width, "\(context) \(row.name)")
            #expect(CATransform3DIsIdentity(layer.transform), "\(context) \(row.name)")
        }
    }

    @Test func layersFollowTheFigmaTableInOrder() throws {
        let counts = [7, 10]
        for (picture, count) in zip(pictures, counts) {
            let view = ModePictureView(layout: picture.layout)
            let root = try #require(view.layer)
            #expect(root.name == "window")
            #expect(root.bounds.size == CGSize(width: 180, height: 114))
            #expect(root.cornerRadius == 4 && root.masksToBounds)
            #expect(view.intrinsicContentSize == CGSize(width: 180, height: 114))
            let layers = sublayers(view)
            #expect(layers.count == count)
            #expect(layers.map(\.name) == picture.rows.map(\.name))
            for (layer, row) in zip(layers, picture.rows) {
                #expect(layer.frame == CGRect(x: row.x, y: 114 - row.y - row.height, width: row.width, height: row.height), "\(row.name)")
                #expect(layer.cornerRadius == row.radius, "\(row.name)")
            }
            #expect(layers.first?.name == "titleBar" && layers.first?.frame.maxY == 114)
        }
    }

    @Test func aCardOnAVisibleWindowLoopsEveryShapeOnOneClock() throws {
        #expect(ModePictureLayout.loop == 5.0 && ModePictureLayout.fadeStart == 4.6)
        #expect(pictures.allSatisfy { $0.loop == ModePictureLayout.loop && $0.fadeStart == ModePictureLayout.fadeStart })
        for picture in pictures {
            let (window, _, view) = host(picture.layout)
            defer { window.close() }
            for (layer, row) in zip(sublayers(view), picture.rows) {
                let expectedKeys: Set<String> = switch row.move {
                case .none: []
                case .fade: ["opacity"]
                case .grow: ["opacity", "bounds.size.width"]
                case .rise: ["opacity", "transform.translation.y"]
                }
                #expect(keys(layer) == expectedKeys, "\(row.name)")
                for key in expectedKeys {
                    let animation = try #require(layer.animation(forKey: key) as? CAKeyframeAnimation, "\(row.name) \(key)")
                    #expect(animation.duration == picture.loop && animation.repeatCount == .infinity, "\(row.name) \(key)")
                    let times = try #require(animation.keyTimes).map(\.doubleValue)
                    let values = try #require(animation.values as? [Double], "\(row.name) \(key)")
                    #expect(times.first == 0 && times.last == 1 && zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "\(row.name) \(key) \(times)")
                    #expect(times.count == values.count && animation.timingFunctions?.count == values.count - 1, "\(row.name) \(key)")
                    #expect(close(row.start / picture.loop, times[1]) && close(row.end / picture.loop, times[2]), "\(row.name) \(key) \(times)")
                    switch key {
                    case "opacity":
                        #expect(values == [0, 0, 1, 1, 0], "\(row.name)")
                        #expect(close(picture.fadeStart / picture.loop, times[3]), "\(row.name) \(times)")
                        #expect(values[2] == Double(layer.opacity), "\(row.name)")
                    case "bounds.size.width":
                        #expect(close(0.4 * Double(row.width), values[0]) && close(0.4 * Double(row.width), values[1]), "\(row.name) \(values)")
                        #expect(values[2] == Double(layer.bounds.width) && values[3] == Double(layer.bounds.width), "\(row.name) \(values)")
                    default:
                        #expect(values == [-4, -4, 0, 0], "\(row.name)")
                        #expect(CATransform3DIsIdentity(layer.transform), "\(row.name)")
                    }
                }
            }
        }
    }

    @Test func aStoredLoopStartPutsEveryAnimationOnItsClock() throws {
        let (plainWindow, _, plain) = host(.simple)
        defer { plainWindow.close() }
        let first = sublayers(plain).compactMap { $0.animation(forKey: "opacity") }
        #expect(!first.isEmpty && first.allSatisfy { $0.beginTime == 0 }, "no loopStart keeps today's start at add")

        let (window, _, view) = host(.normal, seen: false)
        defer { window.close() }
        let start = CACurrentMediaTime()
        view.loopStart = start
        window.set(seen: true)
        let animations = sublayers(view).flatMap { layer in (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) } }
        #expect(!animations.isEmpty)
        let begin = try #require(animations.first).beginTime
        #expect(begin != 0 && abs(begin - start) < 1, "the begin time is the stored start in layer time")
        #expect(animations.allSatisfy { $0.beginTime == begin }, "every animation of a picture shares one begin time")
    }

    @Test func aStillPictureShowsTheRestFrame() {
        for picture in pictures {
            let (window, _, view) = host(picture.layout)
            defer { window.close() }
            #expect(moving(view), "a visible window")

            view.reduceMotion = { true }
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            expectRestFrame(view, picture, "Reduce Motion")

            let (hiddenWindow, _, covered) = host(picture.layout, seen: false)
            defer { hiddenWindow.close() }
            expectRestFrame(covered, picture, "window not visible")
        }
    }

    @Test func theVisibilitySeamDecidesWhatTheWindowSays() {
        for picture in pictures {
            let (window, _, view) = host(picture.layout, seen: false)
            defer { window.close() }
            expectRestFrame(view, picture, "covered window")

            view.isShown = { _ in true }
            #expect(moving(view), "the seam says shown")

            window.seen = true
            view.isShown = { _ in false }
            expectRestFrame(view, picture, "the seam says not shown")
        }
    }

    @Test func reduceMotionIsPickedUpWhileThePageIsOpen() {
        let (window, _, view) = host(.simple)
        defer { window.close() }
        let center = NSWorkspace.shared.notificationCenter
        #expect(moving(view))

        view.reduceMotion = { true }
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(!moving(view))

        view.reduceMotion = { false }
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(moving(view))
    }

    @Test func coveringHidingAndRemovingStopTheLoop() throws {
        let (window, holder, view) = host(.normal)
        defer { window.close() }
        #expect(moving(view))

        let field = try #require(sublayers(view).first { $0.name == "field1" })
        let running = field.animation(forKey: "opacity")
        window.set(seen: true)
        #expect(field.animation(forKey: "opacity") === running, "a repeated refresh must not restart the loop")

        window.set(seen: false)
        #expect(!moving(view))
        window.set(seen: true)
        #expect(moving(view))

        holder.isHidden = true
        #expect(!moving(view))
        holder.isHidden = false
        #expect(moving(view))

        view.removeFromSuperview()
        #expect(!moving(view))
        window.set(seen: true)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        #expect(!moving(view))
    }

    @Test func colorsResolveInEveryLookAndNeverAnimate() async throws {
        for picture in pictures {
            let (window, _, view) = host(picture.layout)
            defer { window.close() }
            let root = try #require(view.layer)
            var fills: [Look: [Int]] = [:]
            for look in Look.allCases {
                let contrast = look == .lightContrast || look == .darkContrast
                view.appearance = look.appearance
                let edge = bits(contrast ? NSColor.labelColor : .separatorColor, look)
                let background = bits(NSColor.windowBackgroundColor, look)
                try await untilTrue(waitingFor: "the \(look) picture") {
                    bits(root.borderColor, look) == edge && bits(root.backgroundColor, look) == background
                }
                fills[look] = bits(root.backgroundColor, look)
                #expect(root.borderWidth == 1, "\(look)")
                for (layer, row) in zip(sublayers(view), picture.rows) {
                    let outlined = row.outlined || (contrast && row.outlinedInContrast)
                    let edgeColor = contrast ? NSColor.labelColor : NSColor.separatorColor
                    #expect(bits(layer.backgroundColor, look) == bits(row.fill, look), "\(look) \(row.name)")
                    #expect(layer.borderWidth == (outlined ? 1 : 0), "\(look) \(row.name)")
                    #expect(bits(layer.borderColor, look) == (outlined ? bits(edgeColor, look) : nil), "\(look) \(row.name)")
                    #expect(layer.animation(forKey: "backgroundColor") == nil && layer.animation(forKey: "borderColor") == nil && layer.animation(forKey: "borderWidth") == nil, "\(look) \(row.name)")
                    #expect((layer.animation(forKey: "opacity") != nil) == (row.move != .none), "\(look) \(row.name)")
                }
            }
            #expect(fills[.light] != fills[.dark])
        }
    }

    @Test func aThemeRepaintsOnlyTheRootAndTheFieldsAndRestartsNothing() throws {
        for picture in pictures {
            let (window, _, view) = host(picture.layout, seen: false)
            defer { window.close() }
            view.appearance = Look.darkContrast.appearance
            view.loopStart = CACurrentMediaTime()
            window.set(seen: true)
            let begin = try #require(sublayers(view).compactMap { $0.animation(forKey: "opacity") }.first).beginTime
            view.loopStart = CACurrentMediaTime() + 10
            for theme in [Theme.warmPaper, .inkAndGlass, .midnightTeal, .systemNative] {
                view.theme = theme
                #expect(bits(view.layer?.backgroundColor, .darkContrast) == bits(theme.windowBackground, .darkContrast), "\(theme) root")
                for (layer, row) in zip(sublayers(view), picture.rows) {
                    let fill = row.outlined && theme != .systemNative ? theme.rowBackground : row.fill
                    #expect(bits(layer.backgroundColor, .darkContrast) == bits(fill, .darkContrast), "\(theme) \(row.name)")
                    #expect(layer.animation(forKey: "backgroundColor") == nil, "\(theme) \(row.name)")
                }
                #expect(sublayers(view).compactMap { $0.animation(forKey: "opacity") }.allSatisfy { $0.beginTime == begin }, "\(theme) restarted the loop")
            }
        }
    }

    @Test func systemColorChangesAndDisplayOptionsRefreshTheColors() throws {
        let (window, _, view) = host(.simple)
        defer { window.close() }
        view.appearance = Look.light.appearance
        let row = try #require(sublayers(view).first { $0.name == "row1" })
        let stale = CGColor(red: 1, green: 0, blue: 1, alpha: 1)
        let expected = bits(NSColor.controlAccentColor, .light)

        row.backgroundColor = stale
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        #expect(bits(row.backgroundColor, .light) == expected)

        row.backgroundColor = stale
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(bits(row.backgroundColor, .light) == expected)
    }

    @Test func thePictureIsDecorativeForAccessibility() {
        for picture in pictures {
            let view = ModePictureView(layout: picture.layout)
            #expect(!view.isAccessibilityElement())
            #expect(view.subviews.isEmpty)
        }
    }
}
