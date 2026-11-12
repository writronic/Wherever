import AppKit
import Combine

final class WelcomeToolBox: WelcomeBox {
    let action = NSButton(title: "", target: nil, action: nil)
    let uninstall = NSButton(title: "", target: nil, action: nil)
    private let model: CommandLineToolModel
    private let bundle: Bundle
    private let announcer = NoticeAnnouncer()
    private let row: WelcomeRow
    private let caption: NSTextField
    private let notice: NSTextField
    private var watch: AnyCancellable?

    override var theme: Theme {
        didSet {
            caption.textColor = theme.secondaryText
            row.label.textColor = theme.text
        }
    }

    var keyViews: [NSView] { [action, uninstall] }

    private var installTitle: String { String(localized: "Install", table: "Settings", bundle: bundle) }
    private var uninstallTitle: String { String(localized: "Uninstall", table: "Settings", bundle: bundle) }

    init(model: CommandLineToolModel, bundle: Bundle, size: TextSize, post: @escaping Announcer.Post) {
        self.model = model
        self.bundle = bundle
        let width = WelcomeMetrics.toolCaptionWidth
        let points = size.points(WelcomeMetrics.captionSize)
        caption = .welcomeLabel(width: width, size: points, color: Theme.systemNative.secondaryText, alignment: .natural)
        notice = .welcomeLabel(width: width, size: points, color: .systemRed, alignment: .natural)
        let buttons = NSStackView(views: [action, uninstall])
        buttons.spacing = WelcomeMetrics.toolButtonGap
        buttons.translatesAutoresizingMaskIntoConstraints = false
        row = WelcomeRow(title: String(localized: "Command-Line Tool", table: "Settings", bundle: bundle), control: buttons, size: size)
        super.init()
        announcer.post = post
        for button in [action, uninstall] {
            button.target = self
            if let font = button.font { button.font = size.font(font) }
        }
        action.action = #selector(actionPressed)
        action.setAccessibilityIdentifier("welcome-tool")
        uninstall.action = #selector(uninstallPressed)
        uninstall.title = uninstallTitle
        uninstall.setAccessibilityIdentifier("welcome-tool-uninstall")
        caption.cell?.setAccessibilityElement(false)
        let lines = NSStackView(views: [row, caption, notice])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = SettingsWindow.Metrics.captionSpacing
        hold(lines)
        announcer.setAccessibilityElement(false)
        addSubview(announcer)
        watch = Publishers.CombineLatest4(model.$isOn, model.$linked, model.$busy, model.$notice)
            .sink { [weak self] isOn, linked, busy, notice in
                self?.show(isOn: isOn, linked: linked, busy: busy, notice: notice)
                self?.announce()
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func tallestHeight() -> CGFloat {
        let notices: [CommandLineToolModel.Notice?] = [nil, .installFailed, .uninstallFailed, .taken, .movable]
        let tallest = [(false, false), (true, true), (true, false)].flatMap { state in
            notices.map { notice -> CGFloat in
                show(isOn: state.0, linked: state.1, busy: false, notice: notice)
                return naturalHeight
            }
        }.max() ?? 0
        show(isOn: model.isOn, linked: model.linked, busy: model.busy, notice: model.notice)
        return tallest
    }

    private var naturalHeight: CGFloat {
        let spacing = SettingsWindow.Metrics.captionSpacing
        let controls = [SettingsWindow.Metrics.standardRowHeight, row.label.intrinsicContentSize.height, action.intrinsicContentSize.height]
        let failure = notice.isHidden ? 0 : spacing + notice.intrinsicContentSize.height
        return 2 * WelcomeMetrics.toolPadding + (controls.max() ?? 0) + spacing + caption.intrinsicContentSize.height + failure
    }

    private func captionText(isOn: Bool, linked: Bool) -> String {
        if !isOn {
            return String(localized: "Search from the command line with the wherever command.", table: "Settings", bundle: bundle)
        }
        if linked {
            return String(localized: "Installed at \(Bidi.path(model.linkPath)).", table: "Settings", bundle: bundle) + " "
                + String(localized: "Open a new Terminal window to use it.", table: "Settings", bundle: bundle)
        }
        return String(localized: "The wherever command is missing. Install it again.", table: "Settings", bundle: bundle)
    }

    private func show(isOn: Bool, linked: Bool, busy: Bool, notice state: CommandLineToolModel.Notice?) {
        action.title = isOn && linked ? uninstallTitle : installTitle
        action.isEnabled = !busy
        uninstall.isHidden = !isOn || linked
        uninstall.isEnabled = !busy
        caption.stringValue = captionText(isOn: isOn, linked: linked)
        notice.stringValue = state.map { model.text(for: $0, bundle: bundle) } ?? ""
        notice.isHidden = state == nil
        let help = state == nil ? caption.stringValue : caption.stringValue + " " + notice.stringValue
        action.setAccessibilityHelp(help)
        uninstall.setAccessibilityHelp(help)
        let extra = uninstall.isHidden ? 0 : WelcomeMetrics.toolButtonGap + uninstall.intrinsicContentSize.width
        row.fit(controlWidth: action.intrinsicContentSize.width + extra)
    }

    private func announce() {
        announcer.text = notice.isHidden ? nil : notice.stringValue
        announcer.announce()
    }

    @objc private func actionPressed() {
        if model.isOn && model.linked { model.uninstall() } else { model.install() }
    }

    @objc private func uninstallPressed() {
        model.uninstall()
    }
}
