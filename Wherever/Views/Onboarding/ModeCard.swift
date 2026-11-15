import AppKit

final class ModeCard: WelcomeBox {
    let mode: WindowMode
    let radio: NSButton
    let picture: ModePictureView
    private let onPick: (WindowMode) -> Void

    override var isOn: Bool {
        didSet { radio.state = isOn ? .on : .off }
    }

    override var theme: Theme {
        didSet { picture.theme = theme }
    }

    init(mode: WindowMode, title: String, size: TextSize, onPick: @escaping (WindowMode) -> Void) {
        self.mode = mode
        self.onPick = onPick
        picture = ModePictureView(layout: mode == .simple ? .simple : .normal)
        radio = NSButton(radioButtonWithTitle: title, target: nil, action: nil)
        super.init()
        radio.font = .systemFont(ofSize: size.points(WelcomeMetrics.modeNameSize))
        radio.target = self
        radio.action = #selector(radioPressed)
        radio.setAccessibilityIdentifier("welcome-mode-\(mode.rawValue)")
        radio.translatesAutoresizingMaskIntoConstraints = false
        picture.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picture)
        addSubview(radio)
        let padding = WelcomeMetrics.cardPadding
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: WelcomeMetrics.cardWidth),
            picture.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            picture.centerXAnchor.constraint(equalTo: centerXAnchor),
            radio.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: WelcomeMetrics.cardSpacing),
            radio.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ((WelcomeMetrics.cardWidth - radio.fittingSize.width) / 2).rounded()),
            bottomAnchor.constraint(equalTo: radio.bottomAnchor, constant: padding),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === radio ? radio : self
    }

    override func mouseDown(with event: NSEvent) {
        radio.performClick(nil)
    }

    @objc private func radioPressed() {
        onPick(mode)
    }
}
