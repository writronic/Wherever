import AppKit
import CoreText
import Foundation
import SwiftUI
import WhereverInterface

struct ArchiveView: View {
    static let problemID = "archive-problem"
    static let problemRevealID = "archive-problem-show-in-finder"

    @ObservedObject var model: ArchiveWindowModel
    @AppStorage(SearchFilters.hidesHiddenKey) private var hidesHidden = false
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        VStack(spacing: 0) {
            SearchField(
                model: model.results,
                placeholder: String(localized: "Search in “\(Bidi.name(model.name))”", table: "Archive"),
                onEmptyEscape: {}
            )
            .controlSize(.large)
            .padding(.vertical, SearchMetrics.fieldInset)
            .padding(.horizontal, SearchMetrics.sideInset)
            .id(ObjectIdentifier(model.results))
            Divider()
            ArchivePathBar(model: model)
            Divider()
            if let problem = model.blocked {
                VStack(spacing: SearchMetrics.inspectorSpacing) {
                    Text(verbatim: ArchiveWindowModel.line(problem, name: model.name))
                        .font(textSize.body)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(Self.problemID)
                    if ArchiveWindowModel.revealsArchive(problem) {
                        Button(String(localized: "Show in Finder", table: "Results"), action: model.showInFinder)
                            .font(textSize.body)
                            .accessibilityIdentifier(Self.problemRevealID)
                    }
                }
                .padding(SearchMetrics.inspectorPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ArchiveTable(model: model, results: model.results)
                    .id(ObjectIdentifier(model.results))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ArchiveStatusBar(model: model, results: model.results) }
        .frame(minWidth: SearchMetrics.windowMinWidth, minHeight: SearchMetrics.windowMinHeight)
        .themedWindowBackground()
        .sheet(isPresented: Binding(get: { model.asking != nil }, set: { if !$0 { model.cancelPassword() } })) {
            ArchivePasswordSheet(model: model, name: model.asking ?? model.name)
        }
        .onAppear { model.results.filters.hidesHidden = hidesHidden }
        .onChange(of: hidesHidden) { model.results.filters.hidesHidden = $0 }
    }
}

struct ArchivePathBar: View {
    static let barID = "archive-path-bar"
    static let enclosingID = "archive-enclosing-folder"
    static let expandID = "archive-expand-archive"

    static func segmentID(_ index: Int) -> String { "archive-path-segment-\(index)" }

    @ObservedObject var model: ArchiveWindowModel
    @AppStorage(Theme.key) private var theme = Theme.systemNative
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        let enclosing = String(localized: "Enclosing Folder", table: "Archive")
        let segments = model.segments
        HStack(spacing: SearchMetrics.iconGap) {
            Button(action: model.goEnclosing) { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(!model.canGoUp)
                .help(enclosing)
                .accessibilityLabel(Text(verbatim: enclosing))
                .accessibilityIdentifier(Self.enclosingID)
            ForEach(segments.indices, id: \.self) { index in
                if index > 0 {
                    Image(systemName: "chevron.forward")
                        .imageScale(.small)
                        .foregroundStyle(Color(nsColor: theme.secondaryText))
                        .accessibilityHidden(true)
                }
                Button { model.go(toSegment: index) } label: { Text(verbatim: segments[index]) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(nsColor: index == segments.count - 1 ? theme.text : theme.secondaryText))
                    .accessibilityIdentifier(Self.segmentID(index))
            }
            Spacer(minLength: 0)
            Button(String(localized: "Expand Archive…", table: "Archive"), action: model.expandArchive)
                .controlSize(.small)
                .disabled(!model.canExpand)
                .accessibilityIdentifier(Self.expandID)
        }
        .font(Font(ResultsTable.font(textSize) as CTFont))
        .lineLimit(1)
        .frame(height: ResultsTable.rowHeight(textSize))
        .padding(.horizontal, SearchMetrics.sideInset)
        .padding(.vertical, SearchMetrics.statusVerticalInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.barID)
    }
}

struct ArchiveStatusBar: View {
    static let statusID = "archive-status"
    static let formatID = "archive-status-format"
    static let itemsID = "archive-status-items"
    static let sizeID = "archive-status-size"
    static let lockID = "archive-status-lock"
    static let activityID = "archive-status-activity"
    static let skippedID = "archive-status-skipped"
    static let stopID = "archive-stop"
    static let preparingID = "archive-status-preparing"
    static let preparingStopID = "archive-preparing-stop"
    static let openingID = "archive-status-opening"
    static let openingStopID = "archive-opening-stop"
    static let noticeID = "archive-status-notice"
    static let progressID = "archive-status-progress"
    static let expandingID = "archive-status-expanding"
    static let expandingStopID = "archive-expanding-stop"
    static let expandedID = "archive-status-expanded"
    static let expandedSkippedID = "archive-status-expanded-skipped"
    static let expandedRevealID = "archive-expanded-show-in-finder"
    static let searchID = "archive-status-search"
    static let readOnlyID = "archive-status-read-only"
    static let addingID = "archive-status-adding"
    static let addingStopID = "archive-adding-stop"
    static let savingID = "archive-status-saving"
    static let savingStopID = "archive-saving-stop"
    static let progressWidth: CGFloat = 120

    @ObservedObject var model: ArchiveWindowModel
    @ObservedObject var results: SearchModel
    @Environment(\.locale) private var locale
    @AppStorage(Theme.key) private var theme = Theme.systemNative
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        let line = StatusBarView.lineHeight(textSize)
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: SearchMetrics.statusItemSpacing) {
                if model.reading {
                    activity(Text("Reading “\(Bidi.name(model.name))”…", tableName: "Archive"), id: Self.activityID, line: line)
                    Button(String(localized: "Stop", table: "Normal", locale: locale)) { model.stopReading() }
                        .buttonStyle(.link)
                        .accessibilityIdentifier(Self.stopID)
                } else {
                    Text(verbatim: ArchiveWindowModel.formatName(model.name))
                        .foregroundStyle(Color(nsColor: theme.text))
                        .accessibilityIdentifier(Self.formatID)
                    if let saving = model.saving {
                        let label = Text("Saving “\(Bidi.name(saving.name))”…", tableName: "Archive")
                        progress(saving.fraction, label: label, line: line)
                        label
                            .foregroundStyle(Color(nsColor: theme.text))
                            .accessibilityIdentifier(Self.savingID)
                        Button(String(localized: "Stop", table: "Normal", locale: locale)) { model.stopSaving() }
                            .buttonStyle(.link)
                            .accessibilityIdentifier(Self.savingStopID)
                    } else if let expansion = model.expansion {
                        expansionItems(expansion, line: line)
                    } else if let summary = model.summary, model.blocked == nil {
                        if summary.encrypted {
                            Image(systemName: "lock.fill")
                                .accessibilityLabel(Text("Encrypted", tableName: "Archive"))
                                .accessibilityIdentifier(Self.lockID)
                        }
                        Text("Items: \(summary.items.formatted(.number.locale(locale)))", tableName: "Archive")
                            .accessibilityIdentifier(Self.itemsID)
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(clamping: summary.bytes), countStyle: .file))
                            .accessibilityIdentifier(Self.sizeID)
                        if summary.skipped > 0 {
                            Text("\(Int(clamping: summary.skipped)) items skipped", tableName: "Archive")
                                .help(String(localized: "Items whose names or links point outside the archive, and device files.", table: "Archive", locale: locale))
                                .accessibilityIdentifier(Self.skippedID)
                        }
                    }
                    if let adding = model.edits?.adding {
                        activity(Text("Adding “\(Bidi.name(adding))”…", tableName: "Archive"), id: Self.addingID, line: line)
                        Button(String(localized: "Stop", table: "Normal", locale: locale)) { model.edits?.stopAdding() }
                            .buttonStyle(.link)
                            .accessibilityIdentifier(Self.addingStopID)
                    } else if let opening = model.opening {
                        activity(Text("Opening “\(Bidi.name(opening))”…", tableName: "Archive"), id: Self.openingID, line: line)
                        Button(String(localized: "Stop", table: "Normal", locale: locale)) { model.stopPreparing() }
                            .buttonStyle(.link)
                            .accessibilityIdentifier(Self.openingStopID)
                    } else if let preparing = model.preparing {
                        activity(Text("Preparing “\(Bidi.name(preparing))”…", tableName: "Archive"), id: Self.preparingID, line: line)
                        Button(String(localized: "Stop", table: "Normal", locale: locale)) { model.stopPreparing() }
                            .buttonStyle(.link)
                            .accessibilityIdentifier(Self.preparingStopID)
                    } else if let notice = model.notice {
                        Text(verbatim: notice)
                            .foregroundStyle(Color(nsColor: theme.text))
                            .help(notice)
                            .accessibilityIdentifier(Self.noticeID)
                    } else if model.blocked == nil, let problem = model.problem {
                        let line = ArchiveWindowModel.line(problem, name: model.name)
                        Text(verbatim: line)
                            .foregroundStyle(Color(nsColor: theme.text))
                            .help(line)
                            .accessibilityIdentifier(ArchiveView.problemID)
                    }
                }
                Spacer(minLength: 0)
                if model.searching, !model.reading, results.results.generation != nil, let time = results.lastSearchTime {
                    let count = String(localized: "\(results.results.count) results", table: "Results", locale: locale)
                    let milliseconds = time.formatted(.units(allowed: [.milliseconds], width: .abbreviated).locale(locale))
                    Text("Search: \(count) – \(milliseconds)")
                        .accessibilityIdentifier(Self.searchID)
                }
                if let reason = model.readOnly {
                    Text("Read only", tableName: "Archive")
                        .help(reason)
                        .accessibilityIdentifier(Self.readOnlyID)
                }
            }
            .font(Font(StatusBarView.font(textSize) as CTFont))
            .foregroundStyle(Color(nsColor: theme.secondaryText))
            .lineLimit(1)
            .frame(height: line)
            .padding(.horizontal, SearchMetrics.sideInset)
            .padding(.vertical, SearchMetrics.statusVerticalInset)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Self.statusID)
        }
        .background(Color(nsColor: theme.windowBackground))
    }

    @ViewBuilder private func expansionItems(_ expansion: ArchiveWindowModel.Expansion, line: CGFloat) -> some View {
        switch expansion {
        case let .running(name, fraction):
            let label = Text("Expanding “\(Bidi.name(name))”…", tableName: "Archive")
            progress(fraction, label: label, line: line)
            label
                .foregroundStyle(Color(nsColor: theme.text))
                .accessibilityIdentifier(Self.expandingID)
            Button(String(localized: "Stop", table: "Normal", locale: locale)) { model.stopExpanding() }
                .buttonStyle(.link)
                .accessibilityIdentifier(Self.expandingStopID)
        case let .done(items, _, skipped):
            Text("Expanded \(Int(clamping: items)) items", tableName: "Archive")
                .foregroundStyle(Color(nsColor: theme.text))
                .accessibilityIdentifier(Self.expandedID)
            if skipped > 0 {
                Text("\(Int(clamping: skipped)) items skipped", tableName: "Archive")
                    .help(String(localized: "Items whose names or links point outside the archive, device files, and items Wherever couldn’t expand.", table: "Archive", locale: locale))
                    .accessibilityIdentifier(Self.expandedSkippedID)
            }
            Button(String(localized: "Show in Finder", table: "Results", locale: locale)) { model.showExpanded() }
                .buttonStyle(.link)
                .accessibilityIdentifier(Self.expandedRevealID)
        }
    }

    private func progress(_ fraction: Double?, label: Text, line: CGFloat) -> some View {
        Group {
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .controlSize(.small)
        .frame(width: Self.progressWidth, height: line)
        .accessibilityLabel(label)
        .accessibilityIdentifier(Self.progressID)
    }

    private func activity(_ text: Text, id: String, line: CGFloat) -> some View {
        HStack(spacing: SearchMetrics.statusMarkGap) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: line, height: line)
                .accessibilityHidden(true)
            text
                .foregroundStyle(Color(nsColor: theme.text))
                .accessibilityIdentifier(id)
        }
    }
}

struct ArchiveTable: NSViewRepresentable {
    static let tableID = "archive-results"

    @ObservedObject var model: ArchiveWindowModel
    @ObservedObject var results: SearchModel
    @AppStorage(Theme.key) private var theme = Theme.systemNative
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    func makeCoordinator() -> ResultsTable.Coordinator {
        ResultsTable.Coordinator(model: results, appIcon: { _ in nil }, announcer: .shared)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ResultsTable.makeView(context.coordinator, textSize: textSize, actions: model.actions)
        context.coordinator.table?.setAccessibilityIdentifier(Self.tableID)
        context.coordinator.table?.joinedWindow = { [weak table = context.coordinator.table] in table.map(select) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        ResultsTable.update(context.coordinator, theme: theme, textSize: textSize, actions: model.actions)
        context.coordinator.table.map(select)
    }

    private func select(_ table: ThemedTable) {
        guard let window = table.window, let row = model.takeSelection() else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        if window.firstResponder !== table { window.makeFirstResponder(table) }
    }
}
