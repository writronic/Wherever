import AppKit
import SwiftUI
import Testing
@testable import Wherever

func themeTileRow(in view: NSView) -> ThemeTileRow? {
    view as? ThemeTileRow ?? view.subviews.lazy.compactMap(themeTileRow(in:)).first
}

private final class PaintedLayers: NSView {
    private let colors: [NSColor]

    init(colors: [NSColor]) {
        self.colors = colors
        super.init(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        for color in colors {
            color.setFill()
            NSBezierPath(rect: bounds).fill()
        }
    }
}

@Suite(.serialized) struct ThemeTileTests {
    private static let languages = ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"]
    private static let sizes: [TextSize] = [.smallest, .standard, .maximum]

    private func language(_ name: String) throws -> Bundle {
        try #require(Bundle.main.url(forResource: name, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(name).lproj")
    }

    private func makeRow(
        picked: Theme = .systemNative, textSize: TextSize = .standard, bundle: Bundle = .main, onPick: @escaping (Theme) -> Void = { _ in }
    ) -> ThemeTileRow {
        let row = ThemeTileRow(picked: picked, textSize: textSize, bundle: bundle, onPick: onPick)
        row.frame = NSRect(origin: .zero, size: row.intrinsicContentSize)
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func frames(_ row: ThemeTileRow) -> [NSRect] {
        row.layoutSubtreeIfNeeded()
        return (row.tiles as [NSView] + row.names as [NSView]).map(\.frame) + [NSRect(origin: .zero, size: row.intrinsicContentSize)]
    }

    private func clickName(_ name: ThemeTileName) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        #expect(name.hitTest(NSPoint(x: name.frame.midX, y: name.frame.midY)) === name)
        name.mouseDown(with: event)
    }

    private func painted(_ colors: [NSColor], _ look: Look) throws -> [Int] {
        let view = PaintedLayers(colors: colors)
        view.appearance = look.appearance
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try #require(srgbPixel(rep, x: 0, y: 0))
    }

    private func closeEnough(_ drawn: [Int]?, _ expected: [Int], _ what: String) {
        guard let drawn, drawn.count == 3 else {
            Issue.record("\(what): no pixel")
            return
        }
        #expect(zip(drawn, expected).allSatisfy { abs($0 - $1) <= 1 }, "\(what): drew \(drawn), expected \(expected)")
    }

    @Test func aThemeNameDoesNotMoveTheWindow() {
        let row = makeRow()
        #expect(row.names.allSatisfy { !$0.mouseDownCanMoveWindow })
    }

    @Test(arguments: Theme.allCases) func eachTileDrawsItsThemeInEveryLook(theme: Theme) throws {
        for look in Look.allCases {
            for picked in [false, true] {
                let tile = ThemeTile(theme: theme)
                tile.appearance = look.appearance
                tile.state = picked ? .on : .off
                let rep = try #require(tile.bitmapImageRepForCachingDisplay(in: tile.bounds))
                tile.cacheDisplay(in: tile.bounds, to: rep)
                let scale = rep.pixelsWide / Int(ThemeTile.Metrics.size.width)
                #expect(scale >= 1)
                func at(_ x: Int, _ y: Int) -> [Int]? { srgbPixel(rep, x: x * scale, y: y * scale) }

                let window = theme.windowBackground
                let panel = [window, theme.rowBackground]
                let label = "\(theme) \(look) picked \(picked)"
                closeEnough(at(70, 10), try painted([window], look), "\(label) tile")
                closeEnough(at(28, 10), try painted([window, theme.text], look), "\(label) header bar")
                closeEnough(at(80, 50), try painted(panel, look), "\(label) panel")
                closeEnough(at(47, 27), try painted(panel + [theme.matchText], look), "\(label) accent bar")
                closeEnough(at(38, 38), try painted(panel + [theme.text], look), "\(label) first text bar")
                closeEnough(at(32, 47), try painted(panel + [theme.secondaryText], look), "\(label) second text bar")

                if picked {
                    let accent = try painted([window, .controlAccentColor], look)
                    closeEnough(at(47, 0), accent, "\(label) border, first point")
                    closeEnough(at(47, 1), accent, "\(label) border, second point")
                    closeEnough(at(47, 2), try painted([window], look), "\(label) inside the border")
                } else {
                    closeEnough(at(47, 0), try painted([window, .separatorColor], look), "\(label) border")
                    closeEnough(at(47, 1), try painted([window], look), "\(label) inside the border")
                }
            }
        }
    }

    @Test func aPickCallsBackOnceAndARepeatedPickStaysOnWithNoSecondCall() throws {
        var picks: [Theme] = []
        let row = makeRow { picks.append($0) }

        row.tiles[1].performClick(nil)
        #expect(picks == [.inkAndGlass])
        #expect(row.picked == .inkAndGlass)

        row.tiles[1].performClick(nil)
        #expect(picks == [.inkAndGlass])
        #expect(row.tiles[1].state == .on)

        try clickName(row.names[2])
        #expect(picks == [.inkAndGlass, .warmPaper])
        #expect(row.tiles[2].state == .on)

        try clickName(row.names[2])
        #expect(picks == [.inkAndGlass, .warmPaper])
        #expect(row.tiles[2].state == .on)
    }

    @Test func anOutsidePickMovesTheTilesWithNoCallback() {
        var picks: [Theme] = []
        let row = makeRow(picked: .warmPaper) { picks.append($0) }
        row.update(picked: .midnightTeal, textSize: .standard, bundle: .main)
        #expect(row.picked == .midnightTeal)
        #expect(row.tiles.map(\.state) == [.off, .off, .off, .on])
        #expect(picks.isEmpty)
    }

    @Test func exactlyOneTileIsOnAfterAnySequence() throws {
        let row = makeRow(picked: .midnightTeal)
        func checkOne(_ step: String) {
            let on = row.tiles.filter { $0.state == .on }
            #expect(on.map(\.theme) == [row.picked], "\(step): \(row.tiles.map(\.state))")
        }
        checkOne("first")
        for index in [0, 0, 3, 1, 2, 2, 0, 3] {
            row.tiles[index].performClick(nil)
            checkOne("tile \(index)")
        }
        try clickName(row.names[1])
        checkOne("name")
        row.update(picked: .systemNative, textSize: .standard, bundle: .main)
        checkOne("outside")
        row.tiles[0].performClick(nil)
        checkOne("the tile already on")
    }

    @Test func thePlacesAreDerivedFromThePlan() throws {
        let row = makeRow()
        #expect(ThemeTileRow.width == 400)
        for (index, tile) in row.tiles.enumerated() {
            #expect(tile.frame == NSRect(x: CGFloat(index) * 102, y: 0, width: 94, height: 60))
            let name = row.names[index]
            #expect(name.frame.midX == tile.frame.midX && name.frame.width == 94 && name.frame.minY == 66)
        }
        #expect(row.intrinsicContentSize.height == 66 + row.names[0].frame.height)
        #expect(row.names[0].frame.height == row.names[0].frame.height.rounded())
    }

    @Test func rightToLeftMirrorsTheOrder() {
        let row = makeRow()
        row.userInterfaceLayoutDirection = .rightToLeft
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        #expect(row.tiles.map(\.frame.minX) == [306, 204, 102, 0])
        #expect(row.names.map(\.frame.minX) == [306, 204, 102, 0])
    }

    @Test func aPickMovesNothingInAnyLanguageOrSize() throws {
        for name in Self.languages {
            let bundle = try language(name)
            for size in Self.sizes {
                let row = makeRow(textSize: size, bundle: bundle)
                let before = frames(row)
                #expect(before.allSatisfy { $0.height > 0 })
                for tile in row.tiles.reversed() {
                    tile.performClick(nil)
                    #expect(frames(row) == before, "\(name) \(size) \(tile.theme)")
                }
            }
        }
    }

    @Test func noNameIsClippedInAnyLanguageOrSizeAndThePickIsSemibold() throws {
        for name in Self.languages {
            let bundle = try language(name)
            for size in Self.sizes {
                for picked in Theme.allCases {
                    let row = makeRow(picked: picked, textSize: size, bundle: bundle)
                    for (tile, field) in zip(row.tiles, row.names) {
                        let what = "\(name) \(size) \(tile.theme), \(picked) picked"
                        #expect(field.stringValue == tile.theme.name(bundle) && !field.stringValue.isEmpty, "\(what)")
                        #expect(NSContainsRect(row.bounds, field.frame), "\(what)")
                        let needs = try #require(field.cell).cellSize(forBounds: field.bounds)
                        #expect(needs.height <= field.bounds.height && needs.width <= field.bounds.width, "\(what): needs \(needs), has \(field.bounds)")

                        let weight: NSFont.Weight = tile.theme == picked ? .semibold : .regular
                        let font = field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                        #expect(font == NSFont.systemFont(ofSize: size.points(12), weight: weight), "\(what)")
                        let style = field.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                        #expect(style?.hyphenationFactor == 1 && style?.alignment == .center, "\(what)")
                    }
                }
            }
        }
    }

    @Test func theTilesAreRadioButtonsInOneNamedGroup() throws {
        for name in Self.languages {
            let bundle = try language(name)
            let row = makeRow(bundle: bundle)
            #expect(row.isAccessibilityElement())
            #expect(row.accessibilityRole() == .radioGroup)
            #expect(row.accessibilityIdentifier() == ThemePicker.id)
            #expect(row.accessibilityLabel() == bundle.localizedString(forKey: "Color theme", value: "\u{1}", table: "Theme"))
            for tile in row.tiles {
                let cell = try #require(tile.cell)
                #expect(cell.accessibilityRole() == .radioButton, "\(tile.theme)")
                #expect(cell.accessibilityLabel() == tile.theme.name(bundle), "\(name) \(tile.theme)")
            }
            let children = row.accessibilityChildren() ?? []
            #expect(children.count == row.tiles.count, "\(name): names must not read twice, \(children)")
        }
    }

    @Test func theRowStaysInsideThePaneAtTheMinimumWindowInRussianAtTheLargestText() async throws {
        let suite = "com.writronic.wherever.tests.themetile.pane"
        let store = try #require(UserDefaults(suiteName: suite))
        store.removePersistentDomain(forName: suite)
        store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        let width = SettingsWindow.Metrics.minSize.width - SettingsWindow.Metrics.sidebarWidth
        let form = Form { Section { WholeHeight { ThemePicker() } } }
            .formStyle(.grouped)
            .environment(\.locale, Locale(identifier: "ru"))
            .defaultAppStorage(store)
        let host = SearchHost(root: AnyView(form))
        defer { host.close() }
        host.window.setContentSize(NSSize(width: width, height: SettingsWindow.Metrics.minSize.height))
        try await host.until("the tiles in the pane") { themeTileRow(in: host.view)?.window != nil }
        let row = try #require(themeTileRow(in: host.view))
        let bundle = try language("ru")
        #expect(row.names[0].stringValue == Theme.systemNative.name(bundle))
        let label = bundle.localizedString(forKey: "Color theme", value: "\u{1}", table: "Theme")

        func text() -> NSObject? {
            AXTree.elements(in: host.view).first {
                AXTree.value("accessibilityRole", of: $0) == NSAccessibility.Role.staticText.rawValue && AXTree.names(of: $0).contains(label)
            }
        }
        try await host.until("the label") { text() != nil }
        #expect(host.view.bounds.width == width)
        let place = row.convert(row.bounds, to: host.view)
        #expect(row.frame.size == row.intrinsicContentSize)
        #expect(NSContainsRect(host.view.bounds, place), "the row is at \(place) in \(host.view.bounds)")

        let tiles = try #require(AXTree.frame(of: row))
        let words = try #require(text().flatMap(AXTree.frame(of:)))
        #expect(words.width > 0 && !words.intersects(tiles), "label \(words), tiles \(tiles)")
        #expect(tiles.minX - words.maxX >= SettingsWindow.Metrics.labelToTiles, "label \(words), tiles \(tiles)")
    }
}
