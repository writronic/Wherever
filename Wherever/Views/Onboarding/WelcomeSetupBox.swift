import AppKit

final class WelcomeSetupBox: WelcomeBox {
    let launcher = NSSwitch()
    let menuBarIcon = NSSwitch()
    let tiles: ThemeTileRow
    private let onLauncher: (Bool) -> Void
    private let onMenuBarIcon: (Bool) -> Void
    private var paintText: (Theme) -> Void = { _ in }

    override var theme: Theme {
        didSet { paintText(theme) }
    }

    var keyViews: [NSView] { [launcher, menuBarIcon] + tiles.tiles }

    init(
        choices: WelcomeChoices, shortcut: String, bundle: Bundle, size: TextSize,
        onLauncher: @escaping (Bool) -> Void, onMenuBarIcon: @escaping (Bool) -> Void, onTheme: @escaping (Theme) -> Void
    ) {
        tiles = ThemeTileRow(picked: choices.theme, textSize: size, bundle: bundle, onPick: onTheme)
        self.onLauncher = onLauncher
        self.onMenuBarIcon = onMenuBarIcon
        super.init()
        let launcherTitle = String(localized: "Launcher shortcut", table: "Welcome", bundle: bundle)
        let menuBarTitle = String(localized: "Show Menu Bar Icon", table: "Settings", bundle: bundle)
        let press = String(localized: "Press it in any app to search your files.", table: "Settings", bundle: bundle)
        configure(launcher, id: "welcome-launcher", title: launcherTitle, help: press + " " + shortcut, on: choices.launcher, action: #selector(launcherChanged))
        configure(menuBarIcon, id: "welcome-menu-bar-icon", title: menuBarTitle, help: nil, on: choices.menuBarIcon, action: #selector(menuBarIconChanged))
        let launcherRow = row(launcherTitle, launcher, size)
        let menuBarRow = row(menuBarTitle, menuBarIcon, size)
        let width = WelcomeMetrics.toolCaptionWidth
        let caption = NSTextField.welcomeLabel(width: width, size: size.points(WelcomeMetrics.captionSize), color: Theme.systemNative.secondaryText, alignment: .natural)
        let points = size.points(WelcomeMetrics.captionSize)
        caption.cell?.setAccessibilityElement(false)
        let themeLabel = NSTextField.welcomeLabel(width: width, size: size.points(WelcomeMetrics.boxLabelSize), color: Theme.systemNative.text, alignment: .natural)
        themeLabel.stringValue = String(localized: "Color theme", table: "Theme", bundle: bundle)
        themeLabel.cell?.setAccessibilityElement(false)
        tiles.translatesAutoresizingMaskIntoConstraints = false
        let firstRule = WelcomeRule()
        let secondRule = WelcomeRule()
        let rows = NSStackView(views: [launcherRow, caption, firstRule, menuBarRow, secondRule, themeLabel, tiles])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.setCustomSpacing(SettingsWindow.Metrics.captionSpacing, after: launcherRow)
        for view in [caption, firstRule, menuBarRow, secondRule] { rows.setCustomSpacing(WelcomeMetrics.rowPadding, after: view) }
        rows.setCustomSpacing(WelcomeMetrics.labelToSwatches, after: themeLabel)
        hold(rows)
        paintText = { theme in
            for label in [launcherRow.label, menuBarRow.label, themeLabel] { label.textColor = theme.text }
            let text = NSMutableAttributedString(string: press, attributes: [.font: NSFont.systemFont(ofSize: points), .foregroundColor: theme.secondaryText])
            text.append(NSAttributedString(string: "\u{2002}" + shortcut, attributes: [.font: NSFont.systemFont(ofSize: points, weight: .medium), .foregroundColor: theme.text]))
            caption.attributedStringValue = text
        }
        paintText(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure(_ control: NSSwitch, id: String, title: String, help: String?, on: Bool, action: Selector) {
        control.controlSize = .mini
        control.state = on ? .on : .off
        control.target = self
        control.action = action
        control.setAccessibilityIdentifier(id)
        control.setAccessibilityLabel(title)
        control.setAccessibilityHelp(help)
    }

    private func row(_ title: String, _ control: NSSwitch, _ size: TextSize) -> WelcomeRow {
        let row = WelcomeRow(title: title, control: control, size: size)
        row.fit(controlWidth: control.intrinsicContentSize.width)
        row.label.cell?.setAccessibilityElement(false)
        return row
    }

    @objc private func launcherChanged() {
        onLauncher(launcher.state == .on)
    }

    @objc private func menuBarIconChanged() {
        onMenuBarIcon(menuBarIcon.state == .on)
    }
}
