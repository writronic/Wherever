import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

@Suite struct SearchFiltersTests {
    @Test func everyPresetWritesItsExactToken() {
        let kinds: [(SearchFilters.Kind, String?)] = [
            (.any, nil), (.files, "kind:file"), (.folders, "kind:folder"), (.links, "kind:link"), (.images, "type:image"),
            (.videos, "type:video"), (.audio, "type:audio"), (.documents, "type:doc"), (.code, "type:code"),
            (.archives, "type:archive"), (.fonts, "type:font"), (.apps, "type:app"),
        ]
        #expect(SearchFilters.Kind.allCases.count == kinds.count)
        for (kind, token) in kinds { #expect(SearchFilters(kind: kind).tokens == (token ?? ""), "\(kind)") }

        let sizes: [(SearchFilters.Size, String?)] = [
            (.any, nil), (.small, "size:<=1mb"), (.medium, "size:1mb..100mb"), (.large, "size:100mb..1gb"), (.huge, "size:>=1gb"),
        ]
        #expect(SearchFilters.Size.allCases.count == sizes.count)
        for (size, token) in sizes { #expect(SearchFilters(size: size).tokens == (token ?? ""), "\(size)") }

        let times: [(SearchFilters.Modified, String?)] = [
            (.any, nil), (.day, "mtime:<1d"), (.week, "mtime:<7d"), (.month, "mtime:<30d"), (.year, "mtime:<365d"),
        ]
        #expect(SearchFilters.Modified.allCases.count == times.count)
        for (modified, token) in times { #expect(SearchFilters(modified: modified).tokens == (token ?? ""), "\(modified)") }

        #expect(SearchFilters(hidesHidden: true).tokens == "hidden:no")
        #expect(SearchFilters(folder: "/Volumes/Disk 1/Photos").tokens == "in:\"/Volumes/Disk 1/Photos\"")
        #expect(SearchFilters(folder: "/tmp/Notes \"draft\"").tokens == "in:\"/tmp/Notes \"\"draft\"\"\"")
    }

    @Test func noFilterWritesNoToken() {
        #expect(SearchFilters().tokens == "")
    }

    @Test func extensionsLoseSpacesDotsCaseAndQuotes() {
        let typed: [(String, String)] = [
            ("pdf, .docx", "ext:pdf,docx"), ("PDF", "ext:pdf"), ("  pdf  ", "ext:pdf"), ("pdf docx", "ext:pdf,docx"),
            ("tar.gz", "ext:gz"), ("c++, a_b-c", "ext:c++,a_b-c"), ("\"pdf", "ext:pdf"), ("pdf\" kind:file", "ext:pdf,kindfile"),
            ("pdf,,docx,", "ext:pdf,docx"), ("jpg;png", "ext:jpg,png"), ("pdf; .Docx;", "ext:pdf,docx"),
        ]
        for (text, token) in typed { #expect(SearchFilters(extensions: text).tokens == token, "\(text)") }
        for empty in ["", " ", ",", " , ,", ";", " ; ,", ".", "\"", "\"\""] { #expect(SearchFilters(extensions: empty).tokens == "", "\(empty)") }
    }

    @Test func tokensJoinInTheFixedOrder() {
        var filters = SearchFilters(
            extensions: "pdf, .docx", kind: .folders, size: .medium, modified: .week, folder: "/tmp/A B", hidesHidden: true
        )
        #expect(filters.tokens == "ext:pdf,docx kind:folder size:1mb..100mb mtime:<7d in:\"/tmp/A B\" hidden:no")
        filters.kind = .images
        filters.folder = nil
        #expect(filters.tokens == "ext:pdf,docx type:image size:1mb..100mb mtime:<7d hidden:no")
        filters.size = .any
        #expect(filters.tokens == "ext:pdf,docx type:image mtime:<7d hidden:no")
    }

    @Test func onlyHiddenAloneDoesNotNarrowTheResults() {
        #expect(!SearchFilters().narrowsResults)
        #expect(!SearchFilters(hidesHidden: true).narrowsResults)
        #expect(SearchFilters(extensions: "pdf").narrowsResults)
        #expect(SearchFilters(kind: .files, hidesHidden: true).narrowsResults)
        #expect(SearchFilters(size: .small).narrowsResults)
        #expect(SearchFilters(modified: .day).narrowsResults)
        #expect(SearchFilters(folder: "/tmp").narrowsResults)
        #expect(!SearchFilters(extensions: ",").narrowsResults)
    }
}

@Suite struct SearchModelFilterTests {
    @Test func noFilterSendsTheTypedTextAlone() {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "report"
        #expect(fake.queries == ["report"])
    }

    @Test func eachFilterAddsItsTokenAfterTheText() {
        let steps: [(String, (SearchModel) -> Void)] = [
            ("report ext:pdf,docx", { $0.filters.extensions = "pdf, .docx" }),
            ("report kind:folder", { $0.filters.kind = .folders }),
            ("report type:image", { $0.filters.kind = .images }),
            ("report size:1mb..100mb", { $0.filters.size = .medium }),
            ("report mtime:<7d", { $0.filters.modified = .week }),
            ("report in:\"/tmp/A B\"", { $0.filters.folder = "/tmp/A B" }),
            ("report hidden:no", { $0.filters.hidesHidden = true }),
        ]
        for (expected, set) in steps {
            let fake = FakeSearchClient()
            let index = IndexModel(client: fake)
            let model = index.makeModel()
            model.query = "report"
            set(model)
            #expect(fake.queries == ["report", expected])
        }
    }

    @Test func allSixSendTheFixedOrderAndClearingOneRemovesOnlyItsToken() {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "report"
        model.filters = SearchFilters(
            extensions: "pdf", kind: .documents, size: .large, modified: .month, folder: "/tmp/A B", hidesHidden: true
        )
        #expect(fake.queries.last == "report ext:pdf type:doc size:100mb..1gb mtime:<30d in:\"/tmp/A B\" hidden:no")
        model.filters.size = .any
        #expect(fake.queries.last == "report ext:pdf type:doc mtime:<30d in:\"/tmp/A B\" hidden:no")
        model.filters.hidesHidden = false
        #expect(fake.queries.last == "report ext:pdf type:doc mtime:<30d in:\"/tmp/A B\"")
        model.filters = SearchFilters()
        #expect(fake.queries.last == "report")
        #expect(fake.queries.count == 5)
    }

    @Test func everyKeystrokeKeepsTheToken() {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.filters.kind = .folders
        for text in ["r", "re", "rep"] { model.query = text }
        #expect(fake.queries == ["kind:folder", "r kind:folder", "re kind:folder", "rep kind:folder"])
    }

    @Test func clearingTheTextWithAFilterSearchesWithTheTokensOnly() {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.filters.extensions = "pdf"
        model.query = "rep"
        model.query = ""
        #expect(fake.queries == ["ext:pdf", "rep ext:pdf", "ext:pdf"])
    }

    @Test func hiddenAloneWithAnEmptyFieldSendsNothingAndClearsTheRows() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "rep"
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the row") { model.names == ["Safari.app"] }
        model.filters.hidesHidden = true
        #expect(fake.queries == ["rep", "rep hidden:no"])
        model.query = ""
        #expect(fake.queries == ["rep", "rep hidden:no"])
        #expect(model.count == 0)

        let alone = FakeSearchClient()
        let aloneIndex = IndexModel(client: alone)
        let aloneModel = aloneIndex.makeModel()
        aloneModel.filters.hidesHidden = true
        #expect(alone.queries.isEmpty)
        aloneModel.filters.hidesHidden = false
        #expect(alone.queries.isEmpty)
    }

    @Test func anOpenQuoteIsClosedBeforeTheTokens() {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "\"my file"
        model.filters.extensions = "pdf"
        model.query = "\"my file\""
        model.query = "a \"b\" \"c"
        #expect(fake.queries == ["\"my file", "\"my file\" ext:pdf", "\"my file\" ext:pdf", "a \"b\" \"c\" ext:pdf"])
    }

    @Test func aLateResultForTheOldFilterChangesNothing() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        let older = fake.latest
        model.filters.kind = .folders
        let newer = fake.latest
        fake.send(.resultsReady(older, count: 1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.rowRequests.isEmpty)
        #expect(model.count == 0)
        fake.send(.resultsReady(newer, count: 1))
        try await untilTrue(waitingFor: "the newer rows") { model.names == ["Safari.app"] }
        #expect(fake.rowRequests == [.init(generation: newer, range: 0..<1)])
    }

    @Test func aLiveChangeRepeatsTheSearchWithTheTokens() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.filters.kind = .folders
        fake.send(.resultsReady(fake.latest, count: 0))
        fake.send(.resultsChanged)
        try await untilTrue(waitingFor: "the repeated search") { fake.queries.count == 2 }
        #expect(fake.queries == ["kind:folder", "kind:folder"])
    }
}

@Suite(.serialized) struct FilterBarTests {
    private struct Harness: View {
        @ObservedObject var model: SearchModel
        let bundle: Bundle
        let locale: String
        var direction = LayoutDirection.leftToRight

        var body: some View {
            FilterBar(filters: $model.filters, bundle: bundle).environment(\.locale, Locale(identifier: locale)).environment(\.layoutDirection, direction)
        }
    }

    private final class Bar {
        let fake: FakeSearchClient
        let index: IndexModel
        let model: SearchModel
        let host: SearchHost

        init(locale: String = "en", direction: LayoutDirection = .leftToRight, hits: [SearchHit] = [], normal: Bool = false, store: UserDefaults? = nil) {
            let fake = FakeSearchClient(hits: hits)
            fake.setVolumes(.success([]))
            let index = IndexModel(client: fake)
            let model = index.makeModel()
            self.fake = fake
            self.index = index
            self.model = model
            let bundle = Bundle.main.url(forResource: locale, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? .main
            let root: AnyView = normal
                ? AnyView(SearchView(model: model, mode: .normal, bundle: bundle).environment(\.searchClient, fake))
                : AnyView(Harness(model: model, bundle: bundle, locale: locale, direction: direction))
            host = SearchHost(root: store.map { AnyView(root.defaultAppStorage($0)) } ?? root)
        }

        func element(_ id: String) -> NSObject? { AXTree.element(id, in: host.view) }

        func control(_ id: String) async throws -> NSObject {
            try await host.until("the \(id) control among \(AXTree.nodeCount(in: host.view)) accessibility nodes") { self.element(id) != nil }
            return try #require(element(id))
        }

        func pill(_ id: String) async throws -> NSButton {
            try await host.until("the \(id) pill") { self.pillView(id) != nil }
            return try #require(pillView(id))
        }

        private func pillView(_ id: String) -> NSButton? {
            Self.descendants(NSButton.self, in: host.view).first { $0.identifier?.rawValue == id }
        }

        func popoverField() -> NSTextField? {
            NSApp.windows.filter(\.isVisible).compactMap { $0.contentView.flatMap { AXTree.textField(FilterBar.extensionsFieldID, in: $0) } }.first
        }

        func openExtensions() async throws -> NSTextField {
            try await pill(FilterBar.extensionsID).performClick(nil)
            try await host.until("the extensions field in its popover") { self.popoverField() != nil }
            return try #require(popoverField())
        }

        func type(_ text: String, into field: NSTextField) throws {
            let window = try #require(field.window)
            try #require(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }

        func key(_ characters: String, code: UInt16, in window: NSWindow) throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ))
            window.sendEvent(event)
        }

        func setExtensions(_ text: String) async throws {
            let field = try await openExtensions()
            let window = try #require(field.window)
            try type(text, into: field)
            try key("\r", code: 36, in: window)
            try await host.until("the popover to close") { self.popoverField() == nil }
        }

        func choose<T: CaseIterable & Equatable>(_ value: T, in id: String) async throws {
            let target = try #require(Array(T.allCases).firstIndex(of: value))
            let button = try await pill(id)
            let menu = try #require(button.menu)
            menu.performActionForItem(at: target)
        }

        func click(_ id: String) async throws {
            let found = try await control(id)
            try #require(AXTree.press(found), "\(id) took no press")
        }

        func queryEnds(_ expected: String) async throws {
            try await host.until("the query \(expected); sent \(fake.queries)") { self.fake.queries.last == expected }
        }

        func screenFrame(_ view: NSView) -> NSRect { host.window.convertToScreen(view.convert(view.bounds, to: nil)) }

        func laidOut(_ view: NSView) -> NSRect {
            host.window.convertToScreen(view.superview.map { $0.convert(view.alignmentRect(forFrame: view.frame), to: nil) } ?? view.convert(view.bounds, to: nil))
        }

        func isSemibold(_ pill: NSButton) -> Bool {
            let traits = pill.font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            return (traits?[.weight] as? CGFloat ?? 0) >= NSFont.Weight.semibold.rawValue
        }

        static func titles(of pill: NSButton) -> [String] { pill.menu?.items.map(\.title) ?? [] }

        static func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
            root.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + descendants(type, in: $0) }
        }

        static func links(from start: NSView) -> [NSView] {
            var links = [start]
            while let next = links.last?.nextKeyView, !links.contains(where: { $0 === next }) { links.append(next) }
            return links
        }
    }

    private static let pillIDs = [FilterBar.kindID, FilterBar.extensionsID, FilterBar.sizeID, FilterBar.modifiedID]
    private static let barIDs = pillIDs + [FilterBar.hiddenID]

    @Test func eachControlWritesItsTokenAfterTheText() async throws {
        let steps: [(expected: String, act: (Bar) async throws -> Void)] = [
            ("report ext:pdf,docx", { try await $0.setExtensions("pdf, .docx") }),
            ("report kind:folder", { try await $0.choose(SearchFilters.Kind.folders, in: FilterBar.kindID) }),
            ("report type:image", { try await $0.choose(SearchFilters.Kind.images, in: FilterBar.kindID) }),
            ("report size:1mb..100mb", { try await $0.choose(SearchFilters.Size.medium, in: FilterBar.sizeID) }),
            ("report mtime:<7d", { try await $0.choose(SearchFilters.Modified.week, in: FilterBar.modifiedID) }),
        ]
        for step in steps {
            let bar = Bar()
            defer { bar.host.close() }
            bar.model.query = "report"
            try await step.act(bar)
            try await bar.queryEnds(step.expected)
            #expect(bar.fake.queries == ["report", step.expected])
        }
    }

    @Test(arguments: [("en", LayoutDirection.leftToRight), ("ar", LayoutDirection.rightToLeft)])
    func eachMenuPillOpensItsMenuUnderThePill(locale: String, direction: LayoutDirection) async throws {
        let bar = Bar(locale: locale, direction: direction)
        defer { bar.host.close() }
        bar.host.window.center()
        for id in [FilterBar.kindID, FilterBar.sizeID, FilterBar.modifiedID] {
            let pill = try await bar.pill(id)
            #expect((pill.userInterfaceLayoutDirection == .rightToLeft) == (direction == .rightToLeft))
            let menu = try #require(pill.menu)
            let ways: [(String, () -> Void)] = [("click", { pill.performClick(nil) }), ("VoiceOver press", { _ = pill.accessibilityPerformPress() })]
            for (way, open) in ways {
                try await EventQueueLock.run {
                    try await bar.host.until("the previous popup closes") { !MenuPlacement.popUpShown }
                    let placement = MenuPlacement(menu)
                    placement.measure(open)
                    let shown = try #require(placement.frame, "\(locale) \(id) \(way) opened no menu")
                    let control = bar.screenFrame(pill)
                    #expect(MenuPlacement.opens(shown, under: control, rightToLeft: direction == .rightToLeft), "\(locale) \(id) \(way): menu \(shown) beside pill \(control)")
                }
            }
        }
    }

    @Test func everyOffPillShowsItsArrowAndReadsAlike() async throws {
        let bar = Bar()
        defer { bar.host.close() }
        func drawn(_ pill: NSButton) -> Data? {
            pill.layoutSubtreeIfNeeded()
            guard let rep = pill.bitmapImageRepForCachingDisplay(in: pill.bounds) else { return nil }
            pill.cacheDisplay(in: pill.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }
        var fonts: [NSFont] = []
        for id in Self.pillIDs {
            let pill = try await bar.pill(id)
            fonts.append(try #require(pill.font))
            #expect(!pill.isBordered && !bar.isSemibold(pill), "\(id)")
            #expect(pill.contentTintColor == .labelColor, "\(id)")
            let with = drawn(pill)
            let image = pill.image
            pill.image = nil
            let without = drawn(pill)
            pill.image = image
            #expect(with != nil && with != without, "\(id) draws no arrow with the pointer outside")
            try expectTitleThenArrow(pill, id)
        }
        #expect(fonts.count == 4 && Set(fonts).count == 1, "the four pill fonts: \(fonts)")
    }

    private func expectTitleThenArrow(_ pill: NSButton, _ id: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        pill.layoutSubtreeIfNeeded()
        let cell = try #require(pill.cell, sourceLocation: sourceLocation)
        let bounds = pill.bounds
        let title = cell.titleRect(forBounds: bounds)
        let arrow = cell.imageRect(forBounds: bounds)
        let rep = try #require(pill.bitmapImageRepForCachingDisplay(in: bounds), sourceLocation: sourceLocation)
        pill.cacheDisplay(in: bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / bounds.width
        #expect((title.minX - bounds.minX - NormalMetrics.pillPadding) * scale == 0, "\(id) title box at \(title)", sourceLocation: sourceLocation)
        #expect((arrow.minX - title.maxX - NormalMetrics.pillArrowGap) * scale == 0, "\(id) title \(title), arrow \(arrow)", sourceLocation: sourceLocation)
        #expect((bounds.maxX - arrow.maxX - NormalMetrics.pillPadding) * scale == 0, "\(id) arrow \(arrow) in \(bounds)", sourceLocation: sourceLocation)
        let inked = (0..<rep.pixelsWide).filter { x in (0..<rep.pixelsHigh).contains { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.3 } }
        func inside(_ x: Int, _ box: NSRect) -> Bool { CGFloat(x) / scale >= box.minX && CGFloat(x + 1) / scale <= box.maxX }
        #expect(inked.contains { inside($0, title) } && inked.contains { inside($0, arrow) }, "\(id) inks \(inked)", sourceLocation: sourceLocation)
        let stray = inked.filter { !inside($0, title) && !inside($0, arrow) }
        #expect(stray.isEmpty, "\(id) inks columns \(stray) outside its title \(title) and arrow \(arrow)", sourceLocation: sourceLocation)
    }

    @Test func eachPillWritesItsTokenAndShowsItsValue() async throws {
        let bar = Bar()
        defer { bar.host.close() }
        bar.model.query = "report"
        let kind = try await bar.pill(FilterBar.kindID)
        #expect(kind.title == "Kind" && !bar.isSemibold(kind) && !kind.isBordered)
        try await bar.choose(SearchFilters.Kind.documents, in: FilterBar.kindID)
        try await bar.queryEnds("report type:doc")
        try await bar.host.until("the Kind pill reads Kind: Documents, not \(kind.title)") { kind.title == "Kind: Documents" }
        #expect(bar.isSemibold(kind))
        #expect(kind.isBordered)
        try await bar.choose(SearchFilters.Kind.any, in: FilterBar.kindID)
        try await bar.queryEnds("report")
        try await bar.host.until("the Kind pill reads Kind again, not \(kind.title)") { kind.title == "Kind" }
        #expect(!bar.isSemibold(kind))
        #expect(!kind.isBordered)

        let size = try await bar.pill(FilterBar.sizeID)
        try await bar.choose(SearchFilters.Size.large, in: FilterBar.sizeID)
        try await bar.host.until("the Size pill reads Size: 100 MB to 1 GB, not \(size.title)") { size.title == "Size: 100 MB to 1 GB" }

        let scale = bar.host.window.backingScaleFactor
        var frames: [NSRect] = []
        for id in Self.pillIDs { frames.append(bar.laidOut(try await bar.pill(id))) }
        for (id, frame) in zip(Self.pillIDs, frames) {
            #expect((frame.height - NormalMetrics.pillHeight) * scale == 0, "\(id) is \(frame.height) high")
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect((right.minX - left.maxX - NormalMetrics.pillSpacing) * scale == 0, "pills at \(left) and \(right)")
        }
        let content = bar.screenFrame(bar.host.view)
        #expect((frames[0].minX - content.minX - SearchMetrics.sideInset) * scale == 0, "the first pill starts at \(frames[0].minX), content at \(content.minX)")
        let box = try await bar.control(FilterBar.hiddenID)
        let checkbox = try #require(AXTree.frame(of: box), "the checkbox has no frame")
        #expect(checkbox.minX >= frames[3].maxX, "the checkbox at \(checkbox) does not follow the pills")
        #expect((bar.host.view.fittingSize.height - NormalMetrics.filterBarHeight) * scale == 0, "the bar is \(bar.host.view.fittingSize.height) high")
        #expect(bar.element("filter-folder") == nil)
    }

    private static let thirtyExtensions = (1...30).map { "ext\($0)" }.joined(separator: ", ")

    @Test func thirtyExtensionsStopAtTheWidestKindPillAndTheTooltipKeepsThemAll() async throws {
        let bar = Bar()
        defer { bar.host.close() }
        let kind = try await bar.pill(FilterBar.kindID)
        let pill = try await bar.pill(FilterBar.extensionsID)
        let scale = bar.host.window.backingScaleFactor
        var widest: CGFloat = 0
        for (title, value) in zip(Bar.titles(of: kind), SearchFilters.Kind.allCases) where value != .any {
            bar.model.filters.kind = value
            try await bar.host.until("the Kind pill reads Kind: \(title), not \(kind.title)") { kind.title == "Kind: \(title)" }
            bar.host.view.layoutSubtreeIfNeeded()
            widest = max(widest, bar.laidOut(kind).width)
        }
        let alone = bar.laidOut(pill).width
        bar.model.filters.extensions = Self.thirtyExtensions
        let full = "Extension: \(Self.thirtyExtensions)"
        try await bar.host.until("the pill reads the 30 extensions, not \(pill.title)") { pill.title == full }
        bar.host.view.layoutSubtreeIfNeeded()
        #expect(alone < widest)
        #expect((bar.laidOut(pill).width - widest) * scale == 0, "the Extension pill is \(bar.laidOut(pill).width) wide, the widest Kind pill \(widest)")
        #expect(pill.toolTip == full)
        #expect(pill.cell?.lineBreakMode == .byTruncatingMiddle)
        bar.model.filters.extensions = ""
        try await bar.host.until("the pill back to Extension") { pill.title == "Extension" && pill.toolTip == nil }
        bar.host.view.layoutSubtreeIfNeeded()
        #expect((bar.laidOut(pill).width - alone) * scale == 0)
    }

    @Test func thirtyExtensionsKeepTheNormalWindowsWidthOfOneExtension() async throws {
        let one = Bar(normal: true)
        defer { one.host.close() }
        let many = Bar(normal: true)
        defer { many.host.close() }
        one.model.filters.extensions = "pdf"
        many.model.filters.extensions = Self.thirtyExtensions
        let pdf = try await one.pill(FilterBar.extensionsID)
        let list = try await many.pill(FilterBar.extensionsID)
        try await one.host.until("the pill reads Extension: pdf") { pdf.title == "Extension: pdf" }
        try await many.host.until("the pill reads the 30 extensions") { list.title == "Extension: \(Self.thirtyExtensions)" }
        one.host.view.layoutSubtreeIfNeeded()
        many.host.view.layoutSubtreeIfNeeded()
        #expect(many.host.view.fittingSize.width == one.host.view.fittingSize.width, "\(many.host.view.fittingSize.width) wide with 30, \(one.host.view.fittingSize.width) with one")
    }

    @Test func theExtensionPillTakesTypedExtensions() async throws {
        let bar = Bar()
        defer { bar.host.close() }
        bar.model.query = "report"
        let pill = try await bar.pill(FilterBar.extensionsID)
        #expect(pill.title == "Extension")
        let field = try await bar.openExtensions()
        let window = try #require(field.window)
        try bar.type("pdf", into: field)
        try await bar.queryEnds("report ext:pdf")
        try bar.key("\r", code: 36, in: window)
        try await bar.host.until("the popover to close") { bar.popoverField() == nil }
        try await bar.host.until("the pill reads Extension: pdf, not \(pill.title)") { pill.title == "Extension: pdf" }
        #expect(bar.model.query == "report")

        let again = try await bar.openExtensions()
        let second = try #require(again.window)
        try bar.key("\u{1b}", code: 53, in: second)
        try await bar.host.until("the popover to close on Escape") { bar.popoverField() == nil }
        #expect(bar.model.filters.extensions == "pdf")
        #expect(bar.model.query == "report")
        #expect(bar.fake.queries == ["report", "report ext:pdf"])
    }

    @Test func theHiddenCheckboxReadsHideInvisibleFiles() async throws {
        let bar = Bar()
        defer { bar.host.close() }
        bar.model.query = "report"
        let box = try await bar.control(FilterBar.hiddenID)
        #expect(AXTree.names(of: box).contains("Hide invisible files"), "the checkbox reads \(AXTree.names(of: box))")
        #expect(AXTree.isOn(box) == false)
        try await bar.click(FilterBar.hiddenID)
        try await bar.host.until("the checkbox on") { bar.element(FilterBar.hiddenID).flatMap(AXTree.isOn) == true }
        #expect(!bar.model.filters.hidesHidden)
        #expect(bar.fake.queries == ["report"])
    }

    @Test func theModifiedMenuReadsLast12Months() async throws {
        for (locale, last) in [("en", "Last 12 months"), ("de", "Letzte 12 Monate")] {
            let bar = Bar(locale: locale)
            defer { bar.host.close() }
            let modified = try await bar.pill(FilterBar.modifiedID)
            #expect(Bar.titles(of: modified).last == last, "\(locale) reads \(Bar.titles(of: modified))")
        }
        let bar = Bar()
        defer { bar.host.close() }
        bar.model.query = "report"
        let modified = try await bar.pill(FilterBar.modifiedID)
        try await bar.choose(SearchFilters.Modified.year, in: FilterBar.modifiedID)
        try await bar.queryEnds("report mtime:<365d")
        try await bar.host.until("the Modified pill reads Modified: Last 12 months, not \(modified.title)") { modified.title == "Modified: Last 12 months" }
    }

    @Test func escapeTwiceTurnsEveryPillOff() async throws {
        let bar = Bar(normal: true)
        defer { bar.host.close() }
        try await bar.host.until("the File name field to hold focus") { bar.host.fieldHasFocus }
        try await bar.host.type("rep")
        try await bar.choose(SearchFilters.Kind.documents, in: FilterBar.kindID)
        try await bar.choose(SearchFilters.Size.medium, in: FilterBar.sizeID)
        try await bar.choose(SearchFilters.Modified.week, in: FilterBar.modifiedID)
        bar.model.filters.extensions = "pdf"
        let pills = try await Self.pillIDs.asyncMap { try await bar.pill($0) }
        try await bar.host.until("every pill on, reading \(pills.map(\.title))") { pills.allSatisfy { $0.title.contains(": ") } }
        try bar.host.pressEscape()
        try await bar.host.until("the text cleared") { bar.model.query.isEmpty }
        try bar.host.pressEscape()
        try await bar.host.until("the filters cleared") { bar.model.filters == SearchFilters() }
        try await bar.host.until("every pill off, reading \(pills.map(\.title))") { pills.allSatisfy { !$0.title.contains(": ") } }
        #expect(pills.allSatisfy { !$0.isBordered && !bar.isSemibold($0) })
    }

    @Test func thePillsKeepTheDrawnOrderInTheKeyViewLoop() async throws {
        let bar = Bar()
        defer { bar.host.close() }
        let pills = try await Self.pillIDs.asyncMap { try await bar.pill($0) }
        try await bar.host.until("every pill among the links") {
            bar.host.window.recalculateKeyViewLoop()
            let links = Bar.links(from: pills[0])
            return pills.allSatisfy { pill in links.contains { $0 === pill } }
        }
        let links = Bar.links(from: pills[0])
        let places = pills.compactMap { pill in links.firstIndex { $0 === pill } }
        #expect(places.count == pills.count && places == places.sorted(), "the links run \(links.map { String(describing: type(of: $0)) })")
        #expect(links.last?.nextKeyView === pills[0], "the chain does not wrap to Kind")
        let loop = bar.host.keyViewLoop(from: pills[0])
        let names = loop.map { String(describing: type(of: $0)) }
        if NSApp.isFullKeyboardAccessEnabled {
            let stops = pills.compactMap { pill in loop.firstIndex { $0 === pill } }
            #expect(stops.count == pills.count && stops == stops.sorted(), "the stops run \(names)")
        } else {
            #expect(!loop.dropFirst().contains { view in pills.contains { $0 === view } }, "a pill is a stop with Keyboard navigation off: \(names)")
        }
    }

    @Test func aPersonsKeystrokeNeverTypesIntoTheHost() async throws {
        for guarded in [false, true] {
            let fake = FakeSearchClient()
            let index = IndexModel(client: fake)
            let model = index.makeModel()
            let host = SearchHost(root: AnyView(ContentView(index: index, model: model)), reportsKey: true, guardsKeys: guarded)
            defer { host.close() }
            try await host.type("s")
            let stray = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.window.windowNumber, context: nil, characters: "3", charactersIgnoringModifiers: "3",
                isARepeat: false, keyCode: 20
            ))
            NSApp.sendEvent(stray)
            try host.sendKeys("a")
            if guarded {
                #expect(fake.queries == ["s", "sa"])
            } else {
                #expect(
                    fake.queries == ["s", "s3", "s3a"],
                    "AppKit never routed a key from NSApp.sendEvent to this window, so the guarded half proves nothing"
                )
            }
        }
    }

    @Test func clearingTheTextWithAFilterSearchesWithTheTokensOnly() async throws {
        let bar = Bar()
        defer { bar.host.close() }
        try await bar.setExtensions("pdf")
        try await bar.queryEnds("ext:pdf")
        bar.model.query = "sa"
        bar.model.query = ""
        try await bar.queryEnds("ext:pdf")
        #expect(bar.fake.queries == ["ext:pdf", "sa ext:pdf", "ext:pdf"])
        #expect(bar.model.query.isEmpty)
    }

    @Test func withOnlyHiddenSetClearingTheTextSearchesNothingAndEmptiesTheRows() async throws {
        let bar = Bar(hits: [.named("Safari.app")])
        defer { bar.host.close() }
        bar.model.query = "sa"
        bar.fake.send(.resultsReady(bar.fake.latest, count: 1))
        try await bar.host.until("the row") { bar.model.names == ["Safari.app"] }
        bar.model.filters.hidesHidden = true
        try await bar.queryEnds("sa hidden:no")
        bar.model.query = ""
        try await bar.host.until("no rows") { bar.model.count == 0 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(bar.fake.queries == ["sa", "sa hidden:no"])
    }

    @Test func noBarControlHidesItsFocusRing() async throws {
        let bar = Bar()
        defer { bar.host.close() }
        for id in Self.pillIDs {
            let pill = try await bar.pill(id)
            #expect(pill.focusRingType != .none, "\(id) hides its ring")
        }
        _ = try await bar.control(FilterBar.hiddenID)
        let sign = try await requireFocusRingSign()
        let (shown, report) = try await focusRingShown(sign, on: FilterBar.hiddenID, in: bar.host.view, window: bar.host.window)
        #expect(shown, "\(FilterBar.hiddenID) has no focus ring over it: \(report)")
    }

    @Test func everyControlHasAnAccessibilityLabelFromTheFiltersTable() async throws {
        let bar = Bar()
        defer { bar.host.close() }
        let labels = [
            FilterBar.extensionsID: "Extension", FilterBar.kindID: "Kind", FilterBar.sizeID: "Size",
            FilterBar.modifiedID: "Modified", FilterBar.hiddenID: "Hide invisible files",
        ]
        #expect(Set(labels.keys) == Set(Self.barIDs))
        for (id, label) in labels {
            let control = try await bar.control(id)
            let names = AXTree.names(of: control)
            #expect(names.contains(label), "\(id) reads \(names)")
        }
    }

    @Test func theMenusReadTheFiltersTableInTheWindowsLanguage() async throws {
        let titles = [
            ("en", ["Any kind", "Any size", "Any time"]),
            ("de", ["Beliebige Art", "Beliebige Größe", "Beliebige Zeit"]),
            ("tr", ["Herhangi bir tür", "Herhangi bir büyüklük", "Herhangi bir zaman"]),
        ]
        for (locale, expected) in titles {
            let bar = Bar(locale: locale)
            defer { bar.host.close() }
            var seen: [String] = []
            for id in [FilterBar.kindID, FilterBar.sizeID, FilterBar.modifiedID] {
                seen.append(Bar.titles(of: try await bar.pill(id))[0])
            }
            #expect(seen == expected, "\(locale)")
        }
    }

    @Test func thePillsTheirMenusTheCheckboxAndTheBarFollowTheTextSizeLive() async throws {
        let bar = Bar()
        defer { bar.host.close() }
        let pills = try await Self.pillIDs.asyncMap { try await bar.pill($0) }
        let box = try await bar.control(FilterBar.hiddenID)
        let checkbox = try #require(AXTree.frame(of: box))
        #expect(pills.allSatisfy { bar.laidOut($0).height == NormalMetrics.pillHeight })
        #expect(bar.host.view.fittingSize.height == NormalMetrics.filterBarHeight)
        let large = TextSize.maximum
        let menuFont = large.font(.menuFont(ofSize: 0))
        #expect(NormalMetrics.pillHeight(.standard) == NormalMetrics.pillHeight && NormalMetrics.filterBarHeight(.standard) == NormalMetrics.filterBarHeight)
        #expect(NormalMetrics.pillHeight(large) == 27 && NormalMetrics.filterBarHeight(large) == 39)
        #expect(menuFont.pointSize > NSFont.menuFont(ofSize: 0).pointSize)

        let store = try #require(UserDefaults(suiteName: "com.writronic.wherever.tests.host"))
        store.set(large.rawValue, forKey: TextSize.key)
        try await bar.host.until("27 pt pills, now \(pills.map { bar.laidOut($0).height })") { pills.allSatisfy { bar.laidOut($0).height == 27 } }
        try await bar.host.until("a 39 pt bar, now \(bar.host.view.fittingSize.height)") { bar.host.view.fittingSize.height == 39 }
        for (id, pill) in zip(Self.pillIDs, pills) {
            #expect(pill.font?.pointSize == 18 && !bar.isSemibold(pill), "\(id)")
        }
        for pill in pills where pill.menu != nil { #expect(pill.menu?.font == menuFont) }
        try await bar.host.until("a taller checkbox than \(checkbox.height)") { (AXTree.frame(of: box)?.height ?? 0) > checkbox.height }
        try await bar.choose(SearchFilters.Size.large, in: FilterBar.sizeID)
        let size = try await bar.pill(FilterBar.sizeID)
        try await bar.host.until("the Size pill on") { size.isBordered }
        #expect(size.font?.pointSize == 18 && bar.isSemibold(size) && bar.laidOut(size).height == 27, "the on Size pill is \(bar.laidOut(size).height) high")

        store.removeObject(forKey: TextSize.key)
        try await bar.host.until("22 pt pills again") { pills.allSatisfy { bar.laidOut($0).height == NormalMetrics.pillHeight } }
        #expect(pills.allSatisfy { $0.font?.pointSize == NSFont.systemFontSize })
    }
}

extension Sequence {
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}

extension FilterBarTests {
    @Test(arguments: Theme.allCases, [AppearanceMode.light, .dark])
    func thePillsDrawTheirThemeUnderAForcedMode(theme: Theme, mode: AppearanceMode) async throws {
        let suite = "com.writronic.wherever.tests.filterbar.forced-\(theme.rawValue)-\(mode.rawValue)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        store.set(theme.rawValue, forKey: Theme.key)
        try await forced(mode) {
            let bar = Bar(normal: true, store: store)
            defer { bar.host.close() }
            let view = bar.host.view
            let appearance = view.effectiveAppearance
            #expect(appearance.bestMatch(from: [.aqua, .darkAqua]) == appearanceName(mode), "\(theme) under \(mode)")
            let background = channels(theme.windowBackground, appearance: appearance)
            for id in Self.pillIDs {
                let pill = try await bar.pill(id)
                #expect(pill.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearanceName(mode), "\(theme) \(mode): the \(id) pill")
                let label = try #require(pill.contentTintColor, "\(id) is off, so it tints its title")
                let ratio = contrastRatio(channels(label, appearance: appearance), background)
                #expect(ratio >= 4.5, "\(theme) \(mode): the \(id) title is \(ratio):1 on the window")
                let frame = view.convert(pill.bounds, from: pill)
                try await bar.host.until("\(theme) \(mode): the \(id) pill drawn with a readable contrast") {
                    strongestInk(in: view, rect: frame, against: background) >= 2
                }
            }
        }
    }
}
