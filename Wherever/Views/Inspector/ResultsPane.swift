import AppKit
import Combine
import SwiftUI
import WhereverInterface

struct ResultsPane: NSViewControllerRepresentable {
    @ObservedObject var model: SearchModel
    @AppStorage(Theme.key) private var theme = Theme.systemNative
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @AppStorage(InspectorPane.shownKey) private var shown = false
    @Environment(\.locale) private var locale
    @Environment(\.resultActions) private var actions

    final class Coordinator {
        let table: ResultsTable.Coordinator
        let inspector = InspectorModel()

        init(table: ResultsTable.Coordinator) {
            self.table = table
            table.onSelect = { [inspector] in inspector.select($0, count: $1) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(table: ResultsTable.Coordinator(model: model, appIcon: ResultsTable.liveAppIcon, announcer: .shared))
    }

    func makeNSViewController(context: Context) -> InspectorSplitController {
        let list = NSViewController()
        list.view = ResultsTable.makeView(context.coordinator.table, textSize: textSize, actions: actions)
        let table = { [weak coordinator = context.coordinator] () -> ThemedTable? in
            guard let table = coordinator?.table.table else { return nil }
            table.window?.makeFirstResponder(table)
            return table
        }
        let pane = InspectorPane(
            inspector: context.coordinator.inspector, quickLook: { table()?.toggleQuickLook(nil) }, reveal: { table()?.revealSelected(nil) },
            allows: { [weak coordinator = context.coordinator] in coordinator?.table.table?.actions.inside?.allows($0) == true },
            showInside: { table()?.showInside(nil) }
        )
        pane.apply(theme: theme, textSize: textSize, locale: locale)
        return InspectorSplitController(list: list, inspector: pane)
    }

    func updateNSViewController(_ controller: InspectorSplitController, context: Context) {
        ResultsTable.update(context.coordinator.table, theme: theme, textSize: textSize, actions: actions)
        context.coordinator.inspector.shown = shown
        controller.userToggled = { [binding = $shown] in binding.wrappedValue = $0 }
        controller.pane.apply(theme: theme, textSize: textSize, locale: locale)
        let direction: NSUserInterfaceLayoutDirection = context.environment.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        if controller.pane.view.userInterfaceLayoutDirection != direction { controller.pane.view.userInterfaceLayoutDirection = direction }
        controller.show(shown)
    }
}

final class InspectorSplitController: NSSplitViewController {
    let pane: InspectorPane
    let inspectorItem: NSSplitViewItem
    var userToggled: (Bool) -> Void = { _ in }
    private var placed = false
    private var wanted: Bool?
    private var watch: AnyCancellable?

    init(list: NSViewController, inspector pane: InspectorPane) {
        self.pane = pane
        let listItem = NSSplitViewItem(viewController: list)
        inspectorItem = NSSplitViewItem(viewController: pane)
        super.init(nibName: nil, bundle: nil)
        listItem.holdingPriority = .defaultLow
        inspectorItem.minimumThickness = SearchMetrics.inspectorMinWidth
        inspectorItem.maximumThickness = SearchMetrics.inspectorMaxWidth
        inspectorItem.canCollapse = true
        inspectorItem.canCollapseFromWindowResize = false
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 1)
        inspectorItem.isCollapsed = true
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(listItem)
        addSplitViewItem(inspectorItem)
        watch = inspectorItem.publisher(for: \.isCollapsed, options: [.new]).sink { [unowned self] collapsed in
            guard let wanted, collapsed == wanted else { return }
            self.wanted = !collapsed
            userToggled(!collapsed)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    func show(_ shown: Bool) {
        wanted = shown
        if inspectorItem.isCollapsed == shown { inspectorItem.isCollapsed = !shown }
        if shown, !placed, splitView.bounds.width > 0 { splitView.layoutSubtreeIfNeeded() }
        place()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        place()
    }

    private func place() {
        guard !placed, !inspectorItem.isCollapsed, splitView.bounds.width > 0, let list = splitViewItems.first?.viewController.view else { return }
        placed = true
        let width = SearchMetrics.inspectorWidth
        let total = splitView.bounds.width
        let leading = pane.view.convert(pane.view.bounds, to: splitView).minX < list.convert(list.bounds, to: splitView).minX
        splitView.setPosition(leading ? width : total - width - splitView.dividerThickness, ofDividerAt: 0)
    }
}
