import AppKit
import Carbon
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

private func unshiftedCharacter(atKeyCode keyCode: Int) -> String? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
        let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let layout = unsafeBitCast(raw, to: CFData.self)
    var dead: UInt32 = 0
    var length = 0
    var chars = [UniChar](repeating: 0, count: 4)
    let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
        UCKeyTranslate(
            $0, UInt16(keyCode), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars
        )
    }
    return status == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length) : nil
}

private func hiddenStore(hidden: Bool? = nil, mode: WindowMode = .simple) -> UserDefaults {
    let name = "com.writronic.wherever.tests.hiddenfiles"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    if let hidden { store.set(hidden, forKey: SearchFilters.hidesHiddenKey) }
    store.set(mode.rawValue, forKey: WindowMode.key)
    return store
}

@MainActor
private struct HiddenRig {
    let fake: FakeSearchClient
    let index: IndexModel
    let model: SearchModel
    let host: SearchHost

    init(store: UserDefaults) {
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        self.fake = fake
        self.index = index
        self.model = model
        host = SearchHost(root: AnyView(ContentView(index: index, model: model).environment(\.searchClient, fake).defaultAppStorage(store)))
    }

    var checkbox: NSObject? { AXTree.element(FilterBar.hiddenID, in: host.view) }

    func untilMode(_ mode: WindowMode) async throws {
        try await host.until("the \(mode) top") { host.field() != nil && (checkbox != nil) == (mode == .normal) }
    }

    func untilChecked(_ on: Bool) async throws {
        try await host.until("the checkbox \(on ? "on" : "off")") { checkbox.flatMap(AXTree.isOn) == on }
    }

    func queryEnds(_ expected: String) async throws {
        try await host.until("the query \(expected); sent \(fake.queries)") { fake.queries.last == expected }
    }
}

private let menuTitle = "Hide Invisible Files"

private func menuItem() -> NSMenuItem? {
    func find(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if item.title == menuTitle { return item }
            if let found = find(in: item.submenu) { return found }
        }
        return nil
    }
    return find(in: NSApp.mainMenu)
}

@MainActor
private func withStandardSetting(_ body: () async throws -> Void) async throws {
    let (standard, key) = (UserDefaults.standard, SearchFilters.hidesHiddenKey)
    let before = standard.object(forKey: key)
    defer { if let before { standard.set(before, forKey: key) } else { standard.removeObject(forKey: key) } }
    standard.removeObject(forKey: key)
    try await body()
}

@Suite(.serialized) struct HiddenFilesTests {
    @Test func theSettingStartsOffInBothPlaces() async throws {
        try await withStandardSetting {
            try await untilTrue(waitingFor: "the View menu item, unchecked") { menuItem()?.state == .off }
            let item = try #require(menuItem())
            #expect(item.keyEquivalent == unshiftedCharacter(atKeyCode: kVK_ANSI_Period))
            #expect(item.keyEquivalentModifierMask.isSuperset(of: [.command, .shift]))
        }
        let rig = HiddenRig(store: hiddenStore(mode: .normal))
        defer { rig.host.close() }
        try await rig.untilMode(.normal)
        try await rig.untilChecked(false)
        rig.model.query = "report"
        try await rig.queryEnds("report")
        #expect(rig.fake.queries == ["report"])
        #expect(!rig.model.filters.hidesHidden)
    }

    @Test func theMenuItemTogglesTheStoredSetting() async throws {
        try await withStandardSetting {
            let standard = UserDefaults.standard
            try await untilTrue(waitingFor: "the View menu item") { menuItem() != nil }
            for on in [true, false] {
                let item = try #require(menuItem())
                let menu = try #require(item.menu)
                menu.performActionForItem(at: menu.index(of: item))
                try await untilTrue(waitingFor: "the setting \(on) and the item's mark") {
                    standard.bool(forKey: SearchFilters.hidesHiddenKey) == on && menuItem()?.state == (on ? .on : .off)
                }
            }
        }
    }

    @Test func theSettingHidesInvisibleFilesInEveryWindow() async throws {
        let store = hiddenStore()
        let (first, second) = (HiddenRig(store: store), HiddenRig(store: store))
        defer { first.host.close(); second.host.close() }
        for rig in [first, second] {
            try await rig.untilMode(.simple)
            rig.model.query = "report"
            try await rig.queryEnds("report")
        }

        store.set(true, forKey: SearchFilters.hidesHiddenKey)
        for rig in [first, second] { try await rig.queryEnds("report hidden:no") }

        store.set(WindowMode.normal.rawValue, forKey: WindowMode.key)
        for rig in [first, second] {
            try await rig.untilMode(.normal)
            try await rig.untilChecked(true)
        }

        store.set(false, forKey: SearchFilters.hidesHiddenKey)
        for rig in [first, second] {
            try await rig.queryEnds("report")
            try await rig.untilChecked(false)
        }
    }

    @Test func theCheckboxWritesTheSettingEveryWindowReads() async throws {
        let store = hiddenStore(mode: .normal)
        let (first, second) = (HiddenRig(store: store), HiddenRig(store: store))
        defer { first.host.close(); second.host.close() }
        for rig in [first, second] {
            try await rig.untilMode(.normal)
            rig.model.query = "report"
            try await rig.queryEnds("report")
        }

        let box = try #require(first.checkbox)
        try #require(AXTree.press(box), "the checkbox took no press")
        try await untilTrue(waitingFor: "the stored setting") { store.bool(forKey: SearchFilters.hidesHiddenKey) }
        for rig in [first, second] {
            try await rig.queryEnds("report hidden:no")
            try await rig.untilChecked(true)
        }
    }

    @Test func escapeTwiceKeepsHideInvisibleFiles() async throws {
        for mode in [WindowMode.simple, .normal] {
            let rig = HiddenRig(store: hiddenStore(hidden: true, mode: mode))
            defer { rig.host.close() }
            try await rig.untilMode(mode)
            rig.model.filters.kind = .documents
            try await rig.host.type("box")
            try await rig.queryEnds("box type:doc hidden:no")
            try rig.host.pressEscape()
            try await rig.host.until("the text cleared in \(mode)") { rig.model.query.isEmpty }
            try rig.host.pressEscape()
            try await rig.host.until("the filters back to the setting alone in \(mode), now \(rig.model.filters)") {
                rig.model.filters == SearchFilters(hidesHidden: true)
            }
        }
    }

    @Test func backToSimpleKeepsHideInvisibleFiles() async throws {
        let store = hiddenStore(hidden: true, mode: .normal)
        let rig = HiddenRig(store: store)
        defer { rig.host.close() }
        try await rig.untilMode(.normal)
        rig.model.query = "report"
        rig.model.filters.kind = .documents
        rig.model.filters.nameMode = .beginsWith
        try await rig.queryEnds("begins:\"report\" type:doc hidden:no")

        store.set(WindowMode.simple.rawValue, forKey: WindowMode.key)
        try await rig.untilMode(.simple)
        try await rig.host.until("the filters back to the setting alone, now \(rig.model.filters)") {
            rig.model.filters == SearchFilters(hidesHidden: true)
        }
        try await rig.queryEnds("report hidden:no")
    }

    @Test func aNewWindowStartsWithTheSetting() async throws {
        let store = hiddenStore(hidden: true)
        let first = HiddenRig(store: store)
        defer { first.host.close() }
        try await first.untilMode(.simple)

        let second = HiddenRig(store: store)
        defer { second.host.close() }
        try await second.untilMode(.simple)
        try await second.host.type("box")
        try await second.queryEnds("box hidden:no")
        #expect(second.model.filters.hidesHidden)
    }
}
