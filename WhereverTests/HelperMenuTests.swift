import AppKit
import Foundation
import Testing
@testable import Wherever

private let languages = ["en", "tr", "de", "fr", "es", "ru", "nl", "ja", "zh-Hans", "ar", "pl"]

private let order: [HelperMenu.Item?] = [.liveUpdates, nil, .openWherever, .settings, .shortcuts, nil, .quit]

private func freshDefaults(_ name: String) -> UserDefaults {
    let store = UserDefaults(suiteName: domain(name))!
    store.removePersistentDomain(forName: domain(name))
    return store
}

private func domain(_ name: String) -> String { "com.writronic.wherever.tests.helpermenu.\(name)" }

private func expected(_ item: HelperMenu.Item, _ language: String) throws -> String {
    let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
    let (key, table): (String, String) = switch item {
    case .liveUpdates: ("Live Updates", "MenuBar")
    case .openWherever: ("Open Wherever", "MenuBar")
    case .settings: ("Settings…", "MenuBar")
    case .shortcuts: ("Keyboard Shortcuts", "Help")
    case .quit: ("Quit Wherever", "MenuBar")
    }
    return bundle.localizedString(forKey: key, value: "\u{1}", table: table).replacingOccurrences(of: "\u{A0}", with: " ")
}

private struct MenuRig {
    let seams = FakeHelperSeams(parent: Bundle.main.bundleURL)
    let defaults: UserDefaults
    let actions: HelperMenuActions
    private let exits: ExitCount

    final class ExitCount { var count = 0 }

    init(_ name: String) {
        defaults = freshDefaults(name)
        let exits = ExitCount()
        self.exits = exits
        actions = HelperMenuActions(sender: seams.sender, defaults: defaults, exit: { exits.count += 1 })
    }

    var exitCount: Int { exits.count }

    func menu(_ language: String = "en") -> NSMenu { actions.menu(languages: [language]) }

    func item(_ which: HelperMenu.Item, _ language: String = "en") throws -> NSMenuItem {
        try #require(menu(language).items.first { ($0.representedObject as? String) == which.rawValue }, "no \(which)")
    }
}

private func delivered(within seconds: Double = 5, _ received: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if received() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return received()
}

@Suite(.serialized) struct HelperMenuTests {
    @Test func theMenuHasTheFiveItemsInTheOwnersOrderWithTheLiveUpdatesCheck() throws {
        let rig = MenuRig("order")
        #expect(HelperMenu.layout == order)
        let items = rig.menu().items
        #expect(items.map(\.isSeparatorItem) == order.map { $0 == nil })
        #expect(items.map(\.title) == ["Live Updates", "", "Open Wherever", "Settings…", "Keyboard Shortcuts", "", "Quit Wherever"])
        for (item, which) in zip(items, order) {
            guard let which else { continue }
            #expect(item.target === rig.actions, "\(which)")
            #expect(item.action == #selector(HelperMenuActions.fire(_:)), "\(which)")
            #expect(item.representedObject as? String == which.rawValue, "\(which)")
            #expect(item.isEnabled, "\(which)")
            #expect(item.state == (which == .liveUpdates ? .on : .off), "\(which)")
        }
    }

    @Test func everyItemAndTheButtonHaveTheirOwnIdentifier() {
        let rig = MenuRig("ids")
        let ids = rig.menu().items.filter { !$0.isSeparatorItem }.map { $0.identifier?.rawValue }
        #expect(ids == HelperMenu.layout.compactMap { $0 }.map { "menubar-\($0.rawValue)" })
        #expect(Set(ids).count == HelperMenu.Item.allCases.count)
        #expect(HelperMenu.buttonID == "menubar-icon")
        #expect(!ids.contains(HelperMenu.buttonID))
    }

    @Test func theMenuFollowsTheDirectionOfTheLanguageChosenInWherever() {
        let store = freshDefaults("direction")
        store.set(["ar"], forKey: HelperLink.Key.appleLanguages)
        let rig = MenuRig("direction-menu")
        let chosen = HelperMenu.languages(in: store, domain: domain("direction"))
        #expect(rig.actions.menu(languages: chosen).userInterfaceLayoutDirection == .rightToLeft)
        for language in languages {
            let direction = rig.menu(language).userInterfaceLayoutDirection
            #expect(direction == (language == "ar" ? .rightToLeft : .leftToRight), "\(language)")
        }
        #expect(rig.menu("xx").userInterfaceLayoutDirection == .leftToRight)
    }

    @Test func theLiveUpdatesCheckFollowsTheStoredPause() throws {
        let rig = MenuRig("check")
        #expect(try rig.item(.liveUpdates).state == .on)
        rig.defaults.set(true, forKey: HelperLink.Key.liveUpdatesPaused)
        #expect(try rig.item(.liveUpdates).state == .off)
        rig.defaults.set(false, forKey: HelperLink.Key.liveUpdatesPaused)
        #expect(try rig.item(.liveUpdates).state == .on)
        rig.defaults.removeObject(forKey: HelperLink.Key.liveUpdatesPaused)
        #expect(try rig.item(.liveUpdates).state == .on)
    }

    @Test func aPauseWrittenElsewhereShowsInTheNextMenu() throws {
        let rig = MenuRig("elsewhere")
        let before = try rig.item(.liveUpdates)
        #expect(before.state == .on)
        rig.defaults.set(true, forKey: HelperLink.Key.liveUpdatesPaused)
        #expect(before.state == .on)
        #expect(try rig.item(.liveUpdates).state == .off)
        #expect(HelperMenu.isLive(in: rig.defaults) == false)
        rig.defaults.set(false, forKey: HelperLink.Key.liveUpdatesPaused)
        #expect(HelperMenu.isLive(in: rig.defaults))
    }

    @Test func clickingLiveUpdatesWritesThePauseAndPostsAndOpensNothing() throws {
        for state in [HelperSender.WhereverState.running, .closed] {
            let rig = MenuRig("live-\(state)")
            rig.seams.state = state
            rig.actions.fire(try rig.item(.liveUpdates))
            #expect(rig.defaults.object(forKey: HelperLink.Key.liveUpdatesPaused) as? Bool == true, "\(state)")
            #expect(rig.seams.posts == [FakeHelperPost(name: HelperCommand.liveUpdates.notification, object: rig.seams.parent.path)], "\(state)")
            #expect(rig.seams.opens.isEmpty, "\(state)")
            #expect(rig.exitCount == 0, "\(state)")

            let resume = try rig.item(.liveUpdates)
            #expect(resume.state == .off, "\(state)")
            rig.actions.fire(resume)
            #expect(rig.defaults.object(forKey: HelperLink.Key.liveUpdatesPaused) as? Bool == false, "\(state)")
            #expect(rig.seams.posts.count == 2, "\(state)")
            #expect(rig.seams.opens.isEmpty, "\(state)")
        }
    }

    @Test func theClickWritesTheOppositeOfTheCheckItShowed() throws {
        let rig = MenuRig("opposite")
        rig.defaults.set(true, forKey: HelperLink.Key.liveUpdatesPaused)
        let shown = try rig.item(.liveUpdates)
        #expect(shown.state == .off)
        rig.defaults.set(false, forKey: HelperLink.Key.liveUpdatesPaused)
        rig.actions.fire(shown)
        #expect(rig.defaults.object(forKey: HelperLink.Key.liveUpdatesPaused) as? Bool == false)
    }

    @Test func theOtherItemsGoThroughTheSender() throws {
        let rig = MenuRig("others")
        rig.seams.state = .running
        rig.actions.fire(try rig.item(.settings))
        rig.actions.fire(try rig.item(.shortcuts))
        #expect(rig.seams.posts.map(\.name) == [HelperCommand.settings.notification, HelperCommand.shortcuts.notification])
        rig.actions.fire(try rig.item(.openWherever))
        #expect(rig.seams.opens == [FakeHelperOpen(app: rig.seams.parent, arguments: [], activates: true)])

        let closed = MenuRig("others-closed")
        closed.actions.fire(try closed.item(.settings))
        #expect(closed.seams.opens == [FakeHelperOpen(app: closed.seams.parent, arguments: ["--command", "settings"], activates: true)])
        #expect(closed.seams.posts.isEmpty)
    }

    @Test func clicksRouteToTheLauncherOrTheMenu() {
        let cases: [(NSEvent.EventType, NSEvent.ModifierFlags, HelperMenu.Click)] = [
            (.leftMouseUp, [], .launcher), (.leftMouseUp, .command, .launcher), (.leftMouseUp, .shift, .launcher),
            (.leftMouseUp, .option, .launcher), (.leftMouseDown, [], .launcher),
            (.rightMouseUp, [], .menu), (.rightMouseDown, [], .menu), (.rightMouseUp, .command, .menu),
            (.leftMouseUp, .control, .menu), (.leftMouseUp, [.control, .option], .menu),
        ]
        for (type, modifiers, route) in cases {
            #expect(HelperMenu.click(type, modifiers: modifiers) == route, "\(type.rawValue) \(modifiers.rawValue)")
        }
    }

    @Test func titlesComeFromTheStoredLanguage() throws {
        let store = freshDefaults("language")
        #expect(HelperMenu.languages(in: store, domain: domain("language")).isEmpty == false)
        store.set(["tr-TR", "en-US"], forKey: HelperLink.Key.appleLanguages)
        #expect(HelperMenu.languages(in: store, domain: domain("language")) == ["tr-TR", "en-US"])

        let rig = MenuRig("titles")
        for language in languages {
            let titles = rig.menu(language).items.filter { !$0.isSeparatorItem }.map(\.title)
            let wanted = try HelperMenu.Item.allCases.map { try expected($0, language) }
            #expect(titles == wanted, "\(language)")
        }
        #expect(try rig.item(.liveUpdates, "tr").title == "Canlı Güncelleme")
        #expect(try rig.item(.liveUpdates, "ja").title == "ライブ更新")
        #expect(try rig.item(.liveUpdates, "de-DE").title == "Live-Aktualisierung")
        #expect(try rig.item(.liveUpdates, "xx").title == "Live Updates")
    }

    @Test func theIconLabelComesFromTheMenuBarTableInEveryLanguage() throws {
        for language in languages {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)), "no \(language).lproj")
            let wanted = bundle.localizedString(forKey: "Wherever", value: "\u{1}", table: "MenuBar")
            #expect(wanted != "\u{1}", "\(language) lacks the key")
            #expect(HelperMenu.label(in: HelperMenu.localization(of: Bundle.main.bundleURL, languages: [language])) == wanted, "\(language)")
        }
    }

    @Test func theIconComesFromTheParentAsATemplate() throws {
        let image = try #require(HelperMenu.icon(of: Bundle.main.bundleURL))
        #expect(image.isTemplate)
        #expect(HelperMenu.icon(of: URL(fileURLWithPath: "/nonexistent/Wherever.app")) == nil)
    }

    @Test func theItemFollowsTheIconSettingWhileTheHelperStays() {
        let store = freshDefaults("icon")
        store.set(true, forKey: HelperLink.Key.welcomeCompleted)
        var installs = 0
        var removes = 0
        let item = HelperItemController(defaults: store, install: { installs += 1 }, remove: { removes += 1 }, exit: {})

        item.refresh()
        #expect(installs == 1 && removes == 0 && item.installed)
        item.refresh()
        #expect(installs == 1)

        store.set(false, forKey: HelperLink.Key.showMenuBarIcon)
        #expect(HelperLink.shouldRun(in: store))
        item.refresh()
        #expect(installs == 1 && removes == 1 && !item.installed)
        item.refresh()
        #expect(removes == 1)

        store.set(true, forKey: HelperLink.Key.showMenuBarIcon)
        item.refresh()
        #expect(installs == 2 && removes == 1 && item.installed)
    }

    @Test func aStartWithTheIconOffInstallsNothing() {
        let store = freshDefaults("icon-start")
        store.set(false, forKey: HelperLink.Key.showMenuBarIcon)
        var installs = 0
        let item = HelperItemController(defaults: store, install: { installs += 1 }, remove: {}, exit: {})
        item.refresh()
        #expect(installs == 0 && !item.installed)
        #expect(HelperMenu.wantsItem(in: store) == false)
        store.removeObject(forKey: HelperLink.Key.showMenuBarIcon)
        #expect(HelperMenu.wantsItem(in: store))
    }

    @Test func aCommandDragWritesTheIconOffOnceAndAnEchoWritesNothing() {
        let store = freshDefaults("drag")
        var removes = 0
        let item = HelperItemController(defaults: store, install: {}, remove: { removes += 1 }, exit: {})
        item.refresh()

        item.removedByUser()
        #expect(store.object(forKey: HelperLink.Key.showMenuBarIcon) as? Bool == false)
        #expect(removes == 1 && !item.installed)

        store.set(true, forKey: HelperLink.Key.showMenuBarIcon)
        item.removedByUser()
        #expect(store.object(forKey: HelperLink.Key.showMenuBarIcon) as? Bool == true)
        #expect(removes == 1)
    }

    @Test func aRemovalWhileTheSettingIsAlreadyOffWritesNothing() {
        let store = freshDefaults("echo-off")
        var removes = 0
        let item = HelperItemController(defaults: store, install: {}, remove: { removes += 1 }, exit: {})
        item.refresh()
        store.set(false, forKey: HelperLink.Key.showMenuBarIcon)
        item.refresh()
        #expect(removes == 1)
        item.removedByUser()
        #expect(store.object(forKey: HelperLink.Key.showMenuBarIcon) as? Bool == false)
        #expect(removes == 1)
    }

    @Test func aCommandDragWithNoShortcutEndsTheHelper() {
        let store = freshDefaults("drag-no-job")
        store.set(true, forKey: HelperLink.Key.welcomeCompleted)
        store.set(Data(), forKey: HelperLink.Key.summonHotkey)
        var exits = 0
        let item = HelperItemController(defaults: store, install: {}, remove: {}, exit: { exits += 1 })
        item.refresh()
        item.removedByUser()
        #expect(exits == 1)
    }

    @Test func aCommandDragWithAShortcutKeepsTheHelperForTheKey() {
        let store = freshDefaults("drag-key")
        store.set(true, forKey: HelperLink.Key.welcomeCompleted)
        store.set(Data([1]), forKey: HelperLink.Key.summonHotkey)
        var exits = 0
        let item = HelperItemController(defaults: store, install: {}, remove: {}, exit: { exits += 1 })
        item.refresh()
        item.removedByUser()
        #expect(store.object(forKey: HelperLink.Key.showMenuBarIcon) as? Bool == false)
        #expect(exits == 0)
    }

    @Test func quitWithARunningWhereverPostsAndKeepsTheHelper() throws {
        let rig = MenuRig("quit-running")
        rig.seams.state = .running
        rig.actions.fire(try rig.item(.quit))
        #expect(rig.seams.posts == [FakeHelperPost(name: HelperCommand.quit.notification, object: rig.seams.parent.path)])
        #expect(rig.exitCount == 0)
        #expect(rig.seams.opens.isEmpty)
    }

    @Test func quitWithALaunchingWhereverWaitsThenPostsAndKeepsTheHelper() throws {
        let rig = MenuRig("quit-launching")
        rig.seams.state = .launching
        rig.actions.fire(try rig.item(.quit))
        #expect(rig.seams.posts.isEmpty && rig.exitCount == 0)
        rig.seams.finishLaunching()
        #expect(rig.seams.posts == [FakeHelperPost(name: HelperCommand.quit.notification, object: rig.seams.parent.path)])
        #expect(rig.exitCount == 0)
    }

    @Test func quitWithAClosedWhereverExitsAtOnce() throws {
        let rig = MenuRig("quit-closed")
        rig.actions.fire(try rig.item(.quit))
        #expect(rig.exitCount == 1)
        #expect(rig.seams.posts.isEmpty && rig.seams.opens.isEmpty)
    }

    @Test func theHelperExitsWhenItsParentSaysItQuit() async {
        let parent = URL(fileURLWithPath: "/tmp/helpermenu-\(UUID().uuidString)/Wherever.app")
        var exits = 0
        let observation = HelperMenu.exitOnQuit(parent: parent) { exits += 1 }
        defer { DistributedNotificationCenter.default().removeObserver(observation) }
        HelperLink.post(HelperLink.Note.helperQuit, object: "/tmp/helpermenu-other/Wherever.app")
        HelperLink.post(HelperLink.Note.helperQuit, object: parent.path)
        #expect(await delivered { exits == 1 })
        #expect(exits == 1)
    }
}
