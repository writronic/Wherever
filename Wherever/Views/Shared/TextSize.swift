import AppKit
import Combine
import SwiftUI

nonisolated enum TextSize: Int, CaseIterable {
    case smallest = 11, smaller, standard, larger, large, extraLarge, largest, maximum

    static let key = "textSize"

    static func stored(_ defaults: UserDefaults) -> TextSize {
        TextSize(rawValue: defaults.integer(forKey: key)) ?? .standard
    }

    var after: TextSize { TextSize(rawValue: min(rawValue + 1, Self.maximum.rawValue)) ?? .maximum }
    var before: TextSize { TextSize(rawValue: max(rawValue - 1, Self.smallest.rawValue)) ?? .smallest }

    private var scale: CGFloat { CGFloat(rawValue) / CGFloat(Self.standard.rawValue) }

    func points(_ standard: CGFloat) -> CGFloat {
        self == .standard ? standard : max(10, (standard * scale).rounded())
    }

    func width(_ standard: CGFloat) -> CGFloat {
        self == .standard ? standard : (standard * scale).rounded()
    }

    func font(_ standard: NSFont) -> NSFont {
        self == .standard ? standard : NSFont(descriptor: standard.fontDescriptor, size: points(standard.pointSize)) ?? standard
    }

    func lineHeight(_ standard: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font(standard))
    }

    func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: points(size), weight: weight, design: design)
    }

    var caption: Font { self == .standard ? .caption : styled(.caption1) }
    var body: Font { self == .standard ? .body : styled(.body) }
    var headline: Font { self == .standard ? .headline : styled(.headline) }
    var monospacedBody: Font { self == .standard ? .system(.body, design: .monospaced) : styled(.body, design: .monospaced) }

    var formText: Font? { self == .standard ? nil : font(size: NSFont.systemFontSize) }
    var formLabel: Font? { self == .standard ? nil : styled(.body) }
    var formHeader: Font? { self == .standard ? nil : styled(.body, weight: .semibold) }

    private func styled(_ style: NSFont.TextStyle, weight: NSFont.Weight? = nil, design: NSFontDescriptor.SystemDesign? = nil) -> Font {
        var descriptor = NSFont.preferredFont(forTextStyle: style).fontDescriptor
        if let design { descriptor = descriptor.withDesign(design) ?? descriptor }
        if let weight { descriptor = descriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]]) }
        return Font(font(NSFont(descriptor: descriptor, size: 0) ?? .preferredFont(forTextStyle: style)) as CTFont)
    }
}

final class TextSizeWatch {
    private var fitted: TextSize
    private var watch: AnyCancellable?

    init(_ defaults: UserDefaults, changed: @escaping @MainActor () -> Void) {
        fitted = TextSize.stored(defaults)
        watch = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    let size = TextSize.stored(defaults)
                    guard let self, size != self.fitted else { return }
                    self.fitted = size
                    DispatchQueue.main.async { changed() }
                }
            }
    }
}
