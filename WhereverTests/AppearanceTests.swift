import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever

private func freshSuite(_ name: String) -> UserDefaults {
    let domain = "com.writronic.wherever.tests.appearance.\(name)"
    let defaults = UserDefaults(suiteName: domain)!
    defaults.removePersistentDomain(forName: domain)
    return defaults
}

private final class AppearanceSpy {
    private(set) var applied: [NSAppearance.Name?] = []

    func apply(_ appearance: NSAppearance?) { applied.append(appearance?.name) }
}

private func segment(_ title: String, in host: SearchHost) -> NSObject? {
    guard let picker = AXTree.element(AppearanceRow.id, in: host.view) else { return nil }
    return AXTree.elements(in: picker).dropFirst().first { AXTree.names(of: $0).contains(title) }
}

private func segmentsSeen(in host: SearchHost) -> String {
    guard let picker = AXTree.element(AppearanceRow.id, in: host.view) else { return "no picker" }
    return AXTree.elements(in: picker).dropFirst()
        .map { "\(AXTree.names(of: $0)) = \(String(describing: AXTree.value("accessibilityValue", of: $0) as Any?))" }
        .joined(separator: ", ")
}

private func segmentedControl(in host: SearchHost) -> NSSegmentedControl? {
    func visit(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + visit($0) } }
    return visit(host.view).compactMap { $0 as? NSSegmentedControl }.first { $0.identifier?.rawValue == AppearanceRow.id }
}

@Suite(.serialized) struct AppearanceTests {
    @Test func theSegmentsFollowTheTextSizeAndAPressStillStoresItsMode() async throws {
        let suite = freshSuite("textsize")
        let store = freshSuite("textsize.store")
        store.set(TextSize.maximum.rawValue, forKey: TextSize.key)
        let spy = AppearanceSpy()
        let host = SearchHost(root: AnyView(Form { AppearanceRow(defaults: suite, apply: spy.apply) }.formStyle(.grouped).defaultAppStorage(store)))
        defer { host.close() }
        try await host.until("the segmented control") { segmentedControl(in: host) != nil }
        let control = try #require(segmentedControl(in: host))
        #expect(control.segmentCount == 3 && control.font?.pointSize == 18)
        #expect((0..<control.segmentCount).allSatisfy { control.image(forSegment: $0) == nil }, "a segment carries an image")
        #expect((0..<control.segmentCount).map { control.label(forSegment: $0) } == ["System", "Light", "Dark"])
        try await host.until("the Dark segment") { segment("Dark", in: host) != nil }
        #expect(AXTree.press(try #require(segment("Dark", in: host))))
        try await host.until("dark stored, the spy holding \(spy.applied)") { suite.string(forKey: AppearanceMode.key) == "dark" && spy.applied == [.darkAqua] }
        store.removeObject(forKey: TextSize.key)
        try await host.until("the standard font, now \(String(describing: control.font))") { control.font == NSFont.messageFont(ofSize: 0) }
    }

    @Test func theRowReadsItsThreeSegmentsAndEachPressStoresAndAppliesItsMode() async throws {
        let suite = freshSuite("row")
        let spy = AppearanceSpy()
        let host = SearchHost(root: AnyView(Form { AppearanceRow(defaults: suite, apply: spy.apply) }.formStyle(.grouped)))
        defer { host.close() }
        try await host.until("the System, Light and Dark segments, the picker holding \(segmentsSeen(in: host))") {
            ["System", "Light", "Dark"].allSatisfy { segment($0, in: host) != nil }
        }
        let picker = try #require(AXTree.element(AppearanceRow.id, in: host.view))
        #expect(AXTree.names(of: picker).contains("Appearance"), "the picker reads \(AXTree.names(of: picker))")

        let presses: [(title: String, stored: String, applied: NSAppearance.Name?)] = [
            ("Dark", "dark", .darkAqua), ("Light", "light", .aqua), ("System", "system", nil),
        ]
        for (count, press) in presses.enumerated() {
            #expect(AXTree.press(try #require(segment(press.title, in: host))), "\(press.title) took no press")
            try await host.until("\(press.stored) stored, the spy holding \(spy.applied)") {
                suite.string(forKey: AppearanceMode.key) == press.stored && spy.applied.count == count + 1
            }
            try await host.until("\(press.title) selected, the segments reading \(segmentsSeen(in: host))") {
                segment(press.title, in: host).flatMap(AXTree.isOn) == true
            }
            #expect(spy.applied.last == press.applied, "\(press.title) applied \(String(describing: spy.applied.last))")
        }
        #expect(spy.applied == [.darkAqua, .aqua, nil])
    }

    @Test func theRowOpensOnTheStoredModeAndAppliesNothing() async throws {
        let suite = freshSuite("opens")
        suite.set("dark", forKey: AppearanceMode.key)
        let spy = AppearanceSpy()
        let host = SearchHost(root: AnyView(Form { AppearanceRow(defaults: suite, apply: spy.apply) }.formStyle(.grouped)))
        defer { host.close() }
        try await host.until("Dark selected, System and Light not, the segments reading \(segmentsSeen(in: host))") {
            segment("Dark", in: host).flatMap(AXTree.isOn) == true
                && segment("System", in: host).flatMap(AXTree.isOn) == false
                && segment("Light", in: host).flatMap(AXTree.isOn) == false
        }
        #expect(spy.applied.isEmpty, "opening the row applied \(spy.applied)")
        #expect(suite.string(forKey: AppearanceMode.key) == "dark")
    }

    @Test func theSegmentTitlesFollowTheViewsLocale() throws {
        #expect(AppearanceRow.bundle(.current) === Bundle.main)
        let german = try #require(Bundle.main.url(forResource: "de", withExtension: "lproj").flatMap(Bundle.init(url:)))
        let light = german.localizedString(forKey: "Light", value: nil, table: "Settings")
        #expect(light != "Light")
        #expect(AppearanceMode.light.title(AppearanceRow.bundle(Locale(identifier: "de"))) == light)
        #expect(AppearanceMode.light.title(.main) == Bundle.main.localizedString(forKey: "Light", value: nil, table: "Settings"))
    }

    @Test func applyStoredHandsTheStoredModesAppearanceToAppKit() {
        for (stored, applied) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let suite = freshSuite("apply.\(stored)")
            suite.set(stored, forKey: AppearanceMode.key)
            let spy = AppearanceSpy()
            AppearanceMode.applyStored(from: suite, apply: spy.apply)
            #expect(spy.applied == [applied], "\(stored) applied \(spy.applied)")
        }
        let system = freshSuite("apply.system")
        system.set("system", forKey: AppearanceMode.key)
        let spy = AppearanceSpy()
        AppearanceMode.applyStored(from: system, apply: spy.apply)
        #expect(spy.applied == [nil])
    }

    @Test(arguments: [nil, "", "purple"] as [String?])
    func aMissingEmptyOrUnknownValueReadsSystemAndStaysStored(_ value: String?) {
        let suite = freshSuite("junk.\(value ?? "missing")")
        if let value { suite.set(value, forKey: AppearanceMode.key) }
        #expect(AppearanceMode.stored(suite) == .system)
        let spy = AppearanceSpy()
        AppearanceMode.applyStored(from: suite, apply: spy.apply)
        #expect(spy.applied == [nil])
        #expect(suite.string(forKey: AppearanceMode.key) == value)
    }
}
