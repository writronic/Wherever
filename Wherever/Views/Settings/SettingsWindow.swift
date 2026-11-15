import AppKit
import Combine
import SwiftUI
import WhereverInterface

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, locations, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General", table: "Settings")
        case .locations: String(localized: "Locations", table: "Settings")
        case .about: String(localized: "About", table: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .locations: "externaldrive"
        case .about: "info.circle"
        }
    }

    var rowID: String { "settings-row-\(rawValue)" }
    var paneID: String { "settings-pane-\(rawValue)" }
}

final class EscapeClosingWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        event.keyCode == 53 ? cancelOperation(nil) : super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

final class SettingsWindow: NSWindowController, NSToolbarDelegate {
    enum Metrics {
        static let size = NSSize(width: 978, height: 604)
        static let minSize = NSSize(width: 850, height: 525)
        static let sidebarWidth: CGFloat = 240
        static let detailWidth = size.width - sidebarWidth
        static let rowFontSize: CGFloat = 14
        static let rowIconWidth: CGFloat = 24
        static let standardRowHeight: CGFloat = 24
        static let sidebarTopMargin: CGFloat = 12
        static let captionSpacing: CGFloat = 4
        static let sliderTrackWidth: CGFloat = 240
        static let sliderLabelSpacing: CGFloat = 8
        static let labelToTiles: CGFloat = 12

        static func rowHeight(_ size: TextSize) -> CGFloat {
            let font = NSFont.systemFont(ofSize: rowFontSize)
            return standardRowHeight + ceil(size.lineHeight(font)) - ceil(TextSize.standard.lineHeight(font))
        }
    }

    final class Selection: ObservableObject {
        @Published var pane: SettingsPane = .general
    }

    let selection = Selection()
    let split = NSSplitViewController()
    var reset: @MainActor () async throws -> Void = {}
    var reopen: @MainActor () throws -> Void = {}
    private let activate: @MainActor () -> Void
    private let dialogs: ModalWindowCoordinator
    private let buildWindow: (SettingsWindow) -> Void
    private var placed = false
    private var titling: AnyCancellable?
    private static let trackingID = NSToolbarItem.Identifier("settings-sidebar-tracking")

    init(
        launchAtLogin: LaunchAtLoginModel, locations: LocationsModel, hotkey: HotkeyModel, client: any SearchClient,
        updates: UpdatesModel = .idle, commandLine: CommandLineToolModel = .inert(), defaults: UserDefaults = .standard, open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        activate: @escaping @MainActor () -> Void = Availability.activateApp, dialogs: ModalWindowCoordinator = .shared
    ) {
        self.activate = activate
        self.dialogs = dialogs
        buildWindow = { controller in
            let window = EscapeClosingWindow(
                contentRect: NSRect(origin: .zero, size: Metrics.size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("settings")
            window.autorecalculatesKeyViewLoop = true
            controller.window = window

            let toolbar = NSToolbar(identifier: "settings-toolbar")
            toolbar.delegate = controller
            window.toolbar = toolbar
            window.toolbarStyle = .unified

            let sidebar = NSHostingController(rootView: SettingsSidebar(selection: controller.selection).defaultAppStorage(defaults))
            sidebar.sizingOptions = []
            let detail = NSHostingController(rootView: SettingsDetail(
                selection: controller.selection, launchAtLogin: launchAtLogin, locations: locations, hotkey: hotkey, client: client, updates: updates, commandLine: commandLine, open: open,
                reset: { [weak controller] in try await controller?.reset() },
                files: SettingsFileIO(defaults: defaults, reopen: { [weak controller] in try controller?.reopen() })
            ).defaultAppStorage(defaults))
            detail.sizingOptions = []
            let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
            sidebarItem.canCollapse = false
            sidebarItem.minimumThickness = Metrics.sidebarWidth
            sidebarItem.maximumThickness = Metrics.sidebarWidth
            sidebarItem.allowsFullHeightLayout = true
            controller.split.splitViewItems = [sidebarItem, NSSplitViewItem(viewController: detail)]
            window.contentViewController = controller.split
            window.setContentSize(Metrics.size)
            window.minSize = Metrics.minSize
            let added = window.minSize.height - Metrics.minSize.height
            window.minSize.height = Metrics.minSize.height - added

            controller.titling = controller.selection.$pane.sink { [weak window] pane in window?.title = pane.title }
        }
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        itemIdentifier == Self.trackingID ? NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: split.splitView, dividerIndex: 0) : nil
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.trackingID] }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.trackingID] }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { selection.pane = pane }
        if window == nil { buildWindow(self) }
        showWindow(nil)
        if !placed, let window { place(window) }
        if let window { dialogs.register(window) }
        activate()
    }

    private func place(_ window: NSWindow) {
        placed = true
        guard let screen = NSApp.windows.first(where: MainWindow.isMain)?.screen ?? NSScreen.main else { return window.center() }
        let visible = screen.visibleFrame
        let snap = { (value: CGFloat) in (value * screen.backingScaleFactor).rounded() / screen.backingScaleFactor }
        window.setFrameOrigin(NSPoint(x: snap(visible.midX - window.frame.width / 2), y: snap(visible.midY - window.frame.height / 2)))
    }
}

private struct SettingsSidebar: View {
    @ObservedObject var selection: SettingsWindow.Selection
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        List(SettingsPane.allCases, selection: $selection.pane) { pane in
            Label {
                Text(pane.title).font(textSize.font(size: SettingsWindow.Metrics.rowFontSize))
            } icon: {
                Image(systemName: pane.symbol).frame(width: SettingsWindow.Metrics.rowIconWidth).accessibilityHidden(true)
            }
            .font(.system(size: SettingsWindow.Metrics.rowFontSize))
            .imageScale(.large)
            .frame(height: SettingsWindow.Metrics.rowHeight(textSize))
            .accessibilityIdentifier(pane.rowID)
            .tag(pane)
        }
        .listStyle(.sidebar)
        .scrollContentTopMargin(SettingsWindow.Metrics.sidebarTopMargin)
        .environment(\.sidebarRowSize, .medium)
        .accessibilityIdentifier("settings-sidebar")
    }
}

private struct SettingsDetail: View {
    @ObservedObject var selection: SettingsWindow.Selection
    let launchAtLogin: LaunchAtLoginModel
    let locations: LocationsModel
    let hotkey: HotkeyModel
    let client: any SearchClient
    let updates: UpdatesModel
    let commandLine: CommandLineToolModel
    let open: (URL) -> Void
    let reset: @MainActor () async throws -> Void
    let files: SettingsFileIO

    var body: some View {
        Group {
            switch selection.pane {
            case .general: GeneralPane(launchAtLogin: launchAtLogin, hotkey: hotkey, reset: reset, files: files, updates: updates, commandLine: commandLine).environment(\.searchClient, client)
            case .locations: LocationsPane(model: locations)
            case .about: AboutPane(open: open)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(selection.pane.paneID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
