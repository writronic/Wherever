import AppKit
import Combine
import QuartzCore

enum WelcomeMetrics {
    static let width: CGFloat = 600
    static let iconTop: CGFloat = 90
    static let iconSize: CGFloat = 80
    static let iconToTitle: CGFloat = 20
    static let tickSize: CGFloat = 64
    static let iconToTick: CGFloat = 20
    static let tickToTitle: CGFloat = 20
    static let titleSize: CGFloat = 28
    static let titleMargin: CGFloat = 40
    static let titleToMotto: CGFloat = 8
    static let mottoSize: CGFloat = 17
    static let mottoToText: CGFloat = 30
    static let textSize: CGFloat = 14
    static let textMargin: CGFloat = 60
    static let textToButton: CGFloat = 40
    static let captionSize: CGFloat = 12
    static let buttonMinWidth: CGFloat = 200
    static let backMinWidth: CGFloat = 100
    static let buttonGap: CGFloat = 12
    static let buttonToLine: CGFloat = 20
    static let lineSize: CGFloat = 12
    static let lineMargin: CGFloat = 40
    static let bottomMargin: CGFloat = 40
    static let cardPadding: CGFloat = 12
    static let cardWidth: CGFloat = 204
    static let cardSpacing: CGFloat = 8
    static let cardRadius: CGFloat = 8
    static let cardBorder: CGFloat = 1
    static let cardBorderOn: CGFloat = 2
    static let cardGap: CGFloat = 16
    static let cardsToTool: CGFloat = 16
    static let modeNameSize: CGFloat = 13
    static let boxLabelSize: CGFloat = 13
    static let toolPadding: CGFloat = 12
    static let toolRowGap: CGFloat = 12
    static let toolButtonGap: CGFloat = 8
    static let rowPadding: CGFloat = 12
    static let labelToSwatches: CGFloat = 8
    static let titleWidth = width - 2 * titleMargin
    static let textWidth = width - 2 * textMargin
    static let lineWidth = width - 2 * lineMargin
    static let toolCaptionWidth = 2 * cardWidth + cardGap - 2 * toolPadding
}

private final class WelcomeWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        event.keyCode == 53 ? cancelOperation(nil) : super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

final class WelcomeDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class WelcomeActionButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount <= 1 else { return }
        super.mouseDown(with: event)
    }
}

final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    enum Page: Int, CaseIterable { case access, modes, setup, done }

    private static let stages: [AccessModel.Stage] = [.waiting, .stillOff, .checkFailed, .settingsFailed, .granted, .startFailed, .reopen]

    private(set) var page = Page.access
    private var furthest = 0
    private(set) var choices: WelcomeChoices
    private let returning: Bool
    private let model: AccessModel
    private let bundle: Bundle
    private let size: TextSize
    private let post: Announcer.Post
    private let visibleHeight: (NSWindow) -> CGFloat
    private let line: NSTextField
    private let steps: WelcomeSteps
    private let button = WelcomeActionButton()
    private let back = WelcomeActionButton()
    private let background = WelcomeBackground()
    private let scroll = NSScrollView()
    private let host = WelcomeDocument()
    private let buttonWidth: NSLayoutConstraint
    private let buttonHeight: NSLayoutConstraint
    private let backWidth: NSLayoutConstraint
    private var buttonTop: NSLayoutConstraint?
    private var backMargin: NSLayoutConstraint?
    private var buttonMargin: NSLayoutConstraint?
    private var pageTops: [Page: NSLayoutConstraint] = [:]
    private var extents: [Page: CGFloat] = [:]
    private lazy var scrollTop = scroll.topAnchor.constraint(equalTo: background.topAnchor)
    private lazy var scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
    private lazy var documentHeight = host.heightAnchor.constraint(equalToConstant: 0)
    private var subscription: AnyCancellable?
    private var screens: AnyCancellable?
    private var rendered: AccessModel.Stage?

    private(set) lazy var modeCards = [WindowMode.simple, .normal].map { mode in
        ModeCard(mode: mode, title: mode == .simple ? simpleTitle : normalTitle, size: size) { [weak self] in self?.pick($0) }
    }

    private(set) lazy var toolBox = WelcomeToolBox(model: model.tools.commandLine, bundle: bundle, size: size, post: post)

    private(set) lazy var setupBox = WelcomeSetupBox(
        choices: choices, shortcut: model.tools.shortcut(), bundle: bundle, size: size,
        onLauncher: { [weak self] in self?.choices.launcher = $0 },
        onMenuBarIcon: { [weak self] in
            self?.choices.menuBarIcon = $0
            self?.choices.menuBarIconMoved = true
        },
        onTheme: { [weak self] in
            self?.choices.theme = $0
            self?.paint()
        }
    )

    private lazy var body = NSTextField.welcomeLabel(width: WelcomeMetrics.textWidth, size: size.points(WelcomeMetrics.textSize), color: Theme.systemNative.secondaryText)

    private lazy var pages: [Page: WelcomePage] = {
        let motto = String(localized: "Wherever it is, find it.", table: "Welcome", bundle: bundle)
        body.stringValue = [
            String(localized: "Wherever reads file names, sizes and dates, and in Normal mode the words inside your files. Nothing leaves your Mac.", table: "Welcome", bundle: bundle),
            String(localized: "Full Disk Access lets Wherever see every folder on this Mac, so it can find any file.", table: "Welcome", bundle: bundle),
        ].joined(separator: "\n\n")
        let modesHeading = String(localized: "Choose Your Mode", table: "Welcome", bundle: bundle)
        let pair = NSStackView(views: modeCards)
        pair.spacing = WelcomeMetrics.cardGap
        pair.translatesAutoresizingMaskIntoConstraints = false
        pair.setAccessibilityElement(true)
        pair.setAccessibilityRole(.radioGroup)
        pair.setAccessibilityLabel(modesHeading)
        pair.setAccessibilityIdentifier("welcome-modes")
        return [
            .access: WelcomePage(heading: String(localized: "Welcome to Wherever!", table: "Welcome", bundle: bundle), subtitle: motto, content: [body], size: size),
            .modes: WelcomePage(
                heading: modesHeading,
                subtitle: String(localized: "You can change it later in the View menu.", table: "Welcome", bundle: bundle), content: [pair, toolBox], size: size
            ),
            .setup: WelcomePage(
                heading: String(localized: "Set Up Wherever", table: "Welcome", bundle: bundle),
                subtitle: String(localized: "You can change these later in Settings.", table: "Welcome", bundle: bundle), content: [setupBox], size: size
            ),
            .done: WelcomePage(heading: String(localized: "You’re All Set", table: "Welcome", bundle: bundle), subtitle: motto, content: [], size: size, tick: WelcomePage.tickView()),
        ]
    }()

    init(
        model: AccessModel, bundle: Bundle, post: @escaping Announcer.Post = Announcer.voiceOver,
        visibleHeight: @escaping (NSWindow) -> CGFloat = { ($0.screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude }
    ) {
        self.model = model
        self.bundle = bundle
        self.post = post
        self.visibleHeight = visibleHeight
        choices = model.storedChoices
        returning = model.defaults.bool(forKey: AccessModel.completedKey)
        let size = TextSize.stored(model.defaults)
        self.size = size
        steps = WelcomeSteps(count: Page.allCases.count, size: size, bundle: bundle)
        line = .welcomeLabel(width: WelcomeMetrics.lineWidth, size: size.points(WelcomeMetrics.lineSize), color: Theme.welcomeWarning)
        buttonWidth = button.widthAnchor.constraint(equalToConstant: WelcomeMetrics.buttonMinWidth)
        buttonHeight = button.heightAnchor.constraint(equalToConstant: 0)
        backWidth = back.widthAnchor.constraint(equalToConstant: WelcomeMetrics.backMinWidth)
        let window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: WelcomeMetrics.width, height: WelcomeMetrics.width),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.title = String(localized: "Welcome to Wherever", table: "Welcome", bundle: bundle)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        steps.onStep = { [weak self] index in
            if let page = Page(rawValue: index) { self?.go(to: page) }
        }
        layOut(window)
        steps.isHidden = returning
        back.isHidden = returning
        paint()
        window.defaultButtonCell = button.cell as? NSButtonCell
        pick(choices.mode)
        turn(to: .access)
        subscription = model.$stage.sink { [weak self] stage in self?.render(stage) }
        screens = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: window))
            .sink { [weak self] _ in self?.fit() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        fit()
        window?.center()
        showWindow(nil)
    }

    private func layOut(_ window: NSWindow) {
        let view = background
        window.contentView = view
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.horizontalScrollElasticity = .none
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        view.addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollTop, scrollHeight, documentHeight,
            host.topAnchor.constraint(equalTo: clip.topAnchor),
            host.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])
        for page in Page.allCases {
            guard let group = pages[page] else { continue }
            host.addSubview(group)
            let top = group.topAnchor.constraint(equalTo: host.topAnchor)
            pageTops[page] = top
            NSLayoutConstraint.activate([top, group.centerXAnchor.constraint(equalTo: host.centerXAnchor)])
        }
        view.addSubview(steps)
        NSLayoutConstraint.activate([
            steps.topAnchor.constraint(equalTo: view.topAnchor),
            steps.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        for control in [back, button] {
            control.bezelStyle = .push
            control.controlSize = .large
            if let font = control.font { control.font = size.font(font) }
            control.target = self
            control.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(control)
        }
        back.title = String(localized: "Back", table: "Welcome", bundle: bundle)
        back.action = #selector(pressBack)
        back.setAccessibilityIdentifier("welcome-back")
        button.action = #selector(press)
        button.keyEquivalent = "\r"
        button.setAccessibilityIdentifier("welcome-action")
        line.setAccessibilityIdentifier("welcome-status")
        view.addSubview(line)
        let top = button.topAnchor.constraint(equalTo: view.topAnchor)
        buttonTop = top
        let leading = back.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let trailing = view.trailingAnchor.constraint(equalTo: button.trailingAnchor)
        backMargin = leading
        buttonMargin = trailing
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: WelcomeMetrics.width),
            top, buttonWidth, buttonHeight, backWidth, leading, trailing,
            back.topAnchor.constraint(equalTo: button.topAnchor),
            back.heightAnchor.constraint(equalTo: button.heightAnchor),
            line.topAnchor.constraint(equalTo: button.bottomAnchor, constant: WelcomeMetrics.buttonToLine),
            line.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private var openTitle: String { String(localized: "Open System Settings", table: "Welcome", bundle: bundle) }
    private var nextTitle: String { String(localized: "Next", table: "Welcome", bundle: bundle) }
    private var goTitle: String { String(localized: "Let's Go!", table: "Welcome", bundle: bundle) }
    private var quitTitle: String { String(localized: "Quit Wherever", table: "MenuBar", bundle: bundle) }
    private var simpleTitle: String { String(localized: "Simple", bundle: bundle) }
    private var normalTitle: String { String(localized: "Normal", bundle: bundle) }

    private func statusLine(_ stage: AccessModel.Stage) -> String {
        switch stage {
        case .waiting, .ready: String(localized: "Under Privacy & Security, Full Disk Access, turn on Wherever.", table: "Welcome", bundle: bundle)
        case .stillOff: String(localized: "Full Disk Access is still off. In System Settings > Privacy & Security > Full Disk Access, turn on this copy of Wherever.", table: "Welcome", bundle: bundle)
        case .checkFailed: String(localized: "Wherever could not check Full Disk Access. It will try again. If this continues, quit and reopen Wherever.", table: "Welcome", bundle: bundle)
        case .settingsFailed: String(localized: "System Settings could not open. Open it from the Apple menu, then choose Privacy & Security > Full Disk Access.", table: "Welcome", bundle: bundle)
        case .granted: "✓ " + String(localized: "Full Disk Access is on. Wherever is ready to start.", table: "Welcome", bundle: bundle)
        case .startFailed: String(localized: "Wherever could not start its search. Quit and reopen Wherever, then try again.", table: "Welcome", bundle: bundle)
        case .reopen: String(localized: "Quit and reopen Wherever so it can search every folder.", table: "Welcome", bundle: bundle)
        }
    }

    private func actionTitle(_ stage: AccessModel.Stage) -> String {
        switch (page, stage) {
        case (.done, _): goTitle
        case (.access, .granted) where returning: goTitle
        case (.modes, _), (.setup, _), (.access, .granted): nextTitle
        case (.access, .reopen), (.access, .startFailed): quitTitle
        case (.access, _): openTitle
        }
    }

    private func render(_ stage: AccessModel.Stage) {
        let previous = rendered
        let previousTitle = button.title
        rendered = stage
        guard stage != .ready else { return }
        steps.canMove = stage == .granted && !returning
        if stage != .granted, page != .access { turn(to: .access) }
        button.title = actionTitle(stage)
        line.textColor = stage == .granted ? Theme.welcomeGranted : Theme.welcomeWarning
        line.stringValue = statusLine(stage)
        guard let previous, previous != stage, let window else { return }
        post(window, button.title == previousTitle ? line.stringValue : line.stringValue + " " + button.title)
    }

    private func paint() {
        let theme = choices.theme
        background.theme = theme
        for group in pages.values { group.theme = theme }
        body.textColor = theme.secondaryText
        for card in modeCards { card.theme = theme }
        toolBox.theme = theme
        setupBox.theme = theme
        steps.theme = theme
    }

    private func pick(_ mode: WindowMode) {
        choices.mode = mode
        for card in modeCards { card.isOn = card.mode == mode }
    }

    private func pageControls(_ page: Page) -> [NSView] {
        switch page {
        case .access, .done: []
        case .modes: modeCards.map(\.radio) + toolBox.keyViews
        case .setup: setupBox.keyViews
        }
    }

    private func turn(to new: Page) {
        page = new
        furthest = max(furthest, new.rawValue)
        steps.page = new.rawValue
        steps.reach = furthest + 1
        if new == .setup, !choices.menuBarIconMoved {
            choices.menuBarIcon = model.defaults.object(forKey: MenuBarIcon.key) as? Bool ?? MenuBarIcon.standard
            setupBox.menuBarIcon.state = choices.menuBarIcon ? .on : .off
        }
        if new == .modes {
            let start = CACurrentMediaTime()
            for card in modeCards { card.picture.loopStart = start }
        }
        for (key, group) in pages { group.isHidden = key != new }
        line.isHidden = new != .access
        back.isEnabled = new != .access
        let controls = pageControls(new)
        let row: [NSView] = returning ? [button] : [back, button] + steps.dots
        let views = controls + row
        for (view, next) in zip(views, views.dropFirst() + views.prefix(1)) { view.nextKeyView = next }
        documentHeight.constant = extents[new] ?? 0
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let first = controls.first ?? button
        window?.initialFirstResponder = first
        window?.makeFirstResponder(nil)
        if first.canBecomeKeyView { window?.makeFirstResponder(first) }
    }

    private func fit() {
        guard let window, let view = window.contentView else { return }
        let scale = window.backingScaleFactor
        func pixels(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
        let current = button.title
        let sizes = [openTitle, nextTitle, goTitle, quitTitle].map { title -> NSSize in
            button.title = title
            return button.intrinsicContentSize
        }
        button.title = current
        let backSize = back.intrinsicContentSize
        buttonWidth.constant = pixels(max(WelcomeMetrics.buttonMinWidth, sizes.map(\.width).max() ?? 0))
        buttonHeight.constant = pixels(max(backSize.height, sizes.map(\.height).max() ?? 0))
        backWidth.constant = pixels(max(WelcomeMetrics.backMinWidth, backSize.width))
        func margins() -> CGFloat { WelcomeMetrics.width - buttonWidth.constant - (returning ? 0 : backWidth.constant + WelcomeMetrics.buttonGap) }
        if Int((margins() * scale).rounded()) % 2 != 0 {
            if returning { buttonWidth.constant += 1 / scale } else { backWidth.constant += 1 / scale }
        }
        backMargin?.constant = margins() / 2
        buttonMargin?.constant = margins() / 2
        let status = line.stringValue
        let lines = Self.stages.map { stage -> CGFloat in
            line.stringValue = statusLine(stage)
            return line.intrinsicContentSize.height
        }
        line.stringValue = status
        var groups = pages.mapValues(\.fittingSize.height)
        groups[.modes] = (groups[.modes] ?? 0) - toolBox.fittingSize.height + toolBox.tallestHeight()
        let layout = WelcomeLayout(
            minimumIconTop: steps.fit(scale: scale) + WelcomeMetrics.stepsToIcon,
            tallestGroup: groups.values.max() ?? 0,
            buttonHeight: buttonHeight.constant, tallestLine: lines.max() ?? 0, visibleHeight: visibleHeight(window), scale: scale
        )
        scrollTop.constant = layout.minimumIconTop
        scrollHeight.constant = layout.viewport
        for (page, group) in groups {
            let top = page == .access || page == .done ? layout.centredTop(ofGroup: group) : layout.iconTop
            pageTops[page]?.constant = top - layout.minimumIconTop
            extents[page] = layout.documentHeight(top: top, group: group)
        }
        documentHeight.constant = extents[page] ?? 0
        buttonTop?.constant = layout.buttonY
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - layout.height, width: WelcomeMetrics.width, height: layout.height), display: true)
        view.layoutSubtreeIfNeeded()
    }

    @objc private func press() {
        switch model.stage {
        case .granted:
            if returning {
                model.completeWelcome(choices: nil)
            } else if let next = Page(rawValue: page.rawValue + 1) {
                go(to: next)
            } else {
                model.completeWelcome(choices: choices)
            }
        case .reopen, .startFailed: model.quit()
        case .waiting, .stillOff, .checkFailed, .settingsFailed: model.openSettings()
        case .ready: break
        }
    }

    @objc private func pressBack() {
        if let before = Page(rawValue: page.rawValue - 1) { go(to: before) }
    }

    private func go(to new: Page) {
        guard model.stage == .granted, !returning, new != page, new.rawValue <= furthest + 1 else { return }
        turn(to: new)
        button.title = actionTitle(model.stage)
        if let window, let heading = pages[new]?.heading { post(window, heading) }
    }

    private func end() {
        guard model.welcome === self else { return }
        subscription = nil
        model.forgetWelcome()
    }

    func windowWillClose(_ notification: Notification) {
        end()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
        model.tools.commandLine.refresh()
    }
}
