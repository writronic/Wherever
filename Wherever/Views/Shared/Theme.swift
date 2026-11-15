import AppKit
import os
import SwiftUI

nonisolated enum Theme: String, CaseIterable {
    case systemNative, inkAndGlass, warmPaper, midnightTeal

    static let key = "colourTheme"

    static var launcherSelection: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.09)
        }
    }

    static var launcherSelectionBorder: NSColor { Tone(0x6E6E73, 0x8E8E93, lightContrast: 0x000000, darkContrast: 0xFFFFFF).color }

    var windowBackground: NSColor {
        switch self {
        case .systemNative: .windowBackgroundColor
        case .inkAndGlass: Tone(0xF2F5FA, 0x0B0B24, darkContrast: 0x05051A).color
        case .warmPaper: Tone(0xEAE1D2, 0x2D261F).color
        case .midnightTeal: Tone(0xDCE8E5, 0x071A1E).color
        }
    }

    var rowBackground: NSColor {
        switch self {
        case .systemNative: .controlBackgroundColor
        case .inkAndGlass: Tone(0xFFFFFF, 0x0D0D2A, darkContrast: 0x08081F).color
        case .warmPaper: Tone(0xFBF7F0, 0x1F1A15).color
        case .midnightTeal: Tone(0xF8FBFA, 0x0C2327).color
        }
    }

    var stripeBackground: NSColor {
        switch self {
        case .systemNative: NSColor.alternatingContentBackgroundColors[1]
        case .inkAndGlass: Tone(0xF2F5FB, 0x141438, darkContrast: 0x0F0F2E).color
        case .warmPaper: Tone(0xF3ECE0, 0x27211B).color
        case .midnightTeal: Tone(0xEDF4F2, 0x112B30).color
        }
    }

    var text: NSColor {
        switch self {
        case .systemNative: .labelColor
        case .inkAndGlass: Tone(0x131253, 0xE8EBFA, lightContrast: 0x0A0A33, darkContrast: 0xFFFFFF).color
        case .warmPaper: Tone(0x2A2017, 0xF3EBDF, lightContrast: 0x1A120B, darkContrast: 0xFFFFFF).color
        case .midnightTeal: Tone(0x0A2A2C, 0xE3F2EF).color
        }
    }

    var secondaryText: NSColor {
        switch self {
        case .systemNative: Tone(0x636366, 0xA0A0A0, lightContrast: 0x3D3D3F, darkContrast: 0xC8C8C8).color
        case .inkAndGlass: Tone(0x4B5078, 0xA9B0D8, lightContrast: 0x2C305A, darkContrast: 0xD2D6F2).color
        case .warmPaper: Tone(0x66533F, 0xC2B29E, lightContrast: 0x4A3A2A, darkContrast: 0xE0D2BF).color
        case .midnightTeal: Tone(0x42605D, 0x9CBFB9, lightContrast: 0x2A4542, darkContrast: 0xC3DDD8).color
        }
    }

    var matchText: NSColor {
        switch self {
        case .systemNative: Tone(0x0058D0, 0x4DA3FF, lightContrast: 0x003F9E, darkContrast: 0x8CC4FF).color
        case .inkAndGlass: Tone(0x0471B3, 0x33B1FF, lightContrast: 0x03507F, darkContrast: 0x7FD0FF).color
        case .warmPaper: Tone(0x953C04, 0xFFB466, lightContrast: 0x7A2F00, darkContrast: 0xFFC98C).color
        case .midnightTeal: Tone(0x00695C, 0x6EE7D2, lightContrast: 0x004D43, darkContrast: 0x9AF2E2).color
        }
    }

    var link: NSColor { matchText }

    var stateLive: NSColor {
        switch self {
        case .systemNative: Tone(0x00845F, 0x32D74B, lightContrast: 0x006B4D, darkContrast: 0x5BE07A).color
        case .inkAndGlass: Tone(0x009E73, 0x009E73, lightContrast: 0x005C45, darkContrast: 0x5FE0B5).color
        case .warmPaper: Tone(0x00785A, 0x33C49D).color
        case .midnightTeal: Tone(0x007A5E, 0x3FD69B).color
        }
    }

    var stateIndexing: NSColor {
        switch self {
        case .systemNative: Tone(0x0072B2, 0x56B4E9, lightContrast: 0x005A8C, darkContrast: 0x8ACDF2).color
        case .inkAndGlass: Tone(0x0471B3, 0x33B1FF, lightContrast: 0x03507F, darkContrast: 0x7FD0FF).color
        case .warmPaper: Tone(0x0068A3, 0x5AB4E8).color
        case .midnightTeal: Tone(0xA15F00, 0xF2B544).color
        }
    }

    static var welcomeWarning: NSColor { Tone(0xA04600, 0xE69F00, darkContrast: 0xF5B83D).color }

    static var problem: NSColor { Tone(0xC4161C, 0xFF8A80).color }

    static var welcomeGranted: NSColor { Tone(0x006B4D, 0x32D74B, lightContrast: 0x00583E, darkContrast: 0x5BE07A).color }

    func name(_ bundle: Bundle) -> String {
        switch self {
        case .systemNative: String(localized: "System Native", table: "Theme", bundle: bundle)
        case .inkAndGlass: String(localized: "Ink and Glass", table: "Theme", bundle: bundle)
        case .warmPaper: String(localized: "Warm Paper", table: "Theme", bundle: bundle)
        case .midnightTeal: String(localized: "Midnight Teal", table: "Theme", bundle: bundle)
        }
    }
}

private nonisolated struct Tone: Hashable {
    private static let made = OSAllocatedUnfairLock(initialState: [Tone: NSColor]())

    let light, dark, lightContrast, darkContrast: UInt32

    init(_ light: UInt32, _ dark: UInt32, lightContrast: UInt32? = nil, darkContrast: UInt32? = nil) {
        self.light = light
        self.dark = dark
        self.lightContrast = lightContrast ?? light
        self.darkContrast = darkContrast ?? dark
    }

    var color: NSColor {
        Self.made.withLock { made in
            if let color = made[self] { return color }
            let color = make()
            made[self] = color
            return color
        }
    }

    private func make() -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: dark
            case .accessibilityHighContrastAqua: lightContrast
            case .accessibilityHighContrastDarkAqua: darkContrast
            default: light
            }
            return NSColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        }
    }
}

extension View {
    func themedWindowBackground() -> some View { modifier(ThemedWindowBackground()) }
}

private struct ThemedWindowBackground: ViewModifier {
    @AppStorage(Theme.key) private var theme = Theme.systemNative

    func body(content: Content) -> some View {
        content.background(Color(nsColor: theme.windowBackground), ignoresSafeAreaEdges: .all)
    }
}
