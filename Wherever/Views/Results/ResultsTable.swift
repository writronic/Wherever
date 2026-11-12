import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WhereverInterface

typealias AppIconLoader = @Sendable (String) -> CGImage?

struct ResultsTable: NSViewRepresentable {
    enum Column: String, CaseIterable {
        case name, folder, size, modified, created, opened, kind

        static let defaults: [Column] = [.name, .folder, .size, .modified, .kind]

        var title: String {
            switch self {
            case .name: String(localized: "Name", table: "Results")
            case .folder: String(localized: "Folder", table: "Results")
            case .size: String(localized: "Size", table: "Results")
            case .modified: String(localized: "Modified", table: "Results")
            case .kind: String(localized: "Kind", table: "Results")
            case .created: String(localized: "Created", table: "Results")
            case .opened: String(localized: "Opened", table: "Results")
            }
        }

        var sortColumn: SearchColumn? {
            switch self {
            case .name: .name
            case .folder: .folder
            case .size: .size
            case .modified: .modified
            case .kind: .kind
            case .created: .created
            case .opened: .opened
            }
        }

        var isDate: Bool {
            switch self {
            case .modified, .created, .opened: true
            default: false
            }
        }

        func width(_ size: TextSize) -> CGFloat {
            switch self {
            case .name: size.width(SearchMetrics.nameColumnWidth)
            case .folder: size.width(SearchMetrics.folderColumnWidth)
            case .size: size.width(SearchMetrics.sizeColumnWidth)
            case .modified, .created, .opened: ResultsTable.modifiedWidth(size)
            case .kind: size.width(SearchMetrics.kindColumnWidth)
            }
        }
    }

    final class ToneHeaderCell: NSTableHeaderCell {
        var theme = Theme.systemNative
        var size = TextSize.standard
        override var font: NSFont? {
            get { ResultsTable.headerFont(size) }
            set {}
        }
        override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
            textColor = theme.secondaryText
            super.drawInterior(withFrame: cellFrame.insetBy(dx: SearchMetrics.cellPadding, dy: 0), in: controlView)
        }
    }

    static func font(_ size: TextSize) -> NSFont { size.font(.systemFont(ofSize: NSFont.systemFontSize)) }
    static func dateFont(_ size: TextSize) -> NSFont { size.font(.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)) }
    static func modifiedWidth(_ size: TextSize) -> CGFloat { FileDates.current.width(size) }
    static func rowHeight(_ size: TextSize) -> CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font(size)) + 2 * SearchMetrics.rowInset) }

    static func headerFont(_ size: TextSize) -> NSFont { size.font(.systemFont(ofSize: NSFont.smallSystemFontSize)) }
    static func headerHeight(_ size: TextSize) -> CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: headerFont(size)) + 2 * SearchMetrics.headerInset) + 1 }

    static func trailing(in direction: NSUserInterfaceLayoutDirection) -> NSTextAlignment { direction == .rightToLeft ? .left : .right }

    static var liveAppIcon: AppIconLoader {
        let inert = WhereverApp.usesPreviewServices
        return skippingDataless { path in inert ? nil : NSWorkspace.shared.icon(forFile: path).cgImage(forProposedRect: nil, context: nil, hints: nil) }
    }

    static func skippingDataless(_ load: @escaping AppIconLoader, dataless: @escaping DatalessCheck = isDataless) -> AppIconLoader {
        { path in dataless(path) ? nil : load(path) }
    }

    @ObservedObject var model: SearchModel
    var appIcon: AppIconLoader = Self.liveAppIcon
    var dates = FileDates.current
    var announcer = Announcer.shared
    @AppStorage(Theme.key) private var theme = Theme.systemNative
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    func makeCoordinator() -> Coordinator { Coordinator(model: model, appIcon: appIcon, announcer: announcer, dates: dates) }

    static func countText(_ count: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        count == 0
            ? String(localized: "No results", table: "Results", bundle: bundle)
            : String(localized: "\(count) results", table: "Results", bundle: bundle, locale: locale)
    }

    func makeNSView(context: Context) -> NSScrollView { Self.makeView(context.coordinator, textSize: textSize, actions: context.environment.resultActions) }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        Self.update(context.coordinator, theme: theme, textSize: textSize, actions: context.environment.resultActions)
    }

    static func makeView(_ coordinator: Coordinator, textSize: TextSize, actions: ResultActions) -> NSScrollView {
        coordinator.textSize = textSize
        let table = ThemedTable()
        for column in Column.defaults {
            table.addTableColumn(makeColumn(column, direction: table.userInterfaceLayoutDirection, dates: coordinator.dates, size: textSize))
        }
        table.allowsMultipleSelection = true
        table.allowsColumnSelection = false
        table.allowsTypeSelect = false
        table.style = .inset
        table.headerView = ColumnHeader(preferences: coordinator.model.columnPreferences, frame: NSRect(x: 0, y: 0, width: 0, height: headerHeight(textSize)))
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowSizeStyle = .custom
        table.rowHeight = rowHeight(textSize)
        table.intercellSpacing = .zero
        table.sizeLastColumnToFit()
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = table
        table.doubleAction = #selector(ThemedTable.openClicked(_:))
        table.addGestureRecognizer(PressSelect())
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.hit = { [model = coordinator.model] row in model.rows(in: row..<row + 1).first }
        table.hits = { [model = coordinator.model] rows in model.hits(at: rows) }
        table.searchFailed = { [model = coordinator.model] in model.failed }
        table.readHits = { [model = coordinator.model] rows in model.readHits(at: rows) }
        use(actions, on: table)
        coordinator.table = table
        coordinator.watchColumns()
        coordinator.announcer.watch(table)

        let scroll = KeyLoopScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    private static func makeColumn(_ column: Column, direction: NSUserInterfaceLayoutDirection, dates: FileDates, size: TextSize) -> NSTableColumn {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        let header = ToneHeaderCell(textCell: column.title)
        header.size = size
        tableColumn.headerCell = header
        tableColumn.width = column.isDate ? dates.width(size) : column.width(size)
        if column.isDate { tableColumn.minWidth = dates.width(size) }
        if column == .kind { tableColumn.minWidth = SearchMetrics.kindColumnWidth }
        if column == .size { tableColumn.headerCell.alignment = trailing(in: direction) }
        return tableColumn
    }

    private static func use(_ actions: ResultActions, on table: ThemedTable) {
        table.actions = actions
        let accepts = actions.accept != nil
        guard accepts != table.registeredDraggedTypes.contains(.fileURL) else { return }
        if accepts { table.registerForDraggedTypes([.fileURL]) } else { table.unregisterDraggedTypes() }
    }

    static func update(_ coordinator: Coordinator, theme: Theme, textSize: TextSize, actions: ResultActions) {
        if let table = coordinator.table { use(actions, on: table) }
        coordinator.use(theme)
        coordinator.use(textSize)
        coordinator.mark(coordinator.model.shownSort)
        coordinator.show(coordinator.model.results)
        coordinator.speakEnd()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let appIconLimit = 256

        private enum Kept {
            case all
            case rows([(row: Int, hit: SearchHit)])
        }

        let model: SearchModel
        let dates: FileDates
        let appIcon: AppIconLoader
        private var columnsWatch: AnyCancellable?
        private var datesWatch: AnyCancellable?
        let announcer: Announcer
        weak var table: ThemedTable?
        var onSelect: (SearchHit?, Int) -> Void = { _, _ in }
        var clearsBackground = false
        private var spoken: (revision: Int, press: SearchGeneration?)?
        private var shown = SearchModel.Results()
        private var selectedCount = 0
        private var kept: Kept?
        private var quiet = false
        private var appIcons: [String: NSImage] = [:]
        private var loading: Set<String> = []
        private var theme: Theme?
        private var text = NSColor.labelColor
        private var secondary = NSColor.labelColor
        private var match = NSColor.labelColor
        private var marked: SearchSort?
        fileprivate(set) var textSize = TextSize.standard {
            didSet { fonts = (ResultsTable.font(textSize), ResultsTable.dateFont(textSize)) }
        }
        private var fonts = (text: ResultsTable.font(.standard), date: ResultsTable.dateFont(.standard))

        init(model: SearchModel, appIcon: @escaping AppIconLoader, announcer: Announcer, dates: FileDates = .current) {
            self.model = model
            self.dates = dates
            self.appIcon = appIcon
            self.announcer = announcer
        }

        func watchColumns() {
            guard !clearsBackground else { return }
            columnsWatch = model.columnPreferences.$shown.sink { [weak self] in self?.showColumns($0) }
            datesWatch = dates.$revision.dropFirst().sink { [weak self] _ in self?.refreshDates() }
        }

        private func refreshDates() {
            guard let table else { return }
            let selection = table.selectedRowIndexes
            for column in table.tableColumns where Column(rawValue: column.identifier.rawValue)?.isDate == true {
                column.minWidth = dates.width(textSize)
                column.width = dates.width(textSize)
            }
            table.sizeLastColumnToFit()
            table.reloadData()
            table.selectRowIndexes(selection, byExtendingSelection: false)
        }

        private func showColumns(_ shown: Set<Column>) {
            guard let table else { return }
            let selection = table.selectedRowIndexes
            let wanted = Column.allCases.filter { $0 == .name || shown.contains($0) }
            for column in table.tableColumns where !wanted.contains(where: { $0.rawValue == column.identifier.rawValue }) {
                table.removeTableColumn(column)
            }
            for (position, column) in wanted.enumerated() where table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)) == nil {
                let added = ResultsTable.makeColumn(column, direction: table.userInterfaceLayoutDirection, dates: dates, size: textSize)
                (added.headerCell as? ToneHeaderCell)?.theme = theme ?? .systemNative
                table.addTableColumn(added)
                let target = wanted[..<position].last.map { table.column(withIdentifier: NSUserInterfaceItemIdentifier($0.rawValue)) + 1 } ?? 0
                if target != table.numberOfColumns - 1 { table.moveColumn(table.numberOfColumns - 1, toColumn: target) }
            }
            marked = nil
            mark(model.shownSort)
            table.sizeLastColumnToFit()
            table.reloadData()
            table.selectRowIndexes(selection.intersection(IndexSet(integersIn: 0..<table.numberOfRows)), byExtendingSelection: false)
        }

        func use(_ theme: Theme) {
            guard theme != self.theme, let table else { return }
            self.theme = theme
            text = theme.text
            secondary = theme.secondaryText
            match = theme.matchText
            table.backgroundColor = clearsBackground ? .clear : theme.rowBackground
            table.stripe = clearsBackground ? .clear : theme.stripeBackground
            for case let cell as ToneHeaderCell in table.tableColumns.map(\.headerCell) { cell.theme = theme }
            table.headerView?.needsDisplay = true
            table.needsDisplay = true
            table.enumerateAvailableRowViews { view, _ in view.backgroundColor = .clear }
            reloadAvailableRows(of: table)
        }

        func use(_ size: TextSize) {
            guard size != textSize, let table else { return }
            textSize = size
            let scroll = table.enclosingScrollView
            let top = scroll.map { $0.contentView.bounds.minY + $0.contentView.contentInsets.top } ?? 0
            let anchor = top > 0 ? table.row(at: NSPoint(x: table.bounds.midX, y: top)) : -1
            for case let cell as ToneHeaderCell in table.tableColumns.map(\.headerCell) { cell.size = size }
            if let header = table.headerView, let scroll {
                let height = ResultsTable.headerHeight(size)
                header.setFrameSize(NSSize(width: header.frame.width, height: height))
                if let headerClip = header.superview { headerClip.setFrameSize(NSSize(width: headerClip.frame.width, height: height)) }
                scroll.tile()
                header.needsDisplay = true
            }
            if !clearsBackground { table.rowHeight = ResultsTable.rowHeight(size) }
            for tableColumn in table.tableColumns {
                guard let column = Column(rawValue: tableColumn.identifier.rawValue) else { continue }
                if column.isDate { tableColumn.minWidth = dates.width(size) }
                tableColumn.width = column.isDate ? dates.width(size) : column.width(size)
            }
            table.sizeLastColumnToFit()
            if let scroll {
                let clip = scroll.contentView
                let y = anchor > 0 ? table.rect(ofRow: anchor).minY - clip.contentInsets.top : -clip.contentInsets.top
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                scroll.reflectScrolledClipView(clip)
            }
            reloadAvailableRows(of: table)
        }

        private func reloadAvailableRows(of table: NSTableView) {
            let count = table.numberOfRows
            var rows = IndexSet()
            table.enumerateAvailableRowViews { _, row in if row < count { rows.insert(row) } }
            table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) { rowView.backgroundColor = .clear }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let column = Column(rawValue: tableColumn.identifier.rawValue), let sortColumn = column.sortColumn else { return }
            tableView.deselectAll(nil)
            model.sort = model.shownSort.next(clicking: sortColumn)
        }

        func mark(_ sort: SearchSort) {
            guard sort != marked, let table else { return }
            marked = sort
            for column in table.tableColumns {
                let sorted = Column(rawValue: column.identifier.rawValue)?.sortColumn == sort.column
                let image = sorted ? NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil
                table.setIndicatorImage(image, in: column)
                column.headerCell.setAccessibilitySortDirection(sorted ? (sort.ascending ? .ascending : .descending) : .unknown)
            }
        }

        func show(_ results: SearchModel.Results) {
            guard results != shown, let table else { return }
            let kept = results.live ? self.kept : nil
            let resized = results.count != shown.count
            let reuses = results.live || shown.count > 0
            shown = results
            speak(results, from: table)
            quiet = true
            if reuses {
                if resized { table.noteNumberOfRowsChanged() }
                reloadAvailableRows(of: table)
            } else {
                table.reloadData()
            }
            switch kept {
            case .all?:
                table.selectRowIndexes(IndexSet(integersIn: 0..<results.count), byExtendingSelection: false)
            case let .rows(rows)?:
                table.selectRowIndexes(refind(rows), byExtendingSelection: false)
            case nil:
                table.deselectAll(nil)
                if !results.live, results.count > 0 { table.scrollRowToVisible(0) }
            }
            quiet = false
            if results.live, !table.selectedRowIndexes.isEmpty { selectionChanged() }
            if table.selectedRowIndexes.isEmpty, selectedCount > 0 {
                selectedCount = 0
                self.kept = nil
                table.selectionMoved()
                onSelect(nil, 0)
            }
        }

        private func refind(_ rows: [(row: Int, hit: SearchHit)]) -> IndexSet {
            var found = IndexSet()
            for (page, group) in Dictionary(grouping: rows, by: { $0.row / SearchModel.pageSize }) {
                var missing = group.map(\.hit)
                for near in [page, page - 1, page + 1] where near >= 0 && !missing.isEmpty {
                    let start = near * SearchModel.pageSize
                    let hits = model.rows(in: start..<start + SearchModel.pageSize)
                    missing.removeAll { kept in
                        guard let index = hits.firstIndex(where: { $0.name == kept.name && $0.folder == kept.folder }) else { return false }
                        found.insert(start + index)
                        return true
                    }
                }
            }
            return found
        }

        private func speak(_ results: SearchModel.Results, from table: NSTableView) {
            guard results.generation != nil else {
                spoken = nil
                return announcer.hush()
            }
            let asked = (revision: model.searchRevision, press: model.press)
            if results.live || model.reading || spoken.map({ $0 == asked }) == true { return }
            spoken = asked
            announcer.announce(ResultsTable.countText(results.count), from: table)
        }

        func speakEnd() {
            guard let table, let press = model.press, model.results.generation != nil, !model.reading, !model.isPending, spoken?.press != press else { return }
            spoken = (model.searchRevision, press)
            announcer.announce(ResultsTable.countText(model.results.count), from: table)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

        func tableViewSelectionDidChange(_ notification: Notification) {
            if !quiet { selectionChanged() }
        }

        private func selectionChanged() {
            let rows = table?.selectedRowIndexes ?? []
            selectedCount = rows.count
            kept = keep(rows, of: table?.numberOfRows ?? 0)
            table?.selectionMoved()
            onSelect(rows.first.flatMap { model.rows(in: $0..<$0 + 1).first }, rows.count)
        }

        private func keep(_ rows: IndexSet, of total: Int) -> Kept? {
            if rows.count > 1, rows.count == total { return .all }
            var pages = Set<Int>()
            for run in rows.rangeView {
                let first = run.lowerBound / SearchModel.pageSize
                let last = (run.upperBound - 1) / SearchModel.pageSize
                guard last - first < SearchModel.pageLimit else { return nil }
                pages.formUnion(first...last)
                guard pages.count <= SearchModel.pageLimit else { return nil }
            }
            return .rows(rows.compactMap { row in model.rows(in: row..<row + 1).first.map { (row, $0) } })
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            model.rows(in: row..<row + 1).first.flatMap { (tableView as? ThemedTable)?.actions.dragItem($0) }
        }

        private static func accept(_ info: any NSDraggingInfo, on tableView: NSTableView) -> (([URL]) -> Void)? {
            guard (info.draggingSource as AnyObject?) !== tableView else { return nil }
            return (tableView as? ThemedTable)?.actions.accept
        }

        func tableView(
            _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard Self.accept(info, on: tableView) != nil,
                  info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard row == -1, dropOperation == .on, let accept = Self.accept(info, on: tableView),
                  let read = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
            else { return false }
            let urls = read.compactMap(\.filePathURL)
            guard !urls.isEmpty else { return false }
            accept(urls)
            return true
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue) else { return nil }
            let font = column.isDate ? fonts.date : fonts.text
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultCell
                ?? ResultCell.make(identifier, icon: column == .name, font: font)
            if cell.textField?.font != font { cell.textField?.font = font }
            let trailing = ResultsTable.trailing(in: tableView.userInterfaceLayoutDirection)
            cell.textField?.alignment = column == .size ? trailing : .natural
            cell.textField?.lineBreakMode = column == .folder ? .byTruncatingMiddle : .byTruncatingTail
            cell.tone = column == .name ? text : secondary
            cell.matchTone = match
            guard let hit = model.rows(in: row..<row + 1).first else {
                cell.show("")
                cell.imageView?.image = nil
                cell.path = ""
                cell.textField?.setAccessibilityLabel(nil)
                return cell
            }
            switch column {
            case .name: cell.show(hit.name, matches: hit.matches)
            case .folder: cell.show(hit.folder)
            case .size: cell.show(hit.kind == .folder ? "--" : ByteCountFormatter.string(fromByteCount: hit.size, countStyle: .file))
            case .modified: cell.show(dates.string(hit.modified))
            case .kind: cell.show(ResultType.of(hit).kind)
            case .created: cell.show(dateText(hit.created))
            case .opened: cell.show(dateText(hit.opened))
            }
            if column == .name {
                cell.path = hit.path
                cell.imageView?.image = icon(for: hit, at: hit.path)
                cell.textField?.setAccessibilityLabel(hit.name)
            }
            return cell
        }

        private func dateText(_ date: Date) -> String {
            date.timeIntervalSince1970 == 0 ? "--" : dates.string(date)
        }

        private func icon(for hit: SearchHit, at path: String) -> NSImage {
            guard hit.name.lowercased().hasSuffix(".app") else { return ResultType.of(hit).icon }
            if let found = appIcons[path] { return found }
            if loading.insert(path).inserted {
                let load = appIcon
                Task.detached(priority: .utility) { [weak self] in
                    let image = load(path)
                    await self?.finish(path, image)
                }
            }
            return ResultType.of(hit).icon
        }

        private func finish(_ path: String, _ image: CGImage?) {
            loading.remove(path)
            if appIcons.count >= Self.appIconLimit { appIcons.removeAll() }
            let icon = image.map { NSImage(cgImage: $0, size: .zero) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
            appIcons[path] = icon
            guard let table else { return }
            let name = table.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue))
            let visible = table.rows(in: table.visibleRect)
            for row in visible.location..<visible.location + visible.length {
                guard let cell = table.view(atColumn: name, row: row, makeIfNecessary: false) as? ResultCell, cell.path == path else { continue }
                cell.imageView?.image = icon
            }
        }
    }
}

extension SearchSort {
    func next(clicking clicked: SearchColumn) -> SearchSort {
        let first = SearchSort(column: clicked, ascending: ![.size, .modified, .created, .opened].contains(clicked), foldersFirst: foldersFirst)
        guard column == clicked else { return first }
        return ascending == first.ascending ? SearchSort(column: clicked, ascending: !first.ascending, foldersFirst: foldersFirst) : SearchSort(column: .relevance, ascending: false, foldersFirst: foldersFirst)
    }
}

final class KeyLoopScrollView: NSScrollView {
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .tab?: insertTab(nil)
        case .backTab?: insertBacktab(nil)
        default: super.keyDown(with: event)
        }
    }
}
