import AppKit
import SwiftUI

struct NormalForm: View {
    static let id = "normal-form"
    static let nameModeID = "file-name-mode"
    static let contentFieldID = "file-content-field"
    static let contentModeID = "file-content-mode"
    static let searchContentID = "search-content"

    @ObservedObject var model: SearchModel
    var bundle: Bundle = .main
    @AppStorage(Theme.key) private var theme = Theme.systemNative
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @Environment(\.displayScale) private var displayScale
    @State private var popUpWidest = WidestTitle()

    var body: some View {
        PixelCentred(scale: displayScale) { grid }
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Self.id)
    }

    private var grid: some View {
        let popUpWidth = Self.popUpColumn(bundle, textSize, cache: popUpWidest)
        return Grid(horizontalSpacing: NormalMetrics.columnSpacing, verticalSpacing: NormalMetrics.rowSpacing) {
            GridRow {
                label(Text("Search folder:", tableName: "Normal"))
                SearchFolderBox(folder: $model.filters.folder, bundle: bundle).formControl(width: NormalMetrics.fieldWidth)
                Color.clear.frame(width: popUpWidth, height: NormalMetrics.controlHeight)
                buttonSlot
            }
            GridRow {
                label(Text("File name:", tableName: "Normal"))
                SearchField(
                    model: model, bundle: bundle, fontSize: NSFont.systemFontSize,
                    accessibilityLabel: String(localized: "File name:", table: "Normal", bundle: bundle), roundedRectangle: true,
                    height: NormalMetrics.controlHeight - 2 * Availability.searchFieldOutlineInset
                )
                .formControl(width: NormalMetrics.fieldWidth)
                MenuPopUp(
                    id: Self.nameModeID, label: String(localized: "File name match", table: "Normal", bundle: bundle),
                    value: $model.filters.nameMode, items: nameModes
                )
                .formControl(width: popUpWidth)
                buttonSlot
            }
            GridRow {
                label(Text("File content:", tableName: "Normal"))
                ContentTermsField(model: model, bundle: bundle).formControl(width: NormalMetrics.fieldWidth)
                MenuPopUp(
                    id: Self.contentModeID, label: String(localized: "File content match", table: "Normal", bundle: bundle),
                    value: $model.content.match, items: contentModes
                )
                .formControl(width: popUpWidth)
                searchButton
            }
        }
        .padding(.vertical, NormalMetrics.formVerticalInset)
    }

    private var searchButton: some View {
        let search = String(localized: "Search Content", table: "Normal", bundle: bundle)
        let stop = String(localized: "Stop", table: "Normal", bundle: bundle)
        return PushButton(id: Self.searchContentID, title: model.reading ? stop : search, titles: [search, stop], textSize: textSize) {
            model.searchContent()
        }
        .disabled(!model.reading && !model.hasTerms)
        .controlSize(.large)
    }

    private var buttonSlot: some View {
        Color.clear.frame(height: NormalMetrics.controlHeight).gridCellUnsizedAxes(.horizontal)
    }

    private func label(_ text: Text) -> some View {
        text.font(textSize.font(size: NSFont.systemFontSize))
            .fixedSize()
            .foregroundStyle(Color(nsColor: theme.text))
            .frame(minWidth: NormalMetrics.labelMinWidth, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func nameModes() -> [MenuPopUp<SearchFilters.NameMode>.Item] {
        SearchFilters.NameMode.allCases.map { .init(title: Self.title($0, bundle), value: $0) }
    }

    private func contentModes() -> [MenuPopUp<ContentTerms.Match>.Item] {
        [ContentTerms.Match.all, .any].map { .init(title: Self.title($0, bundle), value: $0) }
    }

    private static func title(_ mode: SearchFilters.NameMode, _ bundle: Bundle) -> String {
        switch mode {
        case .contains: String(localized: "Contains", table: "Normal", bundle: bundle)
        case .matches: String(localized: "Matches", table: "Normal", bundle: bundle)
        case .beginsWith: String(localized: "Begins with", table: "Normal", bundle: bundle)
        case .endsWith: String(localized: "Ends with", table: "Normal", bundle: bundle)
        case .fileExtension: String(localized: "Extension", table: "Normal", bundle: bundle)
        case .wildcard: String(localized: "Wildcard", table: "Normal", bundle: bundle)
        case .regex: String(localized: "Regex", table: "Normal", bundle: bundle)
        }
    }

    private static func title(_ match: ContentTerms.Match, _ bundle: Bundle) -> String {
        switch match {
        case .all: String(localized: "Find all terms", table: "Normal", bundle: bundle)
        case .any: String(localized: "Find any term", table: "Normal", bundle: bundle)
        }
    }

    static func popUpTitles(_ bundle: Bundle) -> [String] {
        SearchFilters.NameMode.allCases.map { title($0, bundle) } + [ContentTerms.Match.all, .any].map { title($0, bundle) }
    }

    static func popUpColumn(_ bundle: Bundle, _ size: TextSize, cache: WidestTitle = WidestTitle()) -> CGFloat {
        let fit = cache.width(size, of: popUpTitles(bundle)) { title in
            let probe = NSPopUpButton(frame: .zero, pullsDown: false)
            probe.controlSize = .large
            Availability.roundedRectangle(probe)
            probe.font = size.font(.systemFont(ofSize: NSFont.systemFontSize))
            probe.addItem(withTitle: title)
            return probe.fittingSize.width
        }
        return max(size.width(NormalMetrics.popUpWidth), fit)
    }
}

private struct ContentTermsField: NSViewRepresentable {
    let model: SearchModel
    let bundle: Bundle
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = FormTokenField()
        field.placeholderString = String(localized: "Search terms separated by the Enter key", table: "Normal", bundle: bundle)
        field.tokenizingCharacterSet = .newlines
        field.objectValue = model.content.terms
        field.delegate = context.coordinator
        field.cell?.setAccessibilityIdentifier(NormalForm.contentFieldID)
        field.cell?.setAccessibilityLabel(String(localized: "File content:", table: "Normal", bundle: bundle))
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        let enabled = context.environment.isEnabled
        field.isEditable = enabled
        field.isSelectable = enabled
        let font = textSize.font(.messageFont(ofSize: 0))
        let direction: NSUserInterfaceLayoutDirection = context.environment.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        if field.font != font || field.userInterfaceLayoutDirection != direction {
            field.font = font
            field.userInterfaceLayoutDirection = direction
            field.needsLayout = true
        }
        field.toolTip = String(localized: "Finds files that contain these terms. With an empty Search folder it reads every indexed disk; type or pick a disk or folder to search there.", table: "Normal", bundle: bundle)
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        let model: SearchModel

        init(model: SearchModel) { self.model = model }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), model.hasTerms,
                  textView.string.replacingOccurrences(of: "\u{FFFC}", with: "").isEmpty else { return false }
            model.searchContent()
            return true
        }

        func controlTextDidChange(_ notification: Notification) { read(notification.object as? NSTokenField) }

        func controlTextDidEndEditing(_ notification: Notification) { read(notification.object as? NSTokenField, ending: true) }

        private func read(_ field: NSTokenField?, ending: Bool = false) {
            guard let field else { return }
            let value = (field.objectValue as? [String]) ?? []
            let editor = field.currentEditor()
            let text = editor?.string ?? ""
            let draft = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            var terms = value
            if editor != nil {
                if !ending { terms = Array(value.prefix(text.count - draft.count)) } else if !draft.isEmpty, value.last != draft { terms.append(draft) }
            }
            if terms != model.content.terms { model.content.terms = terms }
            model.contentDraft = ending ? "" : draft
        }
    }
}

private struct PushButton: NSViewRepresentable {
    let id: String
    let title: String
    let titles: [String]
    let textSize: TextSize
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = FormButton(title: title, target: context.coordinator, action: #selector(Coordinator.pressed))
        button.controlSize = .large
        Availability.roundedRectangle(button)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityIdentifier(id)
        button.cell?.setAccessibilityIdentifier(id)
        button.isEnabled = context.environment.isEnabled
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        let font = textSize.font(.messageFont(ofSize: 0))
        if button.font != font { button.font = font }
        button.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSButton, context: Context) -> CGSize? {
        let widest = context.coordinator.widest.width(textSize, of: titles) { title in
            let probe = NSButton(title: title, target: nil, action: nil)
            probe.controlSize = button.controlSize
            probe.font = textSize.font(.messageFont(ofSize: 0))
            return probe.fittingSize.width
        }
        return CGSize(width: widest, height: NormalMetrics.controlHeight)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        let widest = WidestTitle()

        init(action: @escaping () -> Void) { self.action = action }

        @objc func pressed() { action() }
    }
}

private final class FormButton: NSButton {
    override class var cellClass: AnyClass? {
        get { FormButtonCell.self }
        set { super.cellClass = newValue }
    }
}

private final class FormButtonCell: NSButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        super.drawBezel(withFrame: frame, in: controlView)
    }
}

private final class FormTokenField: NSTokenField {
    let icon = FormIcon("doc.text")

    override class var cellClass: AnyClass? {
        get { FormTokenCell.self }
        set { super.cellClass = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .roundedBezel
        controlSize = .large
        Availability.roundedRectangle(self)
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        icon.place(in: self)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NormalMetrics.controlHeight) }
}

private final class FormTokenCell: NSTokenFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        NormalMetrics.formRects(rect, font: font, size: controlSize, direction: controlView?.userInterfaceLayoutDirection ?? .leftToRight).text
    }
}

private struct PixelCentred: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(.unspecified)
        return CGSize(width: max(proposal.width ?? size.width, size.width), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = subviews[0].sizeThatFits(.unspecified)
        let x = ((bounds.minX + (bounds.width - size.width) / 2) * scale).rounded(.down) / scale
        subviews[0].place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
    }
}

extension View {
    fileprivate func formControl(width: CGFloat) -> some View {
        controlSize(.large).frame(width: width, height: NormalMetrics.controlHeight)
    }
}
