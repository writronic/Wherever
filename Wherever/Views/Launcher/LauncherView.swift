import AppKit
import Combine
import Foundation
import Quartz
import SwiftUI
import WhereverInterface

struct LauncherView: View {
    @ObservedObject var launcher: Launcher
    @ObservedObject var model: SearchModel
    @AppStorage(SearchFilters.hidesHiddenKey) private var hidesHidden = false
    @AppStorage(Theme.key) private var theme = Theme.systemNative
    @AppStorage(Launcher.opacityKey) private var opacity = Launcher.standardOpacity
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hasText = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LauncherMetrics.fieldGap) {
                LauncherSearchIcon(color: theme.secondaryText)
                    .frame(width: LauncherMetrics.fieldIcon, height: LauncherMetrics.fieldIcon)
                LauncherField(model: model, hide: { launcher.hide() }, theme: theme, textSize: textSize)
            }
            .frame(height: LauncherMetrics.fieldHeight)
            .padding(.horizontal, LauncherMetrics.fieldSide)
            .padding(.top, LauncherMetrics.fieldTop)
            HStack(spacing: 0) {
                LauncherList(model: model, launcher: launcher)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        Group {
                            if model.failed, model.results.generation == nil {
                                Text("Search failed. Try again.", tableName: "Results")
                                    .accessibilityIdentifier(Launcher.failedID)
                            } else if model.results.generation != nil, model.results.count == 0 {
                                Text("No results", tableName: "Results")
                                    .accessibilityIdentifier(Launcher.emptyID)
                            }
                        }
                        .font(.system(size: ResultsTable.font(textSize).pointSize))
                        .foregroundStyle(Color(nsColor: theme.secondaryText))
                    }
                if launcher.previewShown {
                    hairline.frame(width: LauncherMetrics.hairline)
                    LauncherPreview(url: launcher.previewURL)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, LauncherMetrics.listSide)
            .padding(.top, launcher.listHeight == 0 ? 0 : LauncherMetrics.listTop)
            .padding(.bottom, launcher.listHeight == 0 ? 0 : LauncherMetrics.listBottom)
            .frame(height: launcher.listHeight)
            if hasText {
                Button(action: launcher.showAll) {
                    HStack(spacing: LauncherMetrics.iconGap) {
                        LauncherSearchIcon(color: theme.text, identifier: "launcher-show-all-icon")
                            .frame(width: LauncherMetrics.iconSize, height: LauncherMetrics.iconSize)
                            .accessibilityHidden(true)
                        Text("Show all in Wherever", tableName: "Results")
                        Spacer()
                        Text(verbatim: "⌘N")
                            .foregroundStyle(Color(nsColor: theme.secondaryText))
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: ResultsTable.font(textSize).pointSize))
                    .foregroundStyle(Color(nsColor: theme.text))
                    .padding(.horizontal, LauncherMetrics.fieldSide)
                    .frame(maxWidth: .infinity)
                    .frame(height: LauncherMetrics.rowHeight(textSize))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Show all in Wherever", tableName: "Results"))
                .accessibilityIdentifier(Launcher.showAllID)
            }
            StatusBarView(index: launcher.index, model: model, clearsBackground: true)
        }
        .background(Color(nsColor: theme.windowBackground).opacity(reduceTransparency ? 1 : Double(min(max(opacity, 0), 100)) / 100))
        .onAppear { model.filters.hidesHidden = hidesHidden }
        .onChange(of: hidesHidden) { model.filters.hidesHidden = $0 }
        .onReceive(model.queryChanges) { query in
            guard hasText != SearchModel.holdsWord(query) else { return }
            hasText = SearchModel.holdsWord(query)
            launcher.fit()
        }
    }

    private var hairline: some View { Rectangle().fill(Color(nsColor: .separatorColor)) }
}

private struct LauncherList: NSViewRepresentable {
    private static let columns: Set = [ResultsTable.Column.name.rawValue, ResultsTable.Column.folder.rawValue]

    @ObservedObject var model: SearchModel
    let launcher: Launcher
    @AppStorage(Theme.key) private var theme = Theme.systemNative
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @Environment(\.resultActions) private var actions

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ResultsTable.makeView(context.coordinator.results, textSize: textSize, actions: actions)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        if let table = context.coordinator.results.table {
            table.allowsMultipleSelection = false
            table.headerView = nil
            table.style = .plain
            table.rowHeight = LauncherMetrics.rowHeight(textSize)
            table.delegate = context.coordinator
            for column in table.tableColumns where !Self.columns.contains(column.identifier.rawValue) { table.removeTableColumn(column) }
            table.sizeLastColumnToFit()
            table.setAccessibilityIdentifier(Launcher.listID)
            launcher.table = table
        }
        return scroll
    }

    final class Coordinator: NSObject, NSTableViewDelegate {
        let results: ResultsTable.Coordinator

        init(model: SearchModel) {
            results = ResultsTable.Coordinator(model: model, appIcon: ResultsTable.liveAppIcon, announcer: .shared)
            results.clearsBackground = true
        }

        func tableViewSelectionDidChange(_ notification: Notification) { results.tableViewSelectionDidChange(notification) }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            results.tableView(tableView, didAdd: rowView, forRow: row)
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { LauncherRow() }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let cell = results.tableView(tableView, viewFor: tableColumn, row: row) as? ResultCell else { return nil }
            let name = tableColumn?.identifier.rawValue == ResultsTable.Column.name.rawValue
            cell.textField?.font = results.textSize.font(.preferredFont(forTextStyle: name ? .body : .callout))
            cell.textField?.lineBreakMode = .byTruncatingMiddle
            cell.padding = LauncherMetrics.cellPadding
            cell.iconGap = LauncherMetrics.iconGap
            cell.iconSize = LauncherMetrics.iconSize
            if let hit = results.model.rows(in: row..<row + 1).first {
                cell.show(name ? hit.name : hit.folder, matches: name ? hit.matches : [])
            }
            return cell
        }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let rowHeight = LauncherMetrics.rowHeight(textSize)
        if let table = context.coordinator.results.table, table.rowHeight != rowHeight { table.rowHeight = rowHeight }
        ResultsTable.update(context.coordinator.results, theme: theme, textSize: textSize, actions: actions)
        DispatchQueue.main.async { [weak launcher] in launcher?.fit() }
    }
}

private final class LauncherRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        Theme.launcherSelection.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: LauncherMetrics.rowRadius, yRadius: LauncherMetrics.rowRadius).fill()
        Theme.launcherSelectionBorder.setStroke()
        let scale = window?.backingScaleFactor ?? 1
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5 / scale, dy: 0.5 / scale),
                                  xRadius: LauncherMetrics.rowRadius, yRadius: LauncherMetrics.rowRadius)
        border.lineWidth = 1 / scale
        border.stroke()
    }
}

private struct LauncherSearchIcon: NSViewRepresentable {
    let color: NSColor
    var identifier = "launcher-search-icon"

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        view.imageScaling = .scaleNone
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) { view.contentTintColor = color }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        CGSize(width: LauncherMetrics.fieldIcon, height: LauncherMetrics.fieldIcon)
    }
}

private struct LauncherField: NSViewRepresentable {
    let model: SearchModel
    let hide: () -> Void
    let theme: Theme
    let textSize: TextSize

    func makeCoordinator() -> SearchField.Coordinator { SearchField.Coordinator(model: model, onEmptyEscape: hide) }

    func makeNSView(context: Context) -> LauncherFieldHost {
        let host = LauncherFieldHost()
        let field = host.field
        field.font = textSize.font(.systemFont(ofSize: LauncherMetrics.fieldFontSize))
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        field.placeholderString = String(localized: "Search files")
        field.cell?.setAccessibilityLabel(field.placeholderString)
        field.cell?.setAccessibilityIdentifier(SearchView.fieldID)
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(SearchField.Coordinator.search(_:))
        field.delegate = context.coordinator
        field.stringValue = model.query
        context.coordinator.watch = model.queryChanges.sink { [weak field] query in
            if let field, field.stringValue != query { field.stringValue = query }
        }
        return host
    }

    func updateNSView(_ host: LauncherFieldHost, context: Context) {
        host.field.textColor = theme.text
        let font = textSize.font(.systemFont(ofSize: LauncherMetrics.fieldFontSize))
        guard host.field.font != font else { return }
        host.field.font = font
        host.resizeSubviews(withOldSize: host.bounds.size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LauncherFieldHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.field.intrinsicContentSize.width, height: LauncherMetrics.fieldHeight)
    }
}

private final class LauncherFieldHost: NSView {
    let field = FocusedSearchField()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var alignmentRectInsets: NSEdgeInsets { field.alignmentRectInsets }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    override func mouseDown(with event: NSEvent) { window?.focusSearchField() }
}

final class LauncherPreviewView: QLPreviewView {
    private var item: QLPreviewItem?

    override var acceptsFirstResponder: Bool { false }

    override var previewItem: QLPreviewItem! {
        get { WhereverApp.usesPreviewServices ? item : super.previewItem }
        set {
            item = newValue
            if !WhereverApp.usesPreviewServices { super.previewItem = newValue }
        }
    }
}

private struct LauncherPreview: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> LauncherPreviewView {
        let view: LauncherPreviewView = LauncherPreviewView(frame: .zero, style: .normal)
        view.autostarts = false
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: LauncherPreviewView, context: Context) {
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url.map { $0 as NSURL as QLPreviewItem }
    }

    static func dismantleNSView(_ view: LauncherPreviewView, coordinator: ()) {
        view.close()
    }
}
