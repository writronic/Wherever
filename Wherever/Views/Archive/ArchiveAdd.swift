import AppKit
import Foundation
import WhereverInterface

extension ArchiveWindowModel {
    enum Answer {
        case keepBoth
        case replace
    }

    static let addPanelID = "archive-add-files-panel"
    static let clashAlertID = "archive-clash-alert"
    static let keepBothID = "archive-clash-keep-both"
    static let replaceID = "archive-clash-replace"
    static let clashStopID = "archive-clash-stop"
    static let applyToAllID = "archive-clash-apply-to-all"

    var busy: Bool { edits?.adding != nil || clashing || saving != nil }

    static func addPanel(name: String, in folder: URL) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", table: "Archive")
        panel.message = String(localized: "Choose the items to add to “\(Bidi.name(name))”.", table: "Archive")
        panel.identifier = NSUserInterfaceItemIdentifier(addPanelID)
        panel.directoryURL = folder
        return panel
    }

    static func clashAlert(_ clash: ArchiveClash, many: Bool) -> NSAlert {
        let alert = NSAlert()
        let shown = Bidi.name(clash.name)
        alert.messageText = clash.folder
            ? String(localized: "A folder named “\(shown)” already exists in this location. Do you want to replace it with the one you’re copying?", table: "Archive")
            : String(localized: "An item named “\(shown)” already exists in this location. Do you want to replace it with the one you’re copying?", table: "Archive")
        let buttons = [
            (String(localized: "Keep Both", table: "Archive"), keepBothID), (String(localized: "Replace", table: "Archive"), replaceID),
            (String(localized: "Stop", table: "Archive"), clashStopID),
        ]
        for (title, id) in buttons { alert.addButton(withTitle: title).setAccessibilityIdentifier(id) }
        alert.buttons[2].keyEquivalent = "\u{1b}"
        if many {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Apply to All", table: "Archive")
            alert.suppressionButton?.setAccessibilityIdentifier(applyToAllID)
        }
        alert.window.identifier = NSUserInterfaceItemIdentifier(clashAlertID)
        alert.window.setAccessibilityIdentifier(clashAlertID)
        return alert
    }

    func addFiles() {
        guard editable, !busy else { return base.refuse() }
        pick(Self.addPanel(name: name, in: URL(filePath: outermost).deletingLastPathComponent())) { [weak self] urls in
            if !urls.isEmpty { self?.add(urls) }
        }
    }

    func add(_ urls: [URL]) {
        let folder = self.folder
        let names = urls.map(\.lastPathComponent)
        guard let edits, editable, !busy, !urls.isEmpty, let clashes = try? edits.session.clashes(folder: folder, names: names) else {
            return base.refuse()
        }
        let owners = Self.owners(names: names, clashes: clashes)
        clashing = true
        answer(owners.sorted { $0.key < $1.key }[...], [:]) { [weak self] answers in
            self?.clashing = false
            guard let answers else { return }
            let folded = { (path: String) in path.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
            var items: [ArchiveChange] = []
            var replaced: [String] = []
            for (index, url) in urls.enumerated() {
                var source = url.path(percentEncoded: false)
                while source.count > 1, source.hasSuffix("/") { source.removeLast() }
                let name = url.lastPathComponent
                let clash = owners[index]
                let reply = answers[index]
                if let clash, reply == .replace {
                    let earlier = items.firstIndex { change in
                        guard case let .add(_, at, added) = change else { return false }
                        return folded(at.isEmpty ? added : at + "/" + added) == folded(clash.existing)
                    }
                    if let earlier {
                        items.remove(at: earlier)
                    } else if !replaced.contains(clash.existing) {
                        replaced.append(clash.existing)
                    }
                }
                items.append(.add(source: source, folder: folder, name: reply == .keepBoth ? clash?.freeName ?? name : name))
            }
            edits.add(items, replacing: replaced)
        }
    }

    static func owners(names: [String], clashes: [ArchiveClash]) -> [Int: ArchiveClash] {
        let places = Dictionary(grouping: names.indices) { names[$0] }
        var owners: [Int: ArchiveClash] = [:]
        for (name, asked) in Dictionary(grouping: clashes, by: \.name) {
            for (index, clash) in zip(places[name, default: []].suffix(asked.count), asked) { owners[index] = clash }
        }
        return owners
    }

    private func answer(
        _ clashes: ArraySlice<(key: Int, value: ArchiveClash)>, _ answers: [Int: Answer], done: @escaping ([Int: Answer]?) -> Void
    ) {
        guard let clash = clashes.first?.value else { return done(answers) }
        guard let window = controller?.window else { return done(nil) }
        let alert = Self.clashAlert(clash, many: clashes.count > 1)
        alert.beginSheetModal(for: window) { [weak self] response in
            let reply: Answer? = switch response {
            case .alertFirstButtonReturn: .keepBoth
            case .alertSecondButtonReturn: .replace
            default: nil
            }
            guard let reply else { return done(nil) }
            let all = alert.suppressionButton?.state == .on
            let given = answers.merging((all ? clashes : clashes.prefix(1)).map { ($0.key, reply) }) { $1 }
            if all { return done(given) }
            self?.answer(clashes.dropFirst(), given, done: done)
        }
    }
}
