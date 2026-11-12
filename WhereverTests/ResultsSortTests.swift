import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

@MainActor
private struct SortRig {
    let fake: FakeSearchClient
    let index: IndexModel
    let model: SearchModel
    let host: SearchHost

    init(hits: [SearchHit]) {
        let suiteName = "com.writronic.wherever.tests.sort"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        fake = FakeSearchClient(hits: hits)
        index = IndexModel(client: fake)
        model = index.makeModel()
        host = SearchHost(root: AnyView(ResultsTable(model: model).defaultAppStorage(suite)), reportsKey: true)
    }

    func table() throws -> NSTableView { try need(host.list(), "no results table") }

    func column(_ column: ResultsTable.Column) throws -> NSTableColumn {
        try need(table().tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)), "no \(column) column")
    }

    func search(_ query: String, count: Int) async throws {
        model.query = query
        try await finish(count: count)
    }

    func finish(count: Int) async throws {
        let generation = fake.latest
        fake.send(.resultsReady(generation, count: count))
        try await host.until("\(count) rows of generation \(generation.rawValue)") {
            model.results.generation == generation && host.list()?.numberOfRows == count
        }
    }

    func clickHeader(_ column: ResultsTable.Column, at fraction: CGFloat = 0.5) async throws {
        let table = try table()
        let header = try #require(table.headerView)
        host.view.layoutSubtreeIfNeeded()
        let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
        table.scrollColumnToVisible(index)
        host.view.layoutSubtreeIfNeeded()
        let rect = header.headerRect(ofColumn: index)
        let point = NSPoint(x: rect.minX + rect.width * fraction, y: rect.midY)
        try #require(header.visibleRect.contains(point), "the \(column) header at \(point) lies outside the visible \(header.visibleRect)")
        try await EventQueueLock.run {
            try host.postClicks(at: header.convert(point, to: nil), counts: 1...1)
            host.sendQueuedEvents()
        }
    }

    func marks() throws -> [ResultsTable.Column: String] {
        var marks: [ResultsTable.Column: String] = [:]
        for column in ResultsTable.Column.defaults {
            marks[column] = try table().indicatorImage(in: self.column(column))?.name()
        }
        return marks
    }

    func nameCell(row: Int) throws -> ResultCell { try #require(madeNameCell(row: row)) }

    func madeNameCell(row: Int) -> ResultCell? {
        guard let table = host.list() else { return nil }
        let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(ResultsTable.Column.name.rawValue))
        return table.view(atColumn: index, row: row, makeIfNecessary: false) as? ResultCell
    }
}

@Suite(.serialized) struct ResultsSortTests {
    private static let up = "NSAscendingSortIndicator"
    private static let down = "NSDescendingSortIndicator"

    @Test func theHeaderCycleStartsEachColumnAtItsOwnDirectionThenReversesThenReturnsToBestMatch() {
        let firsts: [(SearchColumn, Bool)] = [(.name, true), (.folder, true), (.kind, true), (.size, false), (.modified, false)]
        for (column, ascending) in firsts {
            let first = SearchSort.bestMatch.next(clicking: column)
            #expect(first == SearchSort(column: column, ascending: ascending), "\(column)")
            let second = first.next(clicking: column)
            #expect(second == SearchSort(column: column, ascending: !ascending), "\(column)")
            #expect(second.next(clicking: column) == .bestMatch, "\(column)")
            for other in firsts.map(\.0) where other != column {
                #expect(second.next(clicking: other) == SearchSort.bestMatch.next(clicking: other), "\(column) then \(other)")
            }
        }
    }

    @Test func headerClicksSortReverseAndReturnToBestMatchAndEachClearsTheSelection() async throws {
        let rig = SortRig(hits: (0..<5).map { .named("hit-\($0)") })
        defer { rig.host.close() }
        try await rig.search("hit", count: 5)
        let table = try rig.table()
        #expect(try rig.marks().isEmpty)
        let session = rig.fake.lastSession

        let steps: [(SearchSort, [ResultsTable.Column: String])] = [
            (SearchSort(column: .size, ascending: false), [.size: Self.down]),
            (SearchSort(column: .size, ascending: true), [.size: Self.up]),
            (.bestMatch, [:]),
        ]
        for (index, (sort, marks)) in steps.enumerated() {
            table.selectRowIndexes([2], byExtendingSelection: false)
            try #require(table.selectedRow == 2)
            try await rig.clickHeader(.size, at: CGFloat(index + 1) / 4)
            #expect(table.selectedRow == -1, "click \(index + 1) kept the selection")
            #expect(rig.model.sort == sort)
            #expect(rig.fake.session(session)?.sorts.last == sort)
            try await rig.host.until("the mark of click \(index + 1)") { (try? rig.marks()) == marks }
            try await rig.finish(count: 5)
        }
        #expect(rig.fake.session(session)?.sorts.count == 3)
        #expect(rig.fake.queries == ["hit"], "a header click never searches again")

        try await rig.clickHeader(.name)
        #expect(rig.model.sort == SearchSort(column: .name, ascending: true))
        try await rig.host.until("the name mark") { (try? rig.marks()) == [.name: Self.up] }
    }

    @Test func aNewQueryKeepsTheHeadersSortAndItsMark() async throws {
        let rig = SortRig(hits: [.named("a"), .named("b")])
        defer { rig.host.close() }
        try await rig.search("a", count: 2)
        try await rig.clickHeader(.modified)
        try await rig.finish(count: 2)
        try await rig.search("ab", count: 2)
        let searches = try #require(rig.fake.session(rig.fake.lastSession)).searches
        #expect(searches.last == FakeSearchClient.Search(query: "ab", sort: SearchSort(column: .modified, ascending: false)))
        #expect(try rig.marks() == [.modified: Self.down])
    }

    @Test func theNameCellDrawsTheMatchedLettersBoldAndReadsThePlainName() async throws {
        let name = "😀 Ünal Report.txt"
        let match = try #require(Range((name as NSString).range(of: "Rep")))
        #expect(match == 8..<11)
        let rig = SortRig(hits: [
            SearchHit(name: name, folder: "/tmp", size: 1, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .file, matches: [match]),
            SearchHit(name: "short", folder: "/tmp", size: 1, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .file, matches: [3..<40]),
            SearchHit(name: "Report.txt", folder: "/tmp", size: 1, modified: Date(timeIntervalSince1970: 0), created: .distantPast, opened: .distantPast, kind: .file, matches: [0..<3]),
        ])
        defer { rig.host.close() }
        try await rig.search("rep", count: 3)
        try await rig.host.until("the name cell") { rig.madeNameCell(row: 0)?.textField?.stringValue == name }

        let cell = try rig.nameCell(row: 0)
        let field = try #require(cell.textField)
        let text = field.attributedStringValue
        #expect(text.string == name)
        let bold = { (location: Int) -> Bool in
            guard let font = text.attribute(.font, at: location, effectiveRange: nil) as? NSFont else { return false }
            return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        }
        #expect(!bold(match.lowerBound - 1))
        #expect(match.allSatisfy(bold))
        #expect(!bold(match.upperBound))
        let tone = try #require(text.attribute(.foregroundColor, at: match.lowerBound, effectiveRange: nil) as? NSColor)
        #expect(eightBits(channels(tone, .light)) == eightBits(hex: 0x0058D0))
        #expect(eightBits(channels(tone, .dark)) == eightBits(hex: 0x4DA3FF))
        #expect(field.accessibilityLabel() == name)
        #expect((text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineBreakMode == .byTruncatingTail)

        cell.backgroundStyle = .emphasized
        let selected = try #require(field.attributedStringValue.attribute(.foregroundColor, at: match.lowerBound, effectiveRange: nil) as? NSColor)
        #expect(selected == .alternateSelectedControlTextColor)
        #expect(field.attributedStringValue.string == name)

        let short = try rig.nameCell(row: 1)
        #expect(short.textField?.stringValue == "short")
        let plain = try #require(short.textField?.attributedStringValue)
        let plainBold = (0..<plain.length).contains { location in
            (plain.attribute(.font, at: location, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true
        }
        #expect(!plainBold)

        let prefix = try #require(try rig.nameCell(row: 2).textField?.attributedStringValue)
        let isBold = { (location: Int) -> Bool in
            (prefix.attribute(.font, at: location, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true
        }
        #expect((0..<3).allSatisfy(isBold))
        #expect(!(3..<prefix.length).contains(where: isBold))
    }
}
