import AppKit
import Combine
import Foundation
import SwiftUI
import WhereverInterface

enum LauncherMetrics {
    static let width: CGFloat = 750
    static let maxRows = 10
    static let screenMargin: CGFloat = 20
    static let cornerRadius: CGFloat = 26
    static let hairline: CGFloat = 1
    static let fieldHeight: CGFloat = 44
    static let fieldFontSize: CGFloat = 20
    static let fieldTop: CGFloat = 10
    static let fieldSide: CGFloat = 16
    static let fieldIcon: CGFloat = 22
    static let fieldGap: CGFloat = 12
    static let listSide: CGFloat = 8
    static let listTop: CGFloat = 4
    static let listBottom: CGFloat = 8
    static let cellPadding: CGFloat = 8
    static let iconSize: CGFloat = fieldIcon
    static let iconGap: CGFloat = 10
    static let rowInset: CGFloat = 8
    static let rowRadius: CGFloat = 10
    static func rowHeight(_ size: TextSize) -> CGFloat { max(iconSize, ceil(size.lineHeight(.preferredFont(forTextStyle: .body)))) + 2 * rowInset }
    static var bandHeight: CGFloat { fieldTop + fieldHeight }
    static var barBottomInset: CGFloat { max(SearchMetrics.statusVerticalInset, ceil(cornerRadius * (1 - 1 / sqrt(2)))) }
    static func barHeight(_ size: TextSize) -> CGFloat { hairline + StatusBarView.launcherLineHeight(size) + SearchMetrics.statusVerticalInset + barBottomInset }
    static func sentenceHeight(_ size: TextSize, width: CGFloat) -> CGFloat {
        let lines = StatusBarView.lineCount(StatusBarView.text(.failed), font: StatusBarView.font(size), width: width - 2 * fieldSide)
        return CGFloat(lines) * StatusBarView.launcherLineHeight(size)
    }

    static func aligned(_ value: CGFloat, scale: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

    static func top(in visible: NSRect, scale: CGFloat) -> CGFloat { aligned(visible.maxY - visible.height / 5, scale: scale) }

    static func panelWidth(in visible: NSRect, scale: CGFloat) -> CGFloat { aligned(min(Self.width, visible.width - 2 * screenMargin), scale: scale) }

    static func frame(in visible: NSRect, scale: CGFloat, height: CGFloat) -> NSRect {
        let width = panelWidth(in: visible, scale: scale)
        let height = aligned(height, scale: scale)
        let x = aligned(visible.midX - width / 2, scale: scale)
        return NSRect(x: x, y: top(in: visible, scale: scale) - height, width: width, height: height)
    }

    static func rows(_ count: Int, room: CGFloat, rowHeight: CGFloat) -> Int {
        min(count, maxRows, max(1, Int((room / rowHeight).rounded(.down))))
    }

    static func screen(at point: NSPoint, in screens: [NSScreen]) -> NSScreen? {
        screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}

final class LauncherPanel: NSPanel {
    var onClose: () -> Void = {}
    var onLostKey: (NSWindow?) -> Void = { _ in }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: LauncherMetrics.width, height: LauncherMetrics.bandHeight + LauncherMetrics.barHeight(.standard)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        identifier = NSUserInterfaceItemIdentifier(Launcher.id)
        title = String(localized: "Wherever", table: "MenuBar")
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        autorecalculatesKeyViewLoop = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) { onClose() }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(performClose(_:)) || super.validateMenuItem(menuItem)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, event.charactersIgnoringModifiers == "w" else {
            return super.performKeyEquivalent(with: event)
        }
        performClose(nil)
        return true
    }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in self?.onLostKey(NSApp.keyWindow) }
    }
}

final class Launcher: ObservableObject {
    static let id = "launcher"
    static let opacityKey = "launcherOpacity"
    static let standardOpacity = 30
    static let listID = "launcher-list"
    static let emptyID = "launcher-empty"
    static let failedID = "launcher-search-failed"
    static let showAllID = "launcher-show-all"

    var showAll: () -> Void = {}

    @Published private(set) var listHeight: CGFloat = 0
    @Published private(set) var previewShown = false
    @Published private(set) var previewURL: URL?

    let index: IndexModel
    private let base: ResultActions
    private let defaults: UserDefaults
    private let isRecording: () -> Bool
    private let activate: () -> Void
    private let hidden: () -> Void
    private(set) lazy var model = index.makeModel()
    private(set) lazy var actions = makeActions()
    private(set) var panel: LauncherPanel?
    weak var table: NSTableView?
    private var placement: (visible: NSRect, scale: CGFloat)?
    private var failureWatch: AnyCancellable?

    init(
        index: IndexModel, actions: ResultActions, defaults: UserDefaults = .standard, isRecording: @escaping () -> Bool = { false },
        activate: @escaping () -> Void = {}, hidden: @escaping () -> Void = {}
    ) {
        self.index = index
        base = actions
        self.defaults = defaults
        self.isRecording = isRecording
        self.activate = activate
        self.hidden = hidden
        failureWatch = index.$indexState.map { $0?.bootPhase == .failed }.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fit() }
    }

    func toggle() {
        guard !isRecording() else { return }
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        placement = LauncherMetrics.screen(at: NSEvent.mouseLocation, in: NSScreen.screens).map { (visible: $0.visibleFrame, scale: $0.backingScaleFactor) }
        fit()
        panel.makeKeyAndOrderFront(nil)
        panel.focusSearchField()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        previewShown = false
        previewURL = nil
        model.query = ""
        hidden()
    }

    func prepareHandOff() {
        guard panel?.isVisible == true else { return }
        index.nextQuery = model.query
        hide()
    }

    func keyMoved(to key: NSWindow?) {
        if key !== panel { hide() }
    }

    func fit() {
        guard let panel, let placement else { return }
        if previewShown, (table?.selectedRow ?? -1) < 0 {
            previewShown = false
            previewURL = nil
        }
        let size = TextSize.stored(defaults)
        let rowHeight = LauncherMetrics.rowHeight(size)
        let sentence = index.indexState?.bootPhase == .failed
            ? LauncherMetrics.sentenceHeight(size, width: LauncherMetrics.panelWidth(in: placement.visible, scale: placement.scale)) : 0
        let fixed = LauncherMetrics.bandHeight + LauncherMetrics.barHeight(size) + sentence + (SearchModel.holdsWord(model.query) ? rowHeight : 0)
        let room = LauncherMetrics.top(in: placement.visible, scale: placement.scale) - placement.visible.minY
            - LauncherMetrics.screenMargin - fixed - LauncherMetrics.listTop - LauncherMetrics.listBottom
        let shown = { (count: Int) in CGFloat(LauncherMetrics.rows(count, room: room, rowHeight: rowHeight)) * rowHeight + LauncherMetrics.listTop + LauncherMetrics.listBottom }
        let results = model.results
        var list: CGFloat = if results.generation == nil { model.failed ? shown(1) : 0 } else if results.count == 0 { shown(1) } else { shown(results.count) }
        if previewShown { list = max(list, shown(LauncherMetrics.maxRows)) }
        if list != listHeight { listHeight = list }
        panel.setFrame(LauncherMetrics.frame(in: placement.visible, scale: placement.scale, height: fixed + list), display: true)
    }

    private func makePanel() -> LauncherPanel {
        let panel = LauncherPanel()
        panel.onClose = { [weak self] in self?.hide() }
        panel.onLostKey = { [weak self] in self?.keyMoved(to: $0) }
        let content = NSHostingView(rootView: LauncherView(launcher: self, model: model)
            .environment(\.resultActions, actions)
            .defaultAppStorage(defaults))
        content.sizingOptions = []
        let container = LauncherSurface(frame: panel.contentRect(forFrameRect: panel.frame))
        container.wantsLayer = true
        container.layer?.cornerRadius = LauncherMetrics.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        for view in [Availability.launcherBackground(cornerRadius: LauncherMetrics.cornerRadius), content] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        panel.contentView = container
        self.panel = panel
        return panel
    }

    private func makeActions() -> ResultActions {
        var actions = base
        let base = base
        actions.open = { [weak self] in
            base.open($0)
            self?.hide()
        }
        actions.reveal = { [weak self] in
            base.reveal($0)
            self?.hide()
        }
        actions.quickLook = ResultActions.QuickLook(
            isOpen: { [weak self] in self?.previewShown ?? false },
            show: { [weak self] in self?.preview($0) },
            hide: { [weak self] in self?.preview(nil) },
            refresh: { [weak self] url in
                guard let self, previewShown else { return }
                previewURL = url
            }
        )
        actions.inside = base.inside.map { inside in
            ResultActions.Inside(allows: inside.allows, enter: { [weak self] hit in
                self?.activate()
                self?.hide()
                inside.enter(hit)
            })
        }
        return actions
    }

    private func preview(_ url: URL?) {
        previewShown = url != nil
        previewURL = url
        fit()
    }
}

private final class LauncherSurface: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        outline()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        outline()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        outline()
    }

    private func outline() {
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (effectiveAppearance.isHighContrast ? NSColor.labelColor : NSColor.separatorColor).cgColor
        }
    }
}

extension NSAppearance {
    var isHighContrast: Bool {
        bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .accessibilityHighContrastAqua || $0 == .accessibilityHighContrastDarkAqua } == true
    }
}
