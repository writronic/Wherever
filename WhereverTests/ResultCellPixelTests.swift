import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Wherever

private struct PixelShape {
    let label: String
    let font: NSFont
    let height: CGFloat
    let padding: CGFloat
    let iconGap: CGFloat
    let iconSize: CGFloat
    var icon: NSImage?
    let text: String
    var matches: [Range<Int>] = []
    var tone = NSColor.secondaryLabelColor
    var alignment = NSTextAlignment.natural
    var cut = NSLineBreakMode.byTruncatingTail
}

@Suite(.serialized) struct ResultCellPixelTests {
    static let width: CGFloat = 180
    static let pitch: CGFloat = 60

    @Test(arguments: [11, 13, 18], [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft])
    func theFrameLaidCellDrawsTheConstraintCellsPixels(points: Int, direction: NSUserInterfaceLayoutDirection) throws {
        let size = try #require(TextSize(rawValue: points))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 3 * Self.width + 40, height: 7 * Self.pitch), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let content = try #require(window.contentView)
        let scale = window.backingScaleFactor
        let shapes = Self.shapes(size, direction: direction)
        for (index, shape) in shapes.enumerated() {
            let row = CGFloat(index) * Self.pitch
            let cell = Self.resultCell(shape, direction: direction)
            #expect(cell.constraints.isEmpty && cell.subviews.allSatisfy { $0.constraints.isEmpty }, "\(shape.label): the new cell holds constraints")
            #expect(cell.subviews.allSatisfy { $0.translatesAutoresizingMaskIntoConstraints }, "\(shape.label): a subview waits for constraints")
            let reference = Self.constraintCell(shape, direction: direction, padding: shape.padding)
            let shifted = Self.constraintCell(shape, direction: direction, padding: shape.padding + 1 / scale)
            for (column, view) in ([cell, reference, shifted] as [NSView]).enumerated() {
                content.addSubview(view)
                view.frame = NSRect(x: CGFloat(column) * (Self.width + 20), y: row, width: Self.width, height: shape.height)
            }
            content.layoutSubtreeIfNeeded()
            let what = "\(shape.label), \(points) pt, \(direction == .rightToLeft ? "right to left" : "left to right"), \(scale)x"
            #expect(cell.textField?.frame == reference.textField?.frame, "\(what): text at \(String(describing: cell.textField?.frame)), constraints put it at \(String(describing: reference.textField?.frame))")
            #expect(cell.imageView?.frame == reference.imageView?.frame, "\(what): icon at \(String(describing: cell.imageView?.frame)), constraints put it at \(String(describing: reference.imageView?.frame))")
            let drawn = try Self.render(cell)
            #expect(Self.inked(drawn) > 0, "\(what): the new cell draws nothing")
            #expect(try Self.inked(Self.render(reference)) > 0, "\(what): the constraint cell draws nothing")
            #expect(try Self.differing(drawn, Self.render(reference)) == 0, "\(what): pixels differ from the constraint cell")
            #expect(try Self.differing(drawn, Self.render(shifted)) > 0, "\(what): a one-pixel shift drew the same pixels")
        }
    }
}

extension ResultCellPixelTests {
    private static func shapes(_ size: TextSize, direction: NSUserInterfaceLayoutDirection) -> [PixelShape] {
        let name = direction == .rightToLeft ? "تقرير الربع الأخير النهائي للمراجعة.pdf" : "Quarterly Report Final Version for Review.pdf"
        let icon = NSWorkspace.shared.icon(for: UTType.pdf)
        let main = ResultsTable.rowHeight(size)
        let launcher = LauncherMetrics.rowHeight(size)
        let padding = SearchMetrics.cellPadding
        let gap = SearchMetrics.iconGap
        let square = SearchMetrics.iconSize
        let wide = LauncherMetrics.cellPadding
        let spaced = LauncherMetrics.iconGap
        let large = LauncherMetrics.iconSize
        return [
            PixelShape(
                label: "Name", font: ResultsTable.font(size), height: main, padding: padding, iconGap: gap, iconSize: square, icon: icon,
                text: name, matches: [0..<5], tone: .labelColor
            ),
            PixelShape(
                label: "Folder", font: ResultsTable.font(size), height: main, padding: padding, iconGap: gap, iconSize: square,
                text: "/Users/someone/Library/Application Support/Wherever/Archives/2026", cut: .byTruncatingMiddle
            ),
            PixelShape(
                label: "Size", font: ResultsTable.font(size), height: main, padding: padding, iconGap: gap, iconSize: square,
                text: "2,048 KB", alignment: ResultsTable.trailing(in: direction)
            ),
            PixelShape(
                label: "Modified", font: ResultsTable.dateFont(size), height: main, padding: padding, iconGap: gap, iconSize: square,
                text: "27/10/2026 12:58:58"
            ),
            PixelShape(
                label: "launcher Name", font: size.font(.preferredFont(forTextStyle: .body)), height: launcher, padding: wide, iconGap: spaced, iconSize: large,
                icon: icon, text: name, matches: [0..<5], tone: .labelColor, cut: .byTruncatingMiddle
            ),
            PixelShape(
                label: "launcher Folder", font: size.font(.preferredFont(forTextStyle: .callout)), height: launcher, padding: wide, iconGap: spaced, iconSize: large,
                text: "/Users/someone/Documents/Reports/Quarterly", cut: .byTruncatingMiddle
            ),
        ]
    }

    private static func resultCell(_ shape: PixelShape, direction: NSUserInterfaceLayoutDirection) -> ResultCell {
        let cell = ResultCell.make(NSUserInterfaceItemIdentifier(shape.label), icon: shape.icon != nil, font: shape.font)
        cell.userInterfaceLayoutDirection = direction
        cell.textField?.alignment = shape.alignment
        cell.textField?.lineBreakMode = shape.cut
        cell.tone = shape.tone
        cell.matchTone = .controlAccentColor
        cell.padding = shape.padding
        cell.iconGap = shape.iconGap
        cell.iconSize = shape.iconSize
        cell.show(shape.text, matches: shape.matches)
        cell.imageView?.image = shape.icon
        return cell
    }

    private static func constraintCell(_ shape: PixelShape, direction: NSUserInterfaceLayoutDirection, padding: CGFloat) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.userInterfaceLayoutDirection = direction
        let text = NSTextField(labelWithString: "")
        text.font = shape.font
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(text)
        cell.textField = text
        var leading = cell.leadingAnchor
        if let icon = shape.icon {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.setAccessibilityElement(false)
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: padding),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: shape.iconSize),
                image.heightAnchor.constraint(equalToConstant: shape.iconSize),
            ])
            leading = image.trailingAnchor
            image.image = icon
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: shape.icon != nil ? shape.iconGap : padding),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -padding),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        text.alignment = shape.alignment
        text.lineBreakMode = shape.cut
        paint(text, shape)
        return cell
    }

    private static func paint(_ field: NSTextField, _ shape: PixelShape) {
        let length = (shape.text as NSString).length
        let runs = shape.matches.filter { $0.lowerBound >= 0 && $0.upperBound <= length }
        guard !runs.isEmpty, let font = field.font else {
            field.stringValue = shape.text
            field.textColor = shape.tone
            return
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = field.lineBreakMode
        style.alignment = field.alignment
        let string = NSMutableAttributedString(string: shape.text, attributes: [.font: font, .foregroundColor: shape.tone, .paragraphStyle: style])
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for run in runs {
            string.addAttributes([.font: bold, .foregroundColor: NSColor.controlAccentColor], range: NSRange(run))
        }
        field.attributedStringValue = string
    }

    private static func render(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        try #require(!rep.isPlanar && rep.bitsPerPixel % 8 == 0, "a planar or packed bitmap")
        let data = try #require(rep.bitmapData)
        data.update(repeating: 0, count: rep.bytesPerPlane)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func inked(_ rep: NSBitmapImageRep) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let bytes = rep.bitsPerPixel / 8
        return (0..<rep.pixelsHigh).reduce(0) { count, y in
            count + (0..<rep.pixelsWide).filter { x in (0..<bytes).contains { data[y * rep.bytesPerRow + x * bytes + $0] != 0 } }.count
        }
    }

    private static func differing(_ left: NSBitmapImageRep, _ right: NSBitmapImageRep) throws -> Int {
        try #require(
            left.pixelsWide == right.pixelsWide && left.pixelsHigh == right.pixelsHigh && left.bitsPerPixel == right.bitsPerPixel
                && left.bytesPerRow == right.bytesPerRow && left.bitmapFormat == right.bitmapFormat,
            "bitmaps of \(left.pixelsWide)x\(left.pixelsHigh) and \(right.pixelsWide)x\(right.pixelsHigh) differ in shape"
        )
        let one = try #require(left.bitmapData)
        let two = try #require(right.bitmapData)
        let bytes = left.bitsPerPixel / 8
        return (0..<left.pixelsHigh).reduce(0) { count, y in
            count + (0..<left.pixelsWide).filter { x in
                let at = y * left.bytesPerRow + x * bytes
                return (0..<bytes).contains { one[at + $0] != two[at + $0] }
            }.count
        }
    }
}
