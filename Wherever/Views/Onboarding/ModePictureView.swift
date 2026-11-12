import AppKit
import Combine
import QuartzCore

final class ModePictureView: NSView {
    var isShown: (NSWindow?) -> Bool = { $0?.occlusionState.contains(.visible) == true } { didSet { refreshMotion() } }
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var loopStart: CFTimeInterval = 0
    var theme = Theme.systemNative { didSet { applyColors() } }

    private let layout: ModePictureLayout
    private var watches: [AnyCancellable] = []

    init(layout: ModePictureLayout) {
        self.layout = layout
        super.init(frame: CGRect(origin: .zero, size: ModePictureLayout.size))
        let root = CALayer()
        layer = root
        wantsLayer = true
        quietly {
            root.name = "window"
            root.frame = bounds
            root.cornerRadius = ModePictureLayout.radius
            root.masksToBounds = true
            root.borderWidth = ModePictureLayout.border
            for shape in layout.shapes { root.addSublayer(sublayer(for: shape)) }
        }
        setAccessibilityElement(false)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { ModePictureLayout.size }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watches = window.map(watching) ?? []
        applyColors()
        refreshMotion()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshMotion()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshMotion()
    }

    private func watching(_ window: NSWindow) -> [AnyCancellable] {
        let center = NotificationCenter.default
        return [
            center.publisher(for: NSWindow.didChangeOcclusionStateNotification)
                .sink { [weak self, weak window] note in
                    guard let window, (note.object as? NSWindow) === window else { return }
                    self?.refreshMotion()
                },
            center.publisher(for: NSColor.systemColorsDidChangeNotification)
                .sink { [weak self] _ in self?.applyColors() },
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
                .sink { [weak self] _ in
                    self?.applyColors()
                    self?.refreshMotion()
                }
        ]
    }

    private func sublayer(for shape: ModePictureLayout.Shape) -> CALayer {
        let sublayer = CALayer()
        sublayer.name = shape.name
        sublayer.cornerRadius = shape.radius
        let rect = CGRect(x: shape.frame.minX, y: ModePictureLayout.size.height - shape.frame.minY - shape.frame.height, width: shape.frame.width, height: shape.frame.height)
        if shape.motion?.kind == .grow {
            sublayer.anchorPoint = CGPoint(x: 0, y: 0.5)
            sublayer.bounds = CGRect(origin: .zero, size: rect.size)
            sublayer.position = CGPoint(x: rect.minX, y: rect.midY)
        } else {
            sublayer.frame = rect
        }
        return sublayer
    }

    private func applyColors() {
        guard let root = layer else { return }
        let highContrast = effectiveAppearance.isHighContrast
        quietly {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                root.backgroundColor = theme.windowBackground.cgColor
                root.borderColor = (highContrast ? NSColor.labelColor : NSColor.separatorColor).cgColor
                for (shape, sublayer) in zip(layout.shapes, root.sublayers ?? []) {
                    let outlined = shape.outlined || (highContrast && shape.outlinedInHighContrast)
                    sublayer.backgroundColor = (shape.outlined && theme != .systemNative ? theme.rowBackground : shape.fill).cgColor
                    sublayer.borderWidth = outlined ? ModePictureLayout.border : 0
                    sublayer.borderColor = outlined ? (highContrast ? NSColor.labelColor : NSColor.separatorColor).cgColor : nil
                }
            }
        }
    }

    private func refreshMotion() {
        let sublayers = layer?.sublayers ?? []
        let on = !reduceMotion() && isShown(window) && !isHiddenOrHasHiddenAncestor
        if !on {
            sublayers.forEach { $0.removeAllAnimations() }
        } else if !sublayers.contains(where: { $0.animation(forKey: "opacity") != nil }) {
            quietly {
                for (shape, sublayer) in zip(layout.shapes, sublayers) {
                    for animation in animations(for: shape, width: sublayer.bounds.width) {
                        animation.beginTime = loopStart == 0 ? 0 : sublayer.convertTime(loopStart, from: nil)
                        sublayer.add(animation, forKey: animation.keyPath)
                    }
                }
            }
        }
    }

    private func animations(for shape: ModePictureLayout.Shape, width: CGFloat) -> [CAKeyframeAnimation] {
        guard let motion = shape.motion else { return [] }
        let start = motion.start, end = motion.end
        let opacity = keyframes("opacity", [0, 0, 1, 1, 0], [0, start, end, ModePictureLayout.fadeStart, ModePictureLayout.loop], [.linear, .easeOut, .linear, .easeIn])
        switch motion.kind {
        case .fade:
            return [opacity]
        case .grow:
            let full = Double(width), small = full * ModePictureLayout.growFrom
            return [opacity, keyframes("bounds.size.width", [small, small, full, full], [0, start, end, ModePictureLayout.loop], [.linear, .easeInEaseOut, .linear])]
        case .rise:
            let low = ModePictureLayout.riseFrom
            return [opacity, keyframes("transform.translation.y", [low, low, 0, 0], [0, start, end, ModePictureLayout.loop], [.linear, .easeOut, .linear])]
        }
    }

    private func keyframes(_ keyPath: String, _ values: [Double], _ times: [CFTimeInterval], _ easing: [CAMediaTimingFunctionName]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0 / ModePictureLayout.loop) }
        animation.timingFunctions = easing.map { CAMediaTimingFunction(name: $0) }
        animation.duration = ModePictureLayout.loop
        animation.repeatCount = .infinity
        return animation
    }

    private func quietly(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}
