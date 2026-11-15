import AppKit
import CoreText
import Foundation
import SwiftUI
import WhereverInterface

struct StatusBarView: View {
    @ObservedObject var index: IndexModel
    @ObservedObject var model: SearchModel
    var clearsBackground = false
    @Environment(\.locale) private var locale
    @AppStorage(Theme.key) private var theme = Theme.systemNative
    @AppStorage(NewDiskChoice.key) private var newDisk = NewDiskChoice.statusBar
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ViewThatFits(in: .horizontal) {
                row(compact: false)
                row(compact: true)
            }
            .font(Font(Self.font(textSize) as CTFont))
            .foregroundStyle(Color(nsColor: theme.secondaryText))
            .lineLimit(1)
            .padding(.horizontal, clearsBackground ? LauncherMetrics.fieldSide : SearchMetrics.sideInset)
            .padding(.top, SearchMetrics.statusVerticalInset)
            .padding(.bottom, clearsBackground ? LauncherMetrics.barBottomInset : SearchMetrics.statusVerticalInset)
        }
        .background(Color(nsColor: clearsBackground ? .clear : theme.windowBackground))
    }

    private var showsFailure: Bool { model.failed && !(clearsBackground && model.results.generation == nil) }

    private var sentenceFloor: CGFloat { clearsBackground ? 0 : SearchMetrics.windowMinWidth - 2 * SearchMetrics.sideInset }

    private func row(compact: Bool) -> some View {
        HStack(alignment: .bottom, spacing: SearchMetrics.statusItemSpacing) {
            if control {
                stateGroup
                    .accessibilityElement(children: .contain)
                    .frame(height: line)
            }
            VStack(alignment: .leading, spacing: 0) {
                if index.indexState?.bootPhase == .failed {
                    let sentence = Self.text(.failed, bundle: AppearanceRow.bundle(locale))
                    SentenceLayout(text: sentence, size: textSize, line: line, floor: sentenceFloor) {
                        Text(verbatim: sentence).lineLimit(nil).foregroundStyle(Color(nsColor: theme.text))
                    }
                }
                HStack(spacing: SearchMetrics.statusItemSpacing) {
                    Group {
                        if !control, Self.mark(index.indexState?.bootPhase) != .empty { stateGroup }
                        if let disks = index.indexState?.indexingDisks, !disks.isEmpty {
                            HStack(spacing: SearchMetrics.statusMarkGap) {
                                markView(.ring, Color(nsColor: theme.stateIndexing))
                                Text("Indexing \(Self.joined(disks, locale: locale))")
                            }
                        }
                        if !compact {
                            ForEach(Self.troubleLines(index.indexState?.troubles ?? [], locale: locale), id: \.self) { Text($0) }
                        }
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1, height: SearchMetrics.statusSeparatorHeight)
                            .accessibilityHidden(true)
                        if let state = index.indexState {
                            Text("Files: \(state.indexed.formatted(.number.locale(locale)))")
                                .layoutPriority(1)
                        }
                        Spacer(minLength: SearchMetrics.statusItemSpacing)
                        if showsFailure {
                            Text("Search failed. Try again.", tableName: "Results")
                                .layoutPriority(1)
                        } else if model.results.generation != nil, let time = model.lastSearchTime {
                            let count = String(localized: "\(model.results.count) results", table: "Results", locale: locale)
                            let milliseconds = time.formatted(.units(allowed: [.milliseconds], width: .abbreviated).locale(locale))
                            Text("Search: \(count) – \(milliseconds)")
                                .layoutPriority(1)
                        }
                        if model.folderMissing {
                            Text("Folder not found")
                        }
                        if !compact, let progress = model.progress {
                            if let line = Self.readLine(progress, locale: locale) {
                                Text(line)
                            }
                            if let skipped = Self.skipLine(progress, locale: locale) {
                                Text(skipped).help(Self.skipLines(progress, locale: locale).joined(separator: "\n"))
                            }
                        }
                    }
                    .anchorPreference(key: ContentBounds.self, value: .bounds) { clearsBackground ? [$0] : [] }
                }
                .frame(height: line)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("status-bar")
            if !compact, !clearsBackground, newDisk == .statusBar || (newDisk == .notification && index.notificationsOff), let disk = index.waitingDisks.first {
                Group {
                    if index.waitingDisks.count == 1 {
                        diskNotice(disk)
                    } else {
                        disksNotice(index.waitingDisks.count)
                    }
                }
                .frame(height: line)
            }
        }
    }

    private var control: Bool {
        !clearsBackground && Self.hasLiveControl(index.indexState?.bootPhase, paused: index.liveUpdatesPaused)
    }

    private var line: CGFloat { clearsBackground ? Self.launcherLineHeight(textSize) : Self.lineHeight(textSize) }

    private func diskNotice(_ disk: IndexedVolume) -> some View {
        HStack(spacing: SearchMetrics.statusMarkGap) {
            Text("\(Bidi.name(disk.name)) is not indexed", tableName: "Results")
                .accessibilityIdentifier(Self.diskNoticeID)
            LinkButton(id: Self.indexDiskID, title: String(localized: "Index", table: "Normal", locale: locale), textSize: textSize, color: theme.link) { index.indexDisk(disk) }
        }
        .accessibilityElement(children: .contain)
    }

    private func disksNotice(_ count: Int) -> some View {
        HStack(spacing: SearchMetrics.statusMarkGap) {
            Text("\(count) disks are not indexed", tableName: "Results")
                .accessibilityIdentifier(Self.disksNoticeID)
            LinkButton(id: Self.manageDisksID, title: String(localized: "Manage…", table: "Results", locale: locale), textSize: textSize, color: theme.link) { index.openLocations() }
        }
        .accessibilityElement(children: .contain)
    }

    private var stateGroup: some View {
        let phase = index.indexState?.bootPhase
        let paused = Self.isPaused(phase, index.liveUpdatesPaused)
        let shape = Self.mark(phase, paused: index.liveUpdatesPaused)
        return HStack(spacing: SearchMetrics.statusMarkGap) {
            markView(shape, Color(nsColor: shape == .pause ? theme.secondaryText : shape == .dot ? theme.stateLive : theme.stateIndexing))
            if control {
                let bundle = AppearanceRow.bundle(locale)
                LinkButton(
                    id: Self.liveUpdatesID,
                    title: Self.text(.live, paused: paused, bundle: bundle),
                    tooltip: paused ? String(localized: "Click to resume live updates", bundle: bundle) : String(localized: "Click to pause live updates", bundle: bundle),
                    textSize: textSize, color: theme.text
                ) { index.toggleLiveUpdates() }
            } else {
                Group {
                    switch phase {
                    case nil: Text("Starting")
                    case .loading: Text("Loading the saved index")
                    case .crawling: Text("Indexing the disk")
                    case .finishing: Text("Finishing the index…", tableName: "Results")
                    case .ready: paused ? Text("Live updates paused") : Text("Ready")
                    case .live: paused ? Text("Live updates paused") : Text("Live updates on")
                    case .failed: EmptyView()
                    }
                }
                .foregroundStyle(Color(nsColor: theme.text))
            }
        }
    }

    @ViewBuilder private func markView(_ shape: Mark, _ color: Color) -> some View {
        let size = SearchMetrics.statusMarkSize
        Group {
            switch shape {
            case .dot: Circle().fill(color)
            case .ring: Circle().strokeBorder(color, lineWidth: size / 4)
            case .pause:
                HStack(spacing: size / 4) {
                    Rectangle().fill(color)
                    Rectangle().fill(color)
                }
            case .empty: EmptyView()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension StatusBarView {
    struct ContentBounds: PreferenceKey {
        nonisolated static var defaultValue: [Anchor<CGRect>] { [] }
        nonisolated static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
            value += nextValue()
        }
    }

    static func readLine(_ progress: SearchModel.ContentProgress, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String? {
        let (read, total) = (progress.read, progress.total)
        if !progress.done { return String(localized: "Read \(read) of \(total) files", table: "Results", bundle: bundle, locale: locale) }
        let stopped = read + progress.notDownloaded + progress.unreadable < total
        return stopped ? String(localized: "Stopped after \(read) of \(total) files", table: "Results", bundle: bundle, locale: locale) : nil
    }

    static func skipLine(_ progress: SearchModel.ContentProgress, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String? {
        let skipped = progress.notDownloaded + progress.unreadable
        return skipped > 0 ? String(localized: "\(skipped) files skipped", table: "Results", bundle: bundle, locale: locale) : nil
    }

    static func skipLines(_ progress: SearchModel.ContentProgress, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> [String] {
        var lines: [String] = []
        if progress.notDownloaded > 0 {
            lines.append(String(localized: "\(progress.notDownloaded) files not downloaded", table: "Results", bundle: bundle, locale: locale))
        }
        if progress.unreadable > 0 {
            lines.append(String(localized: "\(progress.unreadable) files in unsupported formats", table: "Results", bundle: bundle, locale: locale))
        }
        return lines
    }

    static let diskNoticeID = "status-disk-notice"
    static let indexDiskID = "status-disk-index"
    static let disksNoticeID = "status-disks-notice"
    static let manageDisksID = "status-disks-manage"
    static let liveUpdatesID = "status-live-updates"

    nonisolated static func font(_ size: TextSize) -> NSFont { size.font(.systemFont(ofSize: NSFont.smallSystemFontSize)) }
    static func lineHeight(_ size: TextSize) -> CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font(size))) }
    private static var launcherLines: [TextSize: CGFloat] = [:]
    static func launcherLineHeight(_ size: TextSize) -> CGFloat {
        if let found = launcherLines[size] { return found }
        let found = NSHostingView(rootView: Text(verbatim: "Ag").font(Font(font(size) as CTFont)).fixedSize()).fittingSize.height
        launcherLines[size] = found
        return found
    }

    nonisolated static func typographicWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), nil, nil, nil)))
    }

    nonisolated static func widestWord(_ text: String, font: NSFont) -> CGFloat {
        var widest: CGFloat = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, _, _, _ in
            widest = max(widest, typographicWidth(word ?? "", font: font))
        }
        return widest
    }

    nonisolated static func lineCount(_ text: String, font: NSFont, width: CGFloat) -> Int {
        let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let length = (text as NSString).length
        var (start, count) = (0, 0)
        while start < length {
            start += max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            count += 1
        }
        return max(count, 1)
    }

    static func isPaused(_ phase: IndexPhase?, _ paused: Bool) -> Bool { paused && (phase == .ready || phase == .live) }

    static func hasLiveControl(_ phase: IndexPhase?, paused: Bool) -> Bool { phase == .live || isPaused(phase, paused) }

    static func text(_ phase: IndexPhase?, paused: Bool = false, bundle: Bundle = .main) -> String {
        if isPaused(phase, paused) { return String(localized: "Live updates paused", bundle: bundle) }
        switch phase {
        case nil: return String(localized: "Starting", bundle: bundle)
        case .loading: return String(localized: "Loading the saved index", bundle: bundle)
        case .crawling: return String(localized: "Indexing the disk", bundle: bundle)
        case .finishing: return String(localized: "Finishing the index…", table: "Results", bundle: bundle)
        case .ready: return String(localized: "Ready", bundle: bundle)
        case .live: return String(localized: "Live updates on", bundle: bundle)
        case .failed: return String(localized: "Wherever could not build the index. Choose Quit Wherever from the Wherever menu, then open Wherever again.", table: "Results", bundle: bundle)
        }
    }

    static func troubleLines(_ troubles: [DiskTrouble], bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> [String] {
        func names(_ kind: DiskTrouble.Kind) -> String? {
            let names = troubles.filter { $0.kind == kind }.map { $0.path == "/" ? FileManager.default.displayName(atPath: "/") : ($0.path as NSString).lastPathComponent }
            return names.isEmpty ? nil : joined(names, locale: locale)
        }
        return [
            names(.unreadable).map { String(localized: "Could not read \($0)", table: "Results", bundle: bundle, locale: locale) },
            names(.liveUpdatesOff).map { String(localized: "Live updates are off for \($0)", table: "Results", bundle: bundle, locale: locale) },
        ].compactMap { $0 }
    }

    static func indexingText(_ names: [String], bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        String(localized: "Indexing \(joined(names, locale: locale))", bundle: bundle)
    }

    private static func joined(_ names: [String], locale: Locale) -> String {
        let names = names.map(Bidi.name)
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }

    enum Mark { case dot, ring, pause, empty }

    static func mark(_ phase: IndexPhase?, paused: Bool = false) -> Mark {
        if isPaused(phase, paused) { return .pause }
        switch phase {
        case nil, .loading, .crawling, .finishing: return .ring
        case .failed: return .empty
        case .ready, .live: return .dot
        }
    }
}

private struct SentenceLayout: Layout {
    let text: String
    let size: TextSize
    let line: CGFloat
    let floor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let font = StatusBarView.font(size)
        let word = StatusBarView.widestWord(text, font: font)
        guard let proposed = proposal.width else {
            return CGSize(width: word, height: CGFloat(StatusBarView.lineCount(text, font: font, width: max(word, floor))) * line)
        }
        let width = proposed.isFinite ? proposed : StatusBarView.typographicWidth(text, font: font)
        return CGSize(width: width, height: CGFloat(StatusBarView.lineCount(text, font: font, width: width < word ? max(width, floor) : width)) * line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil)) }
    }
}

private struct LinkButton: NSViewRepresentable {
    let id: String
    let title: String
    var tooltip: String?
    let textSize: TextSize
    let color: NSColor
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.pressed))
        button.isBordered = false
        button.bezelStyle = .inline
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityIdentifier(id)
        button.cell?.setAccessibilityIdentifier(id)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.toolTip = tooltip
        button.font = StatusBarView.font(textSize)
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: StatusBarView.font(textSize), .foregroundColor: color])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSButton, context: Context) -> CGSize? {
        CGSize(width: ceil(button.fittingSize.width), height: StatusBarView.lineHeight(textSize))
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) { self.action = action }

        @objc func pressed() { action() }
    }
}
