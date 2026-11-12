import AppKit
import SwiftUI

enum Availability {
    static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    static var inspectorButtonBezel: NSButton.BezelStyle {
        if #available(macOS 14, *) { .flexiblePush } else { .push }
    }

    static func launcherBackground(cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            return glass
        }
        return frostedLauncherBackground()
    }

    static func frostedLauncherBackground() -> NSVisualEffectView {
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        return blur
    }

    static var searchFieldOutlineInset: CGFloat {
        if #available(macOS 27, *) { 1 } else { 0 }
    }

    static func roundedRectangle(_ field: NSTextField) {
        if #available(macOS 26, *) { field.borderShape = .roundedRectangle }
    }

    static func roundedRectangle(_ button: NSButton) {
        if #available(macOS 26, *) { button.borderShape = .roundedRectangle }
    }

    static func borderShape(_ field: NSTextField) -> Int? {
        if #available(macOS 26, *) { field.borderShape.rawValue } else { nil }
    }

    static func borderShape(_ button: NSButton) -> Int? {
        if #available(macOS 26, *) { button.borderShape.rawValue } else { nil }
    }
}

extension View {
    @ViewBuilder func scrollContentTopMargin(_ length: CGFloat) -> some View {
        if #available(macOS 14, *) {
            contentMargins(.top, length, for: .scrollContent)
        } else {
            safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: length) }
        }
    }
}
