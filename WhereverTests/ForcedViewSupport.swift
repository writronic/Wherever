import AppKit
import Foundation
@testable import Wherever

func contrastRatio(_ a: [Double], _ b: [Double]) -> Double {
    func luminance(_ c: [Double]) -> Double {
        let linear = c.prefix(3).map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
    let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
    return (high + 0.05) / (low + 0.05)
}

func pixels(in view: NSView, rect: NSRect) -> [[Int]] {
    view.layoutSubtreeIfNeeded()
    guard view.bounds.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
    let left = max(0, Int((rect.minX * scale).rounded(.down)))
    let right = min(rep.pixelsWide, Int((rect.maxX * scale).rounded(.up)))
    let first = max(0, Int((top * scale).rounded(.down)))
    let last = min(rep.pixelsHigh, Int(((top + rect.height) * scale).rounded(.up)))
    guard left < right, first < last else { return [] }
    return (first..<last).flatMap { y in (left..<right).compactMap { x in srgbPixel(rep, x: x, y: y) } }
}

func strongestInk(in view: NSView, rect: NSRect, against background: [Double]) -> Double {
    pixels(in: view, rect: rect).map { contrastRatio($0.map { Double($0) / 255 }, background) }.max() ?? 0
}

func hasPixel(near color: [Int], in view: NSView, rect: NSRect, tolerance: Int = 3) -> Bool {
    pixels(in: view, rect: rect).contains { zip($0, color).allSatisfy { abs($0 - $1) <= tolerance } }
}

func appearanceName(_ mode: AppearanceMode) -> NSAppearance.Name { mode == .dark ? .darkAqua : .aqua }
