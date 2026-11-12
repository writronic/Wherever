import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import WhereverInterface

final class ResultCell: NSTableCellView {
    var tone = NSColor.labelColor {
        didSet { if tone != oldValue { paint() } }
    }
    var matchTone = NSColor.labelColor {
        didSet { if matchTone != oldValue { paint() } }
    }
    var path = ""
    var padding = SearchMetrics.cellPadding {
        didSet { if padding != oldValue { needsLayout = true } }
    }
    var iconGap = SearchMetrics.iconGap {
        didSet { if iconGap != oldValue { needsLayout = true } }
    }
    var iconSize = SearchMetrics.iconSize {
        didSet { if iconSize != oldValue { needsLayout = true } }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { paint() }
    }

    override var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection {
        didSet { needsLayout = true }
    }

    private var text = ""
    private var matches: [Range<Int>] = []

    func show(_ text: String, matches: [Range<Int>] = []) {
        self.text = text
        self.matches = matches
        paint()
        needsLayout = true
    }

    private func paint() {
        guard let field = textField else { return }
        let selected = backgroundStyle == .emphasized
        let color = selected ? NSColor.alternateSelectedControlTextColor : tone
        let length = (text as NSString).length
        let runs = matches.filter { $0.lowerBound >= 0 && $0.upperBound <= length }
        guard !runs.isEmpty, let font = field.font else {
            field.stringValue = text
            field.textColor = color
            return
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = field.lineBreakMode
        style.alignment = field.alignment
        let string = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for run in runs {
            string.addAttributes([.font: bold, .foregroundColor: selected ? color : matchTone], range: NSRange(run))
        }
        field.attributedStringValue = string
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { needsLayout = true }
        super.setFrameSize(newSize)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let field = textField else { return }
        let rightToLeft = userInterfaceLayoutDirection == .rightToLeft
        let icon = imageView == nil ? 0 : iconSize + iconGap
        let width = max(0, bounds.width - 2 * padding - icon)
        if let image = imageView {
            image.frame = image.frame(forAlignmentRect: centered(x: rightToLeft ? padding + width + iconGap : padding, width: iconSize, height: iconSize))
        }
        field.frame = field.frame(forAlignmentRect: centered(x: rightToLeft ? padding : padding + icon, width: width, height: field.intrinsicContentSize.height))
    }

    private func centered(x: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
        backingAlignedRect(NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height), options: .alignAllEdgesNearest)
    }

    static func make(_ identifier: NSUserInterfaceItemIdentifier, icon: Bool, font: NSFont) -> ResultCell {
        let cell = ResultCell()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.font = font
        cell.addSubview(text)
        cell.textField = text
        if icon {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.setAccessibilityElement(false)
            cell.addSubview(image)
            cell.imageView = image
        }
        return cell
    }
}

enum ResultType {
    private static var cache: [String: (icon: NSImage, kind: String)] = [:]

    static func of(_ hit: SearchHit) -> (icon: NSImage, kind: String) {
        let ext = (hit.name as NSString).pathExtension.lowercased()
        let key = "\(hit.kind) \(ext)"
        if let found = cache[key] { return found }
        let named = ext.isEmpty ? nil : UTType(filenameExtension: ext).flatMap { $0.isDynamic ? nil : $0 }
        let type: UTType = switch hit.kind {
        case .link: .symbolicLink
        case .folder: named.flatMap { $0.conforms(to: .package) ? $0 : nil } ?? .folder
        case .file: named ?? .data
        }
        let found = (NSWorkspace.shared.icon(for: type), type.localizedDescription ?? UTType.data.localizedDescription ?? "")
        cache[key] = found
        return found
    }
}

final class FileDates: ObservableObject {
    static let current = FileDates()
    @Published private(set) var revision = 0
    private var widths: [TextSize: CGFloat] = [:]
    private(set) var formatter = DateFormatter()
    private let calendar: Calendar
    private let localeProvider: () -> Locale
    private var watch: AnyCancellable?

    init(locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent, localeProvider: (() -> Locale)? = nil) {
        self.calendar = calendar
        self.localeProvider = localeProvider ?? { locale }
        rebuild()
        watch = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuild() }
    }

    private func rebuild() {
        let next = DateFormatter()
        next.locale = localeProvider()
        next.calendar = calendar
        next.timeZone = calendar.timeZone
        next.dateStyle = .short
        next.timeStyle = .medium
        var quoted = false
        next.dateFormat = next.dateFormat.split(separator: "'", omittingEmptySubsequences: false).map { part in
            defer { quoted.toggle() }
            return quoted ? String(part) : String(part).replacingOccurrences(of: "(?<!y)yy(?!y)", with: "yyyy", options: .regularExpression)
        }.joined(separator: "'")
        formatter = next
        widths = [:]
        revision += 1
    }

    func string(_ date: Date) -> String { formatter.string(from: date) }

    func width(_ size: TextSize) -> CGFloat {
        if let found = widths[size] { return found }
        let found = columnWidth(font: ResultsTable.dateFont(size))
        widths[size] = found
        return found
    }

    func columnWidth(font: NSFont, now: Date = .now) -> CGFloat {
        let label = NSTextField(labelWithString: "")
        label.font = font
        func measure(_ date: Date) -> CGFloat {
            label.stringValue = string(date)
            return label.intrinsicContentSize.width
        }
        let start = calendar.date(bySettingHour: 12, minute: 58, second: 58, of: now) ?? now
        let days = (0..<366).compactMap { calendar.date(byAdding: .day, value: -$0, to: start) }
        let widestDay = days.map { ($0, measure($0)) }.max { $0.1 < $1.1 }?.0 ?? start
        let hours = (0..<24).compactMap { calendar.date(bySettingHour: $0, minute: 58, second: 58, of: widestDay) }
        let widest = hours.map(measure).max() ?? measure(widestDay)
        return max(SearchMetrics.modifiedColumnWidth, ceil(widest) + 2 * SearchMetrics.cellPadding)
    }
}
