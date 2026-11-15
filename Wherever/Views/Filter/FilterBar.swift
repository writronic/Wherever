import AppKit
import Foundation
import SwiftUI

struct FilterBar: View {
    static let extensionsID = "filter-extensions"
    static let extensionsFieldID = "filter-extensions-field"
    static let kindID = "filter-kind"
    static let sizeID = "filter-size"
    static let modifiedID = "filter-modified"
    static let hiddenID = "filter-hidden"
    private static let popoverFieldWidth: CGFloat = 200
    private static let popoverPadding: CGFloat = 12

    @Binding var filters: SearchFilters
    var bundle: Bundle = .main
    @AppStorage(Theme.key) private var theme = Theme.systemNative
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @AppStorage(SearchFilters.hidesHiddenKey) private var hidesHidden = false
    @State private var extensionsOpen = false

    var body: some View {
        HStack(spacing: NormalMetrics.pillSpacing) {
            pill(
                FilterBar.kindID, String(localized: "Kind", table: "Filters", bundle: bundle), $filters.kind, off: .any,
                title: { $0.title(bundle) }
            )
            extensionsPill
            pill(
                FilterBar.sizeID, String(localized: "Size", table: "Filters", bundle: bundle), $filters.size, off: .any,
                title: { $0.title(bundle) }
            )
            pill(
                FilterBar.modifiedID, String(localized: "Modified", table: "Filters", bundle: bundle), $filters.modified, off: .any,
                title: { $0.title(bundle) }
            )
            hiddenToggle
        }
        .padding(.horizontal, SearchMetrics.sideInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: NormalMetrics.filterBarHeight(textSize))
    }

    private func onTitle(_ name: String, _ value: String) -> String {
        String(localized: "\(name): \(value)", table: "Filters", bundle: bundle)
    }

    private func pill<Value: CaseIterable & Hashable>(
        _ id: String, _ name: String, _ choice: Binding<Value>, off: Value, title: @escaping (Value) -> String
    ) -> some View {
        let isOn = choice.wrappedValue != off
        return MenuPill(
            id: id, label: name, title: isOn ? onTitle(name, title(choice.wrappedValue)) : name, isOn: isOn, textSize: textSize,
            value: choice, items: Value.allCases.map { (title: title($0), value: $0) }
        )
    }

    private var extensionsValue: String? {
        SearchFilters.extensionToken(filters.extensions).map { $0.dropFirst("ext:".count).replacingOccurrences(of: ",", with: ", ") }
    }

    private var extensionsTitleCap: CGFloat {
        let name = String(localized: "Kind", table: "Filters", bundle: bundle)
        let font = textSize.font(.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
        return SearchFilters.Kind.allCases.filter { $0 != .any }
            .map { PillCell.titleWidth(onTitle(name, $0.title(bundle)), font: font) }.max() ?? 0
    }

    private var extensionsPill: some View {
        let name = String(localized: "Extension", table: "Filters", bundle: bundle)
        return ExtensionPill(
            label: name, title: extensionsValue.map { onTitle(name, $0) } ?? name, isOn: extensionsValue != nil, textSize: textSize,
            titleCap: extensionsValue == nil ? .greatestFiniteMagnitude : extensionsTitleCap, isOpen: $extensionsOpen
        )
        .popover(isPresented: $extensionsOpen, arrowEdge: .bottom) {
            TextField(String(localized: "Extension (pdf, docx)", table: "Filters", bundle: bundle), text: $filters.extensions)
                .textFieldStyle(.roundedBorder)
                .font(textSize.formText)
                .frame(width: Self.popoverFieldWidth)
                .padding(Self.popoverPadding)
                .accessibilityLabel(Text("Extension", tableName: "Filters"))
                .accessibilityIdentifier(Self.extensionsFieldID)
                .onSubmit { extensionsOpen = false }
                .onExitCommand { extensionsOpen = false }
                .modifier(FocusOnAppear())
        }
    }

    private var hiddenToggle: some View {
        Toggle(isOn: $hidesHidden) {
            Text("Hide invisible files", tableName: "Filters")
                .font(textSize.formLabel)
                .foregroundStyle(Color(nsColor: theme.secondaryText))
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier(Self.hiddenID)
    }
}

extension SearchFilters.Kind {
    fileprivate func title(_ bundle: Bundle) -> String {
        switch self {
        case .any: String(localized: "Any kind", table: "Filters", bundle: bundle)
        case .files: String(localized: "Files", table: "Filters", bundle: bundle)
        case .folders: String(localized: "Folders", table: "Filters", bundle: bundle)
        case .links: String(localized: "Links", table: "Filters", bundle: bundle)
        case .images: String(localized: "Images", table: "Filters", bundle: bundle)
        case .videos: String(localized: "Videos", table: "Filters", bundle: bundle)
        case .audio: String(localized: "Audio", table: "Filters", bundle: bundle)
        case .documents: String(localized: "Documents", table: "Filters", bundle: bundle)
        case .code: String(localized: "Code", table: "Filters", bundle: bundle)
        case .archives: String(localized: "Archives", table: "Filters", bundle: bundle)
        case .fonts: String(localized: "Fonts", table: "Filters", bundle: bundle)
        case .apps: String(localized: "Apps", table: "Filters", bundle: bundle)
        }
    }
}

extension SearchFilters.Size {
    fileprivate func title(_ bundle: Bundle) -> String {
        switch self {
        case .any: String(localized: "Any size", table: "Filters", bundle: bundle)
        case .small: String(localized: "Under 1 MB", table: "Filters", bundle: bundle)
        case .medium: String(localized: "1 MB to 100 MB", table: "Filters", bundle: bundle)
        case .large: String(localized: "100 MB to 1 GB", table: "Filters", bundle: bundle)
        case .huge: String(localized: "Over 1 GB", table: "Filters", bundle: bundle)
        }
    }
}

extension SearchFilters.Modified {
    fileprivate func title(_ bundle: Bundle) -> String {
        switch self {
        case .any: String(localized: "Any time", table: "Filters", bundle: bundle)
        case .day: String(localized: "Last 24 hours", table: "Filters", bundle: bundle)
        case .week: String(localized: "Last 7 days", table: "Filters", bundle: bundle)
        case .month: String(localized: "Last 30 days", table: "Filters", bundle: bundle)
        case .year: String(localized: "Last 12 months", table: "Filters", bundle: bundle)
        }
    }
}

private final class PillCell: NSButtonCell {
    var maxTitleWidth = CGFloat.greatestFiniteMagnitude
    var fullTitleWidth: CGFloat { ceil(attributedTitle.size().width) }
    var titleWidth: CGFloat { min(fullTitleWidth, maxTitleWidth) }
    var arrowWidth: CGFloat { image?.size.width ?? 0 }
    var width: CGFloat { 2 * NormalMetrics.pillPadding + titleWidth + NormalMetrics.pillArrowGap + arrowWidth }

    static func titleWidth(_ title: String, font: NSFont) -> CGFloat {
        let cell = PillCell(textCell: title)
        cell.font = font
        return cell.fullTitleWidth
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        place(NSSize(width: titleWidth, height: super.titleRect(forBounds: rect).height), at: NormalMetrics.pillPadding, in: rect)
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        place(image?.size ?? .zero, at: NormalMetrics.pillPadding + titleWidth + NormalMetrics.pillArrowGap, in: rect)
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle(title, withFrame: titleRect(forBounds: controlView.bounds), in: controlView)
    }

    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        super.drawImage(image, withFrame: imageRect(forBounds: controlView.bounds), in: controlView)
    }

    private func place(_ size: NSSize, at offset: CGFloat, in rect: NSRect) -> NSRect {
        let x = controlView?.userInterfaceLayoutDirection == .rightToLeft ? rect.maxX - offset - size.width : rect.minX + offset
        return NSRect(x: x, y: rect.minY + ((rect.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }
}

extension NSButton {
    fileprivate static func pill(_ id: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton()
        button.cell = PillCell(textCell: "")
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .accessoryBar
        button.showsBorderOnlyWhileMouseInside = false
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        button.imagePosition = .imageTrailing
        button.lineBreakMode = .byTruncatingMiddle
        button.target = target
        button.action = action
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityLabel(label)
        button.cell?.setAccessibilityIdentifier(id)
        button.cell?.setAccessibilityLabel(label)
        return button
    }

    fileprivate func showPill(_ title: String, isOn: Bool, size: TextSize) {
        self.title = title
        let pillFont = size.font(.systemFont(ofSize: NSFont.systemFontSize, weight: isOn ? .semibold : .regular))
        if font != pillFont { font = pillFont }
        isBordered = isOn
        contentTintColor = isOn ? nil : .labelColor
    }

    fileprivate func pillSize(_ size: TextSize) -> CGSize? {
        (cell as? PillCell).map { CGSize(width: $0.width, height: NormalMetrics.pillHeight(size)) }
    }
}

private struct MenuPill<Value: Hashable>: NSViewRepresentable {
    let id: String
    let label: String
    let title: String
    let isOn: Bool
    let textSize: TextSize
    @Binding var value: Value
    let items: [(title: String, value: Value)]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton.pill(id, label: label, target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        button.cell?.setAccessibilityRole(.menuButton)
        button.menu = NSMenu()
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.userInterfaceLayoutDirection = context.environment.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        button.showPill(title, isOn: isOn, size: textSize)
        let menuFont = textSize.font(.menuFont(ofSize: 0))
        if button.menu?.font != menuFont { button.menu?.font = menuFont }
        context.coordinator.fill(button.menu)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSButton, context: Context) -> CGSize? { button.pillSize(textSize) }

    final class Coordinator: NSObject {
        var parent: MenuPill?
        private var shown: [String]?

        func fill(_ menu: NSMenu?) {
            guard let parent, let menu else { return }
            let titles = parent.items.map(\.title)
            if titles != shown {
                shown = titles
                menu.removeAllItems()
                for title in titles {
                    let item = NSMenuItem(title: title, action: #selector(chose(_:)), keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                }
            }
            for (item, choice) in zip(menu.items, parent.items) { item.state = choice.value == parent.value ? .on : .off }
        }

        @objc func chose(_ item: NSMenuItem) {
            guard let parent, let index = item.menu?.index(of: item), parent.items.indices.contains(index) else { return }
            parent.value = parent.items[index].value
        }

        @objc func pressed(_ button: NSButton) {
            let x = button.userInterfaceLayoutDirection == .rightToLeft ? button.bounds.maxX : button.bounds.minX
            button.menu?.popUp(positioning: nil, at: NSPoint(x: x, y: button.isFlipped ? button.bounds.maxY : 0), in: button)
        }
    }
}

private struct ExtensionPill: NSViewRepresentable {
    let label: String
    let title: String
    let isOn: Bool
    let textSize: TextSize
    let titleCap: CGFloat
    @Binding var isOpen: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        NSButton.pill(FilterBar.extensionsID, label: label, target: context.coordinator, action: #selector(Coordinator.pressed))
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.isOpen = $isOpen
        button.userInterfaceLayoutDirection = context.environment.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        (button.cell as? PillCell)?.maxTitleWidth = titleCap
        button.showPill(title, isOn: isOn, size: textSize)
        button.toolTip = isOn ? title : nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSButton, context: Context) -> CGSize? { button.pillSize(textSize) }

    final class Coordinator: NSObject {
        var isOpen: Binding<Bool>?

        @objc func pressed() { isOpen?.wrappedValue = true }
    }
}

private struct FocusOnAppear: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focused($focused).onAppear { focused = true }
    }
}
