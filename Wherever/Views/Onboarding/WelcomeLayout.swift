import CoreGraphics

struct WelcomeLayout: Equatable {
    let iconTop: CGFloat
    let buttonY: CGFloat
    let height: CGFloat
    let minimumIconTop: CGFloat
    private let scale: CGFloat

    init(minimumIconTop: CGFloat, tallestGroup: CGFloat, buttonHeight: CGFloat, tallestLine: CGFloat, visibleHeight: CGFloat, scale: CGFloat) {
        func pixels(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
        let strip = WelcomeMetrics.buttonToLine + tallestLine + WelcomeMetrics.bottomMargin
        let naturalY = pixels(WelcomeMetrics.iconTop + tallestGroup + WelcomeMetrics.textToButton)
        let spare = max(0, WelcomeMetrics.iconTop - minimumIconTop)
        let cut = max(0, pixels(naturalY + buttonHeight + strip - visibleHeight))
        self.scale = scale
        self.minimumIconTop = minimumIconTop
        iconTop = WelcomeMetrics.iconTop - min(spare, cut)
        buttonY = naturalY - cut
        height = pixels(buttonY + buttonHeight + strip)
    }

    var viewport: CGFloat { buttonY - minimumIconTop }

    func centredTop(ofGroup height: CGFloat) -> CGFloat {
        max(minimumIconTop, ((buttonY - height) / 2 * scale).rounded() / scale)
    }

    func documentHeight(top: CGFloat, group: CGFloat) -> CGFloat {
        max(viewport, ((top - minimumIconTop + group + WelcomeMetrics.textToButton) * scale).rounded(.up) / scale)
    }
}
