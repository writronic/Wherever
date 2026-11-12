import AppKit
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

@Suite(.serialized) struct SearchViewTests {
    @Test func theFieldHoldsFocusWhenTheWindowOpens() async throws {
        let index = IndexModel(client: FakeSearchClient())
        let host = SearchHost(index: index, model: index.makeModel())
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        #expect(AXTree.textField(SearchView.fieldID, in: host.window) === host.field())
    }

    @Test func theFieldFillsTheBandUnderTheTitleBarAndHoldsFocus() async throws {
        let index = IndexModel(client: FakeSearchClient())
        let host = SearchHost(index: index, model: index.makeModel())
        defer { host.close() }
        try await host.until("the field to hold focus and the table") { host.fieldHasFocus && host.list()?.enclosingScrollView != nil }
        let window = host.window
        #expect(window.toolbar == nil)
        #expect(window.titlebarSeparatorStyle == .line)
        #expect(window.styleMask.contains(.fullSizeContentView))
        func titleArea(compactToolbar: Bool) -> CGFloat {
            let reference = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true
            )
            reference.isReleasedWhenClosed = false
            defer { reference.close() }
            if compactToolbar {
                reference.toolbar = NSToolbar(identifier: "reference")
                reference.toolbarStyle = .unifiedCompact
            }
            return reference.frame.height - reference.contentLayoutRect.height
        }
        let plainArea = titleArea(compactToolbar: false)
        #expect(plainArea < titleArea(compactToolbar: true))
        #expect((window.frame.height - window.contentLayoutRect.height - plainArea) * window.backingScaleFactor == 0)

        let field = try #require(host.field())
        #expect(field.isDescendant(of: host.view))
        #expect(field.controlSize == .large)
        #expect(field.font?.pointSize == SearchMetrics.searchFontSize)
        let cell = try #require(field.cell)
        #expect(cell.accessibilityLabel() == String(localized: "Search files", bundle: .main))
        #expect(AXTree.textField(SearchView.fieldID, in: window) === field)

        host.view.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        let content = window.contentLayoutRect
        let frame = field.convert(field.bounds, to: nil)
        let scroll = try #require(host.list()?.enclosingScrollView)
        let tableTop = scroll.convert(scroll.bounds, to: nil).maxY
        let hairline = NSHostingView(rootView: VStack(spacing: 0) { Divider() }).fittingSize.height
        #expect(hairline > 0)
        #expect(content.width == SearchMetrics.windowMinWidth)
        #expect((frame.minX - content.minX - SearchMetrics.sideInset) * scale == 0, "field at \(frame), content at \(content)")
        #expect((frame.width - (content.width - 2 * SearchMetrics.sideInset)) * scale == 0, "field at \(frame), content at \(content)")
        #expect((content.maxY - SearchMetrics.fieldInset - frame.maxY) * scale == 0, "field at \(frame), content at \(content)")
        #expect((frame.height - field.fittingSize.height) * scale == 0, "field at \(frame), fitting \(field.fittingSize)")
        #expect((frame.minY - SearchMetrics.fieldInset - hairline - tableTop) * scale == 0, "field at \(frame), table top \(tableTop)")
    }

    @Test func theSimpleBandIsARoundedRectangleAndAPlainFieldKeepsTheSystemShape() async throws {
        let index = IndexModel(client: FakeSearchClient())
        let simple = SearchHost(index: index, model: index.makeModel())
        defer { simple.close() }
        let plain = SearchHost(root: AnyView(SearchField(model: index.makeModel()).controlSize(.large)))
        defer { plain.close() }
        try await simple.until("the Simple band's field") { simple.field() != nil }
        try await plain.until("a field without the flag, as the archive band uses it") { plain.field() != nil }
        let band = try #require(simple.field())
        let other = try #require(plain.field())
        let automatic = 0
        let roundedRectangle = 2
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            #expect(Availability.borderShape(band) == roundedRectangle)
            #expect(Availability.borderShape(other) == automatic)
        } else {
            #expect(Availability.borderShape(band) == nil && Availability.borderShape(other) == nil)
        }
    }

    @Test func aSimpleWindowShrinksToTheFloor() async throws {
        let index = IndexModel(client: FakeSearchClient())
        let host = SearchHost(index: index, model: index.makeModel())
        defer { host.close() }
        try await host.until("the field and the table") { host.field() != nil && host.list() != nil }
        host.window.setContentSize(NSSize(width: 100, height: SearchMetrics.windowMinHeight))
        try await host.until("the window at \(SearchMetrics.windowMinWidth), now \(host.window.contentLayoutRect.width)") {
            host.window.contentLayoutRect.width == SearchMetrics.windowMinWidth
        }
        #expect(host.window.contentMinSize.width == SearchMetrics.windowMinWidth)
    }

    @Test func simpleShowsNoFilterControl() async throws {
        let index = IndexModel(client: FakeSearchClient())
        let host = SearchHost(index: index, model: index.makeModel())
        defer { host.close() }
        try await host.until("the field to hold focus and the table") { host.fieldHasFocus && host.list() != nil }
        let ids = [
            FilterBar.extensionsID, FilterBar.kindID, FilterBar.sizeID, FilterBar.modifiedID, FilterBar.hiddenID,
        ]
        #expect(AXTree.element(SearchView.fieldID, in: host.window) != nil)
        for id in ids { #expect(AXTree.element(id, in: host.window) == nil, "\(id) is in the Simple window") }
    }

    @Test func typingRightAfterTheWindowOpensReachesTheField() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        try host.sendKeys("saf")
        #expect(fake.queries == ["s", "sa", "saf"])
        #expect(model.query == "saf")
    }

    @Test func aSecondWindowOpensWithItsOwnEmptyFocusedField() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let first = SearchHost(index: index, model: model)
        defer { first.close() }
        try await first.type("sa")
        first.resignKey()
        let secondModel = index.makeModel()
        let second = SearchHost(index: index, model: secondModel)
        defer { second.close() }
        try await second.until("the second field to hold focus") { second.fieldHasFocus }
        #expect(second.field()?.stringValue == "")
        #expect(first.field()?.stringValue == "sa")
        try second.sendKeys("m")
        #expect(fake.queries == ["s", "sa", "m"])
        #expect(secondModel.query == "m")
        #expect(model.query == "sa")
    }

    @Test func theFirstWindowTakesKeysAgainWhenItIsKeyAfterASecondWindowOpened() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let first = SearchHost(index: index, model: model)
        defer { first.close() }
        try await first.until("the first field to hold focus") { first.fieldHasFocus }
        first.resignKey()
        let second = SearchHost(index: index, model: model)
        defer { second.close() }
        try await second.until("the second field to hold focus") { second.fieldHasFocus }
        second.resignKey()
        first.becomeKey()
        try await first.until("the first field to hold focus again") { first.fieldHasFocus }
        try first.sendKeys("s")
        #expect(fake.queries == ["s"])
        #expect(model.query == "s")
    }

    @Test func typingAfterComingBackToTheFirstWindowKeepsItsQuery() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let first = SearchHost(index: index, model: model)
        defer { first.close() }
        try await first.until("the first field to hold focus") { first.fieldHasFocus }
        try first.sendKeys("s")
        first.resignKey()
        let second = SearchHost(index: index, model: model)
        defer { second.close() }
        try await second.until("the second field to hold focus") { second.fieldHasFocus }
        second.resignKey()
        first.becomeKey()
        try await first.until("the first field to hold focus again") { first.fieldHasFocus }
        try first.sendKeys("a")
        #expect(fake.queries == ["s", "sa"])
        #expect(model.query == "sa")
    }

    @Test func typingAfterTabFromTheFieldReturnsToTheField() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus and the table") { host.fieldHasFocus && host.list() != nil }
        try host.pressTab()
        try await host.until("Tab from the field to the table") { host.listHasFocus }
        try host.sendKeys("sa")
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.fieldHasFocus)
        #expect(fake.queries == ["s", "sa"])
        #expect(model.query == "sa")
    }

    @Test func tabReachesTheTableAndShiftTabComesBackToTheField() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        var stops = [Self.focused(in: host.window)]
        while !host.listHasFocus {
            try #require(stops.count <= 8, "eight Tabs from the field never reached the table; stops \(stops.map(Self.name))")
            try host.pressTab()
            try await Task.sleep(for: .milliseconds(20))
            stops.append(Self.focused(in: host.window))
        }
        let tabs = stops.count - 1
        let expected = Array(stops.dropLast().reversed()).map(Self.name)

        let walked = sequence(first: host.list() as NSView?) { $0?.previousValidKeyView }.dropFirst().prefix(tabs).map { Self.name($0) }
        #expect(walked == expected, "previousValidKeyView from the table")

        var back: [String] = []
        for _ in 0..<tabs {
            try host.pressTab(backward: true)
            try await Task.sleep(for: .milliseconds(20))
            back.append(Self.name(Self.focused(in: host.window)))
        }
        try await host.until("\(tabs) Shift-Tabs back to the field; Tabs stopped on \(stops.map(Self.name)), Shift-Tabs on \(back)") {
            host.fieldHasFocus
        }
        #expect(back == expected)
        try host.sendKeys("s")
        #expect(fake.queries == ["s"])
        #expect(model.query == "s")
    }

    @Test func tabFromTheTableWrapsToTheField() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        var tabs = 0
        while !host.listHasFocus {
            try #require(tabs < 8, "eight Tabs from the field never reached the table")
            try host.pressTab()
            tabs += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        try host.pressTab()
        try await host.until("Tab from the table to the field; focus is on \(Self.name(Self.focused(in: host.window)))") { host.fieldHasFocus }
        try host.sendKeys("s")
        #expect(fake.queries == ["s"])
        #expect(model.query == "s")
    }

    static func focused(in window: NSWindow) -> NSView? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return window.firstResponder as? NSView }
        return editor.delegate as? NSView
    }

    static func name(_ view: NSView?) -> String {
        guard let view else { return "nothing" }
        let id = (view as? NSTextField)?.cell.flatMap(AXTree.identifier(of:))
        return [String(describing: type(of: view)), id].compactMap { $0 }.joined(separator: " ")
    }

    @Test func typingInTheListGoesToTheFieldButNothingPullsFocusBackBeforeAKey() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        try await host.focusList()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!host.fieldHasFocus)
        #expect(host.listHasFocus)
        try host.sendKeys("f")
        #expect(host.fieldHasFocus)
        #expect(fake.queries == ["s", "sa", "saf"])
        #expect(model.query == "saf")
    }

    @Test(arguments: [
        (".", UInt16(47), false), ("'", 39, false), ("-", 27, false), (";", 41, false),
        ("!", 18, true), ("^", 22, true), ("$", 21, true), ("*", 28, true), (":", 41, true), ("\"", 39, true),
    ])
    func aPunctuationKeyTypedInTheListReachesTheFieldAndTheNextLetterFollows(key: String, code: UInt16, shifted: Bool) async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        try await host.focusList()
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.listHasFocus)
        try Self.press(key, code: code, flags: shifted ? [.shift] : [], in: host)
        #expect(host.fieldHasFocus, "\(key) must move focus to the field")
        #expect(model.query == "sa" + key)
        try host.sendKeys("f")
        #expect(model.query == "sa" + key + "f")
        #expect(fake.queries == ["s", "sa", "sa" + key, "sa" + key + "f"])
    }

    @Test(arguments: ["。", "،", "€"]) func aNonLatinPunctuationOrSymbolKeyTypedInTheListMovesFocusToTheField(key: String) async throws {
        let index = IndexModel(client: FakeSearchClient())
        let host = SearchHost(index: index, model: index.makeModel())
        defer { host.close() }
        try await host.type("sa")
        try await host.focusList()
        try await Task.sleep(for: .milliseconds(50))
        try Self.press(key, code: 47, in: host)
        #expect(host.fieldHasFocus, "\(key) must move focus to the field")
    }

    @Test func aSpaceOrAControlPunctuationKeyStaysInTheList() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        try await host.focusList()
        try await Task.sleep(for: .milliseconds(50))
        try Self.press(" ", code: 49, flags: [.shift], in: host)
        try Self.press(".", code: 47, flags: [.control], in: host)
        #expect(host.listHasFocus)
        #expect(!host.fieldHasFocus)
        #expect(model.query == "sa")
        #expect(fake.queries == ["s", "sa"])
    }

    private static func press(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in host: SearchHost) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        ))
        host.window.sendEvent(event)
    }

    @Test func theListKeepsFocusWhenTheWindowIsKeyAgain() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        try await host.focusList()
        host.resignKey()
        try await Task.sleep(for: .milliseconds(50))
        host.becomeKey()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!host.fieldHasFocus)
        #expect(host.listHasFocus)
        try host.sendKeys(" ")
        #expect(host.listHasFocus)
        #expect(fake.queries.isEmpty)
        try host.sendKeys("s")
        #expect(host.fieldHasFocus)
        #expect(fake.queries == ["s"])
        #expect(model.query == "s")
    }

    @Test func theFieldTakesKeysAgainWhenTheWindowIsKeyAgain() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        host.resignKey()
        try await Task.sleep(for: .milliseconds(50))
        host.becomeKey()
        try await Task.sleep(for: .milliseconds(50))
        try await host.until("the field to hold focus after the window is key again") { host.fieldHasFocus }
        try host.sendKeys("s")
        #expect(fake.queries == ["s"])
        #expect(model.query == "s")
    }

    @Test func theClearButtonEmptiesTheQueryAndTheRows() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        fake.send(.resultsReady(fake.latest, count: 1))
        try await host.until("the result") { host.shows("Safari.app") }
        try await host.clickClear()
        try await host.until("an empty query and list") { model.query.isEmpty && !host.shows("Safari.app") }
        #expect(host.field()?.stringValue == "")
        #expect(fake.queries == ["s", "sa"])
    }

    @Test func escapeInTheFieldEmptiesTheQueryAndASecondEscapeChangesNothing() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        try host.pressEscape()
        #expect(model.query.isEmpty)
        try await host.until("an empty field") { host.field()?.stringValue == "" }
        try host.pressEscape()
        #expect(model.query.isEmpty)
        #expect(model.filters == SearchFilters())
        #expect(host.fieldHasFocus)
        #expect(fake.queries == ["s", "sa"])
    }

    @Test func escapeClearsTheTextFirstAndThenTheFilters() async throws {
        let fake = FakeSearchClient(hits: [.named("Report.pdf")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        model.filters.extensions = "pdf"
        try host.sendKeys("sa")
        #expect(fake.queries == ["ext:pdf", "s ext:pdf", "sa ext:pdf"])
        try host.pressEscape()
        #expect(model.query.isEmpty)
        #expect(model.filters.extensions == "pdf")
        #expect(fake.queries.last == "ext:pdf")
        fake.send(.resultsReady(fake.latest, count: 1))
        try await host.until("the filter's result") { host.shows("Report.pdf") }
        try host.pressEscape()
        #expect(model.filters == SearchFilters())
        try await host.until("an empty list") { !host.shows("Report.pdf") }
        #expect(fake.queries.count == 4)
        #expect(host.fieldHasFocus)
    }

    @Test func downArrowMovesToTheTableAndSelectsTheFirstRow() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app"), .named("Mail.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("a")
        fake.send(.resultsReady(fake.latest, count: 2))
        try await host.until("the rows") { host.shows("Mail.app") }
        try host.press(.downArrow)
        #expect(host.listHasFocus)
        #expect(host.list()?.selectedRow == 0)
    }

    @Test func downArrowWithNoRowsKeepsFocusInTheField() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("a")
        try host.press(.downArrow)
        #expect(host.fieldHasFocus)
        #expect(host.list()?.selectedRow == -1)
        try host.sendKeys("b")
        #expect(model.query == "ab")
    }

    @Test func upArrowOnTheFirstRowReturnsToTheFieldWithTheCaretAtTheEnd() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app"), .named("Mail.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        fake.send(.resultsReady(fake.latest, count: 2))
        try await host.until("the rows") { host.shows("Mail.app") }
        try host.press(.downArrow)
        #expect(host.listHasFocus)
        try host.press(.upArrow)
        #expect(host.fieldHasFocus)
        try host.sendKeys("b")
        #expect(model.query == "sab")
        #expect(fake.queries == ["s", "sa", "sab"])
    }

    @Test func spaceInTheListDoesNotReachTheField() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        fake.send(.resultsReady(fake.latest, count: 1))
        try await host.until("the row") { host.shows("Safari.app") }
        try host.press(.downArrow)
        try host.sendKeys(" ")
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.listHasFocus)
        #expect(model.query == "sa")
        #expect(fake.queries == ["s", "sa"])
    }

    @Test func escapeInTheListEmptiesTheQueryAndFocusesTheField() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        fake.send(.resultsReady(fake.latest, count: 1))
        try await host.until("the row") { host.shows("Safari.app") }
        try host.press(.downArrow)
        #expect(host.listHasFocus)
        try host.pressEscape()
        #expect(host.fieldHasFocus)
        #expect(model.query.isEmpty)
        try await host.until("an empty list") { !host.shows("Safari.app") }
    }

    @Test func escapeInTheListWithAnEmptyQueryOnlyFocusesTheFieldAndASecondEscapeResetsTheFilters() async throws {
        let fake = FakeSearchClient(hits: [.named("Report.pdf")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        model.filters.kind = .documents
        let filtered = model.filters
        #expect(fake.queries.last?.hasPrefix("type:doc") == true)
        fake.send(.resultsReady(fake.latest, count: 1))
        try await host.until("the row") { host.shows("Report.pdf") }
        try await host.focusList()
        host.list()?.selectRowIndexes([0], byExtendingSelection: false)
        let before = fake.queries.count
        try host.pressEscape()
        #expect(host.fieldHasFocus)
        #expect(model.filters == filtered)
        #expect(fake.queries.count == before, "the Escape sent \(fake.queries.dropFirst(before))")
        try host.pressEscape()
        #expect(model.filters == SearchFilters(hidesHidden: filtered.hidesHidden))
    }

    @Test func returnOnAnEmptyFieldWhileTheFullListIsPendingOpensItsTopRow() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel(listsAll: true)
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        #expect(model.isPending)
        try host.pressReturn()
        #expect(host.recorder.nothingHappened)
        fake.send(.resultsReady(fake.latest, count: 1))
        try await host.until("the top row opened, opened \(host.recorder.opened)") { !host.recorder.opened.isEmpty }
        #expect(host.recorder.opened.map(\.lastPathComponent) == ["Safari.app"])
    }

    @Test func escapeOnAnEmptyFieldDropsAPendingReturn() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel(listsAll: true)
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        #expect(model.isPending)
        try host.pressReturn()
        try host.pressEscape()
        fake.send(.resultsReady(fake.latest, count: 1))
        try await host.until("the full list") { host.shows("Safari.app") }
        #expect(host.recorder.nothingHappened)
    }

    @Test func aSecondWindowWithItsOwnModelTypesOnlyIntoItsOwnQuery() async throws {
        let index = IndexModel(client: FakeSearchClient())
        let firstModel = index.makeModel()
        let secondModel = index.makeModel()
        let first = SearchHost(index: index, model: firstModel)
        defer { first.close() }
        try await first.type("sa")
        first.resignKey()
        let second = SearchHost(index: index, model: secondModel)
        defer { second.close() }
        try await second.until("the second field to hold focus") { second.fieldHasFocus }
        try second.sendKeys("m")
        #expect(secondModel.query == "m")
        #expect(firstModel.query == "sa")
        #expect(first.field()?.stringValue == "sa")
    }

    @Test func aQueryChangedByTheModelShowsInTheField() async throws {
        let index = IndexModel(client: FakeSearchClient())
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        model.query = "mail"
        try await host.until("the model's query in the field") { host.field()?.stringValue == "mail" }
        model.query = ""
        try await host.until("the cleared query in the field") { host.field()?.stringValue == "" }
    }

    @Test func typingSearchesOnEveryKeystroke() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("saf")
        #expect(fake.queries == ["s", "sa", "saf"])
        #expect(model.query == "saf")
    }

    @Test func aReadyEventRedrawsTheListWithTheFakesNames() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app"), .named("Mail.app", in: "/Applications/Utilities")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("a")
        #expect(!host.shows("Safari.app"))
        fake.send(.resultsReady(fake.latest, count: 2))
        try await host.until("both names in the list") { host.shows("Safari.app") && host.shows("Mail.app") }
        #expect(host.shows("/Applications/Utilities"))
        #expect(fake.rowRequests == [.init(generation: fake.latest, range: 0..<2)])
    }

    @Test func anEventForAnOlderGenerationChangesNothing() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("a")
        let older = fake.latest
        fake.send(.resultsReady(older, count: 1))
        try await host.until("the first result") { host.shows("Safari.app") }
        try await host.type("b")
        let newer = fake.latest
        fake.setHits([.named("Mail.app")])
        fake.send(.resultsReady(older, count: 1))
        fake.send(.resultsReady(newer, count: 1))
        try await host.until("the second result") { host.shows("Mail.app") }
        #expect(!host.shows("Safari.app"))
        #expect(fake.rowRequests == [.init(generation: older, range: 0..<1), .init(generation: newer, range: 0..<1)])
    }

    @Test func clearingTheFieldEmptiesTheListAndLateResultsStayOut() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        let cleared = fake.latest
        fake.send(.resultsReady(cleared, count: 1))
        try await host.until("the result") { host.shows("Safari.app") }
        try await host.clear()
        try await host.until("an empty list") { !host.shows("Safari.app") }
        #expect(fake.queries == ["s", "sa"])
        fake.send(.resultsReady(cleared, count: 1))
        try await Task.sleep(for: .milliseconds(50))
        try await host.type("z")
        fake.send(.resultsReady(fake.latest, count: 1))
        try await host.until("the next result") { host.shows("Safari.app") }
        #expect(fake.rowRequests.map(\.generation) == [cleared, fake.latest])
    }

    @Test func theModelKeepsAnsweringAfterItsViewIsRemovedAndANewOneIsShown() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let first = SearchHost(index: index, model: model)
        try await first.type("s")
        fake.send(.resultsReady(fake.latest, count: 1))
        try await first.until("the first window's result") { first.shows("Safari.app") }
        first.close()

        fake.setHits([.named("Mail.app")])
        model.query = "m"
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the model to answer with no window open") { model.names == ["Mail.app"] }

        let second = SearchHost(index: index, model: model)
        defer { second.close() }
        try await second.until("the new window to show the model's list") { second.shows("Mail.app") }
        fake.setHits([.named("Notes.app")])
        try await second.type("x")
        fake.send(.resultsReady(fake.latest, count: 1))
        try await second.until("the new window's result") { second.shows("Notes.app") }
        #expect(!second.shows("Mail.app"))
    }

    @Test func theSimpleFieldFollowsTheTextSizeLive() async throws {
        let index = IndexModel(client: FakeSearchClient())
        let host = SearchHost(index: index, model: index.makeModel())
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        let field = try #require(host.field())
        #expect(field.font == NSFont.systemFont(ofSize: SearchMetrics.searchFontSize))
        let store = try #require(UserDefaults(suiteName: "com.writronic.wherever.tests.host"))
        store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        try await host.until("a 21 pt field, now \(String(describing: field.font?.pointSize))") { field.font?.pointSize == 21 }
        #expect(TextSize.maximum.points(SearchMetrics.searchFontSize) == 21)
        #expect(field.currentEditor()?.font?.pointSize == 21)
        #expect(field.controlSize == .large)
        store.removeObject(forKey: TextSize.key)
        try await host.until("the 15 pt field again") { field.font == NSFont.systemFont(ofSize: SearchMetrics.searchFontSize) }
    }

    @Test func defaultWindowSizeFitsOneSmallScreenAndAboveTheMinimum() {
        #expect(SearchMetrics.windowDefaultWidth >= SearchMetrics.windowMinWidth)
        #expect(SearchMetrics.windowDefaultHeight >= SearchMetrics.windowMinHeight)
        #expect(SearchMetrics.windowDefaultWidth <= 1440)
        #expect(SearchMetrics.windowDefaultHeight <= 805)
    }
}

@Suite struct SearchModelTests {
    @Test func anEmptyQueryNeverReachesTheEngine() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        model.query = ""
        #expect(fake.queries == ["a"])
        #expect(model.count == 0)
    }

    @Test func aLateResultForAClearedQueryStaysOut() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        let cleared = fake.latest
        model.query = ""
        fake.send(.resultsReady(cleared, count: 1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.rowRequests.isEmpty)
        #expect(model.count == 0)
    }

    @Test func aNewQueryOrFilterIsPendingUntilItsResultsAndALiveSearchNeverIs() async throws {
        let marker = IndexState(phase: .ready, indexed: 1)
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        #expect(!model.isPending)
        model.query = "a"
        #expect(model.isPending)
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the first results") { model.count == 1 }
        #expect(!model.isPending)
        #expect(!model.results.live)

        fake.send(.resultsChanged)
        fake.send(.stateChanged(marker))
        try await untilTrue(waitingFor: "the live search") { index.indexState == marker }
        #expect(fake.queries == ["a", "a"])
        #expect(!model.isPending)
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the live results") { model.results.live }
        #expect(!model.isPending)

        model.filters.kind = .folders
        #expect(model.isPending)
        fake.send(.resultsChanged)
        fake.send(.stateChanged(IndexState(phase: .ready, indexed: 2)))
        try await untilTrue(waitingFor: "the waiting change") { index.indexState?.indexed == 2 }
        #expect(fake.queries.count == 3)
        #expect(model.isPending)
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the filtered results") { !model.isPending }
        #expect(!model.results.live, "results for a new filter are not a live re-search")
        #expect(fake.queries.count == 4, "one live search for the change that waited")
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the caught-up results") { model.results.live && model.results.generation == fake.latest }
        #expect(!model.isPending)

        model.query = ""
        model.filters.kind = .any
        #expect(!model.isPending)
        #expect(model.count == 0)
    }

    @Test func theFetchIsBoundedByTheAskedRange() async throws {
        let page = SearchModel.pageSize
        let fake = FakeSearchClient(hits: (0..<page * 20).map { .named("hit-\($0)") })
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.query = "a"
        #expect(fake.rowRequests.isEmpty)
        fake.send(.resultsReady(fake.latest, count: page * 20))
        try await untilTrue(waitingFor: "the results") { model.count == page * 20 }
        #expect(fake.rowRequests.isEmpty)

        #expect(model.rows(in: 0..<1).map(\.name) == ["hit-0"])
        #expect(model.rows(in: page * 2 + 5..<page * 3 + 1).map(\.name) == (page * 2 + 5..<page * 3 + 1).map { "hit-\($0)" })
        #expect(model.rows(in: 3..<4).map(\.name) == ["hit-3"])
        #expect(fake.rowRequests.map(\.range) == [0..<page, page * 2..<page * 3, page * 3..<page * 4])

        for index in 4..<4 + SearchModel.pageLimit { _ = model.rows(in: index * page..<index * page + 1) }
        let before = fake.rowRequests.count
        #expect(model.rows(in: 0..<1).map(\.name) == ["hit-0"])
        #expect(fake.rowRequests.count == before + 1, "page 0 was dropped after \(SearchModel.pageLimit) newer pages")
        #expect(model.rows(in: page * 20 - 1..<page * 25).map(\.name) == ["hit-\(page * 20 - 1)"])
    }
}

@Suite struct FakeSearchClientTests {
    @Test func rowsStayForTheLatestFinishedSearch() throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let session = try fake.makeSession()
        let first = try session.search("a", sort: .bestMatch)
        #expect(throws: WhereverError.staleGeneration) { try session.rows(first, in: 0..<1) }
        fake.send(.resultsReady(first, count: 1))
        let second = try session.search("ab", sort: .bestMatch)
        #expect(try session.rows(first, in: 0..<1).count == 1)
        #expect(throws: WhereverError.staleGeneration) { try session.rows(second, in: 0..<1) }
        fake.send(.resultsReady(second, count: 1))
        #expect(try session.rows(second, in: 0..<1).count == 1)
        #expect(throws: WhereverError.staleGeneration) { try session.rows(first, in: 0..<1) }
        fake.send(.resultsReady(first, count: 1))
        #expect(try session.rows(second, in: 0..<1).count == 1)
    }
}
