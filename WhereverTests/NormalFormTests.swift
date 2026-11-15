import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

@Suite struct NameModeTests {
    @Test func eachNameModeWritesItsText() {
        let written: [(SearchFilters.NameMode, String, String)] = [
            (.contains, "annual report", "annual report"),
            (.contains, "!draft", "!draft"),
            (.endsWith, "!draft", "ends:\"!draft\""),
            (.endsWith, "'s notes", "ends:\"'s notes\""),
            (.endsWith, "re:x", "ends:\"re:x\""),
            (.endsWith, "*.pdf", "ends:\"*.pdf\""),
            (.beginsWith, "v1$", "begins:\"v1$\""),
            (.matches, "'x", "whole:\"'x\""),
            (.matches, "annual report", "whole:\"annual report\""),
            (.beginsWith, "annual report", "begins:\"annual report\""),
            (.endsWith, "annual report", "ends:\"annual report\""),
            (.fileExtension, "pdf, .Docx", "ext:pdf,docx"),
            (.wildcard, "annual*", "glob:\"annual*\""),
            (.regex, "^a.c$", "re:\"^a.c$\""),
            (.beginsWith, "\"annual\" report", "begins:\"\"\"annual\"\" report\""),
            (.regex, "a\"b", "re:\"a\"\"b\""),
            (.matches, "\"", "whole:\"\"\"\""),
            (.contains, "\"my file\"", "\"my file\""),
        ]
        #expect(SearchFilters.NameMode.allCases.count == 7)
        for (mode, typed, text) in written {
            #expect(SearchFilters(nameMode: mode).nameText(typed) == text, "\(mode) \(typed)")
        }
        for mode in SearchFilters.NameMode.allCases where mode != .contains {
            for empty in ["", " ", "\t"] { #expect(SearchFilters(nameMode: mode).nameText(empty) == "", "\(mode) \(empty)") }
        }
        #expect(SearchFilters(nameMode: .fileExtension).nameText(",").isEmpty)
        #expect(SearchFilters(nameMode: .regex).tokens.isEmpty)
        #expect(!SearchFilters(nameMode: .regex).narrowsResults)
    }

    @Test func aBeginsWithQuoteRoundTrips() {
        #expect(SearchFilters(nameMode: .beginsWith).nameText("Notes \"draft\"") == "begins:\"Notes \"\"draft\"\"\"")
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        model.filters.nameMode = .beginsWith
        model.filters.extensions = "pdf"
        model.query = "say \"hi"
        #expect(fake.queries.last == "begins:\"say \"\"hi\" ext:pdf")
    }

    @Test func returningToContainsSendsTheSameTextAsGrammar() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        rig.model.query = "!draft"
        try await rig.queryEnds("!draft")
        try await rig.pick("Ends with", in: NormalForm.nameModeID)
        try await rig.queryEnds("ends:\"!draft\"")
        try await rig.pick("Contains", in: NormalForm.nameModeID)
        try await rig.queryEnds("!draft")
        #expect(rig.model.query == "!draft")
        #expect(rig.fake.queries == ["!draft", "ends:\"!draft\"", "!draft"])
    }
}

private struct NormalRig {
    let fake: FakeSearchClient
    let index: IndexModel
    let model: SearchModel
    let host: SearchHost

    init(
        hits: [SearchHit] = [], volumes: [IndexedVolume] = [], locale: String = "en", store: UserDefaults? = nil,
        direction: LayoutDirection = .leftToRight
    ) {
        let fake = FakeSearchClient(hits: hits)
        fake.setVolumes(.success(volumes))
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        self.fake = fake
        self.index = index
        self.model = model
        let view = SearchView(model: model, mode: .normal)
            .environment(\.searchClient, fake)
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.layoutDirection, direction)
        host = SearchHost(root: store.map { AnyView(view.defaultAppStorage($0)) } ?? AnyView(view))
    }

    func popUp(_ id: String) -> NSPopUpButton? { findPopUp(id, in: host.view) }

    func folderBox() -> FormFolderField? { findFolderField(SearchFolderBox.id, in: host.view) }

    func tokenField() -> NSTokenField? { host.view.descendant(NSTokenField.self) }

    func extensionsPill() -> NSButton? { findButton(FilterBar.extensionsID, in: host.view) }

    func formControls() async throws -> (folder: FormFolderField, mode: NSPopUpButton, terms: NSTokenField, content: NSPopUpButton) {
        try await host.until("the form's pop-ups and fields") {
            folderBox() != nil && popUp(NormalForm.nameModeID) != nil && popUp(NormalForm.contentModeID) != nil
                && tokenField() != nil && host.field() != nil
        }
        return try (
            #require(folderBox()), #require(popUp(NormalForm.nameModeID)), #require(tokenField()),
            #require(popUp(NormalForm.contentModeID))
        )
    }

    func enter(_ terms: [String], thenClick button: NSButton) async throws {
        model.content = ContentTerms(terms: terms)
        try await host.until("the button on") { button.isEnabled }
        button.performClick(nil)
    }

    func searchContentButton() async throws -> NSButton {
        try await host.until("the Search Content button") { findButton(NormalForm.searchContentID, in: host.view) != nil }
        return try #require(findButton(NormalForm.searchContentID, in: host.view))
    }

    func pick(_ title: String, in id: String) async throws {
        try await host.until("the \(id) pop-up") { popUp(id) != nil }
        try NormalFormTests.pick(title, in: try #require(popUp(id)))
    }

    func search(_ count: Int) async throws {
        fake.send(.resultsReady(fake.latest, count: count))
        try await host.until("\(count) rows") { !model.isPending && host.list()?.numberOfRows == count }
    }

    func queryEnds(_ expected: String) async throws {
        try await host.until("the query \(expected); sent \(fake.queries)") { fake.queries.last == expected }
    }

    func pressed(_ query: String, _ terms: [String], all: Bool = false) async throws {
        let want = FakeSearchClient.Press(query: query, terms: terms, matchAll: all, sort: .bestMatch)
        try await host.until("the press \(want); pressed \(fake.presses)") { fake.presses.last == want }
    }

    func endPress() throws {
        model.handle(.contentProgress(try #require(model.press), read: 1, total: 1, notDownloaded: 0, unreadable: 0, done: true))
    }

    func narrowEnds(_ expected: String) async throws {
        try await host.until("the narrow \(expected); narrowed \(fake.narrows)") { fake.narrows.last == expected }
    }

    func reportReady() async throws {
        let state = IndexState(phase: .ready, indexed: 1)
        fake.send(.stateChanged(state))
        try await host.until("the Ready state") { index.indexState == state }
    }

    func screenFrame(_ view: NSView) -> NSRect { host.window.convertToScreen(view.convert(view.bounds, to: nil)) }

    func laidOut(_ view: NSView) -> NSRect {
        host.window.convertToScreen(view.superview.map { $0.convert(view.alignmentRect(forFrame: view.frame), to: nil) } ?? view.convert(view.bounds, to: nil))
    }

    func labelFrame(_ text: String) -> NSRect? {
        AXTree.elements(in: host.view).first { element in
            (AXTree.value("accessibilityRole", of: element) as String?) == NSAccessibility.Role.staticText.rawValue
                && (AXTree.names(of: element).contains(text) || (AXTree.value("accessibilityValue", of: element) as String?) == text)
        }.flatMap(AXTree.frame(of:))
    }
}

private func findButton(_ id: String, in root: NSView) -> NSButton? {
    for view in root.subviews {
        if let found = (view as? NSButton).flatMap({ $0.identifier?.rawValue == id ? $0 : nil }) ?? findButton(id, in: view) { return found }
    }
    return nil
}

private func findFolderField(_ id: String, in root: NSView) -> FormFolderField? {
    for view in root.subviews {
        if let found = (view as? FormFolderField).flatMap({ $0.identifier?.rawValue == id ? $0 : nil }) ?? findFolderField(id, in: view) { return found }
    }
    return nil
}

private func findPopUp(_ id: String, in root: NSView) -> NSPopUpButton? {
    for view in root.subviews {
        if let found = (view as? NSPopUpButton).flatMap({ $0.identifier?.rawValue == id ? $0 : nil }) ?? findPopUp(id, in: view) { return found }
    }
    return nil
}

@Suite(.serialized) struct NormalFormTests {
    static let nameTitles = ["Contains", "Matches", "Begins with", "Ends with", "Extension", "Wildcard", "Regex"]

    static func pick(_ title: String, in popUp: NSPopUpButton) throws {
        let index = popUp.indexOfItem(withTitle: title)
        try #require(index >= 0, "no \(title) among \(popUp.itemTitles)")
        try #require(popUp.item(at: index)?.isEnabled == true, "\(title) is disabled")
        popUp.selectItem(at: index)
        try #require(popUp.sendAction(popUp.action, to: popUp.target))
    }

    static func openList(_ box: FormFolderField) {
        box.diskMenu.delegate?.menuNeedsUpdate?(box.diskMenu)
        box.diskMenu.update()
    }

    static func titles(_ box: FormFolderField) -> [String] {
        box.diskMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    static func commit(_ title: String, in box: FormFolderField) throws {
        openList(box)
        let index = box.diskMenu.indexOfItem(withTitle: title)
        try #require(index >= 0, "no \(title) among \(titles(box))")
        box.diskMenu.performActionForItem(at: index)
    }

    static func edit(_ text: String, in box: FormFolderField) {
        box.stringValue = text
        box.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: box))
    }

    @Test func theFormSitsAsDrawn() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let (folder, mode, terms, content) = try await rig.formControls()
        let searchContent = try await rig.searchContentButton()
        let button = rig.laidOut(searchContent)
        let field = try #require(rig.host.field())
        let labels = ["Search folder:", "File name:", "File content:"]
        try await rig.host.until("the three labels and the form") {
            labels.allSatisfy { rig.labelFrame($0) != nil } && AXTree.element(NormalForm.id, in: rig.host.view) != nil
        }
        let scale = rig.host.window.backingScaleFactor
        let name = rig.screenFrame(field)
        let popUps = [mode, content].map(rig.laidOut)
        let inset = Availability.searchFieldOutlineInset
        let rows = [rig.screenFrame(folder), NSRect(x: name.minX, y: popUps[0].minY, width: name.width, height: popUps[0].height), rig.screenFrame(terms)]
        #expect((name.height - NormalMetrics.controlHeight + 2 * inset) * scale == 0, "File name is \(name.height) high")
        #expect((name.minY - rows[1].minY - inset) * scale == 0, "File name's bottom is \(name.minY - rows[1].minY) above its slot's")
        #expect((rows[1].maxY - name.maxY - inset) * scale == 0, "File name's top is \(rows[1].maxY - name.maxY) below its slot's")
        let form = try #require(AXTree.element(NormalForm.id, in: rig.host.view).flatMap(AXTree.frame(of:)), "the form has no frame")
        let height = 2 * NormalMetrics.formVerticalInset + 3 * NormalMetrics.controlHeight + 2 * NormalMetrics.rowSpacing
        #expect((form.height - height) * scale == 0, "the form is \(form.height) high")
        #expect((form.maxY - NormalMetrics.formVerticalInset - rows[0].maxY) * scale == 0, "row 1 starts \(form.maxY - rows[0].maxY) below the form's top")
        let area = rig.host.window.convertToScreen(rig.host.window.contentLayoutRect)
        #expect((area.maxY - form.maxY) * scale == 0, "the form starts \(area.maxY - form.maxY) below the title bar")
        for (row, frame) in rows.enumerated() {
            #expect((frame.height - NormalMetrics.controlHeight) * scale == 0, "row \(row + 1) is \(frame.height) high")
            #expect((frame.width - NormalMetrics.fieldWidth) * scale == 0, "row \(row + 1)'s field is \(frame.width) wide")
            #expect((frame.minX - rows[0].minX) * scale == 0, "row \(row + 1)'s field starts at \(frame.minX)")
        }
        for (above, below) in zip(rows, rows.dropFirst()) {
            #expect((above.minY - below.maxY - NormalMetrics.rowSpacing) * scale == 0, "rows \(above.minY - below.maxY) apart")
        }
        let column = NormalForm.popUpColumn(.main, .standard)
        for (popUp, row) in zip(popUps, [rows[1], rows[2]]) {
            #expect((popUp.width - column) * scale == 0, "a pop-up is \(popUp.width) wide")
            #expect((popUp.height - NormalMetrics.controlHeight) * scale == 0, "a pop-up is \(popUp.height) high")
            #expect((popUp.minY - row.minY) * scale == 0)
            #expect((popUp.minX - row.maxX - NormalMetrics.columnSpacing) * scale == 0, "a pop-up sits \(popUp.minX - row.maxX) after its field")
        }
        #expect((button.height - NormalMetrics.controlHeight) * scale == 0, "the button is \(button.height) high")
        #expect((button.minY - rows[2].minY) * scale == 0, "the button's top is \(button.maxY - rows[2].maxY) off row 3's")
        #expect((button.minX - popUps[1].maxX - NormalMetrics.columnSpacing) * scale == 0, "the button sits \(button.minX - popUps[1].maxX) after its pop-up")
        let trailing = try labels.map { try #require(rig.labelFrame($0)) }
        for label in trailing {
            #expect(label.width <= NormalMetrics.labelMinWidth, "an English label is \(label.width) wide")
            #expect((rows[0].minX - NormalMetrics.columnSpacing - label.maxX) * scale == 0, "a label ends \(rows[0].minX - label.maxX) before its field")
        }
        let start = rows[0].minX - NormalMetrics.columnSpacing - NormalMetrics.labelMinWidth
        let width = NormalMetrics.labelMinWidth + 3 * NormalMetrics.columnSpacing + NormalMetrics.fieldWidth + column + button.width
        #expect((button.maxX - start - width) * scale == 0, "the row is \(button.maxX - start) wide")
        #expect(((start + button.maxX) / 2 - area.midX) * scale == 0, "the row's centre is \((start + button.maxX) / 2), the window's \(area.midX)")
    }

    @Test func everyFormControlIsARoundedRectangle() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let (folder, mode, terms, content) = try await rig.formControls()
        let button = try await rig.searchContentButton()
        let name = try #require(rig.host.field())
        let fields: [NSTextField] = [folder, name, terms]
        let buttons: [NSButton] = [mode, content, button]
        let roundedRectangle = 2
        let expected = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? roundedRectangle : nil
        for field in fields { #expect(Availability.borderShape(field) == expected, "\(type(of: field))") }
        for button in buttons { #expect(Availability.borderShape(button) == expected, "\(button.identifier?.rawValue ?? "")") }
        for field in [terms, folder] as [NSTextField] {
            #expect(field.isBezeled, "\(type(of: field))")
            if expected == nil { #expect(field.bezelStyle == .roundedBezel, "\(type(of: field))") }
        }
    }

    static func slot(of field: NSTextField) -> NSRect {
        let frame = field.convert(field.bounds, to: nil)
        return field is NSSearchField ? frame.insetBy(dx: 0, dy: -Availability.searchFieldOutlineInset) : frame
    }

    @Test func theThreeBoxesShareOneTextLine() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let (folder, _, terms, _) = try await rig.formControls()
        let name = try #require(rig.host.field())
        rig.host.view.layoutSubtreeIfNeeded()
        let scale = rig.host.window.backingScaleFactor
        let line = name.convert(try #require(name.cell).drawingRect(forBounds: name.bounds), to: nil)
        let lift = line.minY - Self.slot(of: name).minY
        for (box, field) in [("folder", folder), ("content", terms)] as [(String, NSTextField)] {
            let own = field.convert(try #require(field.cell).drawingRect(forBounds: field.bounds), to: nil)
            let slot = Self.slot(of: field)
            #expect((own.minY - slot.minY - lift) * scale == 0, "the \(box) text sits \(own.minY - slot.minY) into its slot \(slot), File name's \(lift)")
            #expect((own.minX - line.minX) * scale == 0, "the \(box) text starts \(own.minX - line.minX) off File name's")
            #expect((own.height - line.height) * scale == 0, "the \(box) line is \(own.height) high, File name's \(line.height)")
            #expect(rig.host.window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor())
            let edited = editor.convert(editor.bounds, to: nil)
            #expect((edited.minY - slot.minY - lift) * scale == 0, "the \(box) editor sits \(edited.minY - slot.minY) into its slot \(slot), File name's line \(lift)")
            #expect((edited.minX - line.minX) * scale == 0, "the \(box) editor starts \(edited.minX - line.minX) off File name's")
        }
    }

    @Test(arguments: [TextSize.smallest, .standard, .maximum])
    func theThreeBoxesDrawOneOutlineHeight(size: TextSize) async throws {
        let suite = "com.writronic.wherever.tests.normalform.outline-\(size.rawValue)"
        let store = try #require(UserDefaults(suiteName: suite))
        store.removePersistentDomain(forName: suite)
        store.set(size.rawValue, forKey: TextSize.key)
        let rig = NormalRig(store: store)
        defer { rig.host.close() }
        let (folder, mode, terms, content) = try await rig.formControls()
        let button = try await rig.searchContentButton()
        let name = try #require(rig.host.field())
        let points = size.points(NSFont.systemFontSize)
        try await rig.host.until("\(points) pt boxes, pop-ups and button") {
            ([folder, name, terms, mode, content, button] as [NSControl]).allSatisfy { $0.font?.pointSize == points }
        }
        #expect(rig.host.window.makeFirstResponder(nil))
        let view = rig.host.view
        view.layoutSubtreeIfNeeded()
        let row = Self.slot(of: folder)
        let plain = [mode, content, button].map { Self.plainCopy(of: $0, in: view, at: row) }
        defer { plain.forEach { $0.removeFromSuperview() } }
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let reach = Int((NormalMetrics.rowSpacing / 2 * scale).rounded(.down))
        func outline(_ box: NSView, in window: NSRect) throws -> (top: Int, bottom: Int, trace: String) {
            let slot = view.convert(window, from: nil)
            let top = view.isFlipped ? slot.minY : view.bounds.height - slot.maxY
            let first = Int((top * scale).rounded()), last = Int(((top + slot.height) * scale).rounded())
            let x = Int((view.convert(box.bounds, from: box).midX * scale).rounded(.down))
            let background = try #require(srgbPixel(rep, x: 0, y: (first + last) / 2))
            let rows = (first - reach)..<(last + reach)
            let ink = rows.filter { srgbPixel(rep, x: x, y: $0) != background }
            let raw = rows.map { "\($0 - first):\(srgbPixel(rep, x: x, y: $0) ?? [])" }.joined(separator: " ")
            let trace = "frame \(view.convert(box.bounds, from: box)), slot \(slot), background \(background), rows from the slot top \(raw)"
            let inkTop = try #require(ink.first, "\(type(of: box)) drew nothing: \(trace)")
            let inkBottom = try #require(ink.last)
            return (inkTop - first, inkBottom + 1 - last, trace)
        }
        let edges = try [
            ("Search folder", outline(folder, in: Self.slot(of: folder))), ("File name", outline(name, in: Self.slot(of: name))),
            ("File content", outline(terms, in: Self.slot(of: terms))),
        ]
        let reference = edges[0].1
        for (box, edge) in edges.dropFirst() {
            #expect(
                edge.top - reference.top == 0,
                "\(points) pt: \(box)'s outline top is \(edge.top) px off its slot, Search folder's \(reference.top). \(box): \(edge.trace). Search folder: \(reference.trace)"
            )
            #expect(
                edge.bottom - reference.bottom == 0,
                "\(points) pt: \(box)'s outline bottom is \(edge.bottom) px off its slot, Search folder's \(reference.bottom). \(box): \(edge.trace). Search folder: \(reference.trace)"
            )
        }
        let controls: [(String, NSControl, NSRect, NSControl)] = [
            ("the File name pop-up", mode, Self.slot(of: name), plain[0]), ("the File content pop-up", content, Self.slot(of: terms), plain[1]),
            ("Search Content", button, Self.slot(of: terms), plain[2]),
        ]
        for (control, box, slot, native) in controls {
            let height = box.alignmentRect(forFrame: box.frame).height
            #expect((height - NormalMetrics.controlHeight) * scale == 0, "\(points) pt: \(control) is \(height) high")
            let edge = try outline(box, in: slot)
            let expected = try outline(native, in: row)
            #expect(
                edge.top == expected.top,
                "\(points) pt: \(control)'s outline top is \(edge.top) px off its row's slot, a plain \(type(of: native))'s \(expected.top). \(control): \(edge.trace). Plain: \(expected.trace)"
            )
            #expect(
                edge.bottom == expected.bottom,
                "\(points) pt: \(control)'s outline bottom is \(edge.bottom) px off its row's slot, a plain \(type(of: native))'s \(expected.bottom). \(control): \(edge.trace). Plain: \(expected.trace)"
            )
        }
    }

    static func plainCopy(of control: NSControl, in view: NSView, at row: NSRect) -> NSControl {
        let copy: NSButton
        if let popUp = control as? NSPopUpButton {
            let plain = OutlinePopUpButton(frame: .zero, pullsDown: false)
            plain.addItem(withTitle: popUp.titleOfSelectedItem ?? "")
            copy = plain
        } else {
            copy = OutlineButton(title: (control as? NSButton)?.title ?? "", target: nil, action: nil)
        }
        copy.controlSize = control.controlSize
        copy.font = control.font
        Availability.roundedRectangle(copy)
        let laid = view.convert(control.superview.map { $0.convert(control.alignmentRect(forFrame: control.frame), to: nil) } ?? .zero, from: nil)
        let slot = view.convert(row, from: nil)
        copy.frame = copy.frame(forAlignmentRect: NSRect(x: laid.minX, y: slot.minY, width: laid.width, height: laid.height))
        view.addSubview(copy)
        return copy
    }

    @Test func theFolderAndContentIconsSitWhereFileNameShowsItsMagnifier() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let (folder, _, terms, _) = try await rig.formControls()
        let name = try #require(rig.host.field())
        rig.host.view.layoutSubtreeIfNeeded()
        let scale = rig.host.window.backingScaleFactor
        let magnifier = name.convert(try #require(name.cell as? NSSearchFieldCell).searchButtonRect(forBounds: name.bounds), to: nil)
        let lift = magnifier.minY - Self.slot(of: name).minY
        for (field, symbol) in [(folder, "folder"), (terms, "doc.text")] as [(NSTextField, String)] {
            let icons = field.subviews.compactMap { $0 as? FormIcon }
            try #require(icons.count == 1, "\(symbol): \(icons.count) icons")
            let icon = icons[0]
            #expect(icon.symbol == symbol)
            #expect(icon.image != nil, "\(symbol) has no image")
            #expect(icon.pointSize == field.font?.pointSize)
            #expect(icon.contentTintColor == .secondaryLabelColor)
            #expect(!icon.isHidden)
            let placed = icon.convert(icon.bounds, to: nil)
            for (edge, mine, theirs) in [("x", placed.minX, magnifier.minX), ("y in its slot", placed.minY - Self.slot(of: field).minY, lift),
                                         ("width", placed.width, magnifier.width), ("height", placed.height, magnifier.height)] {
                #expect((mine - theirs) * scale == 0, "the \(symbol) icon's \(edge) is \(mine), the magnifier's \(theirs)")
            }
            #expect(!icon.isAccessibilityElement())
            #expect(!AXTree.elements(in: rig.host.view).contains { $0 === icon }, "VoiceOver reaches the \(symbol) icon")
            #expect(icon.hitTest(NSPoint(x: icon.frame.midX, y: icon.frame.midY)) == nil)
        }
    }

    @Test func theContentIconAndTextMirrorRightToLeft() async throws {
        let rig = NormalRig(direction: .rightToLeft)
        defer { rig.host.close() }
        let (_, _, terms, _) = try await rig.formControls()
        try await rig.host.until("the mirrored content field") { terms.userInterfaceLayoutDirection == .rightToLeft }
        rig.host.view.layoutSubtreeIfNeeded()
        let reference = NSSearchField()
        Availability.roundedRectangle(reference)
        reference.font = terms.font
        reference.controlSize = terms.controlSize
        let inset = Availability.searchFieldOutlineInset
        let frame = NSRect(x: 0, y: 0, width: terms.bounds.width, height: terms.bounds.height - 2 * inset)
        reference.frame = frame
        let cell = try #require(reference.cell as? NSSearchFieldCell)
        let magnifier = cell.searchButtonRect(forBounds: frame).offsetBy(dx: 0, dy: inset)
        let line = cell.drawingRect(forBounds: frame).offsetBy(dx: 0, dy: inset)
        let mirror = terms.bounds.minX + terms.bounds.maxX
        let scale = rig.host.window.backingScaleFactor
        let icon = try #require(terms.subviews.compactMap { $0 as? FormIcon }.first)
        #expect((icon.frame.minX - (mirror - magnifier.maxX)) * scale == 0, "the icon starts at \(icon.frame.minX)")
        #expect((icon.frame.minY - magnifier.minY) * scale == 0)
        let text = try #require(terms.cell).drawingRect(forBounds: terms.bounds)
        #expect((text.minX - (mirror - line.maxX)) * scale == 0, "the text starts at \(text.minX)")
        #expect((text.minY - line.minY) * scale == 0)
    }

    @Test func theFolderChevronIsAppleComboButton() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let (folder, _, _, _) = try await rig.formControls()
        rig.host.view.layoutSubtreeIfNeeded()
        let scale = rig.host.window.backingScaleFactor
        let tile = folder.chevron.frame
        let bounds = folder.bounds
        #expect((tile.width - NormalMetrics.comboWidth) * scale == 0, "the tile is \(tile.width) wide")
        #expect((bounds.maxX - NormalMetrics.comboInset - tile.maxX) * scale == 0, "the tile ends \(bounds.maxX - tile.maxX) before the edge")
        #expect((tile.minY - bounds.minY - NormalMetrics.comboInset) * scale == 0, "the tile starts \(tile.minY - bounds.minY) down")
        #expect((bounds.maxY - NormalMetrics.comboInset - tile.maxY) * scale == 0, "the tile ends \(bounds.maxY - tile.maxY) up")
        #expect(folder.chevron.pointSize == (folder.font?.pointSize ?? 0) - 2)
        #expect(folder.chevron.image != nil && folder.chevron.contentTintColor == .labelColor && !folder.chevron.isBordered)
        #expect(folder.chevron.refusesFirstResponder)
        let text = try #require(folder.cell).drawingRect(forBounds: bounds)
        #expect((bounds.maxX - NormalMetrics.comboTextGap - text.maxX) * scale == 0, "the text stops \(bounds.maxX - text.maxX) before the edge")
        for (appearance, white) in [(NSAppearance.Name.aqua, 0.0), (.darkAqua, 1.0)] as [(NSAppearance.Name, CGFloat)] {
            var fill: NSColor?
            try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                fill = NormalMetrics.comboFill.usingColorSpace(.genericGray)
            }
            #expect(fill?.whiteComponent == white && fill?.alphaComponent == 0.08, "\(appearance.rawValue) fill \(String(describing: fill))")
        }
    }

    @Test func eachPickedModeReachesTheEngine() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        rig.model.query = "report"
        let steps = [
            ("Matches", "whole:\"report\""), ("Begins with", "begins:\"report\""), ("Ends with", "ends:\"report\""), ("Extension", "ext:report"),
            ("Wildcard", "glob:\"report\""), ("Regex", "re:\"report\""), ("Contains", "report"),
        ]
        for (title, text) in steps {
            try await rig.pick(title, in: NormalForm.nameModeID)
            try await rig.queryEnds(text)
            #expect(rig.popUp(NormalForm.nameModeID)?.titleOfSelectedItem == title)
        }
        #expect(rig.fake.queries == ["report"] + steps.map(\.1))
    }

    @Test func aNormalWindowOpensWithTheCaretInFileName() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        try await rig.host.until("File name to hold focus") { rig.host.fieldHasFocus }
        #expect(!(rig.host.window.firstResponder is NSPopUpButton))
        try rig.host.sendKeys("sa")
        #expect(rig.model.query == "sa")
        #expect(rig.fake.queries == ["s", "sa"])
        let editor = try #require(rig.host.field()?.currentEditor())
        #expect(editor.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test func typingAfterAModeKeepsIt() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        try await rig.host.until("File name to hold focus") { rig.host.fieldHasFocus }
        try await rig.pick("Begins with", in: NormalForm.nameModeID)
        #expect(rig.fake.queries.isEmpty)
        try await rig.host.type("sa")
        #expect(rig.fake.queries == ["begins:\"s\"", "begins:\"sa\""])
        #expect(rig.model.filters.nameMode == .beginsWith)
        #expect(rig.popUp(NormalForm.nameModeID)?.titleOfSelectedItem == "Begins with")
    }

    @Test func aKeystrokeInNormalPublishesNothing() async throws {
        let rig = NormalRig(hits: [.named("Safari.app")])
        defer { rig.host.close() }
        try await rig.host.until("File name to hold focus") { rig.host.fieldHasFocus }
        try await rig.pick("Begins with", in: NormalForm.nameModeID)
        var publishes = 0
        let watch = rig.model.objectWillChange.sink { publishes += 1 }
        defer { watch.cancel() }
        for key in "asfzxbom" {
            try rig.host.sendKeys(String(key))
            rig.host.view.layoutSubtreeIfNeeded()
            rig.host.window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(rig.model.query == "asfzxbom")
        #expect(rig.fake.queries.count == 8)
        #expect(rig.fake.queries.last == "begins:\"asfzxbom\"")
        #expect(publishes == 0, "8 keystrokes published \(publishes) times")
    }

    private static let contentTip = "Finds files that contain these terms. With an empty Search folder it reads every indexed disk; type or pick a disk or folder to search there."

    @Test func theFileContentRowSearchesAnyFolder() async throws {
        let archive = IndexedVolume(id: "0A0A0A0A-0000-4000-8000-00000000000A", name: "Archive", path: "/Volumes/Archive", indexed: true)
        let rig = NormalRig(volumes: [archive])
        defer { rig.host.close() }
        let (folder, mode, terms, content) = try await rig.formControls()
        let button = try await rig.searchContentButton()
        #expect(mode.isEnabled)
        #expect(mode.itemTitles == Self.nameTitles)
        #expect(mode.itemArray.map(\.isEnabled) == Array(repeating: true, count: Self.nameTitles.count))
        #expect(mode.titleOfSelectedItem == "Contains")
        #expect(content.itemTitles == ["Find all terms", "Find any term"])
        #expect(content.titleOfSelectedItem == "Find any term")
        #expect(!content.itemTitles.contains("Similar Image"))
        #expect(terms.placeholderString == "Search terms separated by the Enter key")
        try await rig.host.until("the tip") { terms.toolTip == Self.contentTip }
        #expect(rig.index.indexState == nil)
        try await rig.host.until("the row enabled with no state") {
            terms.isEnabled && content.isEnabled && terms.isEditable && terms.isSelectable
        }
        #expect(!button.isEnabled, "an empty row has nothing to search")
        #expect(terms.toolTip == Self.contentTip)
        #expect(mode.isEnabled)
        try await rig.enter(["alpha"], thenClick: button)
        try await rig.pressed("", ["alpha"])
        try rig.endPress()
        try await rig.pick("Find all terms", in: NormalForm.contentModeID)
        #expect(rig.fake.presses.count == 1, "the mode waits for the press")
        button.performClick(nil)
        try await rig.pressed("", ["alpha"], all: true)
        try rig.endPress()
        #expect(rig.model.content.match == .all)
        #expect(rig.fake.queries.isEmpty, "no press searched names")

        try Self.commit("Archive", in: folder)
        try await rig.pressed("in:\"/Volumes/Archive\"", ["alpha"], all: true)
        #expect(rig.fake.narrows.isEmpty, "a folder change reads again")
        try rig.endPress()
        #expect(terms.isEnabled && content.isEnabled && terms.isEditable && terms.toolTip == Self.contentTip && button.isEnabled)
        rig.model.content.match = .any
        button.performClick(nil)
        try await rig.pressed("in:\"/Volumes/Archive\"", ["alpha"])
        try rig.endPress()

        let documents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path
        rig.model.filters.folder = documents
        try await rig.pressed("in:\"\(documents)\"", ["alpha"])
        try rig.endPress()
        #expect(terms.isEnabled && content.isEnabled)

        try await rig.reportReady()
        #expect(terms.isEnabled && content.isEnabled && button.isEnabled && terms.toolTip == Self.contentTip)
        let sent = rig.fake.presses.count
        button.performClick(nil)
        try await rig.host.until("a press after Ready; pressed \(rig.fake.presses)") { rig.fake.presses.count == sent + 1 }
        try await rig.pressed("in:\"\(documents)\"", ["alpha"])
    }

    @Test func theSearchContentButtonRunsTheContentSearch() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        try await rig.host.until("File name to hold focus") { rig.host.fieldHasFocus }
        let button = try await rig.searchContentButton()
        #expect(button.title == "Search Content")
        #expect(button.keyEquivalent.isEmpty, "Return makes a term and opens a row")
        #expect(rig.index.indexState == nil)
        #expect(!button.isEnabled, "the row is empty")
        button.performClick(nil)
        #expect(rig.fake.presses.isEmpty, "a press with the row empty sends nothing")

        try await rig.host.type("report")
        #expect(rig.fake.queries.last == "report", "File name searches with no press")
        let typed = rig.fake.queries.count
        rig.model.content = ContentTerms(terms: ["alpha"])
        #expect(rig.fake.presses.isEmpty, "a term searches nothing before the press")
        try await rig.host.until("the button on") { button.isEnabled }
        button.performClick(nil)
        try await rig.pressed("report", ["alpha"])
        #expect(rig.fake.queries.count == typed, "the press starts no name search")

        #expect(rig.host.fieldHasFocus, "the press left File name editing, so the next key appends")
        try await rig.host.type("s")
        try await rig.pressed("reports", ["alpha"])
        #expect(rig.fake.narrows.isEmpty, "a changed File name reads again")
        #expect(rig.fake.queries.count == typed, "and starts no name search")
        rig.model.content = ContentTerms()
        rig.model.contentDraft = ""
        try await rig.queryEnds("reports")
        let sent = rig.fake.presses.count
        try await rig.host.until("the button off") { !button.isEnabled }
        button.performClick(nil)
        #expect(rig.fake.presses.count == sent, "a press with the row emptied sends nothing")

        try await rig.reportReady()
        try await rig.enter(["beta"], thenClick: button)
        try await rig.pressed("reports", ["beta"])
    }

    @Test func theButtonIsOnOnlyWithSomethingToSearchOrToStop() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let (_, _, terms, _) = try await rig.formControls()
        let button = try await rig.searchContentButton()
        #expect(!button.isEnabled, "nothing to search")

        try #require(rig.host.window.makeFirstResponder(terms))
        try rig.host.sendKeys("a")
        try await rig.host.until("a draft turns it on") { button.isEnabled }
        #expect(rig.model.hasTerms)
        rig.model.contentDraft = "   "
        try await rig.host.until("a blank draft turns it off") { !button.isEnabled }

        rig.model.content = ContentTerms(terms: ["alpha"])
        try await rig.host.until("a term turns it on") { button.isEnabled }
        button.performClick(nil)
        try await rig.host.until("the title Stop") { button.title == "Stop" }
        #expect(button.isEnabled, "Stop stays on while the press reads")
        button.performClick(nil)
        #expect(rig.fake.stops == 1)
        try rig.endPress()
        try await rig.host.until("the title back") { button.title == "Search Content" }
        #expect(button.isEnabled, "the terms are still there")

        rig.model.content = ContentTerms()
        rig.model.contentDraft = ""
        try await rig.host.until("emptied terms turn it off") { !button.isEnabled }
    }

    @Test func aBlankOrEmptyRowHoldsNoTerms() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        var publishes = 0
        let watch = rig.model.objectWillChange.sink { publishes += 1 }
        defer { watch.cancel() }
        rig.model.contentDraft = " "
        #expect(!rig.model.hasTerms && publishes == 0, "a blank draft flips nothing")
        rig.model.contentDraft = "a"
        #expect(rig.model.hasTerms && publishes == 1, "the flip publishes once")
        rig.model.contentDraft = "ab"
        rig.model.contentDraft = "abc"
        #expect(publishes == 1, "further keys publish nothing")
        rig.model.contentDraft = ""
        #expect(!rig.model.hasTerms && publishes == 2)
    }

    @Test func thePressShowsStopAndTheCount() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let button = try await rig.searchContentButton()
        try await rig.enter(["alpha"], thenClick: button)
        try await rig.pressed("", ["alpha"])
        try await rig.host.until("the title Stop") { button.title == "Stop" }
        let press = try #require(rig.model.press)
        rig.model.handle(.contentProgress(press, read: 3, total: 10, notDownloaded: 0, unreadable: 0, done: false))
        #expect(button.title == "Stop")
        button.performClick(nil)
        #expect(rig.fake.stops == 1, "the button stops the read")
        #expect(rig.fake.presses.count == 1, "and starts none")
        rig.model.handle(.contentProgress(press, read: 4, total: 10, notDownloaded: 0, unreadable: 0, done: true))
        try await rig.host.until("the title back") { button.title == "Search Content" }
    }

    @Test func typingDuringTheReadKeepsStop() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let button = try await rig.searchContentButton()
        try await rig.host.until("File name to hold focus") { rig.host.fieldHasFocus }
        try await rig.enter(["alpha"], thenClick: button)
        try await rig.host.until("the title Stop") { button.title == "Stop" }
        try await rig.host.type("s")
        try await rig.narrowEnds("s")
        let press = try #require(rig.model.press)
        rig.model.handle(.contentProgress(press, read: 5, total: 10, notDownloaded: 0, unreadable: 0, done: false))
        #expect(button.title == "Stop", "a narrow does not end the read")
        #expect(rig.model.progress?.read == 5)
    }

    @Test func simpleDuringAReadResetsTheButton() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let button = try await rig.searchContentButton()
        try await rig.enter(["alpha"], thenClick: button)
        try await rig.host.until("the title Stop") { button.title == "Stop" }
        rig.model.dropNormalControls()
        #expect(rig.fake.stops == 1, "Simple stops the read")
        #expect(!rig.model.reading)
        try await rig.host.until("the title back") { button.title == "Search Content" }
    }

    @Test(arguments: ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"])
    func theButtonKeepsItsWidthWhenItSaysStop(language: String) async throws {
        let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(root: AnyView(
            NormalForm(model: model, bundle: bundle).environment(\.searchClient, fake).environment(\.locale, Locale(identifier: language))
        ))
        defer { host.close() }
        try await host.until("the button") { findButton(NormalForm.searchContentID, in: host.view) != nil }
        let button = try #require(findButton(NormalForm.searchContentID, in: host.view))
        func width() -> CGFloat { host.window.convertToScreen(button.convert(button.bounds, to: nil)).width }
        let search = bundle.localizedString(forKey: "Search Content", value: nil, table: "Normal")
        let stop = bundle.localizedString(forKey: "Stop", value: nil, table: "Normal")
        #expect(button.title == search)
        let before = width()
        model.content = ContentTerms(terms: ["alpha"])
        try await host.until("the button on") { button.isEnabled }
        button.performClick(nil)
        try await host.until("the title \(stop)") { button.title == stop }
        host.view.layoutSubtreeIfNeeded()
        #expect((width() - before) * host.window.backingScaleFactor == 0, "\(language): \(before) before, \(width()) as Stop")
        #expect(stop != search)
    }

    @Test func escapeInTheListWithAnEmptyNameKeepsTheFolderAndPillsThenTheFieldsEscapeResetsThem() async throws {
        let archive = IndexedVolume(id: "0A0A0A0A-0000-4000-8000-00000000000A", name: "Archive", path: "/Volumes/Archive", indexed: true)
        let rig = NormalRig(hits: [.named("Report.pdf", in: "/Volumes/Archive")], volumes: [archive])
        defer { rig.host.close() }
        let (folder, _, _, _) = try await rig.formControls()
        try Self.commit("Archive", in: folder)
        rig.model.filters.kind = .documents
        try await rig.queryEnds("type:doc in:\"/Volumes/Archive\"")
        try await rig.search(1)
        try await rig.host.focusList()
        rig.host.list()?.selectRowIndexes([0], byExtendingSelection: false)
        let before = rig.fake.queries.count
        try rig.host.pressEscape()
        #expect(rig.host.fieldHasFocus)
        #expect(rig.model.filters.folder == "/Volumes/Archive" && rig.model.filters.kind == .documents)
        #expect(folder.stringValue == "/Volumes/Archive")
        #expect(rig.fake.queries.count == before, "the Escape sent \(rig.fake.queries.dropFirst(before))")
        try rig.host.pressEscape()
        #expect(rig.model.filters == SearchFilters())
    }

    @Test func escapeInTheListWithANameClearsOnlyTheName() async throws {
        let archive = IndexedVolume(id: "0A0A0A0A-0000-4000-8000-00000000000A", name: "Archive", path: "/Volumes/Archive", indexed: true)
        let rig = NormalRig(hits: [.named("Report.pdf", in: "/Volumes/Archive")], volumes: [archive])
        defer { rig.host.close() }
        let (folder, _, _, _) = try await rig.formControls()
        try Self.commit("Archive", in: folder)
        rig.model.filters.kind = .documents
        try await rig.host.type("re")
        try await rig.queryEnds("re type:doc in:\"/Volumes/Archive\"")
        try await rig.search(1)
        try await rig.host.focusList()
        rig.host.list()?.selectRowIndexes([0], byExtendingSelection: false)
        try rig.host.pressEscape()
        #expect(rig.host.fieldHasFocus)
        #expect(rig.model.query.isEmpty)
        #expect(rig.model.filters.folder == "/Volumes/Archive" && rig.model.filters.kind == .documents)
        try await rig.queryEnds("type:doc in:\"/Volumes/Archive\"")
    }

    @Test func escapeTwiceResetsTheModeAndTheFolder() async throws {
        let archive = IndexedVolume(id: "0A0A0A0A-0000-4000-8000-00000000000A", name: "Archive", path: "/Volumes/Archive", indexed: true)
        let rig = NormalRig(volumes: [archive])
        defer { rig.host.close() }
        let (folder, _, _, _) = try await rig.formControls()
        try await rig.pick("Begins with", in: NormalForm.nameModeID)
        try Self.commit("Archive", in: folder)
        try await Task.sleep(for: .milliseconds(20))
        try await rig.queryEnds("in:\"/Volumes/Archive\"")
        try await rig.host.type("sa")
        try await rig.queryEnds("begins:\"sa\" in:\"/Volumes/Archive\"")
        try rig.host.pressEscape()
        try await rig.queryEnds("in:\"/Volumes/Archive\"")
        #expect(rig.model.filters.nameMode == .beginsWith)
        #expect(folder.stringValue == "/Volumes/Archive")
        let before = rig.fake.queries.count
        try rig.host.pressEscape()
        #expect(rig.model.filters == SearchFilters())
        try await rig.host.until("Contains and an empty Search folder; the box shows \(folder.stringValue)") {
            rig.popUp(NormalForm.nameModeID)?.titleOfSelectedItem == "Contains" && folder.stringValue.isEmpty
        }
        #expect(folder.placeholderString == "Every indexed disk")
        Self.openList(folder)
        #expect(Self.titles(folder).first == "Every indexed disk")
        #expect(rig.fake.queries.count == before)
        try rig.host.sendKeys("s")
        try await rig.queryEnds("s")
    }

    @Test func theSearchFolderWritesItsScope() async throws {
        let rig = BoxRig("scope")
        defer { rig.close() }
        let box = try await rig.box()
        let boot = FileManager.default.displayName(atPath: "/")
        Self.openList(box)
        #expect(Self.titles(box) == ["Every indexed disk", boot, "Archive", "\(Bidi.name("Backup")) (Not indexed)", "Browse…"])
        #expect(box.placeholderString == "Every indexed disk" && box.stringValue.isEmpty)
        #expect(box.isEditable && box.isSelectable)
        rig.model.query = "report"
        let steps = [
            ("Archive", "/Volumes/Archive", "report in:\"/Volumes/Archive\""), (boot, "/", "report in:\"/\""), ("Every indexed disk", "", "report"),
        ]
        for (title, shown, query) in steps {
            try Self.commit(title, in: box)
            try await rig.host.until("the query \(query); sent \(rig.fake.queries)") { rig.fake.queries.last == query }
            #expect(box.stringValue == shown)
        }
        Self.edit("/tmp", in: box)
        try await rig.host.until("the typed scope; sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"/tmp\"" }
        let sent = rig.fake.queries.count
        try #require(box.sendAction(box.action, to: box.target))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.fake.queries.count == sent)
        Self.edit("nowhere", in: box)
        try await rig.host.until("the scope nowhere; sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"nowhere\"" }
        #expect(box.stringValue == "nowhere")
        rig.model.query = "reports"
        try await rig.host.until("the scope kept; sent \(rig.fake.queries)") { rig.fake.queries.last == "reports in:\"nowhere\"" }
        #expect(rig.answers.asked.isEmpty && rig.fake.switchedOn.isEmpty)
    }

    @Test(arguments: ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"])
    func theFolderMenuUsesNativeSectionsIconsAndChecks(appearance: String) async throws {
        let rig = NormalRig(volumes: [BoxRig.backup, BoxRig.archive])
        defer { rig.host.close() }
        let (box, mode, _, content) = try await rig.formControls()
        rig.host.window.appearance = NSAppearance(named: NSAppearance.Name(appearance))
        Self.openList(box)
        let menu = box.diskMenu
        #expect(menu.font == mode.menu?.font && menu.font == content.menu?.font)
        #expect(menu.items.map(\.isSeparatorItem) == [false, true, false, false, true, false, true, false])
        #expect(Self.titles(box) == ["Every indexed disk", FileManager.default.displayName(atPath: "/"), "Archive", "\(Bidi.name("Backup")) (Not indexed)", "Browse…"])
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["Every indexed disk"])
        #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.isEnabled && $0.view == nil })
        try #require(menu.numberOfItems == 8)
        #expect(menu.items[0].image == nil)
        for index in [2, 3, 5] { #expect(menu.items[index].image != nil) }
        #expect(menu.items[7].image == nil && menu.items[7].state == .off)
        #expect(box.accessibilityIdentifier() == SearchFolderBox.id)
        #expect(box.cell?.accessibilityLabel() == "Search folder:")
        #expect(box.chevron.accessibilityIdentifier() == "search-folder-menu")
        #expect(box.chevron.accessibilityLabel() == "Choose a disk")
        for (title, path) in [("Archive", "/Volumes/Archive"), ("Every indexed disk", "")] {
            try Self.commit(title, in: box)
            Self.openList(box)
            #expect(menu.items.filter { $0.state == .on }.map(\.title) == [title])
            #expect(box.stringValue == path)
        }
        Self.edit("/tmp", in: box)
        Self.openList(box)
        #expect(menu.items.allSatisfy { $0.state == .off })
        rig.fake.setVolumes(.success([]))
        Self.openList(box)
        #expect(menu.items.map(\.isSeparatorItem) == [false, true, false, true, false])
    }

    @Test func browseIsTheLastItemAfterASeparatorAndKeyboardPicksIt() async throws {
        let rig = BoxRig("menu-browse")
        defer { rig.close() }
        let box = try await rig.box()
        Self.openList(box)
        let items = box.diskMenu.items
        let browse = try #require(items.last)
        #expect(items[items.count - 2].isSeparatorItem)
        #expect(browse.title == "Browse…" && browse.identifier?.rawValue == "search-folder-item-browse")
        #expect(browse.accessibilityIdentifier() == "search-folder-item-browse")
        #expect(browse.image == nil && browse.state == .off && browse.isEnabled)
        rig.model.query = "report"
        rig.answers.chosen = URL(fileURLWithPath: "/tmp")
        try await AXTree.choose(box.chevron, item: 4)
        try await rig.host.until("the folder of Browse; sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"/tmp\"" }
        #expect(box.stringValue == "/tmp" && rig.model.filters.folder == "/tmp")
        #expect(rig.answers.starts.count == 1 && rig.answers.starts[0] == nil)
        rig.answers.chosen = nil
        let sent = rig.fake.queries.count
        try await AXTree.choose(box.chevron, item: 4)
        #expect(rig.answers.starts.count == 2 && rig.answers.starts[1]?.path == "/tmp")
        #expect(box.stringValue == "/tmp" && rig.model.filters.folder == "/tmp" && rig.fake.queries.count == sent)
        #expect(rig.answers.asked.isEmpty && rig.fake.switchedOn.isEmpty)
    }

    @Test func theChevronOpensTheMenuAndReturnPicksADisk() async throws {
        let rig = BoxRig("menu-return")
        defer { rig.close() }
        let box = try await rig.box()
        rig.model.query = "report"
        try await AXTree.choose(box.chevron, item: 2)
        try await rig.host.until("Archive's path from the real menu") {
            rig.fake.queries.last == "report in:\"/Volumes/Archive\""
        }
        #expect(box.stringValue == "/Volumes/Archive")
        #expect(rig.answers.asked.isEmpty)
        Self.edit("/tmp", in: box)
        try await rig.host.until("typing after a menu pick") { rig.fake.queries.last == "report in:\"/tmp\"" }
    }

    @Test(arguments: ["down", "up", "accessibility", "chevron"])
    func openingThenCancellingTheMenuPreservesTheEdit(route: String) async throws {
        let rig = BoxRig("menu-cancel-\(route)")
        defer { rig.close() }
        let box = try await rig.box()
        rig.model.query = "report"
        #expect(rig.host.window.makeFirstResponder(box))
        let editor = try #require(box.currentEditor() as? NSTextView)
        editor.string = "/tmp "
        box.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: box))
        try await rig.host.until("the typed scope") { rig.fake.queries.last == "report in:\"/tmp\"" }
        for command in [#selector(NSResponder.moveToBeginningOfParagraph(_:)), #selector(NSResponder.moveToEndOfParagraph(_:))] {
            #expect(box.delegate?.control?(box, textView: editor, doCommandBy: command) == false)
        }
        let before = rig.fake.queries.count
        let tracking = FolderMenuTracking(menu: box.diskMenu)
        try await EventQueueLock.run {
            try tracking.cancelAfterOpening {
                if route == "accessibility" {
                    #expect(box.accessibilityPerformShowMenu())
                } else if route == "chevron" {
                    box.chevron.performClick(nil)
                } else {
                    editor.doCommand(by: route == "down" ? #selector(NSResponder.moveDown(_:)) : #selector(NSResponder.moveUp(_:)))
                }
            }
        }
        #expect(editor.string == "/tmp ")
        #expect(rig.model.filters.folder == "/tmp" && rig.fake.queries.count == before)
        #expect(rig.answers.asked.isEmpty && rig.fake.switchedOn.isEmpty)
        editor.string = "/tmp next"
        box.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: box))
        try await rig.host.until("typing after cancelling") { rig.fake.queries.last == "report in:\"/tmp next\"" }
    }

    @Test(arguments: [("/Volumes/Archive ", "Archive", "/Volumes/Archive"), ("   ", "Every indexed disk", "")])
    func pickingTheCurrentScopeNormalizesTheEditor(typed: String, title: String, expected: String) async throws {
        let rig = BoxRig("normalize")
        defer { rig.close() }
        let box = try await rig.box()
        #expect(rig.host.window.makeFirstResponder(box))
        let editor = try #require(box.currentEditor() as? NSTextView)
        editor.string = typed
        box.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: box))
        #expect(editor.string == typed)
        try Self.commit(title, in: box)
        #expect(editor.string == expected && box.stringValue == expected)
        #expect(rig.answers.asked.isEmpty)
    }

    @Test func theFolderMenuMirrorsWithoutCoveringEditedText() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(root: AnyView(
            SearchFolderBox(folder: Binding(get: { model.filters.folder }, set: { model.filters.folder = $0 }), client: fake)
                .frame(width: NormalMetrics.fieldWidth, height: NormalMetrics.controlHeight)
                .environment(\.layoutDirection, .rightToLeft)
        ))
        defer { host.close() }
        try await host.until("the mirrored field") { findFolderField(SearchFolderBox.id, in: host.view) != nil }
        let box = try #require(findFolderField(SearchFolderBox.id, in: host.view))
        host.view.layoutSubtreeIfNeeded()
        #expect(box.userInterfaceLayoutDirection == .rightToLeft)
        #expect(box.diskMenu.userInterfaceLayoutDirection == .rightToLeft)
        let scale = host.window.backingScaleFactor
        #expect((box.chevron.frame.minX - box.bounds.minX - NormalMetrics.comboInset) * scale == 0, "the tile starts at \(box.chevron.frame.minX)")
        #expect((box.chevron.frame.width - NormalMetrics.comboWidth) * scale == 0)
        let reference = NSSearchField()
        Availability.roundedRectangle(reference)
        reference.font = box.font
        reference.controlSize = box.controlSize
        let inset = Availability.searchFieldOutlineInset
        let outline = NSRect(x: 0, y: 0, width: box.bounds.width, height: box.bounds.height - 2 * inset)
        reference.frame = outline
        let cell = try #require(reference.cell as? NSSearchFieldCell)
        let magnifier = cell.searchButtonRect(forBounds: outline).offsetBy(dx: box.bounds.minX, dy: box.bounds.minY + inset)
        let line = cell.drawingRect(forBounds: outline).offsetBy(dx: box.bounds.minX, dy: box.bounds.minY + inset)
        #expect((box.icon.frame.minX - (box.bounds.minX + box.bounds.maxX - magnifier.maxX)) * scale == 0, "the icon starts at \(box.icon.frame.minX)")
        #expect((box.icon.frame.width - magnifier.width) * scale == 0)
        #expect((box.icon.frame.minY - magnifier.minY) * scale == 0)
        #expect(host.window.makeFirstResponder(box))
        let editor = try #require(box.currentEditor())
        let frame = box.convert(editor.bounds, from: editor)
        #expect(frame.minX >= box.chevron.frame.maxX)
        #expect((frame.minX - box.bounds.minX - NormalMetrics.comboTextGap) * scale == 0, "the text starts at \(frame.minX)")
        #expect(frame.maxX <= box.bounds.maxX)
        #expect((frame.maxX - (box.bounds.minX + box.bounds.maxX - line.minX)) * scale == 0, "the text ends at \(frame.maxX)")
        #expect(box.chevron.refusesFirstResponder)
    }

    @Test func aNotIndexedDiskAsksFirst() async throws {
        let rig = BoxRig("ask")
        defer { rig.close() }
        let box = try await rig.box()
        rig.model.query = "report"
        Self.edit("/Volumes/Backup", in: box)
        try await rig.host.until("the typed scope; sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"/Volumes/Backup\"" }
        #expect(rig.answers.asked.isEmpty)
        try Self.commit("Archive", in: box)
        try await rig.host.until("Archive's scope; sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"/Volumes/Archive\"" }

        try Self.commit("\(Bidi.name("Backup")) (Not indexed)", in: box)
        #expect(rig.answers.asked == ["Backup"])
        #expect(box.stringValue == "/Volumes/Backup" && rig.model.filters.folder == "/Volumes/Backup")
        try await rig.host.until("Backup's scope after Cancel; sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"/Volumes/Backup\"" }
        #expect(rig.fake.switchedOn.isEmpty && rig.storedDisks == nil)

        try Self.commit("Archive", in: box)
        try await rig.host.until("Archive's scope again; sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"/Volumes/Archive\"" }
        rig.answers.replies = [true]
        try Self.commit("\(Bidi.name("Backup")) (Not indexed)", in: box)
        #expect(rig.answers.asked == ["Backup", "Backup"])
        #expect(rig.storedDisks == [BoxRig.backup.id])
        #expect(rig.fake.switchedOn.last == Set([BoxRig.backup.id]))
        #expect(box.stringValue == "/Volumes/Backup")
        try await rig.host.until("Backup's scope; sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"/Volumes/Backup\"" }
    }

    @Test func typingADiskTitleNeverPicksOrAsks() async throws {
        let rig = BoxRig("typed-title")
        defer { rig.close() }
        let box = try await rig.box()
        rig.model.query = "report"
        for title in ["Archive", "Backup (Not indexed)"] {
            Self.edit(title, in: box)
            try await rig.host.until("a typed title stays a path") { rig.fake.queries.last == "report in:\"\(title)\"" }
            #expect(box.stringValue == title && rig.answers.asked.isEmpty && rig.fake.switchedOn.isEmpty)
        }
    }

    @Test func downArrowFromFileNameReachesTheTable() async throws {
        let rig = NormalRig(hits: [.named("Safari.app"), .named("Mail.app")])
        defer { rig.host.close() }
        try await rig.host.type("sa")
        try await rig.search(2)
        try rig.host.press(.downArrow)
        #expect(rig.host.listHasFocus)
        #expect(rig.host.list()?.selectedRow == 0)
    }

    @Test func returnInFileNameOpensTheFirstRow() async throws {
        let rig = NormalRig(hits: [.named("Safari.app"), .named("Mail.app")])
        defer { rig.host.close() }
        try await rig.host.type("sa")
        try await rig.search(2)
        try rig.host.pressReturn()
        #expect(rig.host.recorder.opened.map(\.lastPathComponent) == ["Safari.app"])
        try rig.host.pressReturn(command: true)
        #expect(rig.host.recorder.revealed.map(\.lastPathComponent) == ["Safari.app"])
        #expect(rig.host.fieldHasFocus)
    }

    @Test func returnInFileNameWhileASearchIsPendingOpensTheFirstRowWhenItLands() async throws {
        let rig = NormalRig(hits: [.named("Safari.app"), .named("Mail.app")])
        defer { rig.host.close() }
        try await rig.host.type("sa")
        try rig.host.pressReturn()
        #expect(rig.host.recorder.nothingHappened)
        try await rig.search(2)
        try await rig.host.until("the first row opened") { !rig.host.recorder.opened.isEmpty }
        #expect(rig.host.recorder.opened.map(\.lastPathComponent) == ["Safari.app"])
        #expect(rig.host.fieldHasFocus)
    }

    @Test func aPendingReturnDropsWhenFocusMovesToTheSearchFolder() async throws {
        let rig = NormalRig(hits: [.named("Safari.app")])
        defer { rig.host.close() }
        let (folder, _, _, _) = try await rig.formControls()
        try await rig.host.type("sa")
        try rig.host.pressReturn()
        try #require(rig.host.window.makeFirstResponder(folder))
        try await rig.search(1)
        #expect(rig.host.recorder.nothingHappened)
    }

    @Test func aReturnWhileSearchContentReadsWaitsForNothing() async throws {
        let rig = NormalRig(hits: [.named("Safari.app")])
        defer { rig.host.close() }
        try await rig.host.type("sa")
        try await rig.search(1)
        rig.model.content = ContentTerms(terms: ["invoice"])
        rig.model.searchContent()
        try await rig.pressed("sa", ["invoice"])
        #expect(rig.model.isPending && rig.model.reading)
        try rig.host.pressReturn()
        try await rig.search(1)
        #expect(rig.host.recorder.nothingHappened)
    }

    @Test func aReturnDuringTheWaitForANewReadOpensNothing() async throws {
        let rig = NormalRig(hits: [.named("Safari.app")])
        defer { rig.host.close() }
        rig.model.readDelay = { try? await Task.sleep(for: .seconds(30)) }
        try await rig.host.type("sa")
        try await rig.search(1)
        rig.model.content = ContentTerms(terms: ["invoice"])
        rig.model.searchContent()
        try await rig.pressed("sa", ["invoice"])
        try await rig.search(1)
        try rig.endPress()
        try await rig.host.type("f")
        #expect(rig.model.isPending)
        try rig.host.pressReturn()
        #expect(rig.host.recorder.nothingHappened, "the row on screen answers the old name")
        rig.model.searchContent()
        try await rig.pressed("saf", ["invoice"])
        try await rig.search(1)
        #expect(rig.host.recorder.nothingHappened, "the Return did not wait for the new read")
    }

    @Test func aSearchContentPressAfterAPendingReturnDropsIt() async throws {
        let rig = NormalRig(hits: [.named("Safari.app")])
        defer { rig.host.close() }
        try await rig.host.type("sa")
        try rig.host.pressReturn()
        rig.model.content = ContentTerms(terms: ["invoice"])
        rig.model.searchContent()
        try await rig.pressed("sa", ["invoice"])
        try await rig.search(1)
        #expect(rig.host.recorder.nothingHappened)
    }

    @Test func aLetterInTheNormalTableGoesToFileName() async throws {
        let rig = NormalRig(hits: [.named("Safari.app")])
        defer { rig.host.close() }
        try await rig.pick("Begins with", in: NormalForm.nameModeID)
        try await rig.host.type("sa")
        try await rig.search(1)
        try await rig.host.focusList()
        try rig.host.sendKeys("f")
        #expect(rig.host.fieldHasFocus)
        #expect(rig.model.query == "saf")
        #expect(rig.fake.queries.last == "begins:\"saf\"")
    }

    @Test func theNormalKeyViewOrderFollowsTheForm() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let (folder, mode, terms, content) = try await rig.formControls()
        try await rig.host.until("the content row on") { terms.isEnabled && content.isEnabled }
        try await rig.host.until("the extension pill and the list") { rig.extensionsPill() != nil && rig.host.list() != nil }
        let field = try #require(rig.host.field())
        let extensions = try #require(rig.extensionsPill())
        let table = try #require(rig.host.list())
        let button = try await rig.searchContentButton()
        rig.model.content = ContentTerms(terms: ["alpha"])
        try await rig.host.until("the button on, so it is a stop") { button.isEnabled }
        let ordered: [NSView] = [folder, field, mode, terms, content, button, extensions, table]
        try await rig.host.until("every form stop among the links") {
            rig.host.window.recalculateKeyViewLoop()
            let links = Self.links(from: folder)
            return ordered.allSatisfy { view in links.contains { $0 === view } }
        }
        let loop = rig.host.keyViewLoop(from: field)
        let names = loop.map { String(describing: type(of: $0)) }
        let links = Self.links(from: folder)
        let places = ordered.compactMap { view in links.firstIndex { $0 === view } }
        #expect(places.count == ordered.count && places == places.sorted(), "the links run \(links.map { String(describing: type(of: $0)) })")
        let termsStop = try #require(loop.firstIndex { $0 === terms || $0.isDescendant(of: terms) }, "no content field among \(names)")
        let fieldStop = try #require(loop.firstIndex { $0 === field })
        let tableStop = try #require(loop.firstIndex { $0 === table }, "no table among \(names)")
        #expect(fieldStop < termsStop && termsStop < tableStop, "the stops run \(names)")
        #expect(loop.last?.nextValidKeyView === field, "the stops \(names) do not wrap to File name")
        #expect(loop.last === folder, "the stops \(names) do not end at the Search folder")
        if NSApp.isFullKeyboardAccessEnabled {
            let extensionStop = try #require(loop.firstIndex { $0 === extensions }, "no extension pill among \(names)")
            let modeStop = try #require(loop.firstIndex { $0 === mode }, "no name mode among \(names)")
            let folderStop = try #require(loop.firstIndex { $0 === folder }, "no Search folder among \(names)")
            let contentStop = try #require(loop.firstIndex { $0 === content }, "no content mode among \(names)")
            let buttonStop = try #require(loop.firstIndex { $0 === button }, "no Search Content among \(names)")
            #expect(fieldStop < extensionStop && extensionStop < tableStop, "the stops run \(names)")
            #expect(modeStop < termsStop && termsStop < contentStop && contentStop < buttonStop && buttonStop < extensionStop, "the stops run \(names)")
            #expect(modeStop < extensionStop && folderStop > tableStop, "the stops run \(names)")
        } else {
            #expect(
                !loop.contains { $0 === mode || $0 === content || $0 === button || $0 === extensions },
                "a pop-up, pill or button is a stop with Keyboard navigation off: \(names)"
            )
        }
    }

    @Test func theLabelsLineUpInGerman() async throws {
        let rig = NormalRig(locale: "de")
        defer { rig.host.close() }
        let (folder, _, _, _) = try await rig.formControls()
        let labels = ["Suchordner:", "Dateiname:", "Dateiinhalt:"]
        try await rig.host.until("the German labels") { labels.allSatisfy { rig.labelFrame($0) != nil } }
        let scale = rig.host.window.backingScaleFactor
        let frames = try labels.map { try #require(rig.labelFrame($0)) }
        let fieldStart = rig.screenFrame(folder).minX
        for (label, frame) in zip(labels, frames) {
            #expect((frame.maxX - frames[0].maxX) * scale == 0, "\(label) ends at \(frame.maxX), not \(frames[0].maxX)")
            #expect((fieldStart - NormalMetrics.columnSpacing - frame.maxX) * scale == 0, "\(label) ends \(fieldStart - frame.maxX) before the fields")
        }
    }

    @Test func theFormStartsOnAPixelAtEveryWidth() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let (folder, _, _, _) = try await rig.formControls()
        let labels = ["Search folder:", "File name:", "File content:"]
        try await rig.host.until("the labels") { labels.allSatisfy { rig.labelFrame($0) != nil } }
        let window = rig.host.window
        let scale = window.backingScaleFactor
        try await rig.host.until("the form's minimum, now \(window.contentMinSize.width)") {
            window.contentMinSize.width > SearchMetrics.windowMinWidth
        }
        let minimum = window.contentMinSize.width
        func gaps() -> [CGFloat] {
            let fieldStart = rig.screenFrame(folder).minX
            return labels.map { label in rig.labelFrame(label).map { fieldStart - $0.maxX } ?? -1 }
        }
        for extra: CGFloat in [1, 2, 3] {
            window.setContentSize(NSSize(width: minimum + extra, height: SearchMetrics.windowMinHeight))
            try await rig.host.until("at +\(extra), a window \(window.contentLayoutRect.width) wide, the labels end \(gaps()) before the fields") {
                window.contentLayoutRect.width == minimum + extra
                    && gaps().allSatisfy { ($0 - NormalMetrics.columnSpacing) * scale == 0 }
            }
        }
    }

    @Test(arguments: [
        ("en", ["Search folder:", "File name:", "File content:"]),
        ("de", ["Suchordner:", "Dateiname:", "Dateiinhalt:"]),
    ])
    func aNormalWindowShrunkToItsMinimumHoldsTheWholeForm(locale: String, labels: [String]) async throws {
        let rig = NormalRig(locale: locale)
        defer { rig.host.close() }
        let (folder, mode, terms, content) = try await rig.formControls()
        let button = try await rig.searchContentButton()
        try await rig.host.until("the \(locale) labels") { labels.allSatisfy { rig.labelFrame($0) != nil } }
        let window = rig.host.window
        window.setContentSize(NSSize(width: 100, height: SearchMetrics.windowMinHeight))
        try await rig.host.until("the window at its minimum, \(window.contentLayoutRect.width) of \(window.contentMinSize.width)") {
            window.contentLayoutRect.width == window.contentMinSize.width
        }
        let scale = window.backingScaleFactor
        let widest = try labels.map { try #require(rig.labelFrame($0)).width }.max() ?? 0
        let form = max(NormalMetrics.labelMinWidth, widest) + NormalMetrics.fieldWidth + NormalForm.popUpColumn(.main, .standard)
            + rig.laidOut(button).width + 3 * NormalMetrics.columnSpacing
        #expect((window.contentMinSize.width - form - 2 * SearchMetrics.sideInset) * scale == 0, "the minimum is \(window.contentMinSize.width), the form \(form)")
        let area = window.convertToScreen(window.contentLayoutRect)
        let inner = area.insetBy(dx: SearchMetrics.sideInset, dy: 0)
        let field = try #require(rig.host.field())
        let frames = [
            ("Search folder", rig.screenFrame(folder)), ("File name", rig.screenFrame(field)), ("File name mode", rig.laidOut(mode)),
            ("File content", rig.screenFrame(terms)), ("File content mode", rig.laidOut(content)), ("button", rig.laidOut(button)),
        ]
        for (name, frame) in frames {
            #expect(frame.minX >= inner.minX && frame.maxX <= inner.maxX, "\(name) at \(frame.minX) to \(frame.maxX) inside margins from \(inner.minX) to \(inner.maxX)")
        }
        let end = rig.laidOut(button).maxX
        #expect((area.maxX - end - SearchMetrics.sideInset) * scale == 0, "the button ends \(area.maxX - end) before the window's edge")
    }

    @Test(arguments: [TextSize.smallest, .standard, .maximum], [false, true])
    func aNormalWindowAtItsMinimumKeepsTheSideInsetOnEachSide(size: TextSize, rightToLeft: Bool) async throws {
        let language = rightToLeft ? "ar" : "en"
        let suite = "com.writronic.wherever.tests.normalform.gutter-\(size.rawValue)-\(language)"
        let store = try #require(UserDefaults(suiteName: suite))
        store.removePersistentDomain(forName: suite)
        store.set(size.rawValue, forKey: TextSize.key)
        let rig = NormalRig(locale: language, store: store, direction: rightToLeft ? .rightToLeft : .leftToRight)
        defer { rig.host.close() }
        let (folder, mode, terms, content) = try await rig.formControls()
        let button = try await rig.searchContentButton()
        let name = try #require(rig.host.field())
        let points = size.points(NSFont.systemFontSize)
        try await rig.host.until("\(points) pt boxes, pop-ups and button") {
            ([folder, name, terms, mode, content, button] as [NSControl]).allSatisfy { $0.font?.pointSize == points }
        }
        let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
        let labels = ["Search folder:", "File name:", "File content:"].map { bundle.localizedString(forKey: $0, value: nil, table: "Normal") }
        try await rig.host.until("the \(language) labels \(labels)") { labels.allSatisfy { rig.labelFrame($0) != nil } }
        let window = rig.host.window
        window.setContentSize(NSSize(width: 100, height: SearchMetrics.windowMinHeight))
        try await rig.host.until("the window at its minimum, \(window.contentLayoutRect.width) of \(window.contentMinSize.width)") {
            window.contentLayoutRect.width == window.contentMinSize.width
        }
        let scale = window.backingScaleFactor
        let widths = try labels.map { try #require(rig.labelFrame($0)).width }
        let column = max(NormalMetrics.labelMinWidth, widths.max() ?? 0)
        let area = window.convertToScreen(window.contentLayoutRect)
        let box = rig.screenFrame(folder)
        let end = rig.laidOut(button)
        let leading = rightToLeft ? area.maxX - (box.maxX + NormalMetrics.columnSpacing + column) : box.minX - NormalMetrics.columnSpacing - column - area.minX
        let trailing = rightToLeft ? end.minX - area.minX : area.maxX - end.maxX
        let context = "\(points) pt \(language): a \(area.width) pt window, labels \(widths), Search folder at \(box), Search Content at \(end)"
        #expect((leading - SearchMetrics.sideInset) * scale == 0, "the form starts \(leading) from the leading edge. \(context)")
        #expect((trailing - SearchMetrics.sideInset) * scale == 0, "Search Content ends \(trailing) from the trailing edge. \(context)")
    }

    @Test func theFormFollowsTheTextSizeLive() async throws {
        let rig = NormalRig(volumes: [BoxRig.archive])
        defer { rig.host.close() }
        let (folder, mode, terms, content) = try await rig.formControls()
        let button = try await rig.searchContentButton()
        let field = try #require(rig.host.field())
        try await rig.host.until("the File name label and the form") {
            rig.labelFrame("File name:") != nil && AXTree.element(NormalForm.id, in: rig.host.view) != nil
        }
        func formWidth() -> CGFloat? { AXTree.element(NormalForm.id, in: rig.host.view).flatMap(AXTree.frame(of:))?.width }
        let label = try #require(rig.labelFrame("File name:"))
        let form = try #require(formWidth())
        let pill = try #require(findButton(FilterBar.kindID, in: rig.host.view))
        #expect(rig.laidOut(pill).height == NormalMetrics.pillHeight)
        for control in [field, folder, mode, content] as [NSControl] { #expect(control.font == NSFont.systemFont(ofSize: NSFont.systemFontSize)) }

        let large = TextSize.maximum
        let store = try #require(UserDefaults(suiteName: "com.writronic.wherever.tests.host"))
        store.set(large.rawValue, forKey: TextSize.key)
        try await rig.host.until("18 pt labels, fields and 27 pt pills, now pill \(rig.laidOut(pill).height)") {
            (rig.labelFrame("File name:")?.height ?? 0) - label.height > 3 && field.font?.pointSize == 18 && rig.laidOut(pill).height == 27
        }
        let scale = rig.host.window.backingScaleFactor
        #expect(NormalMetrics.pillHeight(large) == 27 && large.width(NormalMetrics.popUpWidth) == 180)
        #expect(field.currentEditor()?.font?.pointSize == 18)
        #expect(folder.font?.pointSize == 18)
        let column = NormalForm.popUpColumn(.main, large)
        for popUp in [mode, content] {
            #expect(popUp.font?.pointSize == 18 && popUp.menu?.font.pointSize == 18)
            #expect((rig.laidOut(popUp).width - column) * scale == 0, "a pop-up is \(rig.laidOut(popUp).width) wide")
        }
        Self.openList(folder)
        #expect(folder.diskMenu.font == mode.menu?.font && folder.diskMenu.font.pointSize == 18)
        #expect(terms.font == large.font(.messageFont(ofSize: 0)) && terms.font?.pointSize == 18)
        let buttonFont = large.font(.messageFont(ofSize: 0))
        #expect(button.font == buttonFont)
        let widths = ["Search Content", "Stop"].map { title -> CGFloat in
            let probe = NSButton(title: title, target: nil, action: nil)
            probe.controlSize = .large
            probe.font = buttonFont
            return probe.fittingSize.width
        }
        #expect((rig.laidOut(button).width - (widths.max() ?? 0)) * scale == 0, "the button is \(rig.laidOut(button).width) wide, the titles need \(widths)")
        try await rig.host.until("a wider form than \(form)") { (formWidth() ?? 0) > form }

        store.removeObject(forKey: TextSize.key)
        try await rig.host.until("13 pt again") { field.font?.pointSize == 13 && rig.laidOut(pill).height == NormalMetrics.pillHeight }
        #expect(mode.font == NSFont.systemFont(ofSize: NSFont.systemFontSize))
    }

    @Test(arguments: ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"], [TextSize.standard, .maximum])
    func aMatchPopUpShowsEveryTitleInFull(language: String, size: TextSize) throws {
        let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
        let column = NormalForm.popUpColumn(bundle, size)
        #expect(column >= size.width(NormalMetrics.popUpWidth))
        let font = size.font(.systemFont(ofSize: NSFont.systemFontSize))
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: column, height: NormalMetrics.controlHeight), pullsDown: false)
        popUp.controlSize = .large
        Availability.roundedRectangle(popUp)
        popUp.font = font
        let cell = try #require(popUp.cell as? NSPopUpButtonCell)
        for title in NormalForm.popUpTitles(bundle) {
            popUp.removeAllItems()
            popUp.addItem(withTitle: title)
            let needed = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            let area = cell.titleRect(forBounds: popUp.bounds).width
            #expect(area >= needed, "\(language) at \(size.rawValue) pt: \(title) needs \(needed) in a \(area) pt title area of a \(column) pt pop-up")
        }
    }

    @Test func thePopUpColumnIsMeasuredAgainOnlyWhenTheTextSizeChanges() {
        let cache = WidestTitle()
        let titles = NormalForm.popUpTitles(.main).count
        let standard = NormalForm.popUpColumn(.main, .standard, cache: cache)
        #expect(cache.probes == titles)
        #expect(NormalForm.popUpColumn(.main, .standard, cache: cache) == standard)
        #expect(cache.probes == titles, "the same Text size built \(cache.probes - titles) more probes")
        let large = NormalForm.popUpColumn(.main, .maximum, cache: cache)
        #expect(cache.probes == 2 * titles && large > standard)
    }

    @Test func returnInAnEmptyFileContentFieldStartsSearchContentAndWithADraftMakesATerm() async throws {
        let rig = NormalRig()
        defer { rig.host.close() }
        let (_, _, terms, _) = try await rig.formControls()
        try #require(rig.host.window.makeFirstResponder(terms))
        try rig.host.pressReturn()
        #expect(rig.fake.presses.isEmpty, "Return with no terms searches nothing")
        try rig.host.sendKeys("a")
        try rig.host.pressReturn()
        try await rig.host.until("the draft as a term") { rig.model.content.terms == ["a"] }
        #expect(rig.fake.presses.isEmpty, "Return with a draft makes a term and does not search")
        try rig.host.pressReturn()
        try await rig.host.until("a press for the term; pressed \(rig.fake.presses)") { rig.fake.presses.last?.terms == ["a"] }
        #expect(rig.fake.presses.count == 1)
    }

    private static func links(from start: NSView) -> [NSView] {
        var links = [start]
        while let next = links.last?.nextKeyView, !links.contains(where: { $0 === next }) { links.append(next) }
        return links
    }
}

private final class IndexAnswers {
    var replies: [Bool] = []
    var asked: [String] = []
    var chosen: URL?
    var starts: [URL?] = []

    func choose(_ start: URL?) -> URL? {
        starts.append(start)
        return chosen
    }

    func ask(_ volume: IndexedVolume) -> Bool {
        asked.append(volume.name)
        return replies.isEmpty ? false : replies.removeFirst()
    }
}

private struct FolderHarness: View {
    @ObservedObject var model: SearchModel
    let store: UserDefaults
    let client: FakeSearchClient
    let answers: IndexAnswers

    var body: some View {
        SearchFolderBox(
            folder: $model.filters.folder, store: store, client: client, confirmIndex: { answers.ask($0) },
            chooseFolder: { answers.choose($0) }
        )
            .frame(width: NormalMetrics.fieldWidth, height: NormalMetrics.controlHeight)
    }
}

private final class BoxRig {
    static let archive = IndexedVolume(id: "0A0A0A0A-0000-4000-8000-00000000000A", name: "Archive", path: "/Volumes/Archive", indexed: true)
    static let backup = IndexedVolume(id: "0B0B0B0B-0000-4000-8000-00000000000B", name: "Backup", path: "/Volumes/Backup", indexed: false)

    let fake: FakeSearchClient
    let index: IndexModel
    let model: SearchModel
    let store: UserDefaults
    let answers: IndexAnswers
    let host: SearchHost

    init(_ name: String) {
        let suite = "com.writronic.wherever.tests.foldercombo.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let fake = FakeSearchClient()
        fake.setVolumes(.success([Self.archive, Self.backup]))
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let answers = IndexAnswers()
        host = SearchHost(root: AnyView(FolderHarness(model: model, store: store, client: fake, answers: answers)))
        self.store = store
        self.fake = fake
        self.index = index
        self.model = model
        self.answers = answers
    }

    func close() { host.close() }

    func box() async throws -> FormFolderField {
        try await host.until("the Search folder box") { findFolderField(SearchFolderBox.id, in: host.view) != nil }
        _ = host.window.makeFirstResponder(nil)
        return try #require(findFolderField(SearchFolderBox.id, in: host.view))
    }

    var storedDisks: [String]? { store.stringArray(forKey: LocationsModel.Key.indexedVolumes) }
}

private final class FolderMenuTracking: NSObject {
    let menu: NSMenu
    var opened = false
    var highlightedIgnored = false
    private var arrowFrom: NSMenuItem?
    private var waitingForArrow = false

    init(menu: NSMenu) { self.menu = menu }

    @objc private func began(_ notification: Notification) {
        if notification.object as? NSMenu === menu { opened = true }
    }

    func cancelAfterOpening(_ open: () -> Void) throws {
        NotificationCenter.default.addObserver(self, selector: #selector(began(_:)), name: NSMenu.didBeginTrackingNotification, object: menu)
        let deadline = Date().addingTimeInterval(2)
        let timer = Timer(timeInterval: 0.01, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                if Date() >= deadline { menu.cancelTracking(); return }
                guard opened else { return }
                if let last = menu.items.last, menu.highlightedItem === last {
                    highlightedIgnored = true
                    menu.cancelTracking()
                    return
                }
                if waitingForArrow, menu.highlightedItem === arrowFrom { return }
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .popUpMenu }),
                      let event = NSEvent.keyEvent(
                          with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                          isARepeat: false, keyCode: 125
                      ) else { return }
                arrowFrom = menu.highlightedItem
                waitingForArrow = true
                NSApp.postEvent(event, atStart: false)
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer {
            timer.invalidate()
            NotificationCenter.default.removeObserver(self)
        }
        open()
        try #require(opened, "the control did not open its NSMenu")
        #expect(highlightedIgnored, "the menu never highlighted its last item before cancellation")
    }
}

extension NormalFormTests {
    @Test(arguments: Theme.allCases, [AppearanceMode.light, .dark])
    func theFormDrawsItsThemeUnderAForcedMode(theme: Theme, mode: AppearanceMode) async throws {
        let suite = "com.writronic.wherever.tests.normalform.forced-\(theme.rawValue)-\(mode.rawValue)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        store.set(theme.rawValue, forKey: Theme.key)
        try await forced(mode) {
            let rig = NormalRig(store: store)
            defer { rig.host.close() }
            let controls = try await rig.formControls()
            let view = rig.host.view
            let appearance = view.effectiveAppearance
            let want = appearanceName(mode)
            #expect(appearance.bestMatch(from: [.aqua, .darkAqua]) == want, "\(theme) under \(mode)")
            for (name, control) in [("folder", controls.folder), ("name mode", controls.mode), ("terms", controls.terms), ("content mode", controls.content)] as [(String, NSView)] {
                #expect(control.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == want, "\(theme) \(mode): the \(name) control")
            }
            let background = channels(theme.windowBackground, appearance: appearance)
            let folder = view.convert(controls.folder.bounds, from: controls.folder)
            let labels = NSRect(x: 0, y: folder.minY, width: folder.minX, height: folder.height)
            let padding = pixels(in: view, rect: NSRect(x: 1, y: folder.minY, width: 2, height: 2))
            #expect(!padding.isEmpty && padding.allSatisfy { zip($0, eightBits(background)).allSatisfy { abs($0 - $1) <= 1 } }, "\(theme) \(mode): padding \(padding), window \(eightBits(background))")
            try await rig.host.until("\(theme) \(mode): the Search folder label drawn with a readable contrast") {
                strongestInk(in: view, rect: labels, against: background) >= 2
            }
        }
    }
}

private final class OutlinePopUpButton: NSPopUpButton {
    override class var cellClass: AnyClass? {
        get { OutlinePopUpCell.self }
        set { super.cellClass = newValue }
    }
}

private final class OutlinePopUpCell: NSPopUpButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        super.drawBezel(withFrame: frame, in: controlView)
    }
}

private final class OutlineButton: NSButton {
    override class var cellClass: AnyClass? {
        get { OutlineButtonCell.self }
        set { super.cellClass = newValue }
    }
}

private final class OutlineButtonCell: NSButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        super.drawBezel(withFrame: frame, in: controlView)
    }
}
