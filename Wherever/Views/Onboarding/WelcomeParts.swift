import AppKit
import Combine

extension NSTextField {
    static func welcomeLabel(width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, alignment: NSTextAlignment = .center) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = alignment
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }
}

class WelcomeBackground: NSView {
    var theme = Theme.systemNative { didSet { needsDisplay = true } }
    private var colorWatch: AnyCancellable?

    init() {
        super.init(frame: .zero)
        colorWatch = NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .sink { [weak self] _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        theme.windowBackground.setFill()
        bounds.fill()
    }
}

class WelcomeBox: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    var theme = Theme.systemNative { didSet { needsDisplay = true } }
    private var colorWatch: AnyCancellable?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        colorWatch = NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .sink { [weak self] _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func hold(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let padding = WelcomeMetrics.toolPadding
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = WelcomeMetrics.cardRadius
        theme.rowBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let width = isOn ? WelcomeMetrics.cardBorderOn : WelcomeMetrics.cardBorder
        let inset = width / 2
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
        border.lineWidth = width
        (isOn ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        border.stroke()
    }
}

final class WelcomeRule: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: WelcomeMetrics.toolCaptionWidth, height: 1) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill(using: .sourceOver)
    }
}

final class WelcomeRow: NSStackView {
    let label: NSTextField
    private let labelWidth: NSLayoutConstraint

    init(title: String, control: NSView, size: TextSize) {
        label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: size.points(WelcomeMetrics.boxLabelSize))
        label.textColor = .labelColor
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        labelWidth = label.widthAnchor.constraint(equalToConstant: 0)
        labelWidth.isActive = true
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = WelcomeMetrics.toolRowGap
        translatesAutoresizingMaskIntoConstraints = false
        setHuggingPriority(.defaultHigh, for: .vertical)
        addArrangedSubview(label)
        addArrangedSubview(control)
        heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsWindow.Metrics.standardRowHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func fit(controlWidth: CGFloat) {
        let width = WelcomeMetrics.toolCaptionWidth - WelcomeMetrics.toolRowGap - controlWidth
        label.preferredMaxLayoutWidth = width
        labelWidth.constant = width
    }
}

final class WelcomePage: NSStackView {
    let heading: String
    private let title: NSTextField
    private let line: NSTextField

    var theme = Theme.systemNative {
        didSet {
            title.textColor = theme.text
            line.textColor = theme.secondaryText
        }
    }

    init(heading: String, subtitle: String, content: [NSView], size: TextSize, tick: NSView? = nil) {
        self.heading = heading
        title = .welcomeLabel(width: WelcomeMetrics.titleWidth, size: size.points(WelcomeMetrics.titleSize), weight: .bold, color: Theme.systemNative.text)
        line = .welcomeLabel(width: WelcomeMetrics.titleWidth, size: size.points(WelcomeMetrics.mottoSize), color: Theme.systemNative.secondaryText)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.cell?.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: WelcomeMetrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: WelcomeMetrics.iconSize),
        ])
        title.stringValue = heading
        line.stringValue = subtitle
        ([icon] + [tick].compactMap { $0 } + [title, line] + content).forEach(addArrangedSubview)
        if let tick {
            setCustomSpacing(WelcomeMetrics.iconToTick, after: icon)
            setCustomSpacing(WelcomeMetrics.tickToTitle, after: tick)
        } else {
            setCustomSpacing(WelcomeMetrics.iconToTitle, after: icon)
        }
        setCustomSpacing(WelcomeMetrics.titleToMotto, after: title)
        setCustomSpacing(WelcomeMetrics.mottoToText, after: line)
        for view in content.dropLast() { setCustomSpacing(WelcomeMetrics.cardsToTool, after: view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func tickView() -> NSImageView {
        let colors = NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen])
        let size = NSImage.SymbolConfiguration(pointSize: WelcomeMetrics.tickSize, weight: .regular)
        let image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(size.applying(colors))
        let tick = NSImageView(image: image ?? NSImage())
        tick.imageScaling = .scaleProportionallyUpOrDown
        tick.cell?.setAccessibilityElement(false)
        tick.setAccessibilityIdentifier("welcome-done-tick")
        tick.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tick.widthAnchor.constraint(equalToConstant: WelcomeMetrics.tickSize),
            tick.heightAnchor.constraint(equalToConstant: WelcomeMetrics.tickSize),
        ])
        return tick
    }
}
