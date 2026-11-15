import AppKit
import Combine
import Foundation
import Quartz
import SwiftUI
import WhereverInterface

final class InspectorPane: NSViewController {
    static let shownKey = "inspectorShown"
    static let id = "inspector"
    static let previewID = "inspector-preview"
    static let quickLookID = "inspector-quick-look"
    static let showInFinderID = "inspector-show-in-finder"
    static let showArchiveContentsID = "inspector-show-archive-contents"
    static let infoID = "inspector-info"
    static let notDownloadedID = "inspector-not-downloaded"
    static let selectionID = "inspector-selection"

    private enum Mode { case none, several, single }

    private(set) var inspector: InspectorModel
    private(set) var theme = Theme.systemNative
    private(set) var textSize = TextSize.standard
    private(set) var locale = Locale.current
    var previewsFiles = !WhereverApp.usesPreviewServices
    private let dates: FileDates
    private let quickLook: () -> Void
    private let reveal: () -> Void
    private let allows: (SearchHit) -> Bool
    private let showInside: () -> Void
    private var bundle = Bundle.main
    private var watches: [AnyCancellable] = []
    private var mode: Mode?
    private var keyColumn: CGFloat = 0
    private var contentWidth: CGFloat = 0
    private var buttonWidths: [CGFloat: (CGFloat, CGFloat)] = [:]
    private var buttonHeight: CGFloat = 0
    private var idealWidths: (CGFloat, CGFloat)?
    private var quickFirst: Bool?
    private var archiveIdeal: CGFloat?
    private var archiveWidth: (available: CGFloat, width: CGFloat)?
    private var formatted: (size: Int64, kind: String, folder: Bool, summary: String, bytes: String)?

    private let root = InspectorCanvas()
    private let group = InspectorCanvas()
    private let none = InspectorText.make(wrapping: false)
    private let selection = InspectorText.make(wrapping: false)
    private let row = InspectorCanvas()
    private let quick = InspectorButton(title: "", target: nil, action: nil)
    private let finder = InspectorButton(title: "", target: nil, action: nil)
    private let archive = InspectorButton(title: "", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let details = InspectorCanvas()
    private let box = InspectorCanvas()
    private let clip = NSView()
    private let border = InspectorCanvas()
    private var preview: QLPreviewView?
    private var previewed: SearchHit?
    private let cloud = InspectorText.make(wrapping: false)
    private let name = InspectorText.make(wrapping: true)
    private let summary = InspectorText.make(wrapping: true)
    private let line = InspectorCanvas()
    private let heading = InspectorText.make(wrapping: true)
    private let info = InspectorCanvas()
    private let keys = (0..<7).map { _ in InspectorText.make(wrapping: false) }
    private let values = (0..<7).map { _ in InspectorText.make(wrapping: true) }

    init(
        inspector: InspectorModel, dates: FileDates = .current, quickLook: @escaping () -> Void, reveal: @escaping () -> Void,
        allows: @escaping (SearchHit) -> Bool = { _ in false }, showInside: @escaping () -> Void = {}
    ) {
        self.inspector = inspector
        self.dates = dates
        self.quickLook = quickLook
        self.reveal = reveal
        self.allows = allows
        self.showInside = showInside
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        root.paint = { [unowned self] canvas in
            theme.windowBackground.setFill()
            canvas.bounds.fill()
        }
        root.arrange = { [unowned self] _ in arrange() }
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        group.setAccessibilityElement(true)
        group.setAccessibilityRole(.group)
        group.setAccessibilityIdentifier(Self.id)
        scroll.setAccessibilityIdentifier(Self.id)
        selection.cell?.setAccessibilityIdentifier(Self.selectionID)
        cloud.cell?.setAccessibilityIdentifier(Self.notDownloadedID)
        quick.cell?.setAccessibilityIdentifier(Self.quickLookID)
        finder.cell?.setAccessibilityIdentifier(Self.showInFinderID)
        archive.cell?.setAccessibilityIdentifier(Self.showArchiveContentsID)
        for (button, action) in [(quick, #selector(look)), (finder, #selector(show)), (archive, #selector(enter))] {
            button.bezelStyle = Availability.inspectorButtonBezel
            button.target = self
            button.action = action
        }
        row.subviews = [quick, finder]
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = details
        box.paint = { [unowned self] canvas in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let path = RoundedRectangle(cornerRadius: SearchMetrics.previewRadius).path(in: canvas.bounds).cgPath
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.addPath(path)
            context.setFillColor(theme.rowBackground.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        border.paint = { canvas in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let radius = SearchMetrics.previewRadius - 0.5
            context.addPath(RoundedRectangle(cornerRadius: radius).path(in: canvas.bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath)
            context.setLineWidth(1)
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.strokePath()
        }
        clip.wantsLayer = true
        clip.layer?.cornerRadius = SearchMetrics.previewRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        border.passesHits = true
        box.subviews = [clip, border]
        line.paint = { canvas in
            NSColor.separatorColor.setFill()
            canvas.bounds.fill()
        }
        info.setAccessibilityElement(true)
        info.setAccessibilityRole(.group)
        info.setAccessibilityIdentifier(Self.infoID)
        info.subviews = zip(keys, values).flatMap { [$0, $1] }
        details.subviews = [box, name, summary, row, line, heading, info]
        view = root
        restyle()
        watches = [
            inspector.$state.sink { [weak self] in self?.render($0) },
            dates.$revision.dropFirst().sink { [weak self] _ in
                guard let self else { return }
                formatted = nil
                render(inspector.state)
            },
        ]
    }

    func apply(theme: Theme, textSize: TextSize, locale: Locale) {
        guard theme != self.theme || textSize != self.textSize || locale != self.locale else { return }
        self.theme = theme
        self.textSize = textSize
        self.locale = locale
        guard isViewLoaded else { return }
        restyle()
        render(inspector.state)
    }

    @objc private func look() { quickLook() }

    @objc private func show() { reveal() }

    @objc private func enter() { showInside() }

    private var previewLabel: String { String(localized: "Preview", table: "Inspector", bundle: bundle) }

    private func restyle() {
        bundle = AppearanceRow.bundle(locale)
        formatted = nil
        let body = NSFont.systemFont(ofSize: textSize.points(NSFont.systemFontSize))
        let small = NSFont.systemFont(ofSize: textSize.points(NSFont.smallSystemFontSize))
        let styles: [(InspectorText, NSFont, NSColor)] = [
            (none, body, theme.secondaryText), (selection, body, theme.text),
            (name, .systemFont(ofSize: textSize.points(NSFont.systemFontSize), weight: .semibold), theme.text),
            (summary, small, theme.secondaryText), (cloud, small, theme.secondaryText),
            (heading, .systemFont(ofSize: textSize.points(NSFont.smallSystemFontSize), weight: .semibold), theme.secondaryText),
        ] + keys.map { ($0, small, theme.secondaryText) } + values.map { ($0, small, theme.text) }
        for (field, font, color) in styles {
            field.font = font
            field.textColor = color
        }
        quick.font = body
        finder.font = body
        archive.font = body
        quick.title = String(localized: "Quick Look", table: "Results", bundle: bundle)
        finder.title = String(localized: "Show in Finder", table: "Results", bundle: bundle)
        archive.title = String(localized: "Show Archive Contents", table: "Results", bundle: bundle)
        none.stringValue = String(localized: "No Selection", table: "Inspector", bundle: bundle)
        heading.stringValue = String(localized: "Information", table: "Inspector", bundle: bundle)
        info.setAccessibilityLabel(heading.stringValue)
        preview?.setAccessibilityLabel(previewLabel)
        cloud.stringValue = String(localized: "In iCloud", table: "Inspector", bundle: bundle)
        let found = factKeys()
        keyColumn = found.width
        for (field, key) in zip(keys, found.keys) { field.stringValue = key }
        buttonWidths = [:]
        buttonHeight = quick.intrinsicContentSize.height
        idealWidths = nil
        quickFirst = nil
        archiveIdeal = nil
        archiveWidth = nil
        for canvas in [root, box, border, line] { canvas.needsDisplay = true }
        root.needsLayout = true
    }

    private func render(_ state: InspectorModel.State) {
        let next: Mode = state.count > 1 ? .several : state.hit == nil ? .none : .single
        if next != mode { switchTo(next) }
        switch next {
        case .none:
            break
        case .several:
            set(selection, String(localized: "\(state.count) items", table: "Results", bundle: bundle, locale: locale))
        case .single:
            guard let hit = state.hit else { return }
            set(name, hit.name)
            let kind = ResultType.of(hit).kind
            let folder = hit.kind == .folder
            let unknown = "--"
            if formatted?.size != hit.size || formatted?.kind != kind || formatted?.folder != folder {
                let size = ByteCountFormatter.string(fromByteCount: hit.size, countStyle: .file)
                formatted = (
                    hit.size, kind, folder, folder ? kind : String(localized: "\(kind) · \(size)", table: "Inspector", bundle: bundle, locale: locale),
                    folder ? unknown : Self.sizes.string(fromByteCount: hit.size)
                )
            }
            guard let formatted else { return }
            set(summary, formatted.summary)
            let read = state.facts
            let shown = [
                kind,
                formatted.bytes,
                hit.folder,
                read?.created.map(dates.string) ?? unknown,
                dates.string(hit.modified),
                read?.owner ?? unknown,
                Self.permissions(read),
            ]
            for (field, text) in zip(values, shown) { set(field, text) }
            showsArchive(allows(hit))
            let dataless = read?.dataless == true
            if dataless, cloud.superview == nil {
                box.addSubview(cloud, positioned: .below, relativeTo: border)
                root.needsLayout = true
            } else if !dataless, cloud.superview != nil {
                cloud.removeFromSuperview()
            }
            guard let preview else { return }
            let url = read == nil || dataless ? nil : hit.fileURL
            let item = previewsFiles ? url : nil
            if (preview.previewItem as? NSURL) as URL? != item {
                preview.previewItem = item.map { $0 as NSURL as QLPreviewItem }
            } else if item != nil, let previewed, previewed.size != hit.size || previewed.modified != hit.modified {
                preview.refreshPreviewItem()
            }
            previewed = item == nil ? nil : hit
            if preview.isHidden != (url == nil) { preview.isHidden = url == nil }
        }
    }

    private func set(_ field: InspectorText, _ text: String) {
        guard field.stringValue != text else { return }
        field.stringValue = text
        if mode == .single, field.refit() { return }
        root.needsLayout = true
    }

    private func showsArchive(_ shows: Bool) {
        guard shows != (archive.superview != nil) else { return }
        if shows { row.addSubview(archive) } else { archive.removeFromSuperview() }
        root.needsLayout = true
    }

    private func switchTo(_ next: Mode) {
        mode = next
        if next != .single { showsArchive(false) }
        if next != .single, let preview {
            if preview.window != nil { preview.close() }
            preview.removeFromSuperview()
            self.preview = nil
        }
        switch next {
        case .none:
            root.subviews = [group]
            group.subviews = [none]
        case .several:
            root.subviews = [group]
            group.subviews = [selection, row]
        case .single:
            root.subviews = [scroll]
            details.addSubview(row, positioned: .above, relativeTo: summary)
            scroll.contentView.scroll(to: .zero)
            if preview == nil {
                let made: QLPreviewView = QLPreviewView(frame: .zero, style: .compact)
                made.setAccessibilityIdentifier(Self.previewID)
                made.setAccessibilityLabel(previewLabel)
                for recognizer in made.gestureRecognizers where recognizer is NSPanGestureRecognizer || recognizer is NSPressGestureRecognizer {
                    recognizer.isEnabled = false
                }
                clip.addSubview(made)
                preview = made
            }
        }
        root.needsLayout = true
    }

    private var rtl: Bool { root.userInterfaceLayoutDirection == .rightToLeft }

    private func fit(_ field: InspectorText, _ width: CGFloat) -> NSSize { field.fit(width, alignment: rtl ? .right : .left) }

    private func place(_ field: InspectorText, _ rect: NSRect, in width: CGFloat) {
        field.slot = nil
        field.place(NSRect(x: rtl ? width - rect.maxX : rect.minX, y: rect.minY, width: rect.width, height: rect.height))
    }

    private func place(_ field: InspectorText, _ rect: NSRect, in width: CGFloat, room: CGFloat, spans: Bool) {
        field.slot = (x: rect.minX, room: room, container: width, rtl: rtl, spans: spans)
        field.put(rect.size, y: rect.minY)
    }

    private func arrange() {
        let bounds = root.bounds
        let spacing = SearchMetrics.inspectorSpacing
        switch mode {
        case .none?:
            group.frame = bounds
            let size = fit(none, bounds.width)
            place(none, NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height), in: bounds.width)
        case .several?:
            group.frame = bounds
            let text = fit(selection, bounds.width)
            let top = (bounds.height - text.height - spacing - buttonHeight) / 2
            place(selection, NSRect(x: (bounds.width - text.width) / 2, y: top, width: text.width, height: text.height), in: bounds.width)
            row.frame = NSRect(x: 0, y: root.snap(top + text.height + spacing), width: bounds.width, height: buttonHeight)
            placeButtons(in: bounds.width, centered: true)
        case .single?:
            scroll.frame = bounds
            let gutter = scroll.scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
            let narrow = bounds.width - gutter
            var width = gutter > 0 && contentWidth == narrow ? narrow : bounds.width
            var height = layoutDetails(width)
            if width == bounds.width, gutter > 0, height > bounds.height {
                width = narrow
                height = layoutDetails(width)
            } else if width == narrow, gutter > 0, height <= bounds.height {
                width = bounds.width
                height = layoutDetails(width)
            }
            contentWidth = width
            details.frame = NSRect(x: 0, y: 0, width: width, height: height)
        case nil:
            break
        }
    }

    private func layoutDetails(_ width: CGFloat) -> CGFloat {
        let pad = SearchMetrics.inspectorPadding
        let spacing = SearchMetrics.inspectorSpacing
        let content = width - 2 * pad
        let previewHeight = SearchMetrics.previewHeight
        box.frame = NSRect(x: pad, y: pad, width: content, height: previewHeight)
        clip.frame = box.bounds
        border.frame = box.bounds
        preview?.frame = clip.bounds
        if cloud.superview != nil {
            let size = fit(cloud, content)
            place(cloud, NSRect(x: (content - size.width) / 2, y: (previewHeight - size.height) / 2, width: size.width, height: size.height), in: content)
        }
        var y = pad + previewHeight + spacing
        let nameSize = fit(name, content)
        place(name, NSRect(origin: NSPoint(x: pad, y: y), size: nameSize), in: width, room: content, spans: true)
        y += nameSize.height + SearchMetrics.inspectorTitleSpacing
        let summarySize = fit(summary, content)
        place(summary, NSRect(origin: NSPoint(x: pad, y: y), size: summarySize), in: width, room: content, spans: true)
        y += summarySize.height + spacing
        let rowHeight = archive.superview == nil ? buttonHeight : 2 * buttonHeight + SearchMetrics.inspectorButtonSpacing
        row.frame = NSRect(x: pad, y: y, width: content, height: rowHeight)
        placeButtons(in: content, centered: false)
        y += rowHeight + spacing
        line.frame = NSRect(x: pad, y: y, width: content, height: 1)
        y += 1 + spacing
        let headingSize = fit(heading, content)
        place(heading, NSRect(origin: NSPoint(x: pad, y: y), size: headingSize), in: width)
        y += headingSize.height + spacing
        let gap = SearchMetrics.factGap
        let sizes = zip(keys, values).map { (fit($0, keyColumn), fit($1, content - keyColumn - gap)) }
        let widest = sizes.map(\.1.width).max() ?? 0
        let infoWidth = keyColumn + gap + widest
        var rowY: CGFloat = 0
        for ((key, value), (keySize, valueSize)) in zip(zip(keys, values), sizes) {
            place(key, NSRect(origin: NSPoint(x: 0, y: rowY), size: keySize), in: infoWidth)
            place(value, NSRect(origin: NSPoint(x: keyColumn + gap, y: rowY), size: valueSize), in: infoWidth, room: widest, spans: false)
            rowY += max(keySize.height, valueSize.height) + SearchMetrics.factRowSpacing
        }
        rowY -= SearchMetrics.factRowSpacing
        info.frame = NSRect(x: rtl ? width - pad - infoWidth : pad, y: y, width: infoWidth, height: rowY)
        return y + rowY + pad
    }

    private func placeButtons(in width: CGFloat, centered: Bool) {
        let spacing = SearchMetrics.inspectorButtonSpacing
        let (first, second) = widths(width)
        let start = root.snap(centered ? (width - first - spacing - second) / 2 : 0)
        let split = root.snap(start + first)
        let end = root.snap(start + first + spacing + second)
        let ideal = idealWidths ?? (first, second)
        for (button, minX, maxX, cut) in [(quick, start, split, first < ideal.0), (finder, split + spacing, end, second < ideal.1)] {
            button.toolTip = cut ? button.title : nil
            button.frame = NSRect(x: rtl ? width - maxX : minX, y: 0, width: maxX - minX, height: buttonHeight)
        }
        guard archive.superview != nil else { return }
        let fitted = archiveButtonWidth(width)
        let size = root.snap(fitted)
        archive.toolTip = fitted < (archiveIdeal ?? fitted) ? archive.title : nil
        archive.frame = NSRect(
            x: rtl ? width - size : 0, y: root.snap(buttonHeight + SearchMetrics.inspectorButtonSpacing), width: size, height: buttonHeight
        )
    }

    private func archiveButtonWidth(_ available: CGFloat) -> CGFloat {
        if let archiveWidth, archiveWidth.available == available { return archiveWidth.width }
        let ideal = archiveIdeal ?? Self.buttonWidth(archive.title, textSize: textSize, locale: locale, proposal: .infinity)
        archiveIdeal = ideal
        let width = ideal <= available ? ideal : Self.buttonWidth(archive.title, textSize: textSize, locale: locale, proposal: available)
        archiveWidth = (available, width)
        return width
    }

    private func widths(_ available: CGFloat) -> (CGFloat, CGFloat) {
        if let found = buttonWidths[available] { return found }
        let sizing = { [textSize, locale] (button: NSButton, proposal: CGFloat) in
            Self.buttonWidth(button.title, textSize: textSize, locale: locale, proposal: proposal)
        }
        let ideal = idealWidths ?? (sizing(quick, .infinity), sizing(finder, .infinity))
        idealWidths = ideal
        let first = quickFirst ?? (ideal.0 - sizing(quick, 0) <= ideal.1 - sizing(finder, 0))
        quickFirst = first
        let measure = { (button: NSButton, proposal: CGFloat) in
            let most = button === self.quick ? ideal.0 : ideal.1
            return proposal >= most ? most : min(sizing(button, proposal), proposal)
        }
        let room = available - SearchMetrics.inspectorButtonSpacing
        var widths = ideal
        if first {
            widths.0 = measure(quick, room / 2)
            widths.1 = measure(finder, room - widths.0)
        } else {
            widths.1 = measure(finder, room / 2)
            widths.0 = measure(quick, room - widths.1)
        }
        if buttonWidths.count >= 4 { buttonWidths = [:] }
        buttonWidths[available] = widths
        return widths
    }

    private static func buttonWidth(_ title: String, textSize: TextSize, locale: Locale, proposal: CGFloat) -> CGFloat {
        let sizing = NSHostingController(rootView: Button(action: {}) { Text(verbatim: title).font(textSize.formText) }.environment(\.locale, locale))
        return sizing.sizeThatFits(in: CGSize(width: proposal, height: .infinity)).width
    }

    private static var measuredKeys: [String: (keys: [String], width: CGFloat)] = [:]

    private static let sizes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesActualByteCount = true
        return formatter
    }()

    private func factKeys() -> (keys: [String], width: CGFloat) {
        let id = "\(locale.identifier) \(Locale.current.identifier) \(textSize.rawValue)"
        if let found = Self.measuredKeys[id] { return found }
        let keys = [
            String(localized: "Kind", table: "Results", bundle: bundle),
            String(localized: "Size", table: "Results", bundle: bundle),
            String(localized: "Where", table: "Inspector", bundle: bundle),
            String(localized: "Created", table: "Inspector", bundle: bundle),
            String(localized: "Modified", table: "Results", bundle: bundle),
            String(localized: "Owner", table: "Inspector", bundle: bundle),
            String(localized: "Permissions", table: "Inspector", bundle: bundle),
        ]
        let found = (keys, Self.keyWidth(keys, textSize: textSize))
        Self.measuredKeys[id] = found
        return found
    }

    static func keyWidth(_ keys: [String], textSize: TextSize) -> CGFloat {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: textSize.points(NSFont.smallSystemFontSize))
        let widest = keys.map { key in
            label.stringValue = key
            return label.intrinsicContentSize.width
        }.max() ?? 0
        return max(textSize.width(SearchMetrics.factKeyWidth), ceil(widest))
    }

    static func permissions(_ facts: InspectorModel.Facts?, bundle: Bundle = .main) -> String {
        switch (facts?.readable, facts?.writable) {
        case (true?, true?): String(localized: "Read & Write", table: "Inspector", bundle: bundle)
        case (true?, false?): String(localized: "Read only", table: "Inspector", bundle: bundle)
        case (false?, true?): String(localized: "Write only", table: "Inspector", bundle: bundle)
        case (false?, false?): String(localized: "No access", table: "Inspector", bundle: bundle)
        default: "--"
        }
    }
}

struct InspectorSettingRow: View {
    static let id = "general-show-inspector"

    @AppStorage(InspectorPane.shownKey) private var shown = false
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        Toggle(isOn: $shown) { Text("Show inspector", tableName: "Inspector").font(textSize.formLabel) }
            .toggleStyle(.switch)
            .accessibilityIdentifier(Self.id)
    }
}

private final class InspectorCanvas: NSView {
    var paint: ((InspectorCanvas) -> Void)?
    var arrange: ((InspectorCanvas) -> Void)?
    var passesHits = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { passesHits ? nil : super.hitTest(point) }

    override func draw(_ dirtyRect: NSRect) { paint?(self) }

    override func layout() {
        super.layout()
        arrange?(self)
    }

    override var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection {
        didSet { needsLayout = true }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { needsLayout = true }
        super.setFrameSize(newSize)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

private extension NSView {
    func snap(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 1
        return (value * scale).rounded() / scale
    }
}

private final class InspectorButton: NSButton {
    override class var cellClass: AnyClass? {
        get { InspectorButtonCell.self }
        set {}
    }
}

private final class InspectorButtonCell: NSButtonCell {
    override func accessibilityFrame() -> NSRect {
        guard let view = controlView, let window = view.window else { return super.accessibilityFrame() }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private final class InspectorText: NSTextField {
    private(set) var layoutRect = NSRect.zero
    var slot: (x: CGFloat, room: CGFloat, container: CGFloat, rtl: Bool, spans: Bool)?
    private var fitted: (text: String, width: CGFloat, font: NSFont?, alignment: NSTextAlignment, size: NSSize)?

    static func make(wrapping: Bool) -> InspectorText {
        let field = InspectorText(labelWithString: "")
        let model = wrapping ? NSTextField(wrappingLabelWithString: "") : NSTextField(labelWithString: "")
        let plain = InspectorTextCell(textCell: "")
        plain.wraps = wrapping
        plain.isScrollable = false
        plain.lineBreakMode = model.cell?.lineBreakMode ?? .byClipping
        plain.truncatesLastVisibleLine = model.cell?.truncatesLastVisibleLine ?? false
        plain.isEditable = false
        plain.isSelectable = false
        plain.isBezeled = false
        plain.isBordered = false
        plain.drawsBackground = false
        field.cell = plain
        field.setContentCompressionResistancePriority(model.contentCompressionResistancePriority(for: .horizontal), for: .horizontal)
        return field
    }

    func fit(_ width: CGFloat, alignment: NSTextAlignment) -> NSSize {
        let text = stringValue
        if let fitted, fitted.text == text, fitted.width == width, fitted.font == font, fitted.alignment == alignment { return fitted.size }
        if cell?.wraps == true, preferredMaxLayoutWidth != width { preferredMaxLayoutWidth = width }
        if self.alignment != alignment { self.alignment = alignment }
        let size = intrinsicContentSize
        let found = NSSize(width: min(size.width, width), height: size.height)
        fitted = (text, width, font, alignment, found)
        return found
    }

    static func slack(_ font: NSFont?) -> CGFloat { ceil((font?.pointSize ?? NSFont.systemFontSize) / 2) }

    func put(_ size: NSSize, y: CGFloat) {
        guard let slot else { return }
        let width = slot.spans ? slot.room : size.width
        let mirror = { (x: CGFloat, width: CGFloat) in slot.rtl ? slot.container - x - width : x }
        place(NSRect(x: mirror(slot.x, size.width), y: y, width: size.width, height: size.height), drawn: NSRect(x: mirror(slot.x, width), y: y, width: width, height: size.height))
    }

    func refit() -> Bool {
        guard let fitted, let slot else { return false }
        let old = layoutRect
        let size = fit(fitted.width, alignment: fitted.alignment)
        guard size.height == old.height, slot.spans || (old.width < slot.room && size.width <= slot.room) else { return false }
        put(size, y: old.minY)
        return true
    }

    func place(_ rect: NSRect, drawn box: NSRect? = nil) {
        layoutRect = rect
        let box = box ?? rect
        let drawn = NSRect(x: snap(box.minX), y: snap(box.minY), width: box.width, height: box.height)
        let next = drawn.insetBy(dx: -2, dy: -Self.slack(font))
        if frame != next { frame = next }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityFrame() -> NSRect {
        guard let superview, let window else { return super.accessibilityFrame() }
        return window.convertToScreen(superview.convert(layoutRect, to: nil))
    }
}

private final class InspectorTextCell: NSTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let slack = InspectorText.slack(font)
        let text = cellFrame.insetBy(dx: 0, dy: slack)
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setShouldSmoothFonts(true)
        context?.clip(to: NSRect(x: text.minX + 2, y: cellFrame.minY, width: max(0, text.width - 4), height: cellFrame.height))
        super.drawInterior(withFrame: text, in: controlView)
        context?.restoreGState()
    }
}
