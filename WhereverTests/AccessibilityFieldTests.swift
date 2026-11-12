import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private func a11yFieldBundle(_ language: String) throws -> Bundle {
    try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
}

private func a11yFieldString(_ key: String, _ language: String) throws -> String {
    let text = try a11yFieldBundle(language).localizedString(forKey: key, value: "\u{1}", table: "Localizable")
    try #require(text != "\u{1}", "\(language) Localizable has no \(key)")
    return text
}

private func a11yPopUp(_ id: String, in root: NSView) -> NSPopUpButton? {
    for view in root.subviews {
        if let found = (view as? NSPopUpButton).flatMap({ $0.identifier?.rawValue == id ? $0 : nil }) ?? a11yPopUp(id, in: view) { return found }
    }
    return nil
}

@MainActor
private struct A11yFieldRig {
    let fake = FakeSearchClient()
    let index: IndexModel
    let host: SearchHost

    init() {
        index = IndexModel(client: fake)
        host = SearchHost(index: index, model: index.makeModel())
    }

    func field() async throws -> NSSearchField {
        try await host.until("the search field") { host.field() != nil }
        return try #require(host.field())
    }

    func table() async throws -> NSTableView {
        try await host.until("the list") { host.list() != nil }
        return try #require(host.list())
    }
}

@Suite(.serialized) struct AccessibilityFieldTests {
    @Test func a1TheFieldReadsItsLabelFromTheLocalizableTable() async throws {
        let german = try a11yFieldString("Search files", "de")
        let english = try a11yFieldString("Search files", "en")
        #expect(german != english)
        #expect(!english.lowercased().contains("field"))
        #expect(!german.lowercased().contains("feld"))

        let bundle = try a11yFieldBundle("de")
        let index = IndexModel(client: FakeSearchClient())
        let host = SearchHost(root: AnyView(SearchView(model: index.makeModel(), bundle: bundle)))
        defer { host.close() }
        try await host.until("the search field") { host.field() != nil }
        let cell = try #require(host.field()?.cell)
        #expect(AXTree.identifier(of: cell) == SearchView.fieldID)
        #expect(cell.accessibilityLabel() == german)
        #expect(AXTree.names(of: cell).contains(german))
    }

    @Test func a10TheKeyViewPathRunsFieldThenListThenField() async throws {
        let rig = A11yFieldRig()
        defer { rig.host.close() }
        let field = try await rig.field()
        let table = try await rig.table()
        try await rig.host.until("Tab from the field to the list; it reaches \(String(describing: field.nextValidKeyView))") {
            field.nextValidKeyView === table
        }
        try await rig.host.until("Tab from the list to the field; it reaches \(String(describing: table.nextValidKeyView))") {
            table.nextValidKeyView === field
        }
    }

    @Test func a11TheFieldAndTheListKeepTheirFocusRings() async throws {
        let rig = A11yFieldRig()
        defer { rig.host.close() }
        let field = try await rig.field()
        let table = try await rig.table()
        #expect(field.focusRingType != .none)
        #expect(table.focusRingType != .none)
    }

    @Test func a14TheFieldsFontIsTenPointsOrLarger() async throws {
        let rig = A11yFieldRig()
        defer { rig.host.close() }
        let field = try await rig.field()
        let font = try #require(field.font)
        #expect(font.pointSize >= 10)
    }

    @Test func a15NormalNamesTheBoxAndBothMenusApart() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let host = SearchHost(root: AnyView(SearchView(model: index.makeModel(), mode: .normal).environment(\.searchClient, fake)))
        defer { host.close() }
        try await host.until("the form's field and both pop-ups") {
            host.field() != nil && a11yPopUp(NormalForm.nameModeID, in: host.view) != nil && a11yPopUp(NormalForm.contentModeID, in: host.view) != nil
        }
        let cell = try #require(host.field()?.cell)
        let name = try #require(a11yPopUp(NormalForm.nameModeID, in: host.view)?.cell)
        let content = try #require(a11yPopUp(NormalForm.contentModeID, in: host.view)?.cell)
        #expect(AXTree.identifier(of: cell) == SearchView.fieldID)
        #expect(cell.accessibilityLabel() == "File name:")
        #expect(name.accessibilityLabel() == "File name match")
        #expect(content.accessibilityLabel() == "File content match")
        #expect(Set([cell.accessibilityLabel(), name.accessibilityLabel(), content.accessibilityLabel()]).count == 3)
    }

    @Test func a16TheFieldLabelFollowsTheModeBothWays() async throws {
        let suite = "com.writronic.wherever.tests.namelabels"
        let store = try #require(UserDefaults(suiteName: suite))
        store.removePersistentDomain(forName: suite)
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let host = SearchHost(root: AnyView(ContentView(index: index, model: index.makeModel()).environment(\.searchClient, fake).defaultAppStorage(store)))
        defer { host.close() }
        for (mode, label) in [(WindowMode.simple, "Search files"), (.normal, "File name:"), (.simple, "Search files")] {
            store.set(mode.rawValue, forKey: WindowMode.key)
            try await host.until("the \(mode) field reads \(label)") {
                host.field()?.cell?.accessibilityLabel() == label
                    && (a11yPopUp(NormalForm.nameModeID, in: host.view) != nil) == (mode == .normal)
            }
            #expect(try AXTree.identifier(of: #require(host.field()?.cell)) == SearchView.fieldID)
        }
    }
}
