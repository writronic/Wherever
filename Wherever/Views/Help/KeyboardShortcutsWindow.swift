import AppKit
import Combine
import SwiftUI

final class KeyboardShortcutsWindow: NSWindowController {
    static let windowID = "keyboard-shortcuts"
    static let tableID = "keyboard-shortcuts-table"

    static func rowID(section: Int, row: Int) -> String { "keyboard-shortcuts-row-\(section)-\(row)" }

    private static var shared: KeyboardShortcutsWindow?

    static func show(hotkey: HotkeyModel) {
        let window = shared ?? KeyboardShortcutsWindow(hotkey: hotkey, defaults: .standard)
        shared = window
        window.show()
    }

    private let dialogs: ModalWindowCoordinator
    private let measure: () -> CGSize
    private let visibleFrame: @MainActor (NSWindow) -> NSRect?
    private let scroll: NSScrollView
    private var placed = false
    private var watch: TextSizeWatch?
    private var screens: AnyCancellable?

    init(
        hotkey: HotkeyModel, defaults: UserDefaults, dialogs: ModalWindowCoordinator = .shared,
        visibleFrame: @escaping @MainActor (NSWindow) -> NSRect? = { ($0.screen ?? NSScreen.main)?.visibleFrame }
    ) {
        self.dialogs = dialogs
        self.visibleFrame = visibleFrame
        let host = NSHostingController(rootView: KeyboardShortcutsView(hotkey: hotkey).fixedSize().defaultAppStorage(defaults))
        host.sizingOptions = []
        measure = { host.sizeThatFits(in: .zero) }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = host.view
        self.scroll = scroll
        let window = EscapeClosingWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = scroll
        window.title = String(localized: "Keyboard Shortcuts", table: "Help")
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowID)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        fit()
        watch = TextSizeWatch(defaults) { [weak self] in self?.fit() }
        screens = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: window))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.fit() } }
    }

    private func fit() {
        guard let window, let document = scroll.documentView else { return }
        let fit = measure()
        let scale = window.backingScaleFactor
        let content = NSSize(width: (fit.width * scale).rounded(.up) / scale, height: (fit.height * scale).rounded(.up) / scale)
        document.setFrameSize(content)
        var size = window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
        let frame = window.frame
        var top = frame.maxY
        if let visible = visibleFrame(window) {
            let room = (visible.height * scale).rounded(.down) / scale
            if size.height > room {
                let scrolling = NSScrollView.frameSize(
                    forContentSize: content, horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self,
                    borderType: .noBorder, controlSize: .regular, scrollerStyle: scroll.scrollerStyle
                )
                size = NSSize(width: window.frameRect(forContentRect: NSRect(origin: .zero, size: scrolling)).width, height: room)
            }
            if placed { top = (min(max(top, visible.minY + size.height), visible.maxY) * scale).rounded(.down) / scale }
        }
        window.setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        if !placed, let window {
            window.center()
            placed = true
            fit()
        }
        showWindow(nil)
        if let window { dialogs.register(window) }
    }
}

struct KeyboardShortcutsView: View {
    @ObservedObject var hotkey: HotkeyModel
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    enum Metrics {
        static let side: CGFloat = 20
        static let columnGap: CGFloat = 32
        static let sectionGap: CGFloat = 20
        static let titleToRows: CGFloat = 8
        static let rowGap: CGFloat = 6
        static let cellGap: CGFloat = 12
        static let keysWidth: CGFloat = 96
        static let keysMinimumScale: CGFloat = 0.6
        static let exampleWidth: CGFloat = 150
        static let actionWidth: CGFloat = 250
    }

    var body: some View {
        let sections = KeyboardShortcuts.sections(hotkey: hotkey.hotkey)
        HStack(alignment: .top, spacing: Metrics.columnGap) {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                ForEach(sections.indices.dropLast(), id: \.self) { section(sections, $0, keysWidth: textSize.width(Metrics.keysWidth)) }
            }
            if let last = sections.indices.last { section(sections, last, keysWidth: textSize.width(Metrics.exampleWidth)) }
        }
        .padding(Metrics.side)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(KeyboardShortcutsWindow.tableID)
    }

    static func keysText(_ keys: String, font: Font) -> some View {
        Text(verbatim: Bidi.path(keys)).font(font).accessibilityLabel(Text(verbatim: keys))
    }

    private func section(_ sections: [ShortcutSection], _ index: Int, keysWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Metrics.titleToRows) {
            Text(verbatim: sections[index].title)
                .font(textSize.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Metrics.rowGap) {
                ForEach(sections[index].rows.indices, id: \.self) { row in
                    let item = sections[index].rows[row]
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.cellGap) {
                        Self.keysText(item.keys, font: textSize.monospacedBody)
                            .lineLimit(1)
                            .minimumScaleFactor(Metrics.keysMinimumScale)
                            .frame(width: keysWidth, alignment: .leading)
                        Text(verbatim: item.action)
                            .font(textSize.formText)
                            .foregroundStyle(.secondary)
                            .frame(width: textSize.width(Metrics.actionWidth), alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(KeyboardShortcutsWindow.rowID(section: index, row: row))
                }
            }
        }
    }
}
