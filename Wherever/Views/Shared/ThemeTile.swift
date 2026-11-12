import AppKit

final class ThemeTile: NSButton {
    enum Metrics {
        static let size = NSSize(width: 94, height: 60)
        static let radius: CGFloat = 6
        static let gap: CGFloat = 8
        static let toName: CGFloat = 6
        static let nameSize: CGFloat = 12
        static let unpickedBorder: CGFloat = 1
        static let pickedBorder: CGFloat = 2
    }

    let theme: Theme

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: NSRect(origin: .zero, size: Metrics.size))
        setButtonType(.radio)
        isBordered = false
        title = ""
        imagePosition = .noImage
        let id = "theme-tile-\(theme.rawValue)"
        identifier = NSUserInterfaceItemIdentifier(id)
        setAccessibilityIdentifier(id)
        cell?.setAccessibilityIdentifier(id)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Metrics.size }
    override var focusRingMaskBounds: NSRect { bounds }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }

    func setName(_ name: String) {
        setAccessibilityLabel(name)
        cell?.setAccessibilityLabel(name)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radius, yRadius: Metrics.radius).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let shapes: [(rect: NSRect, radius: CGFloat, color: NSColor)] = [
            (bounds, Metrics.radius, theme.windowBackground),
            (NSRect(x: 8, y: 8, width: 40, height: 4), 2, theme.text),
            (NSRect(x: 6, y: 18, width: 82, height: 36), 3, theme.rowBackground),
            (NSRect(x: 10, y: 23, width: 74, height: 8), 2, theme.matchText),
            (NSRect(x: 10, y: 36, width: 56, height: 4), 2, theme.text),
            (NSRect(x: 10, y: 45, width: 44, height: 4), 2, theme.secondaryText),
        ]
        for shape in shapes {
            shape.color.setFill()
            NSBezierPath(roundedRect: shape.rect, xRadius: shape.radius, yRadius: shape.radius).fill()
        }
        let picked = state == .on
        let width = picked ? Metrics.pickedBorder : Metrics.unpickedBorder
        let inset = width / 2
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: Metrics.radius - inset, yRadius: Metrics.radius - inset)
        border.lineWidth = width
        (picked ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        border.stroke()
    }
}

final class ThemeTileName: NSTextField {
    weak var tile: ThemeTile?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { tile?.performClick(nil) }
}

final class ThemeTileRow: NSView {
    static let width = CGFloat(Theme.allCases.count) * ThemeTile.Metrics.size.width + CGFloat(Theme.allCases.count - 1) * ThemeTile.Metrics.gap

    let tiles = Theme.allCases.map { ThemeTile(theme: $0) }
    let names = Theme.allCases.map { _ in ThemeTileName(wrappingLabelWithString: "") }
    private(set) var picked: Theme
    private var textSize: TextSize
    private var bundle: Bundle
    private let onPick: (Theme) -> Void
    private var nameHeight: CGFloat = 0

    init(picked: Theme, textSize: TextSize, bundle: Bundle, onPick: @escaping (Theme) -> Void) {
        self.picked = picked
        self.textSize = textSize
        self.bundle = bundle
        self.onPick = onPick
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(ThemePicker.id)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityIdentifier(ThemePicker.id)
        for (tile, name) in zip(tiles, names) {
            tile.target = self
            tile.action = #selector(tilePressed(_:))
            addSubview(tile)
            name.tile = tile
            name.isSelectable = false
            name.setAccessibilityElement(false)
            name.cell?.setAccessibilityElement(false)
            addSubview(name)
        }
        applyWords()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: ThemeTile.Metrics.size.height + ThemeTile.Metrics.toName + nameHeight)
    }

    func update(picked: Theme, textSize: TextSize, bundle: Bundle) {
        if textSize != self.textSize || bundle != self.bundle {
            self.textSize = textSize
            self.bundle = bundle
            applyWords()
        }
        if picked != self.picked {
            self.picked = picked
            applyPick()
        }
    }

    override func layout() {
        super.layout()
        let size = ThemeTile.Metrics.size
        let step = size.width + ThemeTile.Metrics.gap
        let last = tiles.count - 1
        for (index, tile) in tiles.enumerated() {
            let slot = userInterfaceLayoutDirection == .rightToLeft ? last - index : index
            let x = CGFloat(slot) * step
            tile.frame = NSRect(origin: NSPoint(x: x, y: 0), size: size)
            names[index].frame = NSRect(x: x, y: size.height + ThemeTile.Metrics.toName, width: size.width, height: nameHeight)
        }
    }

    @objc private func tilePressed(_ tile: ThemeTile) {
        guard tile.theme != picked else {
            tile.state = .on
            return
        }
        picked = tile.theme
        applyPick()
        onPick(tile.theme)
    }

    private func applyWords() {
        setAccessibilityLabel(String(localized: "Color theme", table: "Theme", bundle: bundle))
        for (tile, name) in zip(tiles, names) {
            tile.setName(tile.theme.name(bundle))
            name.attributedStringValue = title(of: tile.theme, weight: .semibold)
        }
        let bounds = NSRect(x: 0, y: 0, width: ThemeTile.Metrics.size.width, height: .greatestFiniteMagnitude)
        nameHeight = ceil(names.map { $0.cell?.cellSize(forBounds: bounds).height ?? 0 }.max() ?? 0)
        applyPick()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func applyPick() {
        for (tile, name) in zip(tiles, names) {
            let on = tile.theme == picked
            tile.state = on ? .on : .off
            name.attributedStringValue = title(of: tile.theme, weight: on ? .semibold : .regular)
        }
    }

    private func title(of theme: Theme, weight: NSFont.Weight) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.hyphenationFactor = 1
        return NSAttributedString(string: theme.name(bundle), attributes: [
            .font: NSFont.systemFont(ofSize: textSize.points(ThemeTile.Metrics.nameSize), weight: weight),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
    }
}
