import AppKit
import ObjectiveC
import SwiftUI
import Testing
@testable import Wherever

enum Look: CaseIterable {
    case light, dark, lightContrast, darkContrast

    var appearance: NSAppearance {
        switch self {
        case .light: NSAppearance(named: .aqua)!
        case .dark: NSAppearance(named: .darkAqua)!
        case .lightContrast: Self.increasedContrast("_aquaAppearanceWithAccessibility:", .accessibilityHighContrastAqua)
        case .darkContrast: Self.increasedContrast("_darkAquaAppearanceWithAccessibility:", .accessibilityHighContrastDarkAqua)
        }
    }

    private static func increasedContrast(_ selector: String, _ name: NSAppearance.Name) -> NSAppearance {
        typealias Factory = @convention(c) (AnyClass, Selector, Int) -> NSAppearance?
        let sel = NSSelectorFromString(selector)
        guard let method = class_getClassMethod(NSAppearance.self, sel),
              let appearance = unsafeBitCast(method_getImplementation(method), to: Factory.self)(NSAppearance.self, sel, 1),
              appearance.bestMatch(from: [.aqua, .darkAqua, name]) == name
        else { preconditionFailure("+[NSAppearance \(selector)] no longer gives \(name.rawValue)") }
        return appearance
    }
}

func channels(_ color: NSColor, _ look: Look) -> [Double] { channels(color, appearance: look.appearance) }

func channels(_ color: NSColor, appearance: NSAppearance) -> [Double] {
    var out: [Double] = []
    appearance.performAsCurrentDrawingAppearance {
        let srgb = color.usingColorSpace(.sRGB)!
        out = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent].map { Double($0) }
    }
    return out
}

func eightBits(_ channels: [Double]) -> [Int] { channels.prefix(3).map { Int(($0 * 255).rounded()) } }

func eightBits(hex: UInt32) -> [Int] { [Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF)] }

func srgbPixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> [Int]? {
    guard let raw = rep.colorAt(x: x, y: y) else { return nil }
    var components = [CGFloat](repeating: 0, count: raw.numberOfComponents)
    raw.getComponents(&components)
    guard let color = NSColor(colorSpace: rep.colorSpace, components: components, count: components.count).usingColorSpace(.sRGB) else { return nil }
    return eightBits([color.redComponent, color.greenComponent, color.blueComponent].map { Double($0) })
}

func over(_ foreground: [Double], _ background: [Double]) -> [Double] {
    let alpha = foreground[3]
    return (0..<3).map { foreground[$0] * alpha + background[$0] * (1 - alpha) } + [1]
}

func ratio(_ a: [Double], _ b: [Double]) -> Double {
    func luminance(_ c: [Double]) -> Double {
        let linear = c.prefix(3).map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
    let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
    return (high + 0.05) / (low + 0.05)
}

func viewDraws(_ color: NSColor, in view: NSView, x: CGFloat, y: CGFloat) -> Bool {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    let factor = CGFloat(rep.pixelsWide) / view.bounds.width
    guard let drawn = srgbPixel(rep, x: Int(x * factor), y: Int(y * factor)) else { return false }
    return zip(drawn, eightBits(channels(color, appearance: view.effectiveAppearance))).allSatisfy { abs($0 - $1) <= 1 }
}

func layerBits(_ color: CGColor?) -> [Int]? {
    color.flatMap { NSColor(cgColor: $0) }.map { eightBits(channels($0, .light)) }
}

struct PagePalette {
    let window, row, stripe, text, secondary, match, live, indexing: [UInt32]
}

let themePages: [Theme: PagePalette] = [
    .inkAndGlass: PagePalette(
        window: [0xF2F5FA, 0x0B0B24, 0xF2F5FA, 0x05051A], row: [0xFFFFFF, 0x0D0D2A, 0xFFFFFF, 0x08081F],
        stripe: [0xF2F5FB, 0x141438, 0xF2F5FB, 0x0F0F2E], text: [0x131253, 0xE8EBFA, 0x0A0A33, 0xFFFFFF],
        secondary: [0x4B5078, 0xA9B0D8, 0x2C305A, 0xD2D6F2], match: [0x0471B3, 0x33B1FF, 0x03507F, 0x7FD0FF],
        live: [0x009E73, 0x009E73, 0x005C45, 0x5FE0B5], indexing: [0x0471B3, 0x33B1FF, 0x03507F, 0x7FD0FF]
    ),
    .warmPaper: PagePalette(
        window: [0xEAE1D2, 0x2D261F, 0xEAE1D2, 0x2D261F], row: [0xFBF7F0, 0x1F1A15, 0xFBF7F0, 0x1F1A15],
        stripe: [0xF3ECE0, 0x27211B, 0xF3ECE0, 0x27211B], text: [0x2A2017, 0xF3EBDF, 0x1A120B, 0xFFFFFF],
        secondary: [0x66533F, 0xC2B29E, 0x4A3A2A, 0xE0D2BF], match: [0x953C04, 0xFFB466, 0x7A2F00, 0xFFC98C],
        live: [0x00785A, 0x33C49D, 0x00785A, 0x33C49D], indexing: [0x0068A3, 0x5AB4E8, 0x0068A3, 0x5AB4E8]
    ),
    .midnightTeal: PagePalette(
        window: [0xDCE8E5, 0x071A1E, 0xDCE8E5, 0x071A1E], row: [0xF8FBFA, 0x0C2327, 0xF8FBFA, 0x0C2327],
        stripe: [0xEDF4F2, 0x112B30, 0xEDF4F2, 0x112B30], text: [0x0A2A2C, 0xE3F2EF, 0x0A2A2C, 0xE3F2EF],
        secondary: [0x42605D, 0x9CBFB9, 0x2A4542, 0xC3DDD8], match: [0x00695C, 0x6EE7D2, 0x004D43, 0x9AF2E2],
        live: [0x007A5E, 0x3FD69B, 0x007A5E, 0x3FD69B], indexing: [0xA15F00, 0xF2B544, 0xA15F00, 0xF2B544]
    ),
]

struct OwnPalette {
    let secondary, match, live, indexing: [UInt32]
}

let systemNativeOwn = OwnPalette(
    secondary: [0x636366, 0xA0A0A0, 0x3D3D3F, 0xC8C8C8], match: [0x0058D0, 0x4DA3FF, 0x003F9E, 0x8CC4FF],
    live: [0x00845F, 0x32D74B, 0x006B4D, 0x5BE07A], indexing: [0x0072B2, 0x56B4E9, 0x005A8C, 0x8ACDF2]
)

func contrastFailures(_ theme: Theme, resolve: (NSColor) -> [Double]) -> (text: [String], marks: [String]) {
    var text: [String] = []
    var marks: [String] = []
    let window = resolve(theme.windowBackground)
    let row = over(resolve(theme.rowBackground), window)
    let stripe = over(resolve(theme.stripeBackground), row)
    for (surface, background) in [("row", row), ("stripe", stripe)] {
        for (name, color) in [("text", theme.text), ("secondary", theme.secondaryText), ("match", theme.matchText)] {
            let value = ratio(over(resolve(color), background), background)
            if !(value >= 4.5) { text.append("\(theme) \(name) on \(surface): \(value)") }
        }
    }
    let words = ratio(over(resolve(theme.text), window), window)
    if !(words >= 4.5) { text.append("\(theme) text on the window: \(words)") }
    let status = ratio(over(resolve(theme.secondaryText), window), window)
    if !(status >= 4.5) { text.append("\(theme) secondary text on the window: \(status)") }
    let link = ratio(over(resolve(theme.link), window), window)
    if !(link >= 4.5) { text.append("\(theme) link on the window: \(link)") }
    for (name, color) in [("live", theme.stateLive), ("indexing", theme.stateIndexing)] {
        let value = ratio(over(resolve(color), window), window)
        if !(value >= 3) { marks.append("\(theme) \(name): \(value)") }
    }
    return (text, marks)
}

@Suite struct ThemeValueTests {
    @Test(arguments: [Theme.inkAndGlass, .warmPaper, .midnightTeal])
    func everyRoleResolvesToThePageHexInEveryAppearance(theme: Theme) throws {
        let page = try #require(themePages[theme])
        let roles: [(String, NSColor, [UInt32])] = [
            ("window", theme.windowBackground, page.window), ("row", theme.rowBackground, page.row),
            ("stripe", theme.stripeBackground, page.stripe), ("text", theme.text, page.text),
            ("secondary", theme.secondaryText, page.secondary), ("match", theme.matchText, page.match),
            ("live", theme.stateLive, page.live), ("indexing", theme.stateIndexing, page.indexing),
        ]
        for (name, color, hexes) in roles {
            for (look, hex) in zip(Look.allCases, hexes) {
                #expect(eightBits(channels(color, look)) == eightBits(hex: hex), "\(theme) \(name) \(look)")
            }
        }
    }

    @Test func systemNativeTakesTheSystemColoursAndSetsFourOfItsOwn() {
        let theme = Theme.systemNative
        let system: [(String, NSColor, NSColor)] = [
            ("window", theme.windowBackground, .windowBackgroundColor), ("row", theme.rowBackground, .controlBackgroundColor),
            ("stripe", theme.stripeBackground, NSColor.alternatingContentBackgroundColors[1]), ("text", theme.text, .labelColor),
        ]
        for (name, color, expected) in system {
            for look in Look.allCases { #expect(channels(color, look) == channels(expected, look), "\(name) \(look)") }
        }
        let own = systemNativeOwn
        let ownRoles: [(String, NSColor, [UInt32])] = [
            ("secondary", theme.secondaryText, own.secondary), ("match", theme.matchText, own.match), ("live", theme.stateLive, own.live),
            ("indexing", theme.stateIndexing, own.indexing),
        ]
        for (name, color, hexes) in ownRoles {
            for (look, hex) in zip(Look.allCases, hexes) { #expect(eightBits(channels(color, look)) == eightBits(hex: hex), "\(name) \(look)") }
        }
    }

    @Test(arguments: Theme.allCases)
    func aRoleReadTwiceIsOneColourThatFollowsEveryAppearanceBothWays(theme: Theme) {
        let hexes: [UInt32] = theme == .systemNative ? systemNativeOwn.secondary : themePages[theme]?.secondary ?? []
        #expect(hexes.count == Look.allCases.count)
        let first = theme.secondaryText
        #expect(first === theme.secondaryText)
        let pairs = Array(zip(Look.allCases, hexes))
        for ordered in [pairs, Array(pairs.reversed())] {
            for (look, hex) in ordered { #expect(eightBits(channels(theme.secondaryText, look)) == eightBits(hex: hex), "\(theme) \(look)") }
        }
    }

    @Test func everyThemeNamesItselfAndAMissingOrUnknownStoredValueIsSystemNative() {
        #expect(Theme.allCases.map(\.rawValue) == ["systemNative", "inkAndGlass", "warmPaper", "midnightTeal"])
        for stored in ["", "7", "graphitePro", "Ink and Glass"] { #expect(Theme(rawValue: stored) == nil, "\(stored)") }
    }

    @Test(arguments: Theme.allCases)
    func everyPageCheckedPairMeetsItsMinimum(theme: Theme) {
        for look in Look.allCases {
            let failures = contrastFailures(theme) { channels($0, look) }.text
            #expect(failures.isEmpty, "\(look): \(failures)")
        }
    }
}

extension ThemeValueTests {
    @Test func systemNativeLinksMeetFourAndAHalfOnTheOlderSystemWindowGreys() {
        let greys: [(Look, UInt32)] = [(.light, 0xECECEC), (.dark, 0x323232), (.lightContrast, 0xECECEC), (.darkContrast, 0x323232)]
        for (look, grey) in greys {
            let window = eightBits(hex: grey).map { Double($0) / 255 } + [1]
            let value = ratio(over(channels(Theme.systemNative.link, look), window), window)
            #expect(value >= 4.5, "\(look) on #\(String(grey, radix: 16)): \(value)")
        }
    }

    @Test(arguments: Theme.allCases)
    func everyStateMarkMeetsThreeToOneOnItsWindow(theme: Theme) {
        for look in Look.allCases {
            let failures = contrastFailures(theme) { channels($0, look) }.marks
            #expect(failures.isEmpty, "\(look): \(failures)")
        }
    }
}

extension ThemeValueTests {
    @Test(arguments: Theme.allCases)
    func theLauncherSelectionBorderMeetsThreeToOneOnEveryPanel(theme: Theme) {
        for look in Look.allCases {
            let window = channels(theme.windowBackground, look)
            let value = ratio(over(channels(Theme.launcherSelectionBorder, look), window), window)
            #expect(value >= 3, "\(theme) \(look): \(value)")
        }
    }

    @Test(arguments: [(Look.light, UInt32(0xECECEC)), (.dark, 0x323232), (.lightContrast, 0xECECEC), (.darkContrast, 0x323232)])
    func theLauncherSelectionBorderMeetsThreeToOneOnTheOlderSystemWindowGreys(look: Look, grey: UInt32) {
        let window = eightBits(hex: grey).map { Double($0) / 255 } + [1]
        let value = ratio(over(channels(Theme.launcherSelectionBorder, look), window), window)
        #expect(value >= 3, "\(look) on #\(String(grey, radix: 16)): \(value)")
    }
}

extension ThemeValueTests {
    @Test(arguments: [(Look.light, UInt32(0xF9F9F9)), (.dark, 0x313131)])
    func theProblemColourMeetsFourAndAHalfOnTheGroupedCard(look: Look, card: UInt32) {
        let background = eightBits(hex: card).map { Double($0) / 255 } + [1]
        let value = ratio(over(channels(Theme.problem, look), background), background)
        #expect(value >= 4.5, "\(look) on #\(String(card, radix: 16)): \(value)")
    }
}

@Suite(.serialized) struct ThemeWindowTests {
    private static let suiteName = "com.writronic.wherever.tests.theme"

    private func freshSuite() -> UserDefaults {
        let suite = UserDefaults(suiteName: Self.suiteName)!
        suite.removePersistentDomain(forName: Self.suiteName)
        return suite
    }

    func open(_ suite: UserDefaults, _ look: Look? = .light) -> (host: SearchHost, model: SearchModel) {
        let index = IndexModel(client: FakeSearchClient())
        let model = index.makeModel()
        let host = SearchHost(root: AnyView(SearchView(model: model).defaultAppStorage(suite)))
        host.window.appearance = look?.appearance
        return (host, model)
    }

    private func pixel(_ host: SearchHost) -> [Int] {
        host.view.layoutSubtreeIfNeeded()
        guard let rep = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else { return [] }
        host.view.cacheDisplay(in: host.view.bounds, to: rep)
        return srgbPixel(rep, x: 2, y: 2) ?? []
    }

    func draws(_ host: SearchHost, _ theme: Theme, _ look: Look) -> Bool {
        let drawn = pixel(host)
        return drawn.count == 3 && zip(drawn, eightBits(channels(theme.windowBackground, look))).allSatisfy { abs($0 - $1) <= 1 }
    }

    @Test func aMissingOrUnknownStoredValueDrawsSystemNativeAndStaysStored() async throws {
        let stored: [Any?] = [nil, "", "7", "graphitePro", 7]
        for value in stored {
            let suite = freshSuite()
            if let value { suite.set(value, forKey: Theme.key) }
            let (host, _) = open(suite)
            defer { host.close() }
            try await host.until("System Native for \(String(describing: value))") { self.draws(host, .systemNative, .light) }
            #expect(suite.object(forKey: Theme.key) as? NSObject == value as? NSObject, "\(String(describing: value)) was rewritten")
        }
    }

    @Test func aPickReachesEveryWindowInEveryAppearanceAndTypingStillLands() async throws {
        let suite = freshSuite()
        let (first, firstModel) = open(suite)
        let (second, _) = open(suite)
        defer { first.close(); second.close() }
        let hosts = [first, second]
        for host in hosts { try await host.until("System Native at first") { self.draws(host, .systemNative, .light) } }

        suite.set(Theme.inkAndGlass.rawValue, forKey: Theme.key)
        for host in hosts { try await host.until("Ink and Glass light") { self.draws(host, .inkAndGlass, .light) } }

        suite.set(Theme.warmPaper.rawValue, forKey: Theme.key)
        for host in hosts { try await host.until("Warm Paper light") { self.draws(host, .warmPaper, .light) } }
        try await first.type("a")
        #expect(firstModel.query == "a")

        for host in hosts { host.window.appearance = Look.dark.appearance }
        for host in hosts { try await host.until("Warm Paper dark") { self.draws(host, .warmPaper, .dark) } }

        suite.set(Theme.systemNative.rawValue, forKey: Theme.key)
        for host in hosts { try await host.until("System Native dark") { self.draws(host, .systemNative, .dark) } }

        for theme in [Theme.inkAndGlass, .warmPaper, .midnightTeal, .systemNative, .inkAndGlass, .midnightTeal] {
            suite.set(theme.rawValue, forKey: Theme.key)
        }
        for host in hosts { try await host.until("Midnight Teal after five quick picks") { self.draws(host, .midnightTeal, .dark) } }
    }

    @Test func thePickerOffersTheFourThemesLabelsItselfAndWritesTheChoiceToItsSuite() async throws {
        let suite = freshSuite()
        let standardBefore = UserDefaults.standard.object(forKey: Theme.key) as? String
        let host = SearchHost(root: AnyView(ThemePicker().defaultAppStorage(suite).padding()))
        defer { host.close() }
        try await host.until("the theme picker") { themeTileRow(in: host.view) != nil }
        let row = try #require(themeTileRow(in: host.view))
        #expect(row.accessibilityLabel() == "Color theme")
        #expect(row.names.map(\.stringValue) == ["System Native", "Ink and Glass", "Warm Paper", "Midnight Teal"])
        #expect(row.picked == .systemNative)

        for tile in row.tiles.dropFirst() {
            tile.performClick(nil)
            #expect(row.picked == tile.theme)
            try await host.until("\(tile.theme) stored") { suite.string(forKey: Theme.key) == tile.theme.rawValue }
        }

        row.tiles[2].performClick(nil)
        try await host.until("Warm Paper stored") { suite.string(forKey: Theme.key) == Theme.warmPaper.rawValue }
        suite.set(Theme.inkAndGlass.rawValue, forKey: Theme.key)
        try await host.until("a stored theme reaches the tiles") { row.picked == .inkAndGlass && row.tiles[1].state == .on }
        #expect(UserDefaults.standard.object(forKey: Theme.key) as? String == standardBefore)
    }
}
