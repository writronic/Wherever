import AppKit
import Foundation
import Quartz
import WhereverInterface

final class ThemedTable: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var stripe = NSColor.clear
    var actions = ResultActions.missing
    var hit: (Int) -> SearchHit? = { _ in nil }
    var hits: (IndexSet) -> [SearchHit] = { _ in [] }
    var readHits: (IndexSet) -> Task<[SearchHit], any Error> = { _ in Task { [] } }
    var joinedWindow: () -> Void = {}
    var searchFailed: () -> Bool = { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { joinedWindow() }
    }

    static let actionLimit = 10_000
    private var reading = false

    private var rowsTop: CGFloat = 0

    override func drawBackground(inClipRect clipRect: NSRect) {
        backgroundColor.setFill()
        clipRect.fill()
        stripe.setFill()
        if numberOfRows > 0 { rowsTop = rect(ofRow: 0).minY }
        let band = rowHeight + intercellSpacing.height
        guard band > 0 else { return }
        let first = max(0, Int(((clipRect.minY - rowsTop) / band).rounded(.down)))
        for row in first..<max(first, Int(((clipRect.maxY - rowsTop) / band).rounded(.up))) where row % 2 == 1 {
            NSRect(x: clipRect.minX, y: rowsTop + CGFloat(row) * band, width: clipRect.width, height: band).intersection(clipRect).fill()
        }
    }

    private static let typable = CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols)

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.specialKey == .f10, modifiers == .shift, let header = headerView as? ColumnHeader {
            header.openMenu()
            return
        }
        switch (event.charactersIgnoringModifiers ?? "", modifiers) {
        case ("\r", []), ("\u{3}", []): return openSelected(nil)
        case ("\r", [.command]), ("\u{3}", [.command]): return revealSelected(nil)
        case (" ", []): return toggleQuickLook(nil)
        default: break
        }
        if actions.remove != nil, Self.deletes(event, modifiers) { return delete(nil) }
        if modifiers == .command, event.specialKey == .downArrow, insideHit != nil { return showInside(nil) }
        if modifiers == .command, event.specialKey == .upArrow, actions.inside?.enclosing != nil { return goEnclosing(nil) }
        let plain = event.modifierFlags.isDisjoint(with: [.command, .control])
        let characters = event.characters ?? ""
        let typed = plain && event.specialKey == nil && !characters.isEmpty
            && characters.unicodeScalars.allSatisfy(Self.typable.contains)
        if plain, !event.modifierFlags.contains(.shift), event.specialKey == .upArrow, selectedRowIndexes == IndexSet(integer: 0),
           window?.focusSearchField() != nil { return }
        if typed || characters == "\u{1b}", let editor = window?.focusSearchField() {
            if typed || !editor.string.isEmpty { editor.keyDown(with: event) }
        } else {
            super.keyDown(with: event)
        }
    }

    static let accessibilityRowLimit = 10_000
    static let accessibilityMarginRows = 16
    private var accessibilityMargin: CGFloat = 0

    override var visibleRect: NSRect {
        accessibilityMargin == 0 ? super.visibleRect : super.visibleRect.insetBy(dx: 0, dy: -accessibilityMargin)
    }

    override func accessibilityRows() -> [any NSAccessibilityRow]? {
        guard numberOfRows > Self.accessibilityRowLimit else { return super.accessibilityRows() }
        return withAccessibilityMargin { super.accessibilityVisibleRows() }
    }

    override func accessibilitySelectedRows() -> [any NSAccessibilityRow]? {
        guard selectedRowIndexes.count > Self.accessibilityRowLimit else { return super.accessibilitySelectedRows() }
        let (range, visible) = withAccessibilityMargin { (rows(in: visibleRect), (super.accessibilityVisibleRows() ?? []) as NSArray) }
        let kept = IndexSet((0..<min(visible.count, range.length)).filter { selectedRowIndexes.contains(range.location + $0) })
        return (visible.objects(at: kept) as NSArray as! [any NSAccessibilityRow])
    }

    private func withAccessibilityMargin<T>(_ body: () -> T) -> T {
        accessibilityMargin = CGFloat(Self.accessibilityMarginRows) * (rowHeight + intercellSpacing.height)
        defer { accessibilityMargin = 0 }
        return body()
    }

    override func accessibilityChildren() -> [Any]? {
        guard numberOfRows > Self.accessibilityRowLimit else { return super.accessibilityChildren() }
        var children: [Any] = (accessibilityRows() ?? []) as NSArray as [AnyObject]
        children += accessibilityColumns() ?? []
        if let headerView { children.append(headerView) }
        return children
    }

    override func accessibilityRowCount() -> Int { numberOfRows }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let header = headerView as? ColumnHeader else { return super.accessibilityPerformShowMenu() }
        header.openMenu()
        return true
    }

    @objc func openSelected(_ sender: Any?) { open(selectedRowIndexes) }

    @objc func revealSelected(_ sender: Any?) { reveal(selectedRowIndexes) }

    @objc func openClicked(_ sender: Any?) {
        guard clickedRow >= 0 else { return }
        open(selectedRowIndexes.contains(clickedRow) ? selectedRowIndexes : IndexSet(integer: clickedRow))
    }

    func open(_ rows: IndexSet) {
        guard let rows = confirmed(rows, ask: actions.confirmOpen) else { return }
        act(on: rows) { $0.forEach(self.actions.openAndRecord) }
    }

    func reveal(_ rows: IndexSet) {
        guard let rows = confirmed(rows, ask: actions.confirmReveal) else { return }
        act(on: rows) { self.actions.reveal($0.map(\.fileURL)) }
    }

    private func confirmed(_ rows: IndexSet, ask: (Int) -> Bool) -> IndexSet? {
        guard !reading, !searchFailed(), !rows.isEmpty else { return nil }
        var asked = rows
        while asked.count >= ResultActions.askLimit {
            guard ask(asked.count) else { return nil }
            let after = selectedRowIndexes
            guard !after.isEmpty else { return nil }
            if after.count <= asked.count { return after }
            asked = after
        }
        return asked
    }

    private func act(on rows: IndexSet, _ action: @escaping ([SearchHit]) -> Void) {
        guard rows.count > Self.actionLimit else { return action(hits(rows)) }
        let read = readHits(rows)
        reading = true
        Task {
            defer { reading = false }
            do { action(try await read.value) } catch { actions.refuse() }
        }
    }

    private var firstSelected: SearchHit? { selectedRowIndexes.first.flatMap(hit) }

    private var insideHit: SearchHit? {
        guard let hit = firstSelected, actions.inside?.allows(hit) == true else { return nil }
        return hit
    }

    @objc func showInside(_ sender: Any?) {
        guard !searchFailed() else { return }
        guard let hit = insideHit else { return actions.refuse() }
        actions.inside?.enter(hit)
    }

    @objc func goEnclosing(_ sender: Any?) {
        guard let enclosing = actions.inside?.enclosing else { return actions.refuse() }
        enclosing()
    }

    @objc func toggleQuickLook(_ sender: Any?) {
        if actions.quickLook.isOpen() { return actions.quickLook.hide() }
        if !searchFailed(), let hit = firstSelected { actions.quickLook.show(actions.previewItem(hit)) }
    }

    @objc func showQuickLook(_ sender: Any?) {
        guard !searchFailed(), let hit = firstSelected else { return }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let item = actions.previewItem(hit)
        if actions.quickLook.isOpen() { actions.quickLook.refresh(item) } else { actions.quickLook.show(item) }
    }

    static let deleteItemID = "results-menu-delete"

    static func deletes(_ event: NSEvent, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        switch event.specialKey {
        case .delete?: modifiers.isEmpty || modifiers == .command
        case .deleteForward?: modifiers.isEmpty
        default: false
        }
    }

    @objc func delete(_ sender: Any?) {
        guard let remove = actions.remove, !reading, !searchFailed(), !selectedRowIndexes.isEmpty else { return actions.refuse() }
        act(on: selectedRowIndexes, remove)
        deselectAll(nil)
    }

    @objc func copy(_ sender: Any?) {
        guard let rows = confirmed(selectedRowIndexes, ask: { _ in true }) else { return }
        act(on: rows) { hits in
            let paths = hits.map(\.path)
            if !paths.isEmpty { self.actions.copyPath(paths.joined(separator: "\n")) }
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let live = !searchFailed()
        return switch item.action {
        case #selector(copy(_:)), #selector(openSelected(_:)), #selector(revealSelected(_:)), #selector(showQuickLook(_:)):
            live && firstSelected != nil
        case #selector(showInside(_:)):
            live && insideHit != nil
        case #selector(goEnclosing(_:)):
            actions.inside?.enclosing != nil
        case #selector(delete(_:)):
            live && actions.remove != nil && firstSelected != nil
        default:
            super.validateUserInterfaceItem(item)
        }
    }

    func selectionMoved() {
        guard actions.quickLook.isOpen(), !searchFailed() else { return }
        actions.quickLook.refresh(firstSelected.flatMap(actions.previewItem))
    }

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        rowIndexes.count <= Self.actionLimit && super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard hit(row) != nil else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        let menu = NSMenu()
        var items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            (String(localized: "Open", table: "Results"), #selector(openSelected(_:)), "\r", []),
            (String(localized: "Show in Finder", table: "Results"), #selector(revealSelected(_:)), "\r", [.command]),
            (String(localized: "Quick Look", table: "Results"), #selector(showQuickLook(_:)), " ", []),
            (String(localized: "Copy Path", table: "Results"), #selector(copy(_:)), "c", [.command]),
        ]
        if insideHit != nil {
            let down = String(Character(NSEvent.SpecialKey.downArrow.unicodeScalar))
            items.insert((String(localized: "Show Archive Contents", table: "Results"), #selector(showInside(_:)), down, [.command]), at: 1)
        }
        for (title, action, key, modifiers) in items {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
        }
        if let first = firstSelected { actions.moreMenu?(menu, first) }
        if actions.remove != nil {
            menu.addItem(.separator())
            let backspace = String(UnicodeScalar(UInt8(NSBackspaceCharacter)))
            let item = menu.addItem(withTitle: String(localized: "Delete", table: "Archive"), action: #selector(delete(_:)), keyEquivalent: backspace)
            item.keyEquivalentModifierMask = []
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(Self.deleteItemID)
        }
        return menu
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { firstSelected == nil ? 0 : selectedRowIndexes.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        var offset = index
        for range in selectedRowIndexes.rangeView {
            if offset < range.count { return hit(range.lowerBound + offset).flatMap(actions.previewItem).map { $0 as NSURL } }
            offset -= range.count
        }
        return nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if selectedRowIndexes.count > 1, event.specialKey == .leftArrow || event.specialKey == .rightArrow { return false }
        keyDown(with: event)
        return true
    }
}

final class PressSelect: NSGestureRecognizer {
    override func mouseDown(with event: NSEvent) {
        if let table = view as? NSTableView, event.modifierFlags.isDisjoint(with: [.command, .shift, .control]) {
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            if row >= 0, !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        }
        state = .failed
    }
}
