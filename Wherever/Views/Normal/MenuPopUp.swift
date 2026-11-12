import AppKit
import SwiftUI

struct MenuPopUp<Value: Hashable>: NSViewRepresentable {
    struct Item: Equatable {
        var title: String
        var value: Value
    }

    let id: String
    let label: String
    @Binding var value: Value
    let items: () -> [Item]
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUp = FormPopUpButton(frame: .zero, pullsDown: false)
        popUp.controlSize = .large
        Availability.roundedRectangle(popUp)
        popUp.autoenablesItems = false
        popUp.identifier = NSUserInterfaceItemIdentifier(id)
        popUp.setAccessibilityIdentifier(id)
        popUp.setAccessibilityLabel(label)
        popUp.cell?.setAccessibilityIdentifier(id)
        popUp.cell?.setAccessibilityLabel(label)
        popUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popUp.target = context.coordinator
        popUp.action = #selector(Coordinator.picked(_:))
        popUp.menu?.delegate = context.coordinator
        popUp.isEnabled = context.environment.isEnabled
        context.coordinator.popUp = popUp
        context.coordinator.parent = self
        context.coordinator.fill()
        return popUp
    }

    func updateNSView(_ popUp: NSPopUpButton, context: Context) {
        popUp.isEnabled = context.environment.isEnabled
        let font = textSize.font(.systemFont(ofSize: NSFont.systemFontSize))
        if popUp.font != font { popUp.font = font }
        context.coordinator.parent = self
        context.coordinator.fill()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView popUp: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? popUp.fittingSize.width, height: NormalMetrics.controlHeight)
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: MenuPopUp?
        weak var popUp: NSPopUpButton?
        private var shown: [Item]?

        private var values: [Value] { shown?.map(\.value) ?? [] }

        func fill() {
            guard let parent, let popUp, let menu = popUp.menu else { return }
            let items = parent.items()
            guard items != shown else { return showValue() }
            shown = items
            menu.removeAllItems()
            for item in items { menu.addItem(NSMenuItem(title: item.title, action: nil, keyEquivalent: "")) }
            showValue()
        }

        private func showValue() {
            guard let parent, let popUp, let index = values.firstIndex(of: parent.value) else { return }
            popUp.selectItem(at: index)
        }

        @objc func picked(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard let parent, values.indices.contains(index) else { return showValue() }
            parent.value = values[index]
            showValue()
        }

        func menuNeedsUpdate(_ menu: NSMenu) { fill() }
    }
}

private final class FormPopUpButton: NSPopUpButton {
    override class var cellClass: AnyClass? {
        get { FormPopUpCell.self }
        set { super.cellClass = newValue }
    }
}

private final class FormPopUpCell: NSPopUpButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        super.drawBezel(withFrame: frame, in: controlView)
    }
}
