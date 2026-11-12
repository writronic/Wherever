import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WhereverInterface

struct SearchFolderBox: View {
    static let id = "search-folder"

    enum Choice {
        case everyDisk
        case path(String)
        case notIndexed(IndexedVolume)
    }

    @Binding var folder: String?
    let bundle: Bundle
    private let store: UserDefaults?
    private var client: (any SearchClient)?
    private let confirmIndex: @MainActor (IndexedVolume) -> Bool
    private let chooseFolder: @MainActor (URL?) -> URL?
    private let beep: @MainActor () -> Void
    let icon: AppIconLoader
    @Environment(\.searchClient) private var environmentClient

    init(
        folder: Binding<String?>, bundle: Bundle = .main, store: UserDefaults? = nil, client: (any SearchClient)? = nil,
        confirmIndex: @escaping @MainActor (IndexedVolume) -> Bool = SearchFolderBox.askToIndex,
        chooseFolder: @escaping @MainActor (URL?) -> URL? = SearchFolderBox.openPanel,
        beep: @escaping @MainActor () -> Void = { NSSound.beep() },
        icon: @escaping AppIconLoader = ResultsTable.liveAppIcon
    ) {
        _folder = folder
        self.bundle = bundle
        self.store = store
        self.client = client
        self.confirmIndex = confirmIndex
        self.chooseFolder = chooseFolder
        self.beep = beep
        self.icon = icon
    }

    var body: some View {
        var owner = self
        owner.client = disks
        return FolderMenuField(owner: owner).onDrop(of: [.fileURL], isTargeted: nil, perform: drop)
    }

    private var disks: any SearchClient { client ?? environmentClient }

    static func scope(_ text: String) -> String? {
        let path = text.filter { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    func choices() -> [(title: String, choice: Choice)] {
        let volumes = (try? disks.volumes()) ?? []
        let indexed = volumes.filter { $0.indexed && !LocationsModel.covered($0, store ?? .standard) }
        return [
            (String(localized: "Every indexed disk", table: "Normal", bundle: bundle), .everyDisk),
            (FileManager.default.displayName(atPath: "/"), .path("/")),
        ]
            + indexed.map { ($0.name, .path($0.path)) }
            + volumes.filter { !indexed.contains($0) }.map { volume in
                let title = volume.indexable
                    ? String(localized: "\(Bidi.name(volume.name)) (Not indexed)", table: "Normal", bundle: bundle)
                    : String(localized: "\(Bidi.name(volume.name)) (Can’t be indexed)", table: "Normal", bundle: bundle)
                return (title, .notIndexed(volume))
            }
    }

    func commit(_ choice: Choice) {
        switch choice {
        case .everyDisk: folder = nil
        case let .path(path): folder = path
        case let .notIndexed(volume):
            index(volume)
            folder = volume.path
        }
    }

    func accept(_ url: URL) -> Bool {
        let path = url.path
        guard url.isFileURL, !path.contains("\n"), Self.isDirectory(path) else { return false }
        if let ignored = ((try? disks.volumes()) ?? []).first(where: { !$0.indexed && (path == $0.path || path.hasPrefix($0.path + "/")) }) {
            index(ignored)
        }
        folder = path
        return true
    }

    func browse() -> Bool {
        let start = folder.flatMap { $0.hasPrefix("/") && Self.isDirectory($0) ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        guard let url = chooseFolder(start) else { return false }
        return accept(url)
    }

    private func index(_ volume: IndexedVolume) {
        guard volume.indexable, !LocationsModel.covered(volume, store ?? .standard), confirmIndex(volume) else { return }
        try? LocationsModel.setIndexed(volume.id, true, client: disks, defaults: store ?? .standard)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            Task { @MainActor in
                if let url, accept(url) { return }
                beep()
            }
        }
        return true
    }

    static func openPanel(at directory: URL?) -> URL? {
        guard !WhereverApp.usesPreviewServices else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.prompt = String(localized: "Choose", table: "Normal")
        panel.message = String(localized: "Choose a folder to search in", table: "Normal")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func askToIndex(_ volume: IndexedVolume) -> Bool {
        guard !WhereverApp.usesPreviewServices else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Index “\(Bidi.name(volume.name))”?", table: "Normal")
        alert.informativeText = String(
            localized: "Wherever reads every file name on this disk before it can search it. A large disk can take several minutes. To ignore it again, add it to Excluded Paths in Settings.",
            table: "Normal"
        )
        alert.addButton(withTitle: String(localized: "Index", table: "Normal"))
        alert.addButton(withTitle: String(localized: "Cancel", table: "Normal")).keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct FolderMenuField: NSViewRepresentable {
    let owner: SearchFolderBox
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FormFolderField {
        let box = FormFolderField()
        box.placeholderString = String(localized: "Every indexed disk", table: "Normal", bundle: owner.bundle)
        let label = String(localized: "Search folder:", table: "Normal", bundle: owner.bundle)
        box.identifier = NSUserInterfaceItemIdentifier(SearchFolderBox.id)
        box.setAccessibilityIdentifier(SearchFolderBox.id)
        box.setAccessibilityLabel(label)
        box.cell?.setAccessibilityIdentifier(SearchFolderBox.id)
        box.cell?.setAccessibilityLabel(label)
        box.chevron.identifier = NSUserInterfaceItemIdentifier("search-folder-menu")
        box.chevron.setAccessibilityIdentifier("search-folder-menu")
        let disk = String(localized: "Choose a disk", table: "Normal", bundle: owner.bundle)
        box.chevron.setAccessibilityLabel(disk)
        box.chevron.cell?.setAccessibilityIdentifier("search-folder-menu")
        box.chevron.cell?.setAccessibilityLabel(disk)
        box.stringValue = owner.folder ?? ""
        box.delegate = context.coordinator
        box.target = context.coordinator
        box.action = #selector(Coordinator.typed)
        box.diskMenu.delegate = context.coordinator
        context.coordinator.owner = owner
        context.coordinator.box = box
        return box
    }

    func updateNSView(_ box: FormFolderField, context: Context) {
        context.coordinator.owner = owner
        let font = textSize.font(.systemFont(ofSize: NSFont.systemFontSize))
        if box.font != font { box.font = font }
        if box.diskMenu.font != font { box.diskMenu.font = font }
        box.isEnabled = context.environment.isEnabled
        box.chevron.isEnabled = box.isEnabled
        box.userInterfaceLayoutDirection = context.environment.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        box.diskMenu.userInterfaceLayoutDirection = box.userInterfaceLayoutDirection
        box.needsLayout = true
        let text = owner.folder ?? ""
        let shown = Coordinator.text(of: box)
        guard shown != text, box.currentEditor() == nil || SearchFolderBox.scope(shown) != owner.folder else { return }
        Coordinator.show(text, in: box)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, NSMenuDelegate {
        var owner: SearchFolderBox?
        weak var box: FormFolderField?
        private var items: [(title: String, choice: SearchFolderBox.Choice)] = []
        private var icons: [String: CGImage] = [:]
        private var requested: Set<String> = []

        static func text(of box: NSTextField) -> String { box.currentEditor()?.string ?? box.stringValue }

        static func show(_ text: String, in box: NSTextField) {
            box.stringValue = text
            box.currentEditor()?.string = text
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let owner else { return }
            items = owner.choices()
            menu.removeAllItems()
            var ignoredSection = false
            for (index, entry) in items.enumerated() {
                let path: String?
                switch entry.choice {
                case .everyDisk: path = nil
                case let .path(value): path = value
                case let .notIndexed(volume):
                    if !ignoredSection {
                        menu.addItem(.separator())
                        ignoredSection = true
                    }
                    path = volume.path
                }
                if index == 1 { menu.addItem(.separator()) }
                let item = NSMenuItem(title: entry.title, action: #selector(picked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.identifier = NSUserInterfaceItemIdentifier(Self.itemID(path ?? "every-disk"))
                item.setAccessibilityIdentifier(item.identifier?.rawValue)
                item.state = owner.folder == path ? .on : .off
                if let path { item.image = icon(path, in: menu) }
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let browse = NSMenuItem(title: String(localized: "Browse…", table: "Normal", bundle: owner.bundle), action: #selector(browse), keyEquivalent: "")
            browse.target = self
            browse.identifier = NSUserInterfaceItemIdentifier("search-folder-item-browse")
            browse.setAccessibilityIdentifier("search-folder-item-browse")
            menu.addItem(browse)
        }

        static func itemID(_ path: String) -> String { "search-folder-item-" + path }

        private func icon(_ path: String, in menu: NSMenu) -> NSImage? {
            if let found = icons[path] {
                let side = ceil(menu.font.ascender - menu.font.descender)
                return NSImage(cgImage: found, size: NSSize(width: side, height: side))
            }
            if let owner, requested.insert(path).inserted {
                let load = owner.icon
                Task.detached(priority: .userInitiated) { [weak self] in
                    let image = load(path)
                    await self?.finish(path, image)
                }
            }
            return NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: menu.font.pointSize, weight: .regular))
        }

        private func finish(_ path: String, _ image: CGImage?) {
            guard let image else { return }
            icons[path] = image
            guard let menu = box?.diskMenu else { return }
            for item in menu.items where item.identifier?.rawValue == Self.itemID(path) { item.image = icon(path, in: menu) }
        }

        @objc func browse() {
            guard let owner, let box, owner.browse() else { return }
            Self.show(owner.folder ?? "", in: box)
        }

        @objc func picked(_ item: NSMenuItem) {
            guard let owner, let box, items.indices.contains(item.tag) else { return }
            owner.commit(items[item.tag].choice)
            Self.show(owner.folder ?? "", in: box)
        }

        @objc func typed() {
            guard let box, let owner else { return }
            let scope = SearchFolderBox.scope(Self.text(of: box))
            if owner.folder != scope { owner.folder = scope }
        }

        func controlTextDidChange(_ notification: Notification) { typed() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
                box?.showDiskMenu()
                return true
            default: return false
            }
        }
    }
}

final class FormFolderField: NSTextField {
    let icon = FormIcon("folder")
    let chevron = ComboTile()
    let diskMenu = NSMenu()

    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = FolderFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        isBezeled = true
        bezelStyle = .roundedBezel
        controlSize = .large
        Availability.roundedRectangle(self)
        drawsBackground = true
        cell?.isScrollable = true
        diskMenu.autoenablesItems = false
        chevron.contentTintColor = .labelColor
        chevron.imagePosition = .imageOnly
        chevron.isBordered = false
        chevron.refusesFirstResponder = true
        chevron.target = self
        chevron.action = #selector(showDiskMenu)
        addSubview(icon)
        addSubview(chevron)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NormalMetrics.controlHeight) }

    override func layout() {
        super.layout()
        chevron.place(in: self)
        icon.place(in: self)
    }

    @objc func showDiskMenu() {
        guard isEnabled else { return }
        let x = userInterfaceLayoutDirection == .rightToLeft ? bounds.maxX : bounds.minX
        diskMenu.popUp(positioning: nil, at: NSPoint(x: x, y: isFlipped ? bounds.maxY : bounds.minY), in: self)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard isEnabled else { return false }
        showDiskMenu()
        return true
    }
}

final class FormIcon: NSImageView {
    let symbol: String
    private(set) var pointSize: CGFloat = 0

    init(_ symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        contentTintColor = .secondaryLabelColor
        imageScaling = .scaleNone
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func place(in field: NSTextField) {
        let font = field.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        if pointSize != font.pointSize {
            pointSize = font.pointSize
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        }
        frame = NormalMetrics.formRects(field.bounds, font: font, size: field.controlSize, direction: field.userInterfaceLayoutDirection).icon
    }
}

final class ComboTile: NSButton {
    private(set) var pointSize: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NormalMetrics.comboFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: NormalMetrics.comboRadius, yRadius: NormalMetrics.comboRadius).fill()
        super.draw(dirtyRect)
    }

    func place(in field: NSTextField) {
        let size = (field.font ?? .systemFont(ofSize: NSFont.systemFontSize)).pointSize - 2
        if pointSize != size {
            pointSize = size
            image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .bold))
        }
        let edge: CGRectEdge = field.userInterfaceLayoutDirection == .rightToLeft ? .minXEdge : .maxXEdge
        frame = field.bounds.insetBy(dx: 0, dy: NormalMetrics.comboInset)
            .divided(atDistance: NormalMetrics.comboInset, from: edge).remainder
            .divided(atDistance: NormalMetrics.comboWidth, from: edge).slice
    }
}

private final class FolderFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let direction = controlView?.userInterfaceLayoutDirection ?? .leftToRight
        let line = NormalMetrics.formRects(rect, font: font, size: controlSize, direction: direction).text
        let edge: CGRectEdge = direction == .rightToLeft ? .minXEdge : .maxXEdge
        return line.intersection(rect.divided(atDistance: NormalMetrics.comboTextGap, from: edge).remainder)
    }
}
