import AppKit
import Combine
import Foundation
import SwiftUI
import WhereverInterface

struct SearchField: NSViewRepresentable {
    let model: SearchModel
    var bundle: Bundle = .main
    var fontSize = SearchMetrics.searchFontSize
    var accessibilityLabel: String?
    var placeholder: String?
    var onEmptyEscape: (() -> Void)?
    var roundedRectangle = false
    var height: CGFloat?
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onEmptyEscape: onEmptyEscape) }

    func makeNSView(context: Context) -> FocusedSearchField {
        let field = FocusedSearchField()
        if roundedRectangle { Availability.roundedRectangle(field) }
        field.placeholderString = placeholder ?? String(localized: "Search files", bundle: bundle)
        field.cell?.setAccessibilityLabel(accessibilityLabel ?? field.placeholderString)
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.cell?.setAccessibilityIdentifier(SearchView.fieldID)
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.delegate = context.coordinator
        field.stringValue = model.query
        context.coordinator.watch = model.queryChanges.sink { [weak field] query in
            if let field, field.stringValue != query { field.stringValue = query }
        }
        return field
    }

    func updateNSView(_ field: FocusedSearchField, context: Context) {
        let font = textSize.font(.systemFont(ofSize: fontSize))
        if field.font != font { field.font = font }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusedSearchField, context: Context) -> CGSize? {
        guard let height, let width = proposal.width else { return nil }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: SearchModel
        let onEmptyEscape: (() -> Void)?
        var watch: AnyCancellable?

        init(model: SearchModel, onEmptyEscape: (() -> Void)? = nil) {
            self.model = model
            self.onEmptyEscape = onEmptyEscape
        }

        @objc func search(_ sender: NSSearchField) { model.query = sender.stringValue }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            model.query = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) { model.dropWaiting() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                model.dropWaiting()
                if textView.string.isEmpty, let onEmptyEscape {
                    onEmptyEscape()
                } else if textView.string.isEmpty {
                    model.filters = SearchFilters(hidesHidden: model.filters.hidesHidden)
                } else {
                    textView.insertText("", replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
                }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                act(on: control) { $0.open($1) }
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard let window = control.window, let table = window.contentView?.descendant(NSTableView.self), table.numberOfRows > 0,
                      window.makeFirstResponder(table) else { return false }
                table.selectRowIndexes([0], byExtendingSelection: false)
                table.scrollRowToVisible(0)
                return true
            case #selector(NSResponder.moveToEndOfDocument(_:)):
                textView.moveToEndOfDocument(nil)
                return true
            default:
                return false
            }
        }

        func act(on field: NSControl, _ action: @escaping (ThemedTable, IndexSet) -> Void) {
            guard let table = field.window?.contentView?.descendant(ThemedTable.self) else { return }
            guard !model.isPending else {
                return model.whenReady { [weak field, weak table] in
                    guard let field, let table, let window = field.window, window.isVisible, let editor = field.currentEditor(),
                          window.firstResponder === editor else { return }
                    action(table, IndexSet(integer: 0))
                }
            }
            guard !model.failed, table.numberOfRows > 0 else { return }
            action(table, table.selectedRowIndexes.isEmpty ? IndexSet(integer: 0) : table.selectedRowIndexes)
        }
    }
}

final class FocusedSearchField: NSSearchField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              ["\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? ""),
              let editor = currentEditor(), window?.firstResponder === editor, let coordinator = delegate as? SearchField.Coordinator else {
            return super.performKeyEquivalent(with: event)
        }
        coordinator.act(on: self) { $0.reveal($1) }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window.firstResponder === window else { return }
        window.focusSearchField()
    }
}

extension NSView {
    func descendant<T: NSView>(_ type: T.Type) -> T? {
        for view in subviews {
            if let found = view as? T ?? view.descendant(type) { return found }
        }
        return nil
    }
}

extension NSWindow {
    var searchField: NSSearchField? { (contentView?.superview ?? contentView)?.descendant(NSSearchField.self) }

    @discardableResult func focusSearchField() -> NSText? {
        guard let field = searchField, makeFirstResponder(field), let editor = field.currentEditor() else {
            return nil
        }
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        return editor
    }
}
