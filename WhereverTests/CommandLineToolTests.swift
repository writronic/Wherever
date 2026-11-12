import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever

private struct ServeRefused: Error {}

private let pathBlock = """
# >>> wherever >>>
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
# <<< wherever <<<

"""

private final class ToolRig {
    let root: URL
    let folder: URL
    let profile: URL
    let tool: URL
    let defaults: UserDefaults
    var serveFails = false
    private(set) var serves: [Bool] = []

    init(_ name: String, folder bin: String = "bin") throws {
        root = FileManager.default.temporaryDirectory.appending(path: "wherever-cli-\(name)-\(UUID().uuidString)")
        folder = root.appending(path: bin)
        profile = root.appending(path: ".zshenv")
        tool = root.appending(path: "Apps/Wherever.app/Contents/Helpers/wherever")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: tool)
        if bin == "bin" { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let suite = "com.writronic.wherever.tests.commandline.\(name)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    var linkPath: String { folder.appending(path: "wherever").path(percentEncoded: false) }
    var toolPath: String { tool.path(percentEncoded: false) }
    var profileText: String? { (try? Data(contentsOf: profile)).map { String(decoding: $0, as: UTF8.self) } }

    func model(tool: URL? = nil) -> CommandLineToolModel {
        CommandLineToolModel(linkFolder: folder, profile: profile, tool: tool ?? self.tool, defaults: defaults)
    }

    func attached(_ model: CommandLineToolModel) -> CommandLineToolModel {
        model.attach { [self] on in
            serves.append(on)
            if serveFails { throw ServeRefused() }
        }
        return model
    }

    func lock() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path(percentEncoded: false))
    }

    func unlock() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
    }

    func close() {
        unlock()
        try? FileManager.default.removeItem(at: root)
    }

    var destination: String? { try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) }
}

@Suite(.serialized) struct CommandLineToolTests {
    private func host(_ row: CommandLineToolRow) -> NSWindow {
        let controller = NSHostingController(rootView: row.environment(\.locale, Locale(identifier: "en")).frame(width: 650))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    @Test func theSharedAnnouncerPostsEachNoticeOnceAndAgainWhenItChangesOrReturns() {
        var posts: [String] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let announcer = NoticeAnnouncer()
        announcer.post = { posted, text in
            #expect(posted === window)
            posts.append(text)
        }
        announcer.text = "first"
        announcer.announce()
        #expect(posts.isEmpty)

        window.contentView?.addSubview(announcer)
        #expect(posts == ["first"])
        announcer.announce()
        announcer.text = "first"
        announcer.announce()
        #expect(posts == ["first"])

        announcer.text = "second"
        announcer.announce()
        announcer.text = nil
        announcer.announce()
        #expect(posts == ["first", "second"])

        announcer.text = "second"
        announcer.announce()
        announcer.announce()
        #expect(posts == ["first", "second", "second"])
    }

    @Test func aMissingLinkOffersUninstallAndStopsServingWithoutAPrompt() async throws {
        let rig = try ToolRig("missing.off")
        defer { rig.close() }
        rig.defaults.set(true, forKey: CommandLineToolModel.key)
        try rig.lock()
        let model = rig.attached(rig.model())
        let window = host(CommandLineToolRow(model: model))
        defer { window.close() }
        let view = try #require(window.contentView)
        try await untilTrue(waitingFor: "Install and Uninstall for the missing link") {
            AXTree.control("Install", in: view) != nil && AXTree.control("Uninstall", in: view) != nil
        }
        let uninstall = try #require(AXTree.control("Uninstall", in: view))
        #expect(AXTree.identifier(of: uninstall) == CommandLineToolRow.id + "-uninstall")
        try #require(AXTree.press(uninstall))
        try await untilTrue(waitingFor: "the tool to stop serving") { rig.serves == [true, false] && !model.busy }
        #expect(!model.isOn && !rig.defaults.bool(forKey: CommandLineToolModel.key))
        #expect(rig.destination == nil)
        try await untilTrue(waitingFor: "only Install after switching off") {
            AXTree.control("Install", in: view) != nil && AXTree.control("Uninstall", in: view) == nil
        }
    }

    @Test(arguments: [false, true])
    func aFailedActionAnnouncesOnceAndAddsItsNoticeToTheButtonHint(uninstalling: Bool) async throws {
        let rig = try ToolRig("notice.\(uninstalling)")
        defer { rig.close() }
        let model = rig.attached(rig.model())
        if uninstalling { try await #require(model.install()).value }
        try rig.lock()
        var announcements: [(NSWindow, String)] = []
        let window = host(CommandLineToolRow(model: model, post: { announcements.append(($0, $1)) }))
        defer { window.close() }
        let view = try #require(window.contentView)
        try await untilTrue(waitingFor: "the tool button") { AXTree.element(CommandLineToolRow.id, in: view) != nil }
        try #require(AXTree.press(try #require(AXTree.element(CommandLineToolRow.id, in: view))))
        let key = uninstalling ? "Wherever could not uninstall the command-line tool." : "Wherever could not install the command-line tool."
        let expected = string(key, "Settings")
        try await untilTrue(waitingFor: "the notice announcement and hint") {
            announcements.count == 1 && AXTree.element(CommandLineToolRow.id, in: view).flatMap {
                AXTree.value("accessibilityHelp", of: $0) as String?
            }?.hasSuffix(expected) == true
        }
        #expect(announcements.first?.0 === window)
        #expect(announcements.map(\.1) == [expected])
        model.refresh()
        await Task.yield()
        #expect(announcements.count == 1)
        rig.unlock()
        try await #require(uninstalling ? model.uninstall() : model.install()).value
        #expect(model.notice == nil)
        #expect(announcements.count == 1)
    }

    @Test func pressingInstallTwiceOnAForeignFileAnnouncesBothFailures() async throws {
        let rig = try ToolRig("notice.repeat")
        defer { rig.close() }
        try Data("other".utf8).write(to: URL(filePath: rig.linkPath))
        let model = rig.attached(rig.model())
        var announcements: [String] = []
        let window = host(CommandLineToolRow(model: model, post: { _, text in announcements.append(text) }))
        defer { window.close() }
        let view = try #require(window.contentView)
        try await untilTrue(waitingFor: "the Install button") { AXTree.control("Install", in: view) != nil }
        for count in 1...2 {
            try await untilTrue(waitingFor: "Install enabled for press \(count)") {
                AXTree.control("Install", in: view).flatMap(AXTree.isEnabled) == true
            }
            try #require(AXTree.press(try #require(AXTree.control("Install", in: view))))
            try await untilTrue(waitingFor: "failure announcement \(count)") { !model.busy && announcements.count == count }
        }
        let expected = String(format: string("Another program already uses %@. Remove it, then try again.", "Settings"), Bidi.path(rig.linkPath))
        #expect(announcements == [expected, expected])
        #expect(rig.serves.isEmpty && rig.profileText == nil)
    }

    @Test func aFreshModelIsOffAndServesNothingAtAttach() throws {
        let rig = try ToolRig("fresh")
        defer { rig.close() }
        let model = rig.attached(rig.model())
        #expect(!model.isOn && !model.linked && model.notice == nil)
        #expect(rig.destination == nil && !FileManager.default.fileExists(atPath: rig.linkPath))
        #expect(rig.serves.isEmpty && rig.profileText == nil)
        #expect(rig.defaults.object(forKey: CommandLineToolModel.key) == nil)
    }

    @Test func aWritableFolderLinksAndAddsThePathBlock() async throws {
        let rig = try ToolRig("writable")
        defer { rig.close() }
        let model = rig.attached(rig.model())
        try await #require(model.install()).value
        #expect(rig.destination == rig.toolPath)
        #expect(model.isOn && model.linked && !model.busy && model.notice == nil)
        #expect(rig.defaults.bool(forKey: CommandLineToolModel.key))
        #expect(rig.serves == [true])
        #expect(rig.profileText == pathBlock)
    }

    @Test func aFileWeDidNotMakeIsLeftAlone() async throws {
        let rig = try ToolRig("foreign")
        defer { rig.close() }
        let bytes = Data("#!/bin/sh\necho other\n".utf8)
        try bytes.write(to: URL(filePath: rig.linkPath))
        let model = rig.attached(rig.model())
        try await #require(model.install()).value
        #expect(model.notice == .taken)
        #expect(try Data(contentsOf: URL(filePath: rig.linkPath)) == bytes)
        #expect(rig.serves.isEmpty && !model.isOn && rig.profileText == nil)
    }

    @Test func aLinkToAnotherWhereverCopyIsReplaced() async throws {
        let rig = try ToolRig("othercopy")
        defer { rig.close() }
        let other = rig.root.appending(path: "Old/Wherever.app/Contents/Helpers/wherever").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: rig.linkPath, withDestinationPath: other)
        let model = rig.attached(rig.model())
        #expect(!model.linked)
        try await #require(model.install()).value
        #expect(rig.destination == rig.toolPath)
        #expect(model.isOn && model.linked && rig.serves == [true])
    }

    @Test func aLinkThatAlreadyWorksNeedsNoWrite() async throws {
        let rig = try ToolRig("kept")
        defer { rig.close() }
        try FileManager.default.createSymbolicLink(atPath: rig.linkPath, withDestinationPath: rig.toolPath)
        try rig.lock()
        let model = rig.attached(rig.model())
        #expect(!model.isOn && model.linked && rig.serves.isEmpty)
        try await #require(model.install()).value
        #expect(rig.destination == rig.toolPath && rig.profileText == pathBlock)
        #expect(model.isOn && rig.defaults.bool(forKey: CommandLineToolModel.key) && rig.serves == [true])
    }

    @Test(arguments: ["/Volumes/Wherever/Wherever.app/Contents/Helpers/wherever", "/private/var/folders/x/AppTranslocation/1/d/Wherever.app/Contents/Helpers/wherever"])
    func aCopyOnADiskImageOrTranslocatedIsRefused(_ path: String) async throws {
        let rig = try ToolRig("moved.\(path.hasPrefix("/Volumes/") ? "volume" : "translocated")")
        defer { rig.close() }
        let model = rig.attached(rig.model(tool: URL(filePath: path)))
        try await #require(model.install()).value
        #expect(model.notice == .movable)
        #expect(rig.destination == nil && rig.serves.isEmpty && !model.isOn && rig.profileText == nil)
    }

    @Test func uninstallRemovesOurLink() async throws {
        let rig = try ToolRig("uninstall")
        defer { rig.close() }
        let model = rig.attached(rig.model())
        try await #require(model.install()).value
        try await #require(model.uninstall()).value
        #expect(rig.destination == nil)
        #expect(!model.isOn && !model.linked && rig.defaults.object(forKey: CommandLineToolModel.key) == nil)
        #expect(rig.serves == [true, false] && rig.profileText == "")
    }

    @Test func uninstallKeepsAForeignFile() async throws {
        let rig = try ToolRig("uninstall.foreign")
        defer { rig.close() }
        rig.defaults.set(true, forKey: CommandLineToolModel.key)
        let bytes = Data("other".utf8)
        try bytes.write(to: URL(filePath: rig.linkPath))
        let model = rig.attached(rig.model())
        try await #require(model.uninstall()).value
        #expect(try Data(contentsOf: URL(filePath: rig.linkPath)) == bytes)
        #expect(!model.isOn && rig.serves == [true, false])
    }

    @Test func attachWithTheChoiceOnServesOnce() throws {
        let rig = try ToolRig("attach")
        defer { rig.close() }
        rig.defaults.set(true, forKey: CommandLineToolModel.key)
        let model = rig.attached(rig.model())
        #expect(rig.serves == [true])
        #expect(model.isOn && model.notice == nil)
    }

    @Test func aThrowingServeAtAttachShowsTheNoticeAndKeepsTheChoice() throws {
        let rig = try ToolRig("attach.fails")
        defer { rig.close() }
        rig.defaults.set(true, forKey: CommandLineToolModel.key)
        rig.serveFails = true
        let model = rig.attached(rig.model())
        #expect(rig.serves == [true])
        #expect(model.notice == .installFailed)
        #expect(model.isOn && rig.defaults.bool(forKey: CommandLineToolModel.key))
    }

    @Test func aDeletedLinkReadsAsMissingAfterARefresh() async throws {
        let rig = try ToolRig("deleted")
        defer { rig.close() }
        let model = rig.attached(rig.model())
        try await #require(model.install()).value
        #expect(model.isOn && model.linked)
        try FileManager.default.removeItem(atPath: rig.linkPath)
        model.refresh()
        #expect(model.isOn && !model.linked)
    }

    @Test func installIntoAMissingFolderMakesTheFolderTheLinkAndOneBlock() async throws {
        let rig = try ToolRig("missing.folder", folder: ".local/bin")
        defer { rig.close() }
        #expect(!FileManager.default.fileExists(atPath: rig.folder.path(percentEncoded: false)))
        let model = rig.attached(rig.model())
        try await #require(model.install()).value
        #expect(rig.destination == rig.toolPath)
        #expect(rig.profileText == pathBlock)
        #expect(model.isOn && model.linked && model.notice == nil && rig.serves == [true])
    }

    @Test func installingTwiceKeepsOneBlockAfterTheUsersLines() async throws {
        let rig = try ToolRig("twice")
        defer { rig.close() }
        try Data("export EDITOR=vi".utf8).write(to: rig.profile)
        let model = rig.attached(rig.model())
        try await #require(model.install()).value
        try FileManager.default.removeItem(atPath: rig.linkPath)
        try await #require(model.install()).value
        #expect(rig.profileText == "export EDITOR=vi\n" + pathBlock)
        #expect(model.isOn && model.linked && rig.serves == [true, true])
    }

    @Test func uninstallRemovesTheLinkAndTheBlockAndKeepsTheOtherLines() async throws {
        let rig = try ToolRig("uninstall.block")
        defer { rig.close() }
        let before = "export EDITOR=vi\n\n"
        let after = "alias ll='ls -l'"
        try Data((before + pathBlock + after).utf8).write(to: rig.profile)
        let model = rig.attached(rig.model())
        try await #require(model.install()).value
        #expect(rig.profileText == before + pathBlock + after)
        try await #require(model.uninstall()).value
        #expect(rig.destination == nil && model.notice == nil)
        #expect(rig.profileText == before + after)
    }

    @Test func removeAllThrowsOnAReadOnlyProfileAndUninstallShowsItsNotice() async throws {
        let rig = try ToolRig("readonly.profile")
        defer { rig.close() }
        let model = rig.attached(rig.model())
        try await #require(model.install()).value
        let text = try #require(rig.profileText)
        let profilePath = rig.profile.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: profilePath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: profilePath) }
        #expect(throws: CommandLineToolModel.RemoveFailed.self) { try model.removeAll() }
        #expect(rig.profileText == text && model.isOn)
        try await #require(model.uninstall()).value
        #expect(model.notice == .uninstallFailed && rig.profileText == text)
    }

    @Test(arguments: [
        "# >>> wherever >>>\nexport PATH=\"$HOME/bin:$PATH\"\n# <<< wherever <<<\n",
        "# <<< wherever <<<\ncase \":$PATH:\" in *\":$HOME/.local/bin:\"*) ;; *) export PATH=\"$HOME/.local/bin:$PATH\" ;; esac\n# >>> wherever >>>\n",
        "# >>> wherever >>>\n",
    ]) func editedMarkersLeaveTheProfileAlone(_ text: String) async throws {
        let rig = try ToolRig("edited.\(text.count)")
        defer { rig.close() }
        let bytes = Data(("export EDITOR=vi\n" + text).utf8)
        try bytes.write(to: rig.profile)
        let model = rig.attached(rig.model())
        try await #require(model.install()).value
        #expect(try Data(contentsOf: rig.profile) == bytes)
        try await #require(model.uninstall()).value
        #expect(try Data(contentsOf: rig.profile) == bytes)
        #expect(rig.destination == nil && model.notice == nil && !model.isOn)
    }

    @Test func anUnwritableFolderFailsTheInstallAndAddsNoBlock() async throws {
        let rig = try ToolRig("locked")
        defer { rig.close() }
        try rig.lock()
        let model = rig.attached(rig.model())
        try await #require(model.install()).value
        #expect(model.notice == .installFailed)
        #expect(rig.destination == nil && rig.profileText == nil)
        #expect(!model.isOn && rig.defaults.object(forKey: CommandLineToolModel.key) == nil && rig.serves.isEmpty)
    }

    @Test func aSymlinkedProfileKeepsItsLink() async throws {
        let rig = try ToolRig("profile.link")
        defer { rig.close() }
        let real = rig.root.appending(path: "dotfiles/zshenv")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("export EDITOR=vi\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: rig.profile, withDestinationURL: real)
        let model = rig.attached(rig.model())
        try await #require(model.install()).value
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rig.profile.path(percentEncoded: false)) == real.path(percentEncoded: false))
        #expect(String(decoding: try Data(contentsOf: real), as: UTF8.self) == "export EDITOR=vi\n" + pathBlock)
        try await #require(model.uninstall()).value
        #expect(String(decoding: try Data(contentsOf: real), as: UTF8.self) == "export EDITOR=vi\n")
    }

    @Test func theInstalledCaptionShowsTheHomeAsATilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let model = CommandLineToolModel.inert()
        let homeModel = CommandLineToolModel(
            linkFolder: home.appending(path: ".local/bin"), profile: URL(filePath: "/nonexistent-wherever-command-line/.zshenv"),
            tool: URL(filePath: "/nonexistent-wherever-command-line/wherever"), defaults: UserDefaults(suiteName: "com.writronic.wherever.tests.commandline.tilde")!
        )
        #expect(homeModel.linkPath == "~/.local/bin/wherever")
        #expect(model.linkPath == "/nonexistent-wherever-command-line/wherever")
    }

    private func string(_ key: String, _ table: String) -> String { Bundle.main.localizedString(forKey: key, value: nil, table: table) }

    @Test func theInertModelWritesNothing() async throws {
        let model = CommandLineToolModel.inert()
        #expect(!model.isOn && !model.linked)
        try await #require(model.install()).value
        #expect(!model.isOn && model.notice == .installFailed)
        #expect(!FileManager.default.fileExists(atPath: "/nonexistent-wherever-command-line"))
        #expect(model.profile.path(percentEncoded: false) == "/nonexistent-wherever-command-line/.zshenv")
    }
}
