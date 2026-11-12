import AppKit
import CoreGraphics
import CoreText
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private func columnFontMatches(_ actual: NSFont, _ expected: NSFont) -> Bool {
    actual.pointSize == expected.pointSize
        && CTFontGetMatrix(actual) == CTFontGetMatrix(expected)
        && CTFontCopyGraphicsFont(actual, nil) == CTFontCopyGraphicsFont(expected, nil)
}

private var columnCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private var columnMoment: Date {
    columnCalendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 18, minute: 50, second: 57))!
}

@MainActor
private struct ColumnsRig {
    let fake: FakeSearchClient
    let model: SearchModel
    let host: SearchHost

    init(preferences: ColumnPreferences, mode: WindowMode? = nil, dates: FileDates = .current, store: UserDefaults? = nil) {
        let fake = FakeSearchClient(hits: [SearchHit(name: "report", folder: "/Applications", size: 12, modified: columnMoment, created: columnMoment, opened: columnMoment, kind: .file)])
        let model = SearchModel(session: try? fake.makeSession(), listsAll: true, columnPreferences: preferences)
        self.fake = fake
        self.model = model
        if let mode {
            let store = UserDefaults(suiteName: "com.writronic.wherever.tests.columns.\(mode.rawValue)")!
            store.set(mode.rawValue, forKey: WindowMode.key)
            host = SearchHost(root: AnyView(ContentView(index: IndexModel(client: fake), model: model).environment(\.searchClient, fake).defaultAppStorage(store)))
        } else {
            let table = ResultsTable(model: model, dates: dates)
            host = SearchHost(root: store.map { AnyView(table.defaultAppStorage($0)) } ?? AnyView(table), reportsKey: true)
        }
    }

    func table() throws -> NSTableView { try need(host.list(), "results table") }
    func menu() throws -> NSMenu { try #require(try table().headerView?.menu, "the header must offer column choices") }
    func item(_ id: String) throws -> NSMenuItem {
        let menu = try menu()
        menu.update()
        return try #require(menu.items.first { $0.identifier?.rawValue == "results.columns.\(id)" })
    }
    func toggle(_ id: String) throws {
        let menu = try menu()
        let item = try item(id)
        menu.performActionForItem(at: menu.index(of: item))
    }
    func visible() throws -> [String] { try table().tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue) }
    func column(_ column: ResultsTable.Column) throws -> NSTableColumn {
        try #require(try table().tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)))
    }
    func click(_ column: ResultsTable.Column) throws {
        let table = try table()
        table.delegate?.tableView?(table, didClick: try self.column(column))
    }
    func finish(count: Int = 1) async throws {
        fake.send(.resultsReady(fake.latest, count: count))
        model.handle(.resultsReady(fake.latest, count: count))
        try await host.until("a result row") { host.list()?.numberOfRows == count }
    }
}

private func columnStore() -> UserDefaults {
    let name = "com.writronic.wherever.tests.columns.\(UUID().uuidString)"
    return UserDefaults(suiteName: name)!
}

private final class ColumnMenuTracking: NSObject {
    let menu: NSMenu
    var opened = false
    var arrowMoved = false
    private var ending = "AppKit closed the menu"
    private var seen = "nothing seen"
    private var arrows = 0
    private var arrowFrom: NSMenuItem?
    private var deadline = Date.distantFuture
    init(_ menu: NSMenu) { self.menu = menu }
    var report: String { "\(arrows) arrows posted, last highlight \(seen), \(ending)" }

    @objc private func began(_ note: Notification) { opened = true; deadline = Date().addingTimeInterval(5) }

    func observe(_ open: () -> Void) {
        NotificationCenter.default.addObserver(self, selector: #selector(began(_:)), name: NSMenu.didBeginTrackingNotification, object: menu)
        deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.01, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                seen = menu.highlightedItem?.title ?? "no item"
                if Date() >= deadline { ending = "deadline"; menu.cancelTracking(); return }
                guard opened else { return }
                let moved = menu.highlightedItem !== arrowFrom
                if arrows > 0, moved, menu.highlightedItem === menu.items.last {
                    arrowMoved = true; ending = "reached"; menu.cancelTracking(); return
                }
                if arrows > 0, !moved { return }
                let up = menu.highlightedItem === menu.items.last
                let key = up ? "\u{F700}" : "\u{F701}"
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .popUpMenu }),
                   let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: up ? 126 : 125) {
                    arrowFrom = menu.highlightedItem
                    arrows += 1
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate(); NotificationCenter.default.removeObserver(self) }
        open()
        MenuPlacement.settle()
    }
}

@Suite(.serialized) struct ColumnsTests {
    @Test func menuOrderChecksAndEveryColumnToggle() async throws {
        let preferences = ColumnPreferences(defaults: columnStore())
        let rig = ColumnsRig(preferences: preferences)
        defer { rig.host.close() }
        try await rig.finish()
        let menu = try rig.menu()
        #expect(menu.items.map(\.title) == ["Folder", "Size", "Modified", "Created", "Opened", "Kind", "", "Keep Folders on Top"])
        #expect(menu.items[6].isSeparatorItem)
        #expect(try rig.visible() == ["name", "folder", "size", "modified", "kind"])
        for column in ResultsTable.Column.allCases where column != .name {
            let wasShown = preferences.shown.contains(column)
            #expect(try rig.item(column.rawValue).state == (wasShown ? .on : .off))
            try rig.toggle(column.rawValue)
            try await rig.host.until("\(column) toggled") { (try? rig.visible().contains(column.rawValue)) == !wasShown }
            #expect(try rig.item(column.rawValue).state == (wasShown ? .off : .on))
            try rig.toggle(column.rawValue)
            try await rig.host.until("\(column) restored") { (try? rig.visible().contains(column.rawValue)) == wasShown }
        }
        #expect(preferences.shown.contains(.name))
    }

    @Test func removedColumnsInTheSavedChoiceAreDropped() {
        let store = columnStore()
        store.set(["name", "added", "tags", "kind"], forKey: ColumnPreferences.shownKey)
        #expect(ColumnPreferences(defaults: store).shown == [.name, .kind])
        #expect(ResultsTable.Column.allCases.map(\.rawValue) == ["name", "folder", "size", "modified", "created", "opened", "kind"])
    }

    @Test func choicesReachBothModesAndANewWindowAndPersist() async throws {
        let store = columnStore()
        let preferences = ColumnPreferences(defaults: store)
        let simple = ColumnsRig(preferences: preferences, mode: .simple)
        let normal = ColumnsRig(preferences: preferences, mode: .normal)
        defer { simple.host.close(); normal.host.close() }
        try await simple.finish()
        try await normal.finish()
        try simple.toggle("created")
        try normal.toggle("folder")
        try await normal.host.until("both windows share column choices") {
            (try? simple.visible()) == ["name", "size", "modified", "created", "kind"] && (try? normal.visible()) == (try? simple.visible())
        }
        let third = ColumnsRig(preferences: preferences)
        defer { third.host.close() }
        try await third.finish()
        #expect(try third.visible() == simple.visible())
        #expect(ColumnPreferences(defaults: store).shown == preferences.shown)
        try normal.toggle("created")
        try await third.host.until("the new window follows later changes") { (try? third.visible().contains("created")) == false }
    }

    @Test func turningColumnsOnOrOffKeepsTheOrderDraggedInThisWindow() async throws {
        let preferences = ColumnPreferences(defaults: columnStore())
        let rig = ColumnsRig(preferences: preferences)
        let other = ColumnsRig(preferences: preferences)
        defer { rig.host.close(); other.host.close() }
        try await rig.finish()
        try await other.finish()
        let table = try rig.table()
        table.moveColumn(table.column(withIdentifier: NSUserInterfaceItemIdentifier("kind")), toColumn: 0)
        try #require(try rig.visible() == ["kind", "name", "folder", "size", "modified"])

        try rig.toggle("created")
        try await rig.host.until("Created beside Modified with Kind still first") {
            (try? rig.visible()) == ["kind", "name", "folder", "size", "modified", "created"]
        }
        try await other.host.until("the undragged window in the default order") {
            (try? other.visible()) == ["name", "folder", "size", "modified", "created", "kind"]
        }

        try other.toggle("folder")
        try await rig.host.until("Folder turned off in the other window keeps this drag") {
            (try? rig.visible()) == ["kind", "name", "size", "modified", "created"]
        }
        try rig.toggle("folder")
        try await rig.host.until("Folder back beside Name") {
            (try? rig.visible()) == ["kind", "name", "folder", "size", "modified", "created"]
        }
        #expect(try other.visible() == ["name", "folder", "size", "modified", "created", "kind"])
    }

    @Test func aDraggedColumnTurnedOffAndOnReturnsBesideItsDefaultNeighbourAndATextSizeSwitchKeepsTheOrder() async throws {
        let store = columnStore()
        let rig = ColumnsRig(preferences: ColumnPreferences(defaults: columnStore()), store: store)
        defer { rig.host.close() }
        try await rig.finish()
        let table = try rig.table()
        table.moveColumn(table.column(withIdentifier: NSUserInterfaceItemIdentifier("size")), toColumn: table.numberOfColumns - 1)
        try #require(try rig.visible() == ["name", "folder", "modified", "kind", "size"])

        try rig.toggle("size")
        try await rig.host.until("Size off") { (try? rig.visible()) == ["name", "folder", "modified", "kind"] }
        try rig.toggle("size")
        try await rig.host.until("Size back after Folder") { (try? rig.visible()) == ["name", "folder", "size", "modified", "kind"] }

        table.moveColumn(table.column(withIdentifier: NSUserInterfaceItemIdentifier("kind")), toColumn: 0)
        try #require(try rig.visible() == ["kind", "name", "folder", "size", "modified"])
        store.set(TextSize.extraLarge.rawValue, forKey: TextSize.key)
        try await rig.host.until("26 pt rows") { table.rowHeight == 26 }
        #expect(try rig.visible() == ["kind", "name", "folder", "size", "modified"])
    }

    @Test func foldersFirstReachesSortThenQueryAndNewSession() async throws {
        let store = columnStore()
        let preferences = ColumnPreferences(defaults: store)
        let first = ColumnsRig(preferences: preferences)
        let second = ColumnsRig(preferences: preferences)
        defer { first.host.close(); second.host.close() }
        try await first.finish()
        try await second.finish()
        try first.toggle("foldersFirst")
        #expect(first.model.shownSort.foldersFirst)
        #expect(second.model.shownSort.foldersFirst)
        #expect(first.fake.session(first.fake.lastSession)?.sorts.last?.foldersFirst == true)
        #expect(second.fake.session(second.fake.lastSession)?.sorts.last?.foldersFirst == true)
        first.model.query = "report"
        #expect(first.fake.session(first.fake.lastSession)?.searches.last?.sort.foldersFirst == true)
        #expect(first.model.shownSort.column == .relevance)
        try first.click(.size)
        #expect(first.model.shownSort.foldersFirst)
        let third = ColumnsRig(preferences: ColumnPreferences(defaults: store))
        defer { third.host.close() }
        #expect(third.fake.session(third.fake.lastSession)?.searches.last?.sort == SearchSort(column: .name, ascending: true, foldersFirst: true))
        try second.toggle("foldersFirst")
        #expect(!first.model.shownSort.foldersFirst)
        #expect(first.model.shownSort.column == .size)
    }

    @Test func hidingSortedColumnKeepsOrderThenAnotherHeaderSorts() async throws {
        let rig = ColumnsRig(preferences: ColumnPreferences(defaults: columnStore()))
        defer { rig.host.close() }
        try await rig.finish()
        try rig.click(.modified)
        let sort = rig.model.shownSort
        try rig.toggle("modified")
        #expect(rig.model.shownSort == sort)
        #expect(try !rig.visible().contains("modified"))
        try rig.click(.name)
        #expect(rig.model.shownSort == SearchSort(column: .name, ascending: true))
        try rig.toggle("modified")
        #expect(try rig.table().indicatorImage(in: rig.column(.modified)) == nil)
    }

    @Test func newDatesStartNewestFirstAndKeepFoldersFirstThroughCycle() async throws {
        let rig = ColumnsRig(preferences: ColumnPreferences(defaults: columnStore()))
        defer { rig.host.close() }
        try await rig.finish()
        try rig.toggle("foldersFirst")
        for (column, sortColumn) in [(ResultsTable.Column.created, SearchColumn.created), (.opened, .opened)] {
            try rig.toggle(column.rawValue)
            try rig.click(column)
            #expect(rig.model.shownSort == SearchSort(column: sortColumn, ascending: false, foldersFirst: true))
            try rig.click(column)
            #expect(rig.model.shownSort == SearchSort(column: sortColumn, ascending: true, foldersFirst: true))
            try rig.click(column)
            #expect(rig.model.shownSort == SearchSort(column: .name, ascending: true, foldersFirst: true))
        }
    }

    @Test(arguments: [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft])
    func keyboardAndVoiceOverOpenTheMenuUnderTheHeader(direction: NSUserInterfaceLayoutDirection) async throws {
        let rig = ColumnsRig(preferences: ColumnPreferences(defaults: columnStore()))
        defer { rig.host.close() }
        rig.host.window.center()
        try await rig.finish()
        let table = try rig.table()
        let header = try #require(table.headerView)
        header.userInterfaceLayoutDirection = direction
        let rightToLeft = direction == .rightToLeft
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .function], timestamp: 0, windowNumber: rig.host.window.windowNumber, context: nil, characters: "\u{F70D}", charactersIgnoringModifiers: "\u{F70D}", isARepeat: false, keyCode: 109))
        let ways: [(String, () -> Void)] = [("Shift-F10", { table.keyDown(with: event) }), ("VoiceOver", { _ = table.accessibilityPerformShowMenu() })]
        for (way, open) in ways {
            try await EventQueueLock.run {
                try await rig.host.until("the previous popup closes") { !MenuPlacement.popUpShown }
                rig.host.window.makeFirstResponder(table)
                let placement = MenuPlacement(try rig.menu())
                placement.measure(open)
                let shown = try #require(placement.frame, "\(way) opened no menu")
                let visible = rig.host.window.convertToScreen(header.convert(header.visibleRect, to: nil))
                #expect(MenuPlacement.opens(shown, under: visible, rightToLeft: rightToLeft), "\(way) \(rightToLeft ? "right to left" : "left to right"): menu \(shown) beside header \(visible)")
            }
        }
    }

    @Test func keyboardAndVoiceOverOpenTheMenuAndArrowsReachAnItem() async throws {
        let rig = ColumnsRig(preferences: ColumnPreferences(defaults: columnStore()))
        defer { rig.host.close() }
        try await rig.finish()
        let table = try rig.table()
        for voiceOver in [false, true] {
            let pass = voiceOver ? "VoiceOver" : "Shift-F10"
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .function], timestamp: 0, windowNumber: rig.host.window.windowNumber, context: nil, characters: "\u{F70D}", charactersIgnoringModifiers: "\u{F70D}", isARepeat: false, keyCode: 109))
            try await EventQueueLock.run {
                try await rig.host.until("the previous popup closes") { !MenuPlacement.popUpShown }
                let tracker = ColumnMenuTracking(try rig.menu())
                rig.host.window.makeFirstResponder(table)
                var performed = false
                tracker.observe {
                    if voiceOver { performed = table.accessibilityPerformShowMenu() } else { table.keyDown(with: event) }
                }
                #expect(tracker.opened, "\(pass) must open the menu")
                #expect(tracker.arrowMoved, "\(pass) arrows must reach Keep Folders on Top: \(tracker.report)")
                if voiceOver { #expect(performed) }
            }
            #expect(rig.host.window.firstResponder === table)
        }
    }
}


extension ColumnsTests {
    @Test(arguments: [
        ("tr_TR", "22.10.2026 18:50:57"),
        ("en_US", "10/22/2026, 6:50:57\u{202f}PM"),
        ("en_GB", "22/10/2026, 18:50:57"),
        ("de_DE", "22.10.2026, 18:50:57")
    ])
    func systemDateIncludesSecondsAndFourDigitYear(locale: String, expected: String) {
        let dates = FileDates(locale: Locale(identifier: locale), calendar: columnCalendar)
        #expect(dates.string(columnMoment) == expected)
    }

    @Test func shortTwoDigitYearIsWidened() {
        let locale = Locale(identifier: "en_US")
        let system = DateFormatter()
        system.locale = locale
        system.dateStyle = .short
        #expect(system.dateFormat.contains("yy"))
        #expect(!system.dateFormat.contains("yyyy"))
        #expect(FileDates(locale: locale, calendar: columnCalendar).string(columnMoment).hasPrefix("10/22/2026,"))
    }

    @Test(arguments: [
        ("ja_JP", Calendar.Identifier.japanese, "R8/10/22 18:50:57"),
        ("en_US", Calendar.Identifier.japanese, "10/22/R8, 6:50:57\u{202f}PM"),
        ("zh_TW", Calendar.Identifier.republicOfChina, "民國 115/10/22"),
        ("th_TH", Calendar.Identifier.buddhist, "22/10/2569 18:50:57")
    ])
    func eraYearIsNotZeroPadded(locale: String, identifier: Calendar.Identifier, expected: String) {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = columnCalendar.timeZone
        let shown = FileDates(locale: Locale(identifier: locale), calendar: calendar).string(columnMoment)
        #expect(shown.hasPrefix(expected), "\(locale) \(identifier): \(shown)")
    }

    @Test func dateCellsUseMonoAndNameKeepsSystemFont() async throws {
        let rig = ColumnsRig(preferences: ColumnPreferences(defaults: columnStore()))
        defer { rig.host.close() }
        try await rig.finish()
        let table = try rig.table()
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        for name in ["modified", "created", "opened"] {
            if name != "modified" { try rig.toggle(name) }
            let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(name))
            table.scrollColumnToVisible(index)
            let cell = try #require(table.view(atColumn: index, row: 0, makeIfNecessary: true) as? NSTableCellView)
            #expect(cell.textField?.font == mono)
        }
        let name = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        #expect(name.textField?.font == ResultsTable.font(.standard))
        #expect(table.rowHeight == ResultsTable.rowHeight(.standard))
        for column in table.tableColumns {
            table.scrollColumnToVisible(table.column(withIdentifier: column.identifier))
            table.headerView?.display()
            let actual = try #require(column.headerCell.font)
            #expect(columnFontMatches(actual, ResultsTable.headerFont(.standard)),
                    "\(column.identifier.rawValue) header: actual \(String(describing: actual)); expected \(ResultsTable.headerFont(.standard))")
        }
    }

    @Test func createdAndOpenedCellsShowTheirOwnDateAndDashesForEpochZero() async throws {
        let dates = FileDates(locale: Locale(identifier: "en_US"), calendar: columnCalendar)
        let modified = columnMoment
        let created = modified.addingTimeInterval(-86_400)
        let opened = modified.addingTimeInterval(86_400)
        let rig = ColumnsRig(preferences: ColumnPreferences(defaults: columnStore()), dates: dates)
        defer { rig.host.close() }
        rig.fake.setHits([
            SearchHit(name: "dated", folder: "/", size: 1, modified: modified, created: created, opened: opened, kind: .file),
            SearchHit(name: "undated", folder: "/", size: 1, modified: modified, created: Date(timeIntervalSince1970: 0), opened: Date(timeIntervalSince1970: 0), kind: .file),
        ])
        try await rig.finish(count: 2)
        try rig.toggle("created")
        try rig.toggle("opened")
        let table = try rig.table()
        func text(_ row: Int, _ column: String) throws -> String {
            let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column))
            table.scrollColumnToVisible(index)
            let cell = try #require(table.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView)
            return try #require(cell.textField?.stringValue)
        }
        #expect(try text(0, "modified") == dates.string(modified))
        #expect(try text(0, "created") == dates.string(created))
        #expect(try text(0, "opened") == dates.string(opened))
        #expect(Set([dates.string(modified), dates.string(created), dates.string(opened)]).count == 3)
        #expect(try text(1, "modified") == dates.string(modified))
        #expect(try text(1, "created") == "--")
        #expect(try text(1, "opened") == "--")
    }

    @Test func aColumnShownAfterATextSizeSwitchTakesTheSize() async throws {
        let store = columnStore()
        let rig = ColumnsRig(preferences: ColumnPreferences(defaults: columnStore()), store: store)
        defer { rig.host.close() }
        try await rig.finish()
        let table = try rig.table()
        store.set(TextSize.extraLarge.rawValue, forKey: TextSize.key)
        try await rig.host.until("26 pt rows") { table.rowHeight == 26 }
        #expect(try rig.column(.modified).headerCell.font?.pointSize == 14)
        try rig.toggle("created")
        let created = try rig.column(.created)
        #expect(created.headerCell.font?.pointSize == 14)
        #expect(created.width == FileDates.current.width(.extraLarge))
        #expect(created.minWidth == FileDates.current.width(.extraLarge))
        let index = table.column(withIdentifier: created.identifier)
        table.scrollColumnToVisible(index)
        let cell = try #require(table.view(atColumn: index, row: 0, makeIfNecessary: true) as? NSTableCellView)
        #expect(cell.textField?.font == ResultsTable.dateFont(.extraLarge))
    }

    @Test func headerFontComparisonRejectsOtherFacesSizesAndWeights() {
        let expected = ResultsTable.headerFont(.standard)
        let wrong = [
            NSFont.monospacedSystemFont(ofSize: expected.pointSize, weight: .regular),
            NSFont.systemFont(ofSize: expected.pointSize + 1),
            NSFont.systemFont(ofSize: expected.pointSize, weight: .bold)
        ]
        for font in wrong {
            #expect(!columnFontMatches(font, expected), "actual \(font); expected \(expected)")
        }
    }

    @Test func localeChangeRedrawsTwoWindowsThenTheOpenInspectorWithoutSearching() async throws {
        var locale = Locale(identifier: "en_US")
        let dates = FileDates(calendar: columnCalendar, localeProvider: { locale })
        let preferences = ColumnPreferences(defaults: columnStore())
        let first = ColumnsRig(preferences: preferences, dates: dates)
        let second = ColumnsRig(preferences: preferences, dates: dates)
        defer { first.host.close(); second.host.close() }
        try await first.finish()
        try await second.finish()
        try first.click(.modified)
        try await first.finish()
        let table = try first.table()
        let modified = try first.column(.modified)
        try await first.host.until("the completed date sort is drawn") { table.indicatorImage(in: modified) != nil }
        table.selectRowIndexes([0], byExtendingSelection: false)
        let order = first.model.shownSort
        let searches = first.fake.session(first.fake.lastSession)?.searches.count
        let width = try first.column(.modified).width
        func text(_ rig: ColumnsRig) throws -> String? {
            let table = try rig.table()
            let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier("modified"))
            table.scrollColumnToVisible(index)
            return (table.view(atColumn: index, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
        }
        #expect(try text(first) == dates.string(columnMoment))
        locale = Locale(identifier: "tr_TR")
        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        try await first.host.until("both existing date cells follow the locale") {
            (try? text(first)) == "22.10.2026 18:50:57" && (try? text(second)) == "22.10.2026 18:50:57"
        }
        #expect(try first.column(.modified).width != width)
        #expect(first.model.shownSort == order)
        #expect(table.selectedRow == 0)
        #expect(first.fake.session(first.fake.lastSession)?.searches.count == searches)

        let inspector = InspectorModel()
        inspector.shown = true
        inspector.select(first.model.rows(in: 0..<1).first)
        let pane = InspectorPane(inspector: inspector, dates: dates, quickLook: {}, reveal: {})
        pane.apply(theme: .systemNative, textSize: .standard, locale: Locale(identifier: "en"))
        let window = NSWindow(contentViewController: pane)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: SearchMetrics.inspectorWidth, height: SearchMetrics.windowMinHeight))
        window.orderFront(nil)
        defer { window.close() }
        let shows = { (text: String) in AXTree.elements(in: pane.view).contains { AXTree.names(of: $0).contains(text) } }
        try await untilTrue(waitingFor: "inspector's current system date") { shows("22.10.2026 18:50:57") }
        locale = Locale(identifier: "de_DE")
        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        try await untilTrue(waitingFor: "open inspector follows the next locale") { shows("22.10.2026, 18:50:57") }
        #expect(try text(first) == "22.10.2026, 18:50:57")
        #expect(first.model.shownSort == order)
        #expect(first.fake.session(first.fake.lastSession)?.searches.count == searches)
    }

    @Test func aTimeZoneChangeRebuildsTheFormatterInTheCurrentZone() async throws {
        let dates = FileDates(locale: Locale(identifier: "en_US"), calendar: .autoupdatingCurrent)
        let before = dates.formatter
        let revision = dates.revision
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        try await untilTrue(waitingFor: "a formatter rebuilt after the time zone change") { dates.formatter !== before }
        #expect(dates.revision > revision)
        #expect(dates.formatter.timeZone.identifier == TimeZone.current.identifier)
    }

    @Test func measuredWidthFitsDatesIncludingSeconds() throws {
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        for locale in ["tr_TR", "en_US", "en_GB", "de_DE", "ar_SA"] {
            let dates = FileDates(locale: Locale(identifier: locale), calendar: columnCalendar)
            let width = dates.columnWidth(font: mono, now: columnMoment)
            let expected = DateFormatter()
            expected.locale = Locale(identifier: locale)
            expected.calendar = columnCalendar
            expected.timeZone = columnCalendar.timeZone
            expected.dateStyle = .short
            expected.timeStyle = .medium
            expected.dateFormat = expected.dateFormat.replacingOccurrences(of: "(?<!y)yy(?!y)", with: "yyyy", options: .regularExpression)
            for month in 1...12 {
                for hour in 0..<24 {
                    let date = try #require(columnCalendar.date(from: DateComponents(year: 2026, month: month, day: 28, hour: hour, minute: 58, second: 59)))
                    let cell = ResultCell.make(NSUserInterfaceItemIdentifier("modified"), icon: false, font: mono)
                    cell.frame = NSRect(x: 0, y: 0, width: width, height: ResultsTable.rowHeight(.standard))
                    cell.show(expected.string(from: date))
                    cell.layoutSubtreeIfNeeded()
                    let label = try #require(cell.textField)
                    #expect(label.frame.width >= label.intrinsicContentSize.width, "\(locale): \(label.stringValue) at \(width)")
                }
            }
        }
    }
}


extension ColumnsTests {
    @Test func openedVisibilityInMainWindowsDoesNotRefreshTheLauncher() throws {
        let preferences = ColumnPreferences(defaults: columnStore())
        let fake = FakeSearchClient(hits: [.named("report")])
        let model = SearchModel(session: try fake.makeSession(), query: "report", columnPreferences: preferences)
        let before = fake.queries.count
        model.handle(.openedChanged)
        #expect(fake.queries.count == before)
        preferences.shown.insert(.opened)
        model.handle(.openedChanged)
        #expect(fake.queries.count == before, "the launcher's fixed columns do not include Opened")
        model.handle(.resultsReady(fake.latest, count: 1))
        model.handle(.resultsChanged)
        #expect(fake.queries.count == before + 1)
        model.query = "reports"
        #expect(fake.queries.last == "reports")
    }

    @Test func openedOnlyChangesRefreshJustVisibleOrSortedWindows() throws {
        for (shown, sorted) in [(false, false), (true, false), (false, true)] {
            let preferences = ColumnPreferences(defaults: columnStore())
            if shown { preferences.shown.insert(.opened) }
            let fake = FakeSearchClient(hits: [.named("report")])
            let model = SearchModel(session: try fake.makeSession(), listsAll: true, columnPreferences: preferences)
            if sorted { model.sort = SearchSort(column: .opened, ascending: false) }
            fake.finish(fake.lastSession)
            model.handle(.resultsReady(fake.latest, count: 1))
            let before = fake.queries.count
            model.handle(.openedChanged)
            #expect(fake.queries.count == before + (shown || sorted ? 1 : 0))
            model.handle(.resultsReady(fake.latest, count: 1))
            let after = fake.queries.count
            model.handle(.resultsChanged)
            #expect(fake.queries.count == after + 1, "other metadata must refresh every window")
        }
    }

    @Test func revealingOrSortingOpenedAfterASuppressedChangeFetchesFreshDates() throws {
        for sort in [false, true] {
            let preferences = ColumnPreferences(defaults: columnStore())
            func hit(_ time: TimeInterval) -> SearchHit {
                SearchHit(name: "report", folder: "/", size: 1, modified: columnMoment, created: columnMoment,
                          opened: Date(timeIntervalSince1970: time), kind: .file)
            }
            let fake = FakeSearchClient(hits: [hit(1_600_000_001)])
            let model = SearchModel(session: try fake.makeSession(), listsAll: true, columnPreferences: preferences)
            func finish() {
                fake.finish(fake.lastSession)
                model.handle(.resultsReady(fake.latest, count: 1))
            }
            finish()
            #expect(model.rows(in: 0..<1).first?.opened == hit(1_600_000_001).opened)
            let before = fake.queries.count
            fake.setHits([hit(1_600_000_002)])
            model.handle(.openedChanged)
            #expect(fake.queries.count == before)
            if sort { model.sort = SearchSort(column: .opened, ascending: false) }
            else { preferences.shown.insert(.opened) }
            #expect(fake.queries.count == before + 1, "a fresh search must replace the held metadata snapshot")
            #expect(fake.session(fake.lastSession)?.sorts.isEmpty == true)
            finish()
            #expect(model.rows(in: 0..<1).first?.opened == hit(1_600_000_002).opened)
            model.query = "report"
            #expect(fake.queries.last == "report")
            #expect(model.shownSort.column == (sort ? .opened : .relevance))
        }
    }

    @Test func openedChangesAndRevealingTheColumnKeepContentResultsFrozen() throws {
        let preferences = ColumnPreferences(defaults: columnStore())
        let fake = FakeSearchClient(hits: [.named("report")])
        let model = SearchModel(session: try fake.makeSession(), listsAll: true, columnPreferences: preferences)
        model.contentDraft = "needle"
        model.searchContent()
        let press = model.press
        let before = fake.queries.count
        model.handle(.openedChanged)
        preferences.shown.insert(.opened)
        model.sort = SearchSort(column: .opened, ascending: false)
        #expect(model.press == press)
        #expect(fake.queries.count == before)
        #expect(fake.presses.count == 1)
        #expect(fake.narrows.isEmpty)
        #expect(fake.session(fake.lastSession)?.sorts.last?.column == .opened)
    }
}
