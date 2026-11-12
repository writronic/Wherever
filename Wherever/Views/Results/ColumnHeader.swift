import AppKit
import Foundation

final class ColumnHeader: NSTableHeaderView, NSMenuDelegate {
    private let preferences: ColumnPreferences

    init(preferences: ColumnPreferences, frame: NSRect) {
        self.preferences = preferences
        super.init(frame: frame)
        setAccessibilityIdentifier("results.columns")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for column in ResultsTable.Column.allCases where column != .name {
            let item = menu.addItem(withTitle: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.identifier = NSUserInterfaceItemIdentifier("results.columns.\(column.rawValue)")
            item.setAccessibilityIdentifier("results.columns.\(column.rawValue)")
        }
        menu.addItem(.separator())
        let folders = menu.addItem(withTitle: String(localized: "Keep Folders on Top", table: "Results"), action: #selector(toggleFolders(_:)), keyEquivalent: "")
        folders.target = self
        folders.identifier = NSUserInterfaceItemIdentifier("results.columns.foldersFirst")
        folders.setAccessibilityIdentifier("results.columns.foldersFirst")
        self.menu = menu
        menuNeedsUpdate(menu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem {
            if let raw = item.representedObject as? String, let column = ResultsTable.Column(rawValue: raw) {
                item.state = preferences.shown.contains(column) ? .on : .off
            } else {
                item.state = preferences.foldersFirst ? .on : .off
            }
        }
    }

    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let column = ResultsTable.Column(rawValue: raw), column != .name else { return }
        if preferences.shown.contains(column) { preferences.shown.remove(column) } else { preferences.shown.insert(column) }
        if let menu { menuNeedsUpdate(menu) }
    }

    @objc private func toggleFolders(_ sender: Any?) {
        preferences.foldersFirst.toggle()
        if let menu { menuNeedsUpdate(menu) }
    }

    override func accessibilityPerformShowMenu() -> Bool {
        openMenu()
        return true
    }

    func openMenu() {
        guard let menu else { return }
        menuNeedsUpdate(menu)
        let x = userInterfaceLayoutDirection == .rightToLeft ? visibleRect.maxX : visibleRect.minX
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: visibleRect.maxY), in: self)
    }
}
