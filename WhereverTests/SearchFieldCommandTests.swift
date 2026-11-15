import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

@Suite(.serialized) struct SearchFieldCommandTests {
    @Test func commandDownInFileNameMovesTheCaretToTheEndAndKeepsTheForm() async throws {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let recorder = ActionRecorder()
        let host = SearchHost(
            root: AnyView(SearchView(model: model, mode: .normal).environment(\.searchClient, fake)), actions: recorder.actions
        )
        defer { host.close() }
        try await host.until("File name to hold focus") { host.fieldHasFocus }
        try host.sendKeys("sa")
        let editor = try #require(host.field()?.currentEditor() as? NSTextView)
        editor.selectedRange = NSRange(location: 0, length: 0)
        try #require(editor.selectedRange.location < editor.string.utf16.count)
        let filters = model.filters
        let sent = fake.queries

        try host.press(.downArrow, flags: .command)
        #expect(editor.selectedRange == NSRange(location: 2, length: 0))
        #expect(host.fieldHasFocus)
        #expect(model.query == "sa")
        #expect(model.filters == filters)
        #expect(fake.queries == sent)
        #expect(recorder.nothingHappened)
    }

    @Test func commandDownInTheLauncherMovesTheCaretToTheEndThenEscapeClears() async throws {
        let storeName = "com.writronic.wherever.tests.fieldcommands"
        let store = try #require(UserDefaults(suiteName: storeName))
        store.removePersistentDomain(forName: storeName)
        let fake = FakeSearchClient(hits: (0..<3).map { SearchHit.named("report-\($0)", in: "/Users/me") })
        let index = IndexModel(client: fake)
        let recorder = ActionRecorder()
        let launcher = Launcher(index: index, actions: recorder.actions, defaults: store)
        var showAlls = 0
        launcher.showAll = { showAlls += 1 }
        let keyGuard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak launcher] event in
            let ours = MainActor.assumeIsolated { launcher?.panel.map { (event.window ?? NSApp.keyWindow) === $0 } ?? false }
            return ours ? nil : event
        }
        defer {
            launcher.hide()
            if let keyGuard { NSEvent.removeMonitor(keyGuard) }
            launcher.panel?.contentView = nil
        }
        func send(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
            let panel = try #require(launcher.panel)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code
            ))
            if flags.contains(.command), panel.performKeyEquivalent(with: event) { return }
            panel.sendEvent(event)
        }
        func fieldHasFocus() -> Bool {
            guard let panel = launcher.panel, let editor = panel.searchField?.currentEditor() else { return false }
            return panel.firstResponder === editor
        }

        launcher.toggle()
        try await untilTrue(waitingFor: "the launcher's field to hold focus") { fieldHasFocus() }
        for (key, code) in [("r", UInt16(15)), ("e", 14), ("p", 35)] { try send(key, code: code) }
        fake.send(.resultsReady(fake.latest, count: 3))
        try await untilTrue(waitingFor: "3 rows") { launcher.table?.numberOfRows == 3 }
        let panel = try #require(launcher.panel)
        let windows = NSApp.windows.filter(\.isVisible).count
        let editor = try #require(panel.searchField?.currentEditor() as? NSTextView)
        editor.selectedRange = NSRange(location: 0, length: 0)
        try #require(editor.selectedRange.location < editor.string.utf16.count)
        let selected = launcher.table?.selectedRowIndexes

        try send(String(Character(NSEvent.SpecialKey.downArrow.unicodeScalar)), code: 125, flags: [.command, .numericPad, .function])
        #expect(editor.selectedRange == NSRange(location: 3, length: 0))
        #expect(fieldHasFocus())
        #expect(panel.isVisible)
        #expect(launcher.model.query == "rep")
        #expect(launcher.table?.selectedRowIndexes == selected)
        #expect(showAlls == 0)
        #expect(NSApp.windows.filter(\.isVisible).count == windows)
        #expect(recorder.nothingHappened)

        try send("\u{1b}", code: 53)
        #expect(panel.isVisible)
        #expect(launcher.model.query.isEmpty)
        try await untilTrue(waitingFor: "an empty field") { panel.searchField?.stringValue == "" }
        #expect(fieldHasFocus())
        #expect(recorder.nothingHappened)
    }

    @Test func returnAndCommandReturnInTheFieldDoNothingAfterAFailedSearchWhileTheOldRowsStay() async throws {
        let fake = FakeSearchClient(hits: (0..<6).map { SearchHit.named("hit-\($0)", in: "/Users/me") })
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let recorder = ActionRecorder()
        let host = SearchHost(root: AnyView(SearchView(model: model).environment(\.searchClient, fake)), actions: recorder.actions)
        defer { host.close() }
        try await host.until("the field to hold focus") { host.fieldHasFocus }
        try host.sendKeys("s")
        fake.send(.resultsReady(fake.latest, count: 6))
        try await host.until("six rows") { !model.isPending && host.list()?.numberOfRows == 6 }
        try host.sendKeys("a")
        fake.send(.searchFailed(fake.latest))
        try await host.until("the failed search") { model.failed && !model.isPending }
        try #require(host.list()?.numberOfRows == 6)

        try host.pressReturn()
        try host.pressReturn(command: true)
        #expect(recorder.nothingHappened)
        #expect(host.list()?.numberOfRows == 6)
    }
}
