import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever

private func freshSuite(_ name: String) -> UserDefaults {
    let domain = "com.writronic.wherever.tests.textsize.\(name)"
    let defaults = UserDefaults(suiteName: domain)!
    defaults.removePersistentDomain(forName: domain)
    return defaults
}

private func usage(_ font: NSFont) -> String? {
    font.fontDescriptor.fontAttributes[NSFontDescriptor.AttributeName("NSCTFontUIUsageAttribute")] as? String
}

@Suite struct TextSizeTests {
    @Test func theStandardSizeChangesNothing() {
        for base: CGFloat in [10, 11, 12, 13, 14, 15, 20, 28] {
            #expect(TextSize.standard.points(base) == base, "\(base) pt")
            #expect(TextSize.standard.width(base * 10) == base * 10, "\(base * 10) wide")
        }
        let fonts = [
            NSFont.systemFont(ofSize: 13), .systemFont(ofSize: 11), .monospacedSystemFont(ofSize: 13, weight: .regular),
            .preferredFont(forTextStyle: .body), .preferredFont(forTextStyle: .callout),
        ]
        for font in fonts { #expect(TextSize.standard.font(font) === font, "\(font)") }
        #expect(TextSize.standard.formText == nil)
        #expect(TextSize.standard.formLabel == nil)
        #expect(TextSize.standard.formHeader == nil)
        #expect(TextSize.standard.caption == .caption && TextSize.standard.body == .body && TextSize.standard.headline == .headline)
        #expect(TextSize.standard.monospacedBody == .system(.body, design: .monospaced))
    }

    @Test func theLargestSizeScalesEveryRole() {
        let size = TextSize.maximum
        #expect(size.points(13) == 18)
        #expect(size.points(11) == 15)
        #expect(size.points(15) == 21)
        #expect(size.points(20) == 28)
        #expect(size.points(28) == 39)
        #expect(size.points(10) == 14)
        #expect(size.width(270) == 374)
        #expect(size.formText != nil && size.formLabel != nil && size.formHeader != nil)
        let body = NSFont.preferredFont(forTextStyle: .body)
        let scaled = size.font(body)
        #expect(scaled.pointSize == 18)
        #expect(usage(scaled) == usage(body) && usage(body) != usage(.systemFont(ofSize: 13)), "the body face: \(scaled.fontDescriptor)")
        #expect(size.lineHeight(body) > TextSize.standard.lineHeight(body))
    }

    @Test(arguments: ["ar", "vi", "en"]) func noTextStyleIsShorterAtALargerSize(_ language: String) {
        let styles: [(String, (TextSize) -> Font)] = [("caption", \.caption), ("body", \.body), ("headline", \.headline), ("monospacedBody", \.monospacedBody)]
        for (name, style) in styles {
            let heights = TextSize.allCases.map { size in
                NSHostingView(
                    rootView: Text(verbatim: "Ag").font(style(size)).typesettingLanguage(.explicit(Locale.Language(identifier: language))).fixedSize()
                ).fittingSize.height
            }
            #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 }, "\(name) in \(language) from 11 to 18 pt: \(heights)")
        }
    }

    @Test func theSmallestSizeStopsAtTenPoints() {
        #expect(TextSize.smallest.points(11) == 10)
        #expect(TextSize.smallest.points(10) == 10)
        #expect(TextSize.smallest.points(13) == 11)
    }

    @Test func theSizesRunElevenToEighteenAndStepWithinThem() {
        #expect(TextSize.allCases.map(\.rawValue) == Array(11...18))
        #expect(TextSize.maximum.after == .maximum)
        #expect(TextSize.smallest.before == .smallest)
        #expect(TextSize.standard.after == .larger)
        #expect(TextSize.standard.before == .smaller)
    }

    @Test func aStoredValueReadsAsAppStorageReadsIt() {
        let cases: [(String, Any?, TextSize)] = [
            ("nothing", nil, .standard), ("99", 99, .standard), ("true", true, .standard),
            ("16", 16, .extraLarge), ("\"16\"", "16", .extraLarge), ("16.0", 16.0, .extraLarge),
        ]
        for (index, (name, value, expected)) in cases.enumerated() {
            let defaults = freshSuite("stored.\(index)")
            if let value { defaults.set(value, forKey: TextSize.key) }
            let stored = TextSize.stored(defaults)
            let read = AppStorage(wrappedValue: TextSize.standard, TextSize.key, store: defaults).wrappedValue
            #expect(stored == expected, "\(name) read \(stored)")
            #expect(read == stored, "\(name): AppStorage \(read), stored \(stored)")
        }
        #expect(TextSize.extraLarge.rawValue == 16 && TextSize.large.rawValue == 15)
    }
}
