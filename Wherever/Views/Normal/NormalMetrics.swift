import AppKit
import CoreGraphics

final class WidestTitle {
    private(set) var probes = 0
    private var cached: (size: TextSize, width: CGFloat)?

    func width(_ size: TextSize, of titles: @autoclosure () -> [String], probe: (String) -> CGFloat) -> CGFloat {
        if let cached, cached.size == size { return cached.width }
        let width = titles().map { title in
            probes += 1
            return probe(title)
        }.max() ?? 0
        cached = (size, width)
        return width
    }
}

enum NormalMetrics {
    static let formVerticalInset: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    static let labelMinWidth: CGFloat = 100
    static let fieldWidth: CGFloat = 440
    static let popUpWidth: CGFloat = 130
    static let columnSpacing: CGFloat = 8
    static let controlHeight: CGFloat = 28
    static let filterBarHeight: CGFloat = 34
    static let pillHeight: CGFloat = 22
    static let pillPadding: CGFloat = 9
    static let pillArrowGap: CGFloat = 4
    static let pillSpacing: CGFloat = 6
    static let comboWidth: CGFloat = 24
    static let comboInset: CGFloat = 2
    static let comboRadius: CGFloat = 5.5
    static let comboTextGap: CGFloat = 28

    nonisolated static var comboFill: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)
        }
    }

    static func pillHeight(_ size: TextSize) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return max(pillHeight, pillHeight + ceil(size.lineHeight(font)) - ceil(TextSize.standard.lineHeight(font)))
    }

    static func filterBarHeight(_ size: TextSize) -> CGFloat { filterBarHeight - pillHeight + pillHeight(size) }

    private static let reference: NSSearchField = {
        let field = NSSearchField()
        Availability.roundedRectangle(field)
        return field
    }()

    static func formRects(
        _ bounds: NSRect, font: NSFont?, size: NSControl.ControlSize, direction: NSUserInterfaceLayoutDirection
    ) -> (text: NSRect, icon: NSRect) {
        reference.font = font
        reference.controlSize = size
        let inset = Availability.searchFieldOutlineInset
        let frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 2 * inset)
        reference.frame = frame
        guard let cell = reference.cell as? NSSearchFieldCell else { return (bounds, .zero) }
        let text = cell.drawingRect(forBounds: frame).offsetBy(dx: bounds.minX, dy: bounds.minY + inset)
        let icon = cell.searchButtonRect(forBounds: frame).offsetBy(dx: bounds.minX, dy: bounds.minY + inset)
        guard direction == .rightToLeft else { return (text, icon) }
        func mirrored(_ rect: NSRect) -> NSRect { NSRect(x: bounds.minX + bounds.maxX - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) }
        return (mirrored(text), mirrored(icon))
    }
}
