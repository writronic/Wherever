import AppKit
import Combine

extension WelcomeMetrics {
    static let stepsWidth: CGFloat = 240
    static let stepsTop: CGFloat = 24
    static let stepsMinimumLabel: CGFloat = 16
    static let stepsLabelToDots: CGFloat = 6
    static let stepsPitch: CGFloat = 36
    static let stepsDot: CGFloat = 8
    static let stepsCurrentDot: CGFloat = 10
    static let stepsRing: CGFloat = 16
    static let stepsLine: CGFloat = 20
    static let stepsLineThickness: CGFloat = 2
    static let stepsLineStart: CGFloat = 8
    static let stepsToIcon: CGFloat = 12
    static let stepsHit: CGFloat = 28
}

struct WelcomeStepsGeometry: Equatable {
    enum State { case done, current, later }
    struct Dot: Equatable {
        let rect: CGRect
        let state: State
    }
    struct Line: Equatable {
        let rect: CGRect
        let isDone: Bool
    }

    let label: CGRect
    let ring: CGRect
    let dots: [Dot]
    let lines: [Line]
    let hits: [CGRect]
    let height: CGFloat

    init(current: Int, count: Int, width: CGFloat, labelHeight: CGFloat, scale: CGFloat, rightToLeft: Bool) {
        typealias M = WelcomeMetrics
        let rowTop = M.stepsTop + labelHeight + M.stepsLabelToDots
        let centreY = rowTop + M.stepsRing / 2
        let rowWidth = M.stepsRing + CGFloat(count - 1) * M.stepsPitch
        let left = ((width - rowWidth) / 2 * scale).rounded() / scale
        func centre(_ index: Int) -> CGFloat { left + M.stepsRing / 2 + CGFloat(index) * M.stepsPitch }
        func edge(_ low: CGFloat, _ length: CGFloat) -> CGFloat { rightToLeft ? width - low - length : low }
        func disc(_ index: Int, _ diameter: CGFloat) -> CGRect {
            CGRect(x: edge(centre(index) - diameter / 2, diameter), y: centreY - diameter / 2, width: diameter, height: diameter)
        }
        label = CGRect(x: 0, y: M.stepsTop, width: width, height: labelHeight)
        ring = disc(current, M.stepsRing)
        dots = (0..<count).map { index in
            let state: State = index < current ? .done : index == current ? .current : .later
            return Dot(rect: disc(index, state == .current ? M.stepsCurrentDot : M.stepsDot), state: state)
        }
        lines = (0..<count - 1).map { index in
            Line(
                rect: CGRect(x: edge(centre(index) + M.stepsLineStart, M.stepsLine), y: centreY - M.stepsLineThickness / 2, width: M.stepsLine, height: M.stepsLineThickness),
                isDone: index < current
            )
        }
        hits = (0..<count).map { index in
            CGRect(x: edge(centre(index) - M.stepsPitch / 2, M.stepsPitch), y: centreY - M.stepsHit / 2, width: M.stepsPitch, height: M.stepsHit)
        }
        height = centreY + M.stepsHit / 2
    }
}

final class WelcomeStepDot: NSButton {
    init(label: String, id: String) {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .noImage
        setAccessibilityIdentifier(id)
        cell?.setAccessibilityIdentifier(id)
        setAccessibilityLabel(label)
        cell?.setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: WelcomeMetrics.stepsPitch, height: WelcomeMetrics.stepsHit) }
    override var focusRingMaskBounds: NSRect { ring }

    private var ring: NSRect {
        let side = WelcomeMetrics.stepsRing
        return NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: ring).fill()
    }

    override func draw(_ dirtyRect: NSRect) {}
}

final class WelcomeSteps: NSView {
    var page = 0 {
        didSet {
            setAccessibilityLabel(text)
            refreshDots()
        }
    }

    var canMove = false {
        didSet { refreshDots() }
    }

    var reach = 0 {
        didSet { refreshDots() }
    }

    var theme = Theme.systemNative {
        didSet { needsDisplay = true }
    }

    var onStep: ((Int) -> Void)?
    let dots: [WelcomeStepDot]

    private let count: Int
    private let size: TextSize
    private let bundle: Bundle
    private var scale: CGFloat = 2
    private var colorWatch: AnyCancellable?

    init(count: Int, size: TextSize, bundle: Bundle) {
        self.count = count
        self.size = size
        self.bundle = bundle
        dots = (0..<count).map { index in
            WelcomeStepDot(label: WelcomeSteps.label(index, count, bundle), id: "welcome-step-\(index + 1)")
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
        for (index, dot) in dots.enumerated() {
            dot.tag = index
            dot.target = self
            dot.action = #selector(stepPressed)
            addSubview(dot)
        }
        setAccessibilityChildren(dots)
        refreshDots()
        colorWatch = NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .sink { [weak self] _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: WelcomeMetrics.stepsWidth, height: geometry.height) }

    var text: String { Self.label(page, count, bundle) }

    private static func label(_ index: Int, _ count: Int, _ bundle: Bundle) -> String {
        String(localized: "Step \(index + 1) of \(count)", table: "Welcome", bundle: bundle)
    }

    private func refreshDots() {
        for (index, dot) in dots.enumerated() { dot.isEnabled = canMove && index != page && index <= reach }
        needsDisplay = true
    }

    @objc private func stepPressed(_ dot: WelcomeStepDot) {
        onStep?(dot.tag)
    }

    var geometry: WelcomeStepsGeometry {
        let height = (max(WelcomeMetrics.stepsMinimumLabel, lineHeight) * scale).rounded(.up) / scale
        return WelcomeStepsGeometry(
            current: page, count: count, width: WelcomeMetrics.stepsWidth, labelHeight: height,
            scale: scale, rightToLeft: userInterfaceLayoutDirection == .rightToLeft
        )
    }

    private var labelFont: NSFont { .systemFont(ofSize: size.points(WelcomeMetrics.captionSize)) }
    private var lineHeight: CGFloat { size.lineHeight(.systemFont(ofSize: WelcomeMetrics.captionSize)) }

    func fit(scale: CGFloat) -> CGFloat {
        self.scale = scale
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
        return geometry.height
    }

    override func layout() {
        super.layout()
        for (dot, hit) in zip(dots, geometry.hits) { dot.frame = hit }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = geometry
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let offset = max(0, (shape.label.height - lineHeight) / 2)
        func later(_ index: Int) -> NSColor { dots[index].isEnabled ? .tertiaryLabelColor : .quaternaryLabelColor }
        text.draw(
            in: shape.label.offsetBy(dx: 0, dy: offset),
            withAttributes: [.font: labelFont, .foregroundColor: theme.secondaryText, .paragraphStyle: style]
        )
        for (index, line) in shape.lines.enumerated() {
            (line.isDone ? NSColor.systemGreen.withAlphaComponent(0.5) : later(index + 1)).setFill()
            NSBezierPath(roundedRect: line.rect, xRadius: line.rect.height / 2, yRadius: line.rect.height / 2).fill()
        }
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: shape.ring).fill()
        for (index, dot) in shape.dots.enumerated() {
            switch dot.state {
            case .done: NSColor.systemGreen.setFill()
            case .current: NSColor.controlAccentColor.setFill()
            case .later: later(index).setFill()
            }
            NSBezierPath(ovalIn: dot.rect).fill()
        }
    }
}
