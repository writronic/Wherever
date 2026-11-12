import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever

private struct Refused: Error {}

private func freshSuite(_ name: String) -> (defaults: UserDefaults, domain: String) {
    let domain = "com.writronic.wherever.tests.language.\(name)"
    let defaults = UserDefaults(suiteName: domain)!
    defaults.removePersistentDomain(forName: domain)
    return (defaults, domain)
}

private func override(_ domain: String) -> [String]? {
    UserDefaults.standard.persistentDomain(forName: domain)?[AppLanguage.appleKey] as? [String]
}

private func hostOverride() -> [String]? {
    override(Bundle.main.bundleIdentifier!)
}

private let caption = "The language change will take effect after restarting Wherever."
private let failure = "Wherever could not reopen."

private final class Reopens {
    var count = 0
    var throwing = false

    func reopen() throws {
        count += 1
        if throwing { throw Refused() }
    }
}

private func rowHost(_ defaults: UserDefaults, launched: AppLanguage, reopens: Reopens) -> SearchHost {
    let row = LanguageRow(defaults: defaults, launched: launched, reopen: { try reopens.reopen() })
    return SearchHost(root: AnyView(Form { row }.formStyle(.grouped).environment(\.locale, Locale(identifier: "en"))), reportsKey: true)
}

private func sheetButton(_ title: String, in host: SearchHost) -> NSButton? {
    guard let content = host.window.attachedSheet?.contentView else { return nil }
    func buttons(_ root: NSView) -> [NSButton] { root.subviews.flatMap { (($0 as? NSButton).map { [$0] } ?? []) + buttons($0) } }
    return buttons(content).first { $0.isEnabled && ($0.title == title || $0.accessibilityLabel() == title || $0.accessibilityTitle() == title) }
}

private func clickSheet(_ title: String, in host: SearchHost) async throws {
    try await host.until("the \(title) button in the alert") { sheetButton(title, in: host) != nil }
    try #require(sheetButton(title, in: host)).performClick(nil)
}

private func choose(_ item: Int, in host: SearchHost) async throws {
    try await host.until("the language pop-up") { AXTree.element(LanguageRow.id, in: host.view) != nil }
    try await AXTree.choose(try #require(AXTree.element(LanguageRow.id, in: host.view)), item: item)
}

@Suite(.serialized) struct LanguageTests {
    @Test func savingALanguageStoresItAndWritesTheOverride() {
        let before = hostOverride()
        for (language, expected) in [(AppLanguage.tr, ["tr"]), (.zhHans, ["zh-Hans"]), (.ar, ["ar"])] {
            let (defaults, domain) = freshSuite("save.\(language.rawValue)")
            language.save(to: defaults)
            #expect(defaults.string(forKey: AppLanguage.key) == language.rawValue)
            #expect(override(domain) == expected, "\(language) wrote \(String(describing: override(domain)))")
        }
        #expect(hostOverride() == before)
    }

    @Test func systemDefaultRemovesTheOverride() throws {
        let before = hostOverride()
        let (defaults, domain) = freshSuite("save.system")
        AppLanguage.de.save(to: defaults)
        try #require(override(domain) == ["de"])
        AppLanguage.system.save(to: defaults)
        #expect(defaults.string(forKey: AppLanguage.key) == "system")
        #expect(UserDefaults.standard.persistentDomain(forName: domain)?[AppLanguage.appleKey] == nil)
        #expect(hostOverride() == before)
    }

    @Test(arguments: [nil, "", "klingon", "zh_Hans"] as [String?])
    func aMissingOrUnknownValueReadsSystemDefault(_ value: String?) {
        let (defaults, _) = freshSuite("junk.\(value ?? "missing")")
        if let value { defaults.set(value, forKey: AppLanguage.key) }
        #expect(AppLanguage.stored(defaults) == .system)
    }

    @Test func theMenuListsSystemDefaultThenTheElevenLanguagesInTheRulebookOrder() {
        #expect(AppLanguage.allCases.map(\.rawValue) == ["system", "en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"])
    }

    @Test func pickingTurkishWritesTheOverrideAsksAndRestartNowReopensOnce() async throws {
        let before = hostOverride()
        let (defaults, domain) = freshSuite("row.restart")
        let reopens = Reopens()
        let host = rowHost(defaults, launched: .system, reopens: reopens)
        defer { host.close() }
        try await host.until("the language pop-up") { AXTree.element(LanguageRow.id, in: host.view) != nil }
        #expect(!host.windowShows(caption), "the caption shows before any pick")
        try await choose(2, in: host)
        try await host.until("tr stored, the override \(String(describing: override(domain)))") {
            defaults.string(forKey: AppLanguage.key) == "tr" && override(domain) == ["tr"]
        }
        try await host.until("the Restart Wherever? alert") { host.window.attachedSheet != nil }
        try await host.until("the caption under the row") { host.windowShows(caption) }
        #expect(reopens.count == 0, "the pick reopened before the answer")
        try await clickSheet("Restart Now", in: host)
        try await host.until("the alert to close") { host.window.attachedSheet == nil }
        #expect(reopens.count == 1)
        #expect(!host.windowShows(failure))
        #expect(hostOverride() == before)
    }

    @Test func laterKeepsTheCaptionAndNeverReopens() async throws {
        let before = hostOverride()
        let (defaults, domain) = freshSuite("row.later")
        let reopens = Reopens()
        let host = rowHost(defaults, launched: .system, reopens: reopens)
        defer { host.close() }
        try await choose(9, in: host)
        try await host.until("zh-Hans stored, the override \(String(describing: override(domain)))") { override(domain) == ["zh-Hans"] }
        try await clickSheet("Later", in: host)
        try await host.until("the alert to close") { host.window.attachedSheet == nil }
        #expect(reopens.count == 0)
        #expect(host.windowShows(caption))
        #expect(defaults.string(forKey: AppLanguage.key) == "zh-Hans")
        #expect(hostOverride() == before)
    }

    @Test func pickingTheRunningLanguageAsksNothingAndDropsTheCaption() async throws {
        let before = hostOverride()
        let (defaults, domain) = freshSuite("row.back")
        AppLanguage.tr.save(to: defaults)
        let reopens = Reopens()
        let host = rowHost(defaults, launched: .system, reopens: reopens)
        defer { host.close() }
        try await host.until("the caption for the pending Türkçe") { host.windowShows(caption) }
        try await choose(0, in: host)
        try await host.until("system stored") { defaults.string(forKey: AppLanguage.key) == "system" }
        try await host.until("the caption to go") { !host.windowShows(caption) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.window.attachedSheet == nil, "picking the running language asked to restart")
        #expect(UserDefaults.standard.persistentDomain(forName: domain)?[AppLanguage.appleKey] == nil)
        #expect(reopens.count == 0)
        #expect(hostOverride() == before)
    }

    @Test func languageRestartAsksBeforeRelaunching() async throws {
        let before = hostOverride()
        let rig = try UnsavedArchives()
        defer { rig.close() }
        let (_, window) = try await rig.edited()
        let (defaults, _) = freshSuite("row.unsaved")
        let reopens = Reopens()
        let host = rowHost(defaults, launched: .system, reopens: reopens)
        defer { host.close() }
        try await choose(2, in: host)
        try await clickSheet("Restart Now", in: host)
        _ = try await rig.question(on: window)
        try await pumpEvents(for: .milliseconds(50))
        #expect(reopens.count == 0, "the restart reopened before the unsaved question was answered")
        #expect(!host.windowShows(failure))
        try await rig.press(ArchiveWindows.unsavedCancelID, on: window)
        try await pumpEvents(for: .milliseconds(300))
        #expect(!host.windowShows(failure), "Cancel after Restart Now showed the failure line")
        #expect(reopens.count == 0)
        #expect(window.isVisible && window.isDocumentEdited)
        #expect(rig.bytes() == UnsavedArchives.original)
        #expect(hostOverride() == before)
    }

    @Test func aReopenThatThrowsShowsTheFailureLine() async throws {
        let before = hostOverride()
        let (defaults, _) = freshSuite("row.fails")
        let reopens = Reopens()
        reopens.throwing = true
        let host = rowHost(defaults, launched: .system, reopens: reopens)
        defer { host.close() }
        try await choose(3, in: host)
        try await clickSheet("Restart Now", in: host)
        try await host.until("the failure line") { host.windowShows(failure) }
        #expect(reopens.count == 1)
        #expect(defaults.string(forKey: AppLanguage.key) == "de")
        #expect(hostOverride() == before)
    }

    private func text(_ key: String, _ table: String, in language: String) throws -> String {
        let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
        return bundle.localizedString(forKey: key, value: "\u{1}", table: table)
    }

    @Test(arguments: [("tr", "Wherever’dan Çık"), ("zh-Hans", "退出 Wherever")])
    func quitWhereverReadsTheSameInTheMenuAndHelpAndTheResultsLineQuotesIt(_ language: String, _ quit: String) throws {
        #expect(try text("Quit Wherever", "MenuBar", in: language) == quit)
        #expect(try text("Quit Wherever", "Help", in: language) == quit)
        let line = try text("Wherever could not build the index. Choose Quit Wherever from the Wherever menu, then open Wherever again.", "Results", in: language)
        #expect(line.contains("“\(quit)”"))
    }

    @Test func whereverSettingsInSimplifiedChineseHasTheSpaceAfterTheName() throws {
        #expect(try text("Wherever Settings", "Settings", in: "zh-Hans") == "Wherever 设置")
    }
}
