import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

@Suite(.serialized) struct KeystrokeCostTests {
    @Test func aKeystrokeRebuildsNoViewThatObservesTheModel() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        var publishes = 0
        let watch = model.objectWillChange.sink { publishes += 1 }
        defer { watch.cancel() }
        var typed = ""
        for key in "asfzxbom" {
            let before = fake.queries.count
            try host.sendKeys(String(key))
            typed.append(key)
            host.view.layoutSubtreeIfNeeded()
            host.window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            #expect(fake.queries.count == before + 1, "\(typed) reached the session \(fake.queries.count - before) times")
            #expect(model.query == typed)
            #expect(host.field()?.stringValue == typed)
            #expect(model.isPending)
        }
        #expect(publishes == 0, "\(typed.count) keystrokes published \(publishes) times; each publish re-evaluates every view on the model")
        fake.finish(fake.lastSession)
        try await host.until("the finished results in the table") { host.shows("Safari.app") }
        #expect(publishes > 0)
        #expect(!model.isPending)
    }

    @Test func aQuerySetByTheModelReachesTheFieldWithoutAPublish() async throws {
        let index = IndexModel(client: FakeSearchClient())
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        var publishes = 0
        let watch = model.objectWillChange.sink { publishes += 1 }
        defer { watch.cancel() }
        model.query = "mail"
        #expect(host.field()?.stringValue == "mail")
        #expect(publishes == 0, "a query write published \(publishes) times")
    }

    @Test func aFinishedSearchPublishesOnceAndCarriesItsTime() async throws {
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(index: index, model: model)
        defer { host.close() }
        try await host.type("sa")
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.lastSearchTime == nil)
        var publishes = 0
        let watch = model.objectWillChange.sink { publishes += 1 }
        defer { watch.cancel() }
        fake.send(.resultsReady(fake.latest, count: 1))
        try await host.until("the finished results in the table") { host.shows("Safari.app") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(publishes == 1, "a finished search published \(publishes) times")
        #expect(model.lastSearchTime != nil)
    }

    @Test func aDraftKeyInTheContentRowPublishesNothing() async throws {
        let name = "com.writronic.wherever.tests.keystrokecost"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        store.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.searchClient, fake).defaultAppStorage(store)))
        defer { host.close() }
        try await host.until("the content field enabled") { host.view.descendant(NSTokenField.self)?.isEnabled == true }
        let field = try #require(host.view.descendant(NSTokenField.self))
        try #require(host.window.makeFirstResponder(field))
        var publishes = 0
        let watch = model.objectWillChange.sink { publishes += 1 }
        defer { watch.cancel() }
        var typed = ""
        for key in "asfzxbom" {
            try host.sendKeys(String(key))
            typed.append(key)
            host.view.layoutSubtreeIfNeeded()
            host.window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            #expect(model.contentDraft == typed)
            #expect(fake.queries.isEmpty, "\(typed) sent \(fake.queries)")
            #expect(publishes == 1, "\(typed.count) draft keys published \(publishes) times; only the first flips the button")
        }
        #expect(model.content.terms.isEmpty)
        model.searchContent()
        #expect(fake.presses.map(\.terms) == [["asfzxbom"]], "the press reads the draft")
        #expect(fake.queries.isEmpty)
    }

    @Test func aDraftKeyOutsideHomePublishesNothing() async throws {
        let row = try await contentRow()
        defer { row.host.close() }
        row.model.filters.folder = "/Volumes/Archive"
        try await settle(row)
        let before = row.fake.queries.count
        var publishes = 0
        let watch = row.model.objectWillChange.sink { publishes += 1 }
        defer { watch.cancel() }
        var typed = ""
        for key in "asfzxbom" {
            try row.host.sendKeys(String(key))
            typed.append(key)
            try await settle(row)
            #expect(row.model.contentDraft == typed)
            #expect(row.fake.queries.count == before, "\(typed) sent \(row.fake.queries)")
            #expect(publishes == 1, "\(typed.count) draft keys published \(publishes) times; only the first flips the button")
        }
        #expect(row.fake.queries.last == "in:\"/Volumes/Archive\"", "the last query is the folder's")
        row.model.searchContent()
        #expect(row.fake.presses == [FakeSearchClient.Press(query: "in:\"/Volumes/Archive\"", terms: ["asfzxbom"], matchAll: false, sort: .bestMatch)])
    }

    private struct ContentRow {
        let fake: FakeSearchClient
        let index: IndexModel
        let model: SearchModel
        let host: SearchHost
    }

    private func contentRow() async throws -> ContentRow {
        let name = "com.writronic.wherever.tests.keystrokecost"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        store.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
        let fake = FakeSearchClient(hits: [.named("Safari.app")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.searchClient, fake).defaultAppStorage(store)))
        try await host.until("the content field enabled") { host.view.descendant(NSTokenField.self)?.isEnabled == true }
        try #require(host.window.makeFirstResponder(host.view.descendant(NSTokenField.self)))
        return ContentRow(fake: fake, index: index, model: model, host: host)
    }

    private func settle(_ row: ContentRow) async throws {
        row.host.view.layoutSubtreeIfNeeded()
        row.host.window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func returnMakesTheDraftATerm() async throws {
        let row = try await contentRow()
        defer { row.host.close() }
        try row.host.sendKeys("asf")
        try await settle(row)
        #expect(row.model.content.terms.isEmpty)
        #expect(row.fake.queries.isEmpty)
        try row.host.pressReturn()
        try await settle(row)
        #expect(row.model.content.terms == ["asf"])
        #expect(row.model.contentDraft.isEmpty)
        #expect(row.fake.queries.isEmpty, "the Return sent \(row.fake.queries)")
        row.model.searchContent()
        #expect(row.fake.presses.map(\.terms) == [["asf"]])
        #expect(row.fake.queries.isEmpty)
    }

    @Test func aDraftAfterATermLeavesTheTermAlone() async throws {
        let row = try await contentRow()
        defer { row.host.close() }
        try row.host.sendKeys("asf")
        try row.host.pressReturn()
        try await settle(row)
        try row.host.sendKeys("cd")
        try await settle(row)
        var publishes = 0
        let watch = row.model.objectWillChange.sink { publishes += 1 }
        defer { watch.cancel() }
        try row.host.sendKeys("e")
        try await settle(row)
        #expect(row.model.content.terms == ["asf"])
        #expect(row.model.contentDraft == "cde")
        #expect(row.fake.queries.isEmpty, "a draft key sent \(row.fake.queries)")
        #expect(publishes == 0, "a draft key published \(publishes) times")
    }

    @Test func backspaceShortensTheDraftWithoutASearch() async throws {
        let row = try await contentRow()
        defer { row.host.close() }
        try row.host.sendKeys("asf")
        try await settle(row)
        try row.host.sendKeys("\u{7f}")
        try await settle(row)
        let before = row.fake.queries.count
        try row.host.sendKeys("\u{7f}")
        try await settle(row)
        #expect(row.model.contentDraft == "a")
        #expect(row.model.content.terms.isEmpty)
        #expect(row.fake.queries.count == before, "Backspace sent \(row.fake.queries.dropFirst(before))")
    }
}
