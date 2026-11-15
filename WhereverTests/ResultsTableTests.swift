import AppKit
import CoreGraphics
import Foundation
import ObjectiveC
import os
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Wherever
import WhereverInterface

nonisolated final class IconCounter: Sendable {
    private let paths = OSAllocatedUnfairLock(initialState: [String]())

    var calls: [String] { paths.withLock { $0 } }

    var loader: AppIconLoader {
        { [paths] path in
            paths.withLock { $0.append(path) }
            let context = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            return context?.makeImage()
        }
    }
}

struct Missing: Error, CustomStringConvertible {
    let description: String
}

func need<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else { throw Missing(description: what) }
    return value
}

@MainActor
private struct TableRig {
    static let million = 1_000_000

    let fake: FakeSearchClient
    let index: IndexModel
    let model: SearchModel
    let host: SearchHost
    let icons: IconCounter

    init(hits: [SearchHit], store: UserDefaults? = nil, appIcon: AppIconLoader? = nil, reportsKey: Bool = false, field: Bool = false) {
        let fake = FakeSearchClient(hits: hits)
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let icons = IconCounter()
        self.fake = fake
        self.index = index
        self.model = model
        self.icons = icons
        let table = ResultsTable(model: model, appIcon: appIcon ?? icons.loader)
        let root = field ? AnyView(SearchView(model: model)) : store.map { AnyView(table.defaultAppStorage($0)) } ?? AnyView(table)
        host = SearchHost(root: root, reportsKey: reportsKey)
    }

    static func numbered(_ count: Int) -> [SearchHit] { (0..<count).map { .named("hit-\($0)") } }

    func table() throws -> NSTableView { try need(host.list(), "no results table") }

    func search(_ query: String, count: Int) async throws {
        model.query = query
        fake.send(.resultsReady(fake.latest, count: count))
        try await host.until("\(count) results of \(query)") { !model.isPending && host.list()?.numberOfRows == count }
    }

    func liveSearch(count: Int) async throws {
        let queries = fake.queries.count
        fake.send(.resultsChanged)
        try await host.until("the live search") { fake.queries.count == queries + 1 }
        fake.send(.resultsReady(fake.latest, count: count))
        try await host.until("the live results") { model.results.live && model.results.generation == fake.latest }
    }

    func visible() throws -> ClosedRange<Int> {
        let table = try table()
        let rows = table.rows(in: table.visibleRect)
        if rows.length == 0 { throw Missing(description: "no row on screen") }
        return rows.location...rows.location + rows.length - 1
    }

    func text(row: Int, column: ResultsTable.Column = .name) -> String? {
        guard let table = host.list(), row < table.numberOfRows else { return nil }
        let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
        return (table.view(atColumn: index, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField?.stringValue
    }

    func pixel(row: Int, dy: CGFloat? = nil, top: CGFloat? = nil) throws -> [Int] {
        let table = try table()
        let x: CGFloat
        if top != nil, madeCell(row: 0) == nil {
            x = 2
        } else {
            let cell = try self.cell(row: 0)
            let inside = try need(cell.subviews.map(\.frame.minX).min(), "the Name cell holds nothing")
            x = table.convert(cell.bounds, from: cell).minX + inside / 2
        }
        let rect = table.visibleRect
        let rep = try need(table.bitmapImageRepForCachingDisplay(in: rect), "no bitmap for the table")
        table.cacheDisplay(in: rect, to: rep)
        let scale = CGFloat(rep.pixelsWide) / rect.width
        let band = table.rowHeight + table.intercellSpacing.height
        let y = (top ?? table.rect(ofRow: 0).minY) + CGFloat(row) * band + (dy ?? band / 2) - rect.minY
        return try need(srgbPixel(rep, x: Int((x - rect.minX) * scale), y: Int(y * scale)), "no pixel at row \(row)")
    }

    func madeCell(row: Int, column: ResultsTable.Column = .name) -> ResultCell? {
        guard let table = host.list(), row < table.numberOfRows else { return nil }
        let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
        return table.view(atColumn: index, row: row, makeIfNecessary: false) as? ResultCell
    }

    func cells() async throws -> [NSView] {
        let table = try table()
        var found: [NSView] = []
        for _ in 0..<40 {
            let last = found.count
            try await Task.sleep(for: .milliseconds(50))
            table.enclosingScrollView?.layoutSubtreeIfNeeded()
            table.displayIfNeeded()
            found = []
            table.enumerateAvailableRowViews { row, _ in found += row.subviews.filter { $0 is ResultCell } }
            if !found.isEmpty, found.count == last { break }
        }
        return found
    }

    func made(since before: [NSView]) async throws -> Int {
        let known = Set(before.map(ObjectIdentifier.init))
        return try await cells().filter { !known.contains(ObjectIdentifier($0)) }.count
    }

    func cell(row: Int, column: ResultsTable.Column = .name) throws -> ResultCell {
        try need(madeCell(row: row, column: column), "no cell made at row \(row)")
    }

    func jump(to row: Int) async throws {
        try table().scrollRowToVisible(row)
        try await host.until("row \(row) on screen with its cell") { (try? visible().contains(row)) == true && text(row: row) != nil }
    }

    func expectOneScreen(since before: Int, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let rows = try visible()
        let page = SearchModel.pageSize
        let pages = rows.upperBound / page - rows.lowerBound / page + 1
        let allowed = max(0, (rows.lowerBound / page - 1) * page)..<(rows.upperBound / page + 2) * page
        let requests = fake.rowRequests.dropFirst(before)
        #expect(requests.allSatisfy { $0.range.lowerBound >= allowed.lowerBound && $0.range.upperBound <= allowed.upperBound },
                "requests \(requests.map(\.range)) outside \(allowed)", sourceLocation: sourceLocation)
        #expect((1...pages + 2).contains(requests.count), "\(requests.count) calls for \(pages) visible pages", sourceLocation: sourceLocation)
        #expect(text(row: rows.lowerBound) == "hit-\(rows.lowerBound)", sourceLocation: sourceLocation)
        #expect(text(row: rows.upperBound) == "hit-\(rows.upperBound)", sourceLocation: sourceLocation)
    }
}

private func freshStore(_ name: String) -> UserDefaults {
    let suiteName = "com.writronic.wherever.tests.results.\(name)"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    return suite
}

@MainActor
private func inkedColumns(of cell: NSTableHeaderCell, size: NSSize, scale: CGFloat, in header: NSView) throws -> ClosedRange<Int> {
    let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    rep.size = size
    let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    cell.drawInterior(withFrame: NSRect(origin: .zero, size: size), in: header)
    NSGraphicsContext.restoreGraphicsState()
    let inked = (0..<rep.pixelsWide).filter { x in (0..<rep.pixelsHigh).contains { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.3 } }
    let first = try #require(inked.first, "\(cell.stringValue) inks nothing")
    return first...(inked.last ?? first)
}

@MainActor
private func painted(_ fills: [NSColor], _ look: Look, like view: NSView) throws -> [Int] {
    let rect = NSRect(x: 0, y: 0, width: 1, height: 1)
    let rep = try need(view.bitmapImageRepForCachingDisplay(in: rect), "no bitmap like the table's")
    let context = try need(NSGraphicsContext(bitmapImageRep: rep), "no graphics context")
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    look.appearance.performAsCurrentDrawingAppearance {
        for fill in fills {
            fill.setFill()
            rect.fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return try need(srgbPixel(rep, x: 0, y: 0), "no painted pixel")
}

private func headerWarmth(_ header: NSTableHeaderView) throws -> (background: Int, warmest: Int) {
    let rep = try #require(header.bitmapImageRepForCachingDisplay(in: header.bounds))
    header.cacheDisplay(in: header.bounds, to: rep)
    func warmth(_ x: Int, _ y: Int) throws -> Int {
        let pixel = try #require(srgbPixel(rep, x: x, y: y))
        return pixel[0] - pixel[2]
    }
    let background = try warmth(1, 1)
    var warmest = background
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            let here = try warmth(x, y)
            warmest = max(warmest, here)
        }
    }
    return (background, warmest)
}

@Suite(.serialized) struct ResultsTableTests {
    @Test func aMillionResultsFetchOnlyTheRowsOnScreen() async throws {
        let rig = TableRig(hits: TableRig.numbered(TableRig.million))
        defer { rig.host.close() }
        try await rig.search("hit", count: TableRig.million)
        try await rig.host.until("the first rows") { rig.text(row: 0) == "hit-0" }
        try rig.expectOneScreen(since: 0)

        let before = rig.fake.rowRequests.count
        try await rig.jump(to: 500_000)
        try rig.expectOneScreen(since: before)
    }

    @Test func aPendingSearchKeepsTheOldRowsAndNeverFetchesItsGeneration() async throws {
        let rig = TableRig(hits: TableRig.numbered(TableRig.million))
        defer { rig.host.close() }
        try await rig.search("hit", count: TableRig.million)
        let shown = rig.fake.latest
        rig.model.query = "hits"
        let pending = rig.fake.latest
        #expect(rig.model.isPending)

        try await rig.jump(to: 300_000)
        let rows = try rig.visible()
        #expect(rig.text(row: rows.lowerBound) == "hit-\(rows.lowerBound)")
        #expect(!rig.fake.rowRequests.contains { $0.generation == pending })
        #expect(rig.fake.rowRequests.allSatisfy { $0.generation == shown })
    }

    @Test func aStaleGenerationLeavesBlankCellsWithoutARetry() async throws {
        let marker = IndexState(phase: .ready, indexed: 1)
        let rig = TableRig(hits: TableRig.numbered(TableRig.million))
        defer { rig.host.close() }
        try await rig.search("hit", count: TableRig.million)
        for query in ["elsewhere", "further"] {
            let elsewhere = rig.fake.search(in: rig.fake.lastSession, query)
            rig.fake.send(.resultsReady(elsewhere, count: 1))
        }
        rig.fake.send(.stateChanged(marker))
        try await rig.host.until("both events") { rig.index.indexState == marker }

        let before = rig.fake.rowRequests.count
        try await rig.jump(to: 700_000)
        #expect(rig.text(row: 700_000) == "")
        #expect(rig.text(row: 700_000, column: .folder) == "")
        let asked = rig.fake.rowRequests.count
        #expect(asked > before)
        let table = try rig.table()
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        #expect(rig.fake.rowRequests.count == asked, "a blank page was asked for again")
    }

    @Test func rowsStayFilledWhenANewerSetIsPublishedButNotYetDelivered() async throws {
        let rig = TableRig(hits: TableRig.numbered(TableRig.million))
        defer { rig.host.close() }
        try await rig.search("hit", count: TableRig.million)
        let shown = rig.fake.latest
        rig.model.query = "hits"
        #expect(rig.fake.latest != shown)
        rig.fake.publish(rig.fake.lastSession)

        let before = rig.fake.rowRequests.count
        try await rig.jump(to: 700_000)
        #expect(rig.text(row: 700_000) == "hit-700000")
        #expect(rig.text(row: 700_000, column: .folder)?.isEmpty == false)
        let asked = rig.fake.rowRequests.dropFirst(before)
        #expect(!asked.isEmpty && asked.allSatisfy { $0.generation == shown })
    }

    @Test func theCellsShowEachColumnAndTheNameReadsPlain() async throws {
        let name = "Ünïcode Résumé.pdf"
        let folder = "/" + String(repeating: "deep folder/", count: 25)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let rig = TableRig(hits: [
            SearchHit(name: name, folder: folder, size: 2_048, modified: modified, created: .distantPast, opened: .distantPast, kind: .file),
            .named("Photos"),
        ], store: freshStore("cells"))
        defer { rig.host.close() }
        try await rig.search("r", count: 2)
        try await rig.host.until("the cells") { rig.text(row: 0) == name }

        let cell = try rig.cell(row: 0)
        #expect(cell.textField?.accessibilityValue() as? String == name)
        #expect(cell.imageView?.image != nil)
        #expect(cell.imageView?.isAccessibilityElement() == false)
        let folderCell = try rig.cell(row: 0, column: .folder)
        #expect(folder.count > 300)
        #expect(folderCell.textField?.stringValue == folder)
        #expect(folderCell.textField?.lineBreakMode == .byTruncatingMiddle)
        #expect(rig.text(row: 0, column: .size) == ByteCountFormatter.string(fromByteCount: 2_048, countStyle: .file))
        #expect(rig.text(row: 0, column: .modified) == FileDates.current.string(modified))
        #expect(rig.text(row: 0, column: .kind) == UTType.pdf.localizedDescription)
        #expect(rig.text(row: 1, column: .size) == "--", "a folder shows no size")
        #expect(rig.text(row: 1, column: .kind) == UTType.folder.localizedDescription)
        let gray = try #require(folderCell.textField?.textColor)
        #expect(eightBits(channels(gray, .light)) == eightBits(hex: 0x636366))
        #expect(eightBits(channels(gray, .dark)) == eightBits(hex: 0xA0A0A0))
    }

    @Test(arguments: [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft])
    func theSizeColumnAlignsToTheTrailingEdgeOfTheLayoutDirection(direction: NSUserInterfaceLayoutDirection) async throws {
        let rig = TableRig(hits: [SearchHit(name: "a", folder: "/", size: 2_048, modified: .now, created: .distantPast, opened: .distantPast, kind: .file)], store: freshStore("trailing"))
        defer { rig.host.close() }
        try await rig.search("a", count: 1)
        try await rig.host.until("the cells") { rig.text(row: 0) == "a" }

        let table = try rig.table()
        table.userInterfaceLayoutDirection = direction
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        try await rig.host.until("the five new cells") { ResultsTable.Column.defaults.allSatisfy { rig.madeCell(row: 0, column: $0) != nil } }
        for column in ResultsTable.Column.defaults {
            let expected: NSTextAlignment = column == .size ? (direction == .rightToLeft ? .left : .right) : .natural
            #expect(try rig.cell(row: 0, column: column).textField?.alignment == expected, "\(column) in \(direction)")
        }
    }

    @Test func theCellsTakeTheStoredThemesTextColours() async throws {
        let suite = freshStore("theme")
        suite.set(Theme.warmPaper.rawValue, forKey: Theme.key)
        let rig = TableRig(hits: [.named("Photos")], store: suite)
        defer { rig.host.close() }
        try await rig.search("p", count: 1)
        try await rig.host.until("the row") { rig.text(row: 0) == "Photos" }
        let name = try #require(try rig.cell(row: 0).textField?.textColor)
        let folder = try #require(try rig.cell(row: 0, column: .folder).textField?.textColor)
        #expect(eightBits(channels(name, .light)) == eightBits(hex: 0x2A2017))
        #expect(eightBits(channels(folder, .light)) == eightBits(hex: 0x66533F))
    }

    private func expectPixel(_ pixel: [Int], is colour: NSColor, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
        expectPixel(pixel, near: eightBits(channels(colour, .light)), message, sourceLocation: sourceLocation)
    }

    private func expectPixel(_ pixel: [Int], near wanted: [Int], _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(pixel.count == 3 && zip(pixel, wanted).allSatisfy { abs($0 - $1) <= 1 }, "\(message): painted \(pixel), wanted \(wanted)", sourceLocation: sourceLocation)
    }

    @Test func everyThemePaintsItsRowAndStripeColoursOnTheRowsAndTheEmptyAreaBelow() async throws {
        for theme in Theme.allCases {
            let suite = freshStore("rows-\(theme.rawValue)")
            suite.set(theme.rawValue, forKey: Theme.key)
            let rig = TableRig(hits: [.named("a"), .named("b")], store: suite)
            defer { rig.host.close() }
            rig.host.window.appearance = Look.light.appearance
            try await rig.search("x", count: 2)
            try await rig.host.until("the rows of \(theme)") { rig.text(row: 1) == "b" }
            let table = try rig.table()
            #expect(!table.usesAlternatingRowBackgroundColors, "the system stripes would paint under \(theme)")
            for row in 0...1 {
                let view = try #require(table.rowView(atRow: row, makeIfNecessary: false))
                #expect(view.backgroundColor == .clear, "row view \(row) of \(theme) paints over the band")
            }
            for (row, colour) in [(0, theme.rowBackground), (1, theme.stripeBackground), (2, theme.rowBackground), (3, theme.stripeBackground)] {
                expectPixel(try rig.pixel(row: row), is: colour, "row \(row) of \(theme)")
            }
        }
    }

    @Test func theEmptyStripesContinueTheRowGridWithOneRowAndWithNone() async throws {
        let theme = Theme.systemNative
        let rig = TableRig(hits: [.named("a")], store: freshStore("edges"))
        defer { rig.host.close() }
        rig.host.window.appearance = Look.light.appearance
        try await rig.search("x", count: 1)
        try await rig.host.until("row 0") { rig.text(row: 0) == "a" }
        let table = try rig.table()
        let top = table.rect(ofRow: 0).minY
        let band = table.rowHeight + table.intercellSpacing.height
        let edge = 0.5 / rig.host.window.backingScaleFactor
        func expectGrid(_ when: String, top: CGFloat?) throws {
            for row in 0...3 {
                for (side, dy) in [("top", edge), ("bottom", band - edge)] {
                    let colour = row % 2 == 0 ? theme.rowBackground : theme.stripeBackground
                    expectPixel(try rig.pixel(row: row, dy: dy, top: top), is: colour, "\(side) edge of row \(row), \(when)")
                }
            }
        }
        try expectGrid("one result", top: nil)
        try await rig.search("y", count: 0)
        try expectGrid("no result", top: top)
    }

    @Test func aThemeChangeKeepsTheSelectedRows() async throws {
        let suite = freshStore("selection")
        let rig = TableRig(hits: TableRig.numbered(6), store: suite)
        defer { rig.host.close() }
        rig.host.window.appearance = Look.light.appearance
        try await rig.search("x", count: 6)
        try await rig.host.until("the rows") { rig.text(row: 5) == "hit-5" }
        let table = try rig.table()
        table.selectRowIndexes([2, 3, 4], byExtendingSelection: false)
        let before = try rig.pixel(row: 1)

        suite.set(Theme.midnightTeal.rawValue, forKey: Theme.key)
        try await rig.host.until("the new theme") { (try? rig.pixel(row: 1)).map { $0 != before } == true }
        #expect(table.selectedRowIndexes == [2, 3, 4])
    }

    @Test func aThemeChangeRepaintsTheRowsAlreadyOnScreen() async throws {
        let suite = freshStore("repaint")
        let rig = TableRig(hits: [.named("a"), .named("b")], store: suite)
        defer { rig.host.close() }
        rig.host.window.appearance = Look.light.appearance
        try await rig.search("x", count: 2)
        try await rig.host.until("the rows") { rig.text(row: 1) == "b" }
        expectPixel(try rig.pixel(row: 1), is: Theme.systemNative.stripeBackground, "row 1 before the change")
        let before = try rig.pixel(row: 1)

        suite.set(Theme.midnightTeal.rawValue, forKey: Theme.key)
        try await rig.host.until("the new theme") { (try? rig.pixel(row: 1)).map { $0 != before } == true }
        for (row, colour) in [(0, Theme.midnightTeal.rowBackground), (1, Theme.midnightTeal.stripeBackground), (3, Theme.midnightTeal.stripeBackground)] {
            expectPixel(try rig.pixel(row: row), is: colour, "row \(row) after the change")
        }
        let view = try #require(try rig.table().rowView(atRow: 1, makeIfNecessary: false))
        #expect(view.backgroundColor == .clear, "the row view paints over the new band")
    }

    @Test(arguments: Theme.allCases)
    func aWindowAppearanceFlipRepaintsRowsStripesAndTextAlreadyOnScreen(theme: Theme) async throws {
        let suite = freshStore("flip-\(theme.rawValue)")
        suite.set(theme.rawValue, forKey: Theme.key)
        let matched = SearchHit(
            name: "alpha", folder: "/Applications", size: 0, modified: Date(timeIntervalSince1970: 0), created: .distantPast,
            opened: .distantPast, kind: .folder, matches: [0..<2]
        )
        let rig = TableRig(hits: [matched, .named("b")], store: suite)
        defer { rig.host.close() }
        rig.host.window.appearance = Look.light.appearance
        try await rig.search("al", count: 2)
        try await rig.host.until("the rows of \(theme)") { rig.text(row: 1) == "b" }
        let table = try rig.table()

        for look in [Look.light, .dark, .light] {
            rig.host.window.appearance = look.appearance
            let row = try painted([theme.rowBackground], look, like: table)
            let stripe = try painted([theme.rowBackground, theme.stripeBackground], look, like: table)
            try await rig.host.until("row 0 of \(theme) in \(look), painted \(String(describing: try? rig.pixel(row: 0))), wanted \(row)") {
                (try? rig.pixel(row: 0)).map { zip($0, row).allSatisfy { abs($0 - $1) <= 1 } } == true
            }
            let pixels = try (0...3).map { try rig.pixel(row: $0) }
            for (index, wanted) in [row, stripe, row, stripe].enumerated() {
                expectPixel(pixels[index], near: wanted, "row \(index) of \(theme) in \(look)")
            }
            expectPixel(pixels[1], near: pixels[3], "\(theme) in \(look): the stripe under a result against the empty stripe below")

            let plain = try #require(try rig.cell(row: 1).textField?.textColor)
            let folder = try #require(try rig.cell(row: 1, column: .folder).textField?.textColor)
            #expect(channels(plain, look) == channels(theme.text, look), "\(theme) name text in \(look)")
            #expect(channels(folder, look) == channels(theme.secondaryText, look), "\(theme) folder text in \(look)")
            let name = try #require(try rig.cell(row: 0).textField?.attributedStringValue)
            let letter = try #require(name.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            let rest = try #require(name.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor)
            let bold = try #require(name.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(channels(letter, look) == channels(theme.matchText, look), "\(theme) match letters in \(look)")
            #expect(channels(rest, look) == channels(theme.text, look), "\(theme) letters after the match in \(look)")
            #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask), "\(theme) match letters are not bold")
        }
    }

    @Test func theRowHeightIsTheFontsLineHeightPlusTwoInsetsAndRowZeroSitsBelowTheHeader() async throws {
        let rig = TableRig(hits: TableRig.numbered(50))
        defer { rig.host.close() }
        try await rig.search("hit", count: 50)
        try await rig.host.until("row 0") { rig.text(row: 0) == "hit-0" }
        let table = try rig.table()
        let scale = rig.host.window.backingScaleFactor
        let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: NSFont.systemFontSize))
        let metric = (lineHeight + 2 * SearchMetrics.rowInset).rounded(.up)
        #expect(ResultsTable.rowHeight(.standard) == metric)
        #expect((table.rect(ofRow: 0).height - metric) * scale == 0)
        #expect((table.rect(ofRow: 1).minY - table.rect(ofRow: 0).maxY) * scale == 0)

        let header = try #require(table.headerView)
        let headerFrame = header.convert(header.bounds, to: nil)
        let rowFrame = table.convert(table.rect(ofRow: 0), to: nil)
        #expect(rowFrame.maxY <= headerFrame.minY, "row 0 \(rowFrame) slips under the header \(headerFrame)")
        #expect(try rig.visible().lowerBound == 0)
    }

    @Test func theHeaderAndColumnsFollowTheDrawing() async throws {
        let store = freshStore("header")
        store.set(Theme.warmPaper.rawValue, forKey: Theme.key)
        let rig = TableRig(hits: TableRig.numbered(5), store: store)
        defer { rig.host.close() }
        try await rig.search("hit", count: 5)
        try await rig.host.until("row 0") { rig.text(row: 0) == "hit-0" }
        let table = try rig.table()
        let scale = rig.host.window.backingScaleFactor
        #expect(table.style == .inset)
        let header = try #require(table.headerView)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: ResultsTable.headerFont(.standard))
        #expect(ResultsTable.headerHeight(.standard) == ceil(lineHeight + 2 * SearchMetrics.headerInset) + 1)
        #expect((header.frame.height - ResultsTable.headerHeight(.standard)) * scale == 0)

        func width(_ column: ResultsTable.Column) -> CGFloat {
            table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))?.width ?? 0
        }
        func resize(to width: CGFloat) async throws {
            rig.host.window.setContentSize(NSSize(width: width, height: SearchMetrics.windowMinHeight))
            try await rig.host.until("the window at \(width) pt") { rig.host.view.frame.width == width }
        }
        try await resize(to: 1_200)
        let before = ResultsTable.Column.defaults.map(width)
        try await resize(to: 1_300)
        let after = ResultsTable.Column.defaults.map(width)
        #expect(before.prefix(4) == [270, 280, 80, ResultsTable.modifiedWidth(.standard)], "the four drawn widths")
        #expect(after.prefix(4) == before.prefix(4), "no column but the last grows")
        #expect(after[4] - before[4] == 100)
        try await resize(to: SearchMetrics.windowMinWidth)
        #expect(width(.kind) >= SearchMetrics.kindColumnWidth)

        let size = try #require(table.tableColumns.first { $0.identifier.rawValue == ResultsTable.Column.size.rawValue })
        #expect(size.headerCell.alignment == .right)
        for look in [Look.light, .dark] {
            rig.host.window.appearance = look.appearance
            let (background, warmest) = try headerWarmth(header)
            #expect(abs(background) <= 3 && warmest - background >= 25, "\(look) header text: warmest pixel \(warmest), background \(background)")
        }
    }

    @Test func aStoredTextSizeSetsTheRowsTheHeaderAndTheColumns() async throws {
        let store = freshStore("textsize")
        store.set(TextSize.extraLarge.rawValue, forKey: TextSize.key)
        let rig = TableRig(hits: TableRig.numbered(50), store: store)
        defer { rig.host.close() }
        try await rig.search("hit", count: 50)
        rig.host.window.setContentSize(NSSize(width: 1_600, height: SearchMetrics.windowMinHeight))
        try await rig.host.until("the window at 1,600 pt") { rig.host.view.frame.width == 1_600 }
        try await rig.host.until("row 0's Name and Modified cells") { rig.text(row: 0) == "hit-0" && rig.madeCell(row: 0, column: .modified) != nil }
        let table = try rig.table()
        let header = try #require(table.headerView)
        #expect(table.rowHeight == 26)
        #expect(ResultsTable.rowHeight(.extraLarge) == 26)
        #expect(header.frame.height == 28)
        #expect(ResultsTable.headerHeight(.extraLarge) == 28)
        #expect(try rig.cell(row: 0).textField?.font == ResultsTable.font(.extraLarge))
        #expect(try rig.cell(row: 0).textField?.font?.pointSize == 16)
        let modified = try #require(try rig.cell(row: 0, column: .modified).textField?.font)
        #expect(modified == ResultsTable.dateFont(.extraLarge) && modified.pointSize == 16)
        #expect(modified != ResultsTable.font(.extraLarge))
        let drawn = try #require(header.bitmapImageRepForCachingDisplay(in: header.bounds))
        header.cacheDisplay(in: header.bounds, to: drawn)
        for column in table.tableColumns { #expect(column.headerCell.font?.pointSize == 14, "\(column.identifier.rawValue) header") }
        func width(_ column: ResultsTable.Column) -> CGFloat {
            table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))?.width ?? 0
        }
        #expect(width(.name) == 332 && width(.folder) == 345 && width(.size) == 98)
        #expect(width(.modified) == FileDates.current.width(.extraLarge))
        #expect(FileDates.current.width(.extraLarge) > FileDates.current.width(.standard))
        let row = table.convert(table.rect(ofRow: 0), to: nil)
        #expect(row.maxY <= header.convert(header.bounds, to: nil).minY, "row 0 \(row) slips under the header")
        #expect(try rig.visible().lowerBound == 0)
    }

    @Test func aLiveTextSizeSwitchRedrawsInPlaceAndKeepsTheTopRow() async throws {
        let store = freshStore("textsize.live")
        let rig = TableRig(hits: TableRig.numbered(1_000), store: store)
        defer { rig.host.close() }
        try await rig.search("hit", count: 1_000)
        try await rig.host.until("row 0") { rig.text(row: 0) == "hit-0" }
        let table = try rig.table()
        let header = try #require(table.headerView)
        let scroll = try #require(table.enclosingScrollView)
        let clip = scroll.contentView
        func rowTop() -> CGFloat { table.convert(table.rect(ofRow: 0), to: nil).maxY }
        func topRow() -> Int { table.row(at: NSPoint(x: table.bounds.midX, y: clip.bounds.minY + clip.contentInsets.top)) }
        func visibleFonts() throws -> Set<CGFloat> {
            Set(try rig.visible().compactMap { rig.madeCell(row: $0)?.textField?.font?.pointSize })
        }
        #expect(table.rowHeight == 24 && header.frame.height == 24)
        let before = rowTop()

        func drawnHeaderFonts() throws -> Set<NSFont?> {
            let drawn = try #require(header.bitmapImageRepForCachingDisplay(in: header.bounds))
            header.cacheDisplay(in: header.bounds, to: drawn)
            return Set(table.tableColumns.map(\.headerCell.font))
        }
        store.set(TextSize.extraLarge.rawValue, forKey: TextSize.key)
        try await rig.host.until("26 pt rows with 16 pt text") { table.rowHeight == 26 && (try? visibleFonts()) == [16] }
        #expect(header.frame.height == 28)
        #expect(try drawnHeaderFonts() == [ResultsTable.headerFont(.extraLarge)])
        #expect(before - rowTop() == 4, "row 0 moved \(before - rowTop()) pt, the header grew 4")
        #expect(rowTop() <= header.convert(header.bounds, to: nil).minY)
        #expect(try rig.visible().lowerBound == 0)

        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: table.rect(ofRow: 200).minY - clip.contentInsets.top))
        scroll.reflectScrolledClipView(clip)
        table.selectRowIndexes([203], byExtendingSelection: false)
        try await rig.host.until("row 200 at the top") { topRow() == 200 && rig.text(row: 200) == "hit-200" }
        for size in [TextSize.maximum, .smallest] {
            store.set(size.rawValue, forKey: TextSize.key)
            let height = ResultsTable.rowHeight(size)
            try await rig.host.until("\(height) pt rows at \(size)") { table.rowHeight == height && (try? visibleFonts()) == [size.points(13)] }
            #expect(topRow() == 200, "\(size): row \(topRow()) at the top")
            #expect(header.frame.height == ResultsTable.headerHeight(size))
            #expect(try drawnHeaderFonts() == [ResultsTable.headerFont(size)], "\(size)")
            #expect(table.selectedRowIndexes == [203], "\(size)")
            #expect(rig.text(row: 200) == "hit-200")
        }
        #expect(ResultsTable.rowHeight(.maximum) == 29 && ResultsTable.rowHeight(.smallest) == 21)
    }

    @Test func dateWidthKeepsTheDesignMinimumAndIncludesTheCompleteTimestamp() {
        let mono = ResultsTable.dateFont(.standard)
        for locale in ["en_US", "en_GB"] {
            let dates = FileDates(locale: Locale(identifier: locale))
            let width = dates.columnWidth(font: mono)
            let label = NSTextField(labelWithString: dates.string(.now))
            label.font = mono
            #expect(width >= SearchMetrics.modifiedColumnWidth)
            #expect(width >= ceil(label.intrinsicContentSize.width) + 2 * SearchMetrics.cellPadding)
            #expect(width == width.rounded(.up))
        }
    }

    @Test func theModifiedCellWritesTheSystemDateAndTime() async throws {
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: .now))
        let hits = [yesterday, .now, Date(timeIntervalSince1970: 1_700_000_000)].enumerated().map {
            SearchHit(name: "dated-\($0.offset)", folder: "/", size: 1, modified: $0.element, created: .distantPast, opened: .distantPast, kind: .file)
        }
        let rig = TableRig(hits: hits, store: freshStore("relativedates"))
        defer { rig.host.close() }
        try await rig.search("dated", count: 3)
        try await rig.host.until("row 2") { rig.text(row: 2, column: .modified) != nil }
        for (row, hit) in hits.enumerated() {
            #expect(rig.text(row: row, column: .modified) == FileDates.current.string(hit.modified), "row \(row)")
        }
        #expect(rig.text(row: 1, column: .modified) != hits[1].modified.formatted(date: .abbreviated, time: .shortened))
    }

    @Test func theMeasuredWidthsFitWithKindTakingTheRest() async throws {
        let rig = TableRig(hits: TableRig.numbered(5))
        defer { rig.host.close() }
        try await rig.search("hit", count: 5)
        try await rig.host.until("row 0's Name cell") { rig.madeCell(row: 0, column: .name) != nil }
        let table = try rig.table()
        let scroll = try #require(table.enclosingScrollView)
        let leadingCell = try rig.cell(row: 0, column: .name)
        let initialInset = table.convert(leadingCell.bounds, from: leadingCell).minX - table.bounds.minX
        let requestedWidth = ResultsTable.Column.defaults.map { $0.width(.standard) }.reduce(0, +)
            + 2 * initialInset + SearchMetrics.kindColumnWidth
        rig.host.window.setContentSize(NSSize(width: requestedWidth, height: SearchMetrics.windowMinHeight))
        try await rig.host.until("the window fits the measured columns") { rig.host.view.frame.width == requestedWidth }
        try await rig.host.until("row 0's Kind cell") { rig.madeCell(row: 0, column: .kind) != nil }
        let columns: [ResultsTable.Column] = [.name, .folder, .size, .modified]
        let drawn = [SearchMetrics.nameColumnWidth, SearchMetrics.folderColumnWidth, SearchMetrics.sizeColumnWidth, ResultsTable.modifiedWidth(.standard)]
        let spacing = table.intercellSpacing.width
        let clip = scroll.contentView.bounds.width
        func frame(_ column: ResultsTable.Column) throws -> NSRect {
            let cell = try rig.cell(row: 0, column: column)
            return table.convert(cell.bounds, from: cell)
        }
        let inset = try frame(.name).minX - table.bounds.minX
        let kindWidth = clip - drawn.reduce(0, +) - 2 * inset
        try await rig.host.until("Kind filling the rest, \(kindWidth) pt, not \(table.tableColumns.map(\.width))") {
            table.tableColumns.last?.width == kindWidth
        }
        table.layoutSubtreeIfNeeded()
        let widths = try columns.map { try frame($0).width }
        let kind = try frame(.kind)
        #expect(widths == drawn, "the drawn cells")
        #expect(kind.width == kindWidth)
        #expect(table.bounds.maxX - kind.maxX == inset, "Kind's cell ends at \(kind.maxX) in \(table.bounds)")
        #expect(kindWidth > SearchMetrics.kindColumnWidth)
        #expect(table.frame.width <= clip, "the table is \(table.frame.width) pt in a \(clip) pt clip")
        #expect(spacing == 0, "the cells carry their own padding")
    }

    @Test func everyHeaderTitleKeepsTheCellPaddingFromItsColumnEdge() async throws {
        let rig = TableRig(hits: TableRig.numbered(5))
        defer { rig.host.close() }
        try await rig.search("hit", count: 5)
        rig.host.window.setContentSize(NSSize(width: 940, height: SearchMetrics.windowMinHeight))
        try await rig.host.until("row 0's Kind cell at 940 pt") { rig.host.view.frame.width == 940 && rig.madeCell(row: 0, column: .kind) != nil }
        let table = try rig.table()
        table.layoutSubtreeIfNeeded()
        let header = try #require(table.headerView)
        let scale = rig.host.window.backingScaleFactor
        let trailing = ResultsTable.trailing(in: table.userInterfaceLayoutDirection)
        for (index, column) in table.tableColumns.enumerated() {
            let cell = try #require(column.headerCell as? ResultsTable.ToneHeaderCell)
            let stock = NSTableHeaderCell(textCell: cell.stringValue)
            stock.font = cell.font
            stock.alignment = cell.alignment
            stock.textColor = cell.theme.secondaryText
            let rect = header.headerRect(ofColumn: index)
            let row = try rig.cell(row: 0, column: try #require(ResultsTable.Column(rawValue: column.identifier.rawValue)))
            let edge = table.convert(row.bounds, from: row)
            let ours = try inkedColumns(of: cell, size: rect.size, scale: scale, in: header)
            let plain = try inkedColumns(of: stock, size: rect.size, scale: scale, in: header)
            let isTrailing = cell.alignment == trailing
            let moved = CGFloat(isTrailing ? plain.upperBound - ours.upperBound : ours.lowerBound - plain.lowerBound)
            let inset = isTrailing ? rect.maxX - edge.maxX : edge.minX - rect.minX
            #expect(moved == (SearchMetrics.cellPadding + inset) * scale, "\(cell.stringValue) inks \(ours), AppKit's own \(plain), row cell \(edge)")
        }
    }

    @Test func copiesOfTheHeaderCellsLeaveTheDrawnToneIntact() async throws {
        let store = freshStore("headercopies")
        store.set(Theme.warmPaper.rawValue, forKey: Theme.key)
        let rig = TableRig(hits: TableRig.numbered(5), store: store)
        defer { rig.host.close() }
        try await rig.search("hit", count: 5)
        try await rig.host.until("row 0") { rig.text(row: 0) == "hit-0" }
        let table = try rig.table()
        let header = try #require(table.headerView)
        for _ in 0..<500 {
            for column in table.tableColumns { autoreleasepool { _ = column.headerCell.copy() } }
        }
        for look in [Look.light, .dark] {
            rig.host.window.appearance = look.appearance
            let (background, warmest) = try headerWarmth(header)
            #expect(abs(background) <= 3 && warmest - background >= 25, "\(look) header text after the copies: warmest pixel \(warmest), background \(background)")
        }
    }

    @Test func theCellsKeepTheDrawnPadding() async throws {
        let rig = TableRig(hits: [.named("Photos")])
        defer { rig.host.close() }
        try await rig.search("p", count: 1)
        try await rig.host.until("the row") { rig.text(row: 0) == "Photos" }
        let cell = try rig.cell(row: 0)
        cell.layoutSubtreeIfNeeded()
        func placed(_ view: NSView) -> CGRect { view.alignmentRect(forFrame: view.frame) }
        let icon = placed(try #require(cell.imageView))
        let text = placed(try #require(cell.textField))
        #expect(icon.minX == SearchMetrics.cellPadding)
        #expect(text.minX == icon.maxX + SearchMetrics.iconGap)
        #expect(cell.bounds.width - text.maxX == SearchMetrics.cellPadding)
        let folder = try rig.cell(row: 0, column: .folder)
        folder.layoutSubtreeIfNeeded()
        #expect(placed(try #require(folder.textField)).minX == SearchMetrics.cellPadding, "no icon: the text starts at the padding")
    }

    @Test func aLiveSearchKeepsTheSelectedFileWhileItStaysInItsPage() async throws {
        let rig = TableRig(hits: TableRig.numbered(1_000))
        defer { rig.host.close() }
        try await rig.search("hit", count: 1_000)
        try await rig.jump(to: 700)
        let top = try rig.visible().lowerBound
        let table = try rig.table()
        table.selectRowIndexes([700], byExtendingSelection: false)

        var moved = TableRig.numbered(1_000)
        moved.insert(.named("new"), at: 650)
        rig.fake.setHits(moved)
        try await rig.liveSearch(count: 1_001)
        try await rig.host.until("the selection to follow hit-700") { table.selectedRow == 701 && table.numberOfRows == 1_001 }
        #expect(try rig.visible().lowerBound == top, "a live re-search keeps the scroll position")

        rig.fake.setHits(moved.filter { $0.name != "hit-700" })
        try await rig.liveSearch(count: 1_000)
        try await rig.host.until("the selection to clear") { table.selectedRow == -1 && table.numberOfRows == 1_000 }
    }

    @Test func aGrowingContentSetKeepsTheSelection() async throws {
        let rig = TableRig(hits: TableRig.numbered(20))
        defer { rig.host.close() }
        rig.model.content = ContentTerms(terms: ["hit"])
        rig.model.searchContent()
        let press = try #require(rig.model.press)
        rig.fake.send(.resultsReady(press, count: 10))
        try await rig.host.until("the first files") { !rig.model.isPending && rig.host.list()?.numberOfRows == 10 }
        let table = try rig.table()
        table.selectRowIndexes([4], byExtendingSelection: false)
        rig.fake.send(.resultsReady(press, count: 20))
        try await rig.host.until("the grown set") { table.numberOfRows == 20 }
        #expect(table.selectedRow == 4)
        #expect(rig.model.results.live)
        #expect(rig.fake.queries.isEmpty)
    }

    @Test func aNewQueryClearsTheSelectionAndGoesToTheTop() async throws {
        let rig = TableRig(hits: TableRig.numbered(1_000))
        defer { rig.host.close() }
        try await rig.search("hit", count: 1_000)
        try await rig.jump(to: 700)
        let table = try rig.table()
        table.selectRowIndexes([700], byExtendingSelection: false)
        let before = try await rig.cells()
        try #require(!before.isEmpty)
        try await rig.search("hit-", count: 1_000)
        try await rig.host.until("no selection at the top") { table.selectedRow == -1 && (try? rig.visible().lowerBound) == 0 }
        try await rig.host.until("the top row's cell") { rig.text(row: 0) == "hit-0" }
        let made = try await rig.made(since: before)
        #expect(made == 0, "a new query reuses the cells")
    }

    @Test func aNewQueryClearsTheSelectionWithOneNoticeOfNothing() async throws {
        let rig = TableRig(hits: TableRig.numbered(1_000))
        defer { rig.host.close() }
        try await rig.search("hit", count: 1_000)
        try await rig.jump(to: 700)
        let table = try rig.table()
        let coordinator = try #require(table.delegate as? ResultsTable.Coordinator)
        var heard: [String] = []

        table.selectRowIndexes([700], byExtendingSelection: false)
        try #require(table.selectedRowIndexes == [700])
        coordinator.onSelect = { hit, count in heard.append("\(hit?.name ?? "nil") \(count)") }
        try await rig.search("hit-", count: 50)
        try await rig.host.until("no selection at the top of 50 rows") { table.selectedRow == -1 && (try? rig.visible().lowerBound) == 0 }
        #expect(heard == ["nil 0"], "a shrinking new query clears the selection with one notice")

        table.selectRowIndexes([5], byExtendingSelection: false)
        try #require(table.selectedRowIndexes == [5])
        heard = []
        try await rig.search("hit", count: 50)
        try await rig.host.until("no selection after a same-size new query") { table.selectedRow == -1 }
        #expect(heard == ["nil 0"], "a same-size new query clears the selection with one notice")

        table.selectRowIndexes([5], byExtendingSelection: false)
        heard = []
        try await rig.search("hit-1", count: 1_000)
        try await rig.host.until("no selection after a growing new query") { table.selectedRow == -1 }
        #expect(heard == ["nil 0"], "a growing new query clears the selection with one notice")
    }

    @Test func twoWindowsOverOneModelKeepTheirOwnSelection() async throws {
        let rig = TableRig(hits: TableRig.numbered(10))
        defer { rig.host.close() }
        let second = SearchHost(root: AnyView(ResultsTable(model: rig.model, appIcon: rig.icons.loader)))
        defer { second.close() }
        try await rig.search("hit", count: 10)
        let other = try #require(second.list())
        try await second.until("the second window's rows") { other.numberOfRows == 10 && second.shows("hit-3") }
        try rig.table().selectRowIndexes([3], byExtendingSelection: false)
        rig.fake.setHits(TableRig.numbered(11))
        try await rig.liveSearch(count: 11)
        try await rig.host.until("the first window's reload") { (try? rig.table().numberOfRows) == 11 }
        try await second.until("the second window's reload") { other.numberOfRows == 11 }
        #expect(try rig.table().selectedRow == 3)
        #expect(other.selectedRow == -1)
    }

    @Test func aDatalessAppRowGetsTheGenericIcon() async throws {
        let nowhere = "/nonexistent-\(UUID().uuidString)"
        let tool = SearchHit(name: "Tool.app", folder: nowhere, size: 0, modified: .now, created: .distantPast, opened: .distantPast, kind: .folder)
        let checked = OSAllocatedUnfairLock(initialState: [String]())
        let icons = IconCounter()
        let loader = ResultsTable.skippingDataless(icons.loader) { path in
            checked.withLock { $0.append(path) }
            return true
        }
        let rig = TableRig(hits: [tool], appIcon: loader)
        defer { rig.host.close() }
        try await rig.search("tool", count: 1)
        let path = nowhere + "/Tool.app"
        try await rig.host.until("the placeholder asked about") { checked.withLock { $0 } == [path] }
        try await rig.host.until("the generic icon in its cell") {
            guard let size = rig.madeCell(row: 0)?.imageView?.image?.size else { return false }
            return size != NSSize(width: 1, height: 1)
        }
        #expect(icons.calls.isEmpty)
        let local = ResultsTable.skippingDataless(icons.loader) { _ in false }
        #expect(local(path) != nil)
        #expect(icons.calls == [path])
    }

    @Test func kindAndIconNeverReadTheDiskAndAnAppIconLoadsOnce() async throws {
        let nowhere = "/nonexistent-\(UUID().uuidString)"
        let report = SearchHit(name: "Report.pdf", folder: nowhere, size: 1, modified: .now, created: .distantPast, opened: .distantPast, kind: .file)
        let tool = SearchHit(name: "Tool.app", folder: nowhere, size: 0, modified: .now, created: .distantPast, opened: .distantPast, kind: .folder)
        let rig = TableRig(hits: [report] + Array(repeating: report, count: 600))
        defer { rig.host.close() }
        try await rig.search("report", count: 601)
        try await rig.host.until("the first row") { rig.text(row: 0, column: .kind) == UTType.pdf.localizedDescription }
        #expect(try rig.cell(row: 0).imageView?.image != nil)
        #expect(rig.icons.calls.isEmpty)

        rig.fake.setHits([tool] + Array(repeating: report, count: 600))
        try await rig.search("tool", count: 601)
        let path = nowhere + "/Tool.app"
        try await rig.host.until("the app icon in its cell") {
            rig.madeCell(row: 0)?.imageView?.image?.size == NSSize(width: 1, height: 1)
        }
        #expect(rig.icons.calls == [path])
        try await rig.jump(to: 590)
        try await rig.jump(to: 0)
        try await rig.host.until("the cached icon") { rig.madeCell(row: 0)?.imageView?.image?.size == NSSize(width: 1, height: 1) }
        #expect(rig.icons.calls == [path])
    }

    @Test func jumpsAcrossAMillionRowsShowTheRightRowAndPrintTheFrameTime() async throws {
        let rig = TableRig(hits: TableRig.numbered(TableRig.million))
        defer { rig.host.close() }
        try await rig.search("hit", count: TableRig.million)
        let table = try rig.table()
        let clock = ContinuousClock()
        var times: [Duration] = []
        for jump in 1...50 {
            let row = jump * (TableRig.million / 51)
            let before = rig.fake.rowRequests.count
            times.append(clock.measure {
                table.scrollRowToVisible(row)
                table.enclosingScrollView?.layoutSubtreeIfNeeded()
                table.displayIfNeeded()
            })
            try await rig.host.until("row \(row) on screen") { (try? rig.visible().contains(row)) == true && rig.text(row: row) != nil }
            try rig.expectOneScreen(since: before)
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: "scroll frame budget: median %.3f ms over %d jumps, limit 8.33 ms", median / .milliseconds(1), times.count))
    }
}

extension ResultsTableTests {
    @Test func aLiveSearchKeepsEverySelectedFileInItsPage() async throws {
        let rig = TableRig(hits: TableRig.numbered(1_000))
        defer { rig.host.close() }
        try await rig.search("hit", count: 1_000)
        try await rig.jump(to: 700)
        let table = try rig.table()
        table.selectRowIndexes([700, 702], byExtendingSelection: false)
        try #require(table.selectedRowIndexes == [700, 702])

        var moved = TableRig.numbered(1_000)
        moved.insert(.named("new"), at: 650)
        rig.fake.setHits(moved)
        try await rig.liveSearch(count: 1_001)
        try await rig.host.until("hit-700 and hit-702 at 701 and 703, selected \(Array(table.selectedRowIndexes))") {
            table.selectedRowIndexes == [701, 703] && table.numberOfRows == 1_001
        }

        moved.removeAll { $0.name == "hit-700" }
        rig.fake.setHits(moved)
        try await rig.liveSearch(count: 1_000)
        try await rig.host.until("hit-702 alone at 702, selected \(Array(table.selectedRowIndexes))") {
            table.selectedRowIndexes == [702] && table.numberOfRows == 1_000
        }

        moved.removeAll { $0.name == "hit-702" }
        rig.fake.setHits(moved)
        try await rig.liveSearch(count: 999)
        try await rig.host.until("no selection, selected \(Array(table.selectedRowIndexes))") {
            table.selectedRowIndexes.isEmpty && table.numberOfRows == 999
        }
    }

    @Test func aLiveSearchKeepsSelectAllAndClearsOtherLargeSelections() async throws {
        let rig = TableRig(hits: TableRig.numbered(2_000))
        defer { rig.host.close() }
        try await rig.search("hit", count: 2_000)
        let table = try rig.table()
        table.selectAll(nil)
        try #require(table.selectedRowIndexes.count == 2_000)
        rig.fake.setHits(TableRig.numbered(2_001))
        try await rig.liveSearch(count: 2_001)
        try await rig.host.until("every row selected, \(table.selectedRowIndexes.count) of \(table.numberOfRows)") {
            table.numberOfRows == 2_001 && table.selectedRowIndexes == IndexSet(0..<2_001)
        }

        table.selectRowIndexes(IndexSet(0..<1_500), byExtendingSelection: false)
        try #require(table.selectedRowIndexes.count == 1_500)
        let coordinator = try #require(table.delegate as? ResultsTable.Coordinator)
        var heard: [String] = []
        coordinator.onSelect = { hit, count in heard.append("\(hit?.name ?? "nil") \(count)") }
        try await rig.liveSearch(count: 2_001)
        try await rig.host.until("the selection to clear, selected \(table.selectedRowIndexes.count)") { table.selectedRowIndexes.isEmpty }
        #expect(heard == ["nil 0"])
    }

    @Test func aSavedFileThatJumpsToTheTopPageStaysSelectedAndFollowsItBack() async throws {
        let rig = TableRig(hits: TableRig.numbered(1_000))
        defer { rig.host.close() }
        try await rig.search("hit", count: 1_000)
        let table = try rig.table()
        table.selectRowIndexes([130], byExtendingSelection: false)
        try #require(table.selectedRowIndexes == [130])
        let coordinator = try #require(table.delegate as? ResultsTable.Coordinator)
        var heard: [String] = []
        coordinator.onSelect = { hit, count in heard.append("\(hit?.name ?? "nil") \(count)") }

        var moved = TableRig.numbered(1_000)
        moved.insert(moved.remove(at: 130), at: 0)
        rig.fake.setHits(moved)
        try await rig.liveSearch(count: 1_000)
        try await rig.host.until("hit-130 at row 0, selected \(Array(table.selectedRowIndexes))") { table.selectedRowIndexes == [0] }
        #expect(heard == ["hit-130 1"])

        rig.fake.setHits(TableRig.numbered(1_000))
        try await rig.liveSearch(count: 1_000)
        try await rig.host.until("hit-130 back at row 130, selected \(Array(table.selectedRowIndexes))") { table.selectedRowIndexes == [130] }
        #expect(heard == ["hit-130 1", "hit-130 1"])
    }

    @Test func aLiveSearchFollowsAFileThatSlidesIntoTheNextPageBesideOneThatStays() async throws {
        let rig = TableRig(hits: TableRig.numbered(1_000))
        defer { rig.host.close() }
        try await rig.search("hit", count: 1_000)
        let table = try rig.table()
        table.selectRowIndexes([100, 127], byExtendingSelection: false)
        try #require(table.selectedRowIndexes == [100, 127])

        var moved = TableRig.numbered(1_000)
        moved.insert(.named("new"), at: 0)
        rig.fake.setHits(moved)
        try await rig.liveSearch(count: 1_001)
        try await rig.host.until("hit-100 and hit-127 at 101 and 128, selected \(Array(table.selectedRowIndexes))") {
            table.selectedRowIndexes == [101, 128] && table.numberOfRows == 1_001
        }
    }

    @Test func aFileTwoPagesAwayOrANamesakeInAnotherFolderIsNeverSelected() async throws {
        let rig = TableRig(hits: TableRig.numbered(1_000))
        defer { rig.host.close() }
        try await rig.search("hit", count: 1_000)
        let table = try rig.table()
        table.selectRowIndexes([130], byExtendingSelection: false)
        try #require(table.selectedRowIndexes == [130])
        let coordinator = try #require(table.delegate as? ResultsTable.Coordinator)
        var heard: [String] = []
        coordinator.onSelect = { hit, count in heard.append("\(hit?.name ?? "nil") \(count)") }

        var moved = TableRig.numbered(1_000)
        moved.insert(moved.remove(at: 130), at: 400)
        rig.fake.setHits(moved)
        try await rig.liveSearch(count: 1_000)
        try await rig.host.until("hit-130 two pages away clears, selected \(Array(table.selectedRowIndexes))") { table.selectedRowIndexes.isEmpty }
        #expect(heard == ["nil 0"])

        table.selectRowIndexes([5], byExtendingSelection: false)
        try #require(table.selectedRowIndexes == [5])
        heard = []
        var namesake = TableRig.numbered(1_000).filter { $0.name != "hit-5" }
        namesake.insert(.named("hit-5", in: "/Users"), at: 200)
        rig.fake.setHits(namesake)
        try await rig.liveSearch(count: 1_000)
        try await rig.host.until("hit-5 in another folder stays unselected, selected \(Array(table.selectedRowIndexes))") { table.selectedRowIndexes.isEmpty }
        #expect(heard == ["nil 0"])
    }

    @Test func selectAllOnAGrowingContentSetGrowsWithIt() async throws {
        let rig = TableRig(hits: TableRig.numbered(20))
        defer { rig.host.close() }
        rig.model.content = ContentTerms(terms: ["hit"])
        rig.model.searchContent()
        let press = try #require(rig.model.press)
        rig.fake.send(.resultsReady(press, count: 10))
        try await rig.host.until("the first files") { !rig.model.isPending && rig.host.list()?.numberOfRows == 10 }
        let table = try rig.table()
        table.selectAll(nil)
        try #require(table.selectedRowIndexes == IndexSet(0..<10))
        rig.fake.send(.resultsReady(press, count: 20))
        try await rig.host.until("the grown set, selected \(Array(table.selectedRowIndexes))") {
            table.numberOfRows == 20 && table.selectedRowIndexes == IndexSet(0..<20)
        }
        #expect(rig.model.results.live)
        #expect(rig.fake.queries.isEmpty)
    }

    @Test func aHeaderClickAndANewQueryClearASeveralRowSelection() async throws {
        let rig = TableRig(hits: TableRig.numbered(10))
        defer { rig.host.close() }
        try await rig.search("hit", count: 10)
        let table = try rig.table()
        table.selectRowIndexes([1, 2, 3], byExtendingSelection: false)
        try #require(table.selectedRowIndexes == [1, 2, 3])
        let name = try #require(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(ResultsTable.Column.name.rawValue)))
        table.delegate?.tableView?(table, didClick: name)
        #expect(table.selectedRowIndexes.isEmpty)
        rig.fake.send(.resultsReady(rig.fake.latest, count: 10))
        try await rig.host.until("the sorted rows") { !rig.model.isPending }

        table.selectRowIndexes([1, 2, 3], byExtendingSelection: false)
        try #require(table.selectedRowIndexes == [1, 2, 3])
        try await rig.search("hit-", count: 10)
        try await rig.host.until("no selection after a new query") { table.selectedRowIndexes.isEmpty }
    }

    @Test func aPressSelectsTheRowBeforeTheButtonGoesUp() async throws {
        let rig = TableRig(hits: TableRig.numbered(TableRig.million), reportsKey: true)
        defer { rig.host.close() }
        try await rig.search("hit", count: TableRig.million)
        let table = try rig.table()
        let row = try rig.visible().lowerBound + 3
        try #require(!table.selectedRowIndexes.contains(row))
        let notices = OSAllocatedUnfairLock(initialState: 0)
        let watch = NotificationCenter.default.addObserver(forName: NSTableView.selectionDidChangeNotification, object: table, queue: nil) { _ in
            notices.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(watch) }
        try await EventQueueLock.run {
            let (selected, noticed) = try await pressMouse(on: table, row: row) { (table.selectedRowIndexes, notices.withLock { $0 }) }
            #expect(selected == [row], "row \(row) unselected while the button is down: \(Array(selected))")
            #expect(noticed == 1)
        }
        #expect(table.selectedRowIndexes == [row])
        #expect(notices.withLock { $0 } == 1)
        #expect(rig.host.recorder.opened.isEmpty)
    }

    @Test func theTableStaysOnAppKitsGestureRecognizers() async throws {
        let rig = TableRig(hits: TableRig.numbered(10))
        defer { rig.host.close() }
        try await rig.search("hit", count: 10)
        let table = try #require(rig.host.list() as? ThemedTable)
        for selector in [#selector(NSResponder.mouseDown(with:)), #selector(NSResponder.mouseDragged(with:))] {
            #expect(class_getMethodImplementation(ThemedTable.self, selector) == class_getMethodImplementation(NSTableView.self, selector),
                    "ThemedTable overrides \(selector), which turns AppKit's table gesture recognizers off")
        }
        let presses = table.gestureRecognizers.compactMap { $0 as? PressSelect }
        #expect(presses.count == 1)
        #expect(presses.first?.delaysPrimaryMouseButtonEvents == false)
    }

    @Test(arguments: [
        "plain", "plainFromField", "double", "doubleOnSelected", "commandAdd", "commandRemove", "shiftExtend",
        "pressInsideMulti", "pressOutsideMulti", "quickTwoRows", "quickTwoRowsCountTwo", "optionClick",
    ])
    func pressMatrixKeepsEveryClickOutcome(_ name: String) async throws {
        let click = try #require(PressCase.all[name], "no case \(name)")
        let appKit = try await pressOutcome(click, name, pressSelect: false, settlesOn: (click.after, click.opens))
        let opens = click.opens ?? appKit.opens
        let pressed = try await pressOutcome(click, name, pressSelect: true, settlesOn: (click.after, opens))
        for (index, press) in click.presses.enumerated() {
            let during = press.during ?? appKit.during[index]
            #expect(pressed.during[index] == during, "\(name): \(Array(pressed.during[index])) while row \(press.row) is down, not \(Array(during))")
        }
        #expect(appKit.after == click.after)
        #expect(pressed.after == click.after)
        #expect(pressed.opens == opens)
    }

    private func pressOutcome(_ click: PressCase, _ name: String, pressSelect: Bool, settlesOn expected: (rows: IndexSet, opens: Int?)) async throws -> (during: [IndexSet], after: IndexSet, opens: Int) {
        let rig = TableRig(hits: TableRig.numbered(6), reportsKey: true, field: true)
        defer { rig.host.close() }
        try await rig.search("hit", count: 6)
        let table = try rig.table()
        if !pressSelect { table.gestureRecognizers.filter { $0 is PressSelect }.forEach(table.removeGestureRecognizer) }
        try #require(table.gestureRecognizers.contains { $0 is PressSelect } == pressSelect)
        table.selectRowIndexes(click.before, byExtendingSelection: false)
        try #require(table.selectedRowIndexes == click.before)
        let focus: NSResponder? = name == "plainFromField" ? rig.host.field() : table
        try #require(rig.host.window.makeFirstResponder(focus))
        var during: [IndexSet] = []
        try await EventQueueLock.run {
            for press in click.presses {
                during.append(try await pressMouse(on: table, row: press.row, modifiers: press.modifiers, clickCount: press.count) { table.selectedRowIndexes })
            }
            try await rig.host.until("\(name)\(pressSelect ? "" : " without PressSelect"): rows \(Array(expected.rows)) and \(expected.opens.map(String.init) ?? "AppKit's") opens, got \(Array(table.selectedRowIndexes)) and \(rig.host.recorder.opened.count) opens") {
                drainEvents()
                return table.selectedRowIndexes == expected.rows && expected.opens.map { rig.host.recorder.opened.count == $0 } ?? true
            }
            try await pumpEvents(for: .milliseconds(50))
        }
        return (during, table.selectedRowIndexes, rig.host.recorder.opened.count)
    }
}

extension ResultsTableTests {
    @Test func aLiveRefreshReusesEveryCellAndShowsTheNewRows() async throws {
        let rig = TableRig(hits: TableRig.numbered(1_000))
        defer { rig.host.close() }
        try await rig.search("hit", count: 1_000)
        let rows = try rig.visible()
        try await rig.host.until("the first screen's cells") { rows.allSatisfy { rig.text(row: $0) == "hit-\($0)" } }
        let before = try await rig.cells()
        try #require(!before.isEmpty)

        rig.fake.setHits((0..<1_000).map { .named("new-\($0)", in: "/Users") })
        try await rig.liveSearch(count: 1_000)
        try await rig.host.until("the new names and folders on screen") {
            rows.allSatisfy { rig.text(row: $0) == "new-\($0)" && rig.text(row: $0, column: .folder) == "/Users" }
        }
        let after = try await rig.cells()
        let made = try await rig.made(since: before)
        #expect(after.count == before.count)
        #expect(made == 0, "a live refresh with the same count makes no new cell")
    }

    @Test func aLiveRefreshThatGrowsOrShrinksShowsTheNewRowsAndKeepsTheSelection() async throws {
        let rig = TableRig(hits: TableRig.numbered(5))
        defer { rig.host.close() }
        try await rig.search("hit", count: 5)
        let table = try rig.table()
        table.selectRowIndexes([3], byExtendingSelection: false)
        let coordinator = try #require(table.delegate as? ResultsTable.Coordinator)
        var heard: [String] = []
        coordinator.onSelect = { hit, count in heard.append("\(hit?.name ?? "nil") \(count)") }
        func expectRows(_ names: [String], _ when: String) async throws {
            rig.fake.setHits(names.map { .named($0) })
            try await rig.liveSearch(count: names.count)
            try await rig.host.until("\(when): \(names), selected \(Array(table.selectedRowIndexes))") {
                table.numberOfRows == names.count && names.indices.allSatisfy { rig.text(row: $0) == names[$0] }
            }
        }

        try await expectRows(["hit-0", "new-a", "hit-1", "hit-2", "hit-3", "hit-4", "new-b", "new-c"], "grown")
        #expect(table.selectedRowIndexes == [4])
        #expect(heard == ["hit-3 1"])

        try await expectRows(["hit-3", "new-d", "new-e"], "shrunk past the selected row")
        #expect(table.selectedRowIndexes == [0])
        #expect(heard == ["hit-3 1", "hit-3 1"], "the trimmed row never reaches the inspector as an empty selection")

        try await expectRows(["new-f", "new-g"], "shrunk without the selected file")
        #expect(table.selectedRowIndexes.isEmpty)
        #expect(heard == ["hit-3 1", "hit-3 1", "nil 0"])
    }

    @Test func aLiveShrinkAtTheBottomShowsTheLastRowsOfTheNewSet() async throws {
        let rig = TableRig(hits: TableRig.numbered(1_000))
        defer { rig.host.close() }
        try await rig.search("hit", count: 1_000)
        try await rig.jump(to: 999)
        let table = try rig.table()
        table.selectRowIndexes([998], byExtendingSelection: false)
        let coordinator = try #require(table.delegate as? ResultsTable.Coordinator)
        var heard: [String] = []
        coordinator.onSelect = { hit, count in heard.append("\(hit?.name ?? "nil") \(count)") }

        rig.fake.setHits(TableRig.numbered(500))
        try await rig.liveSearch(count: 500)
        try await rig.host.until("the last rows of 500, visible \(String(describing: try? rig.visible()))") {
            guard table.numberOfRows == 500, let rows = try? rig.visible(), rows.upperBound == 499 else { return false }
            return rows.allSatisfy { rig.text(row: $0) == "hit-\($0)" }
        }
        #expect(table.selectedRowIndexes.isEmpty)
        #expect(heard == ["nil 0"])
    }

    @Test func aSelectedRowAndSelectAllSurviveTwelveLiveRefreshes() async throws {
        let rig = TableRig(hits: TableRig.numbered(50))
        defer { rig.host.close() }
        try await rig.search("hit", count: 50)
        let table = try rig.table()
        try await rig.host.until("the first rows' cells") { rig.text(row: 6) == "hit-6" }
        table.selectRowIndexes([5], byExtendingSelection: false)
        let coordinator = try #require(table.delegate as? ResultsTable.Coordinator)
        var heard: [String] = []
        coordinator.onSelect = { hit, count in heard.append("\(hit?.name ?? "nil") \(count)") }
        let before = try await rig.cells()
        try #require(!before.isEmpty)

        for round in 1...12 {
            rig.fake.setHits((0..<50).map { .named($0 == 5 ? "hit-5" : "r\(round)-\($0)") })
            try await rig.liveSearch(count: 50)
            try await rig.host.until("round \(round) on screen") { rig.text(row: 6) == "r\(round)-6" }
            #expect(table.selectedRowIndexes == [5], "round \(round)")
        }
        #expect(heard == Array(repeating: "hit-5 1", count: 12))
        let made = try await rig.made(since: before)
        #expect(made == 0, "twelve live refreshes make no new cell")

        table.selectAll(nil)
        try #require(table.selectedRowIndexes == IndexSet(0..<50))
        heard = []
        for round in 13...24 {
            rig.fake.setHits((0..<50).map { .named("r\(round)-\($0)") })
            try await rig.liveSearch(count: 50)
            try await rig.host.until("round \(round) on screen") { rig.text(row: 0) == "r\(round)-0" }
            #expect(table.selectedRowIndexes == IndexSet(0..<50), "round \(round)")
        }
        #expect(heard == (13...24).map { "r\($0)-0 50" })
    }
}

private struct PressCase {
    struct Press {
        let row: Int
        var modifiers: NSEvent.ModifierFlags = []
        var count = 1
        var during: IndexSet?
    }

    let before: IndexSet
    let presses: [Press]
    let after: IndexSet
    var opens: Int? = 0

    static let all: [String: PressCase] = [
        "plain": PressCase(before: [], presses: [Press(row: 0, during: [0])], after: [0]),
        "plainFromField": PressCase(before: [], presses: [Press(row: 0, during: [0])], after: [0]),
        "double": PressCase(before: [], presses: [Press(row: 0, during: [0]), Press(row: 0, count: 2, during: [0])], after: [0], opens: 1),
        "doubleOnSelected": PressCase(before: [0], presses: [Press(row: 0, during: [0]), Press(row: 0, count: 2, during: [0])], after: [0], opens: 1),
        "commandAdd": PressCase(before: [0], presses: [Press(row: 3, modifiers: .command)], after: [0, 3]),
        "commandRemove": PressCase(before: [0, 1, 2], presses: [Press(row: 1, modifiers: .command)], after: [0, 2]),
        "shiftExtend": PressCase(before: [0], presses: [Press(row: 3, modifiers: .shift)], after: [0, 1, 2, 3]),
        "pressInsideMulti": PressCase(before: [0, 1, 2], presses: [Press(row: 1, during: [0, 1, 2])], after: [1]),
        "pressOutsideMulti": PressCase(before: [0, 1, 2], presses: [Press(row: 5, during: [5])], after: [5]),
        "quickTwoRows": PressCase(before: [], presses: [Press(row: 0, during: [0]), Press(row: 2, during: [2])], after: [2]),
        "quickTwoRowsCountTwo": PressCase(before: [], presses: [Press(row: 0, during: [0]), Press(row: 2, count: 2, during: [2])], after: [2], opens: nil),
        "optionClick": PressCase(before: [0], presses: [Press(row: 3, modifiers: .option, during: [3])], after: [3]),
    ]
}
