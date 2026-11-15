import AppKit
import Combine
import Foundation
import SwiftUI

final class CommandLineToolModel: ObservableObject {
    enum Notice: Equatable { case installFailed, uninstallFailed, taken, movable }

    struct RemoveFailed: Error {}

    static let key = "commandLineTool"
    static let profileBlock = [
        "# >>> wherever >>>",
        "case \":$PATH:\" in *\":$HOME/.local/bin:\"*) ;; *) export PATH=\"$HOME/.local/bin:$PATH\" ;; esac",
        "# <<< wherever <<<",
    ]

    @Published private(set) var isOn = false
    @Published private(set) var linked = false
    @Published private(set) var busy = false
    @Published private(set) var notice: Notice?

    let link: URL
    let profile: URL
    let tool: URL
    private let defaults: UserDefaults
    private var serve: (Bool) throws -> Void = { _ in }

    init(
        linkFolder: URL, profile: URL, tool: URL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/wherever"), defaults: UserDefaults = .standard
    ) {
        link = linkFolder.appending(path: "wherever")
        self.profile = profile
        self.tool = tool
        self.defaults = defaults
        refresh()
    }

    static func inert() -> CommandLineToolModel {
        let nowhere = URL(filePath: "/nonexistent-wherever-command-line")
        return CommandLineToolModel(
            linkFolder: nowhere, profile: nowhere.appending(path: ".zshenv"), tool: nowhere.appending(path: "wherever"),
            defaults: UserDefaults(suiteName: "com.writronic.wherever.commandline.inert") ?? UserDefaults()
        )
    }

    var linkPath: String { (path as NSString).abbreviatingWithTildeInPath }
    private var path: String { link.path(percentEncoded: false) }
    private var toolPath: String { tool.path(percentEncoded: false) }

    func refresh() {
        isOn = defaults.bool(forKey: Self.key)
        linked = resolvesToTool
    }

    func attach(serve: @escaping (Bool) throws -> Void) {
        self.serve = serve
        guard isOn else { return }
        do { try serve(true) } catch { notice = .installFailed }
    }

    @discardableResult func install() -> Task<Void, Never>? {
        start(installing: true)
    }

    @discardableResult func uninstall() -> Task<Void, Never>? {
        start(installing: false)
    }

    func removeAll() throws {
        notice = nil
        defer { refresh() }
        if [LinkState.current, .ours].contains(linkState()) { try FileManager.default.removeItem(atPath: path) }
        guard removePathBlock() else { throw RemoveFailed() }
        defaults.removeObject(forKey: Self.key)
        try serve(false)
    }

    func text(for notice: Notice, bundle: Bundle) -> String {
        switch notice {
        case .installFailed: String(localized: "Wherever could not install the command-line tool.", table: "Settings", bundle: bundle)
        case .uninstallFailed: String(localized: "Wherever could not uninstall the command-line tool.", table: "Settings", bundle: bundle)
        case .taken: String(localized: "Another program already uses \(Bidi.path(linkPath)). Remove it, then try again.", table: "Settings", bundle: bundle)
        case .movable: String(localized: "Move Wherever to the Applications folder, then try again.", table: "Settings", bundle: bundle)
        }
    }

    private func start(installing: Bool) -> Task<Void, Never>? {
        guard !busy else { return nil }
        busy = true
        notice = nil
        return Task {
            if installing {
                installNow()
            } else {
                do { try removeAll() } catch { notice = .uninstallFailed }
            }
            busy = false
            refresh()
        }
    }

    private enum LinkState { case absent, current, ours, foreign }

    private var resolvesToTool: Bool {
        FileManager.default.fileExists(atPath: toolPath)
            && link.resolvingSymlinksInPath().path(percentEncoded: false) == tool.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    private func linkState() -> LinkState {
        let files = FileManager.default
        if let destination = try? files.destinationOfSymbolicLink(atPath: path) {
            if resolvesToTool { return .current }
            return URL(filePath: destination).pathComponents.contains("Wherever.app") ? .ours : .foreign
        }
        return (try? files.attributesOfItem(atPath: path)) == nil ? .absent : .foreign
    }

    private func installNow() {
        guard !toolPath.hasPrefix("/Volumes/"), !toolPath.contains("/AppTranslocation/") else {
            notice = .movable
            return
        }
        switch linkState() {
        case .foreign:
            notice = .taken
            return
        case .current:
            break
        case .absent, .ours:
            guard linkDirectly() else {
                notice = .installFailed
                return
            }
        }
        guard resolvesToTool, addPathBlock() else {
            notice = .installFailed
            return
        }
        defaults.set(true, forKey: Self.key)
        do { try serve(true) } catch { notice = .installFailed }
    }

    private func linkDirectly() -> Bool {
        let files = FileManager.default
        do {
            try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? files.destinationOfSymbolicLink(atPath: path)) != nil { try files.removeItem(atPath: path) }
            try files.createSymbolicLink(atPath: path, withDestinationPath: toolPath)
            return true
        } catch {
            return false
        }
    }

    private static let newline = UInt8(ascii: "\n")

    private var profileFile: URL { profile.resolvingSymlinksInPath() }

    private func profileLines() -> [Data]? {
        guard FileManager.default.fileExists(atPath: profileFile.path(percentEncoded: false)) else { return [] }
        return (try? Data(contentsOf: profileFile)).map { $0.split(separator: Self.newline, omittingEmptySubsequences: false) }
    }

    private func writeProfile(_ lines: [Data]) -> Bool {
        (try? Data(lines.joined(separator: [Self.newline])).write(to: profileFile)) != nil
    }

    private func addPathBlock() -> Bool {
        guard var lines = profileLines() else { return false }
        let markers = [Self.profileBlock[0], Self.profileBlock[2]].map { Data($0.utf8) }
        if lines.contains(where: markers.contains) { return true }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return writeProfile(lines + Self.profileBlock.map { Data($0.utf8) } + [Data()])
    }

    private func removePathBlock() -> Bool {
        guard var lines = profileLines() else { return false }
        let block = Self.profileBlock.map { Data($0.utf8) }
        guard let first = lines.indices.first(where: { lines[$0...].starts(with: block) }) else { return true }
        lines.removeSubrange(first..<first + block.count)
        return writeProfile(lines)
    }
}

struct CommandLineToolRow: View {
    static let id = "general-command-line-tool"

    @ObservedObject var model: CommandLineToolModel
    var post: Announcer.Post = Announcer.voiceOver
    @Environment(\.locale) private var locale
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    private var installed: Bool { model.isOn && model.linked }

    private var caption: Text {
        if !model.isOn { return Text("Search from the command line with the wherever command.", tableName: "Settings") }
        if model.linked {
            return Text("Installed at \(Bidi.path(model.linkPath)).", tableName: "Settings") + Text(verbatim: " ")
                + Text("Open a new Terminal window to use it.", tableName: "Settings")
        }
        return Text("The wherever command is missing. Install it again.", tableName: "Settings")
    }

    private var notice: String? { model.notice.map(noticeText) }

    private func noticeText(_ notice: CommandLineToolModel.Notice) -> String {
        model.text(for: notice, bundle: AppearanceRow.bundle(locale))
    }

    private var hint: Text {
        guard let notice else { return caption }
        return caption + Text(verbatim: " " + notice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
            HStack {
                caption.font(textSize.formLabel).frame(maxWidth: .infinity, alignment: .leading).accessibilityHidden(true)
                Button {
                    if installed { model.uninstall() } else { model.install() }
                } label: {
                    (installed ? Text("Uninstall", tableName: "Settings") : Text("Install", tableName: "Settings")).font(textSize.formText)
                }
                .disabled(model.busy)
                .accessibilityIdentifier(Self.id)
                .accessibilityHint(hint)
                if model.isOn && !model.linked {
                    Button { model.uninstall() } label: {
                        Text("Uninstall", tableName: "Settings").font(textSize.formText)
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier(Self.id + "-uninstall")
                    .accessibilityHint(hint)
                }
            }
            if let notice { line(Text(verbatim: notice)) }
        }
        .background(ToolNotice(model: model, text: noticeText, post: post).frame(width: 0, height: 0).accessibilityHidden(true))
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private func line(_ text: Text) -> some View {
        text.font(textSize.caption).foregroundStyle(Color(nsColor: Theme.problem))
    }
}

private struct ToolNotice: NSViewRepresentable {
    let model: CommandLineToolModel
    let text: (CommandLineToolModel.Notice) -> String
    let post: Announcer.Post

    final class Coordinator {
        var render: ((CommandLineToolModel.Notice) -> String)?
        var subscription: AnyCancellable?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NoticeAnnouncer {
        let view = NoticeAnnouncer()
        let coordinator = context.coordinator
        view.post = post
        coordinator.render = text
        coordinator.subscription = model.$notice.sink { [weak view, weak coordinator] notice in
            view?.text = notice.flatMap { coordinator?.render?($0) }
            view?.announce()
        }
        return view
    }

    func updateNSView(_ view: NoticeAnnouncer, context: Context) {
        view.post = post
        context.coordinator.render = text
        view.text = model.notice.map(text)
        view.announce()
    }
}
