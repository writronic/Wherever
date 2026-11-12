import AppKit
import SwiftUI

struct TextSizeRow: View {
    static let id = "text-size-slider"

    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        LabeledContent {
            SliderColumn(minimum: SliderEnd.smallA, maximum: SliderEnd.largeA) {
                TextSizeSlider(selection: $textSize)
            }
        } label: {
            Text("Text size", tableName: "Settings").font(textSize.formLabel)
        }
    }
}

enum SliderEnd {
    static var smallA: Text { Text("A", tableName: "Settings").font(.system(size: CGFloat(TextSize.smallest.rawValue))) }
    static var largeA: Text { Text("A", tableName: "Settings").font(.system(size: CGFloat(TextSize.maximum.rawValue))) }
    static func percent(_ value: Int, _ size: TextSize) -> Text { Text(value, format: .percent).font(size.formText) }
}

struct SliderColumn<Track: View>: View {
    let minimum: Text
    let maximum: Text
    @ViewBuilder let track: Track
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    var body: some View {
        HStack(spacing: SettingsWindow.Metrics.sliderLabelSpacing) {
            end(minimum, alignment: .trailing)
            track.frame(width: SettingsWindow.Metrics.sliderTrackWidth)
            end(maximum, alignment: .leading)
        }
    }

    private func end(_ text: Text, alignment: Alignment) -> some View {
        ZStack(alignment: alignment) {
            ZStack {
                SliderEnd.smallA
                SliderEnd.largeA
                SliderEnd.percent(0, textSize)
                SliderEnd.percent(100, textSize)
            }
            .fixedSize()
            .frame(height: 0)
            .hidden()
            text
        }
        .accessibilityHidden(true)
    }
}

private struct TextSizeSlider: NSViewRepresentable {
    @Binding var selection: TextSize

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = SteppedSlider()
        slider.minValue = Double(TextSize.smallest.rawValue)
        slider.maxValue = Double(TextSize.maximum.rawValue)
        slider.numberOfTickMarks = TextSize.allCases.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = false
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.identifier = NSUserInterfaceItemIdentifier(TextSizeRow.id)
        slider.setAccessibilityIdentifier(TextSizeRow.id)
        slider.cell?.setAccessibilityIdentifier(TextSizeRow.id)
        slider.setAccessibilityLabel(String(localized: "Text size", table: "Settings"))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.selection = $selection
        if slider.integerValue != selection.rawValue { slider.integerValue = selection.rawValue }
        slider.setAccessibilityValueDescription(String(localized: "\(selection.rawValue) pt", table: "Settings"))
    }

    final class Coordinator: NSObject {
        var selection: Binding<TextSize>

        init(selection: Binding<TextSize>) { self.selection = selection }

        @objc func changed(_ slider: NSSlider) {
            selection.wrappedValue = TextSize(rawValue: slider.integerValue) ?? .standard
        }
    }
}

private final class SteppedSlider: NSSlider {
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func moveRight(_ sender: Any?) { step(forward: userInterfaceLayoutDirection == .leftToRight) }
    override func moveUp(_ sender: Any?) { step(forward: true) }
    override func moveLeft(_ sender: Any?) { step(forward: userInterfaceLayoutDirection == .rightToLeft) }
    override func moveDown(_ sender: Any?) { step(forward: false) }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
    override func accessibilityPerformIncrement() -> Bool { step(forward: true) }
    override func accessibilityPerformDecrement() -> Bool { step(forward: false) }

    @discardableResult private func step(forward: Bool) -> Bool {
        let size = TextSize(rawValue: integerValue) ?? .standard
        let next = forward ? size.after : size.before
        guard next != size else { return false }
        integerValue = next.rawValue
        return sendAction(action, to: target)
    }
}
