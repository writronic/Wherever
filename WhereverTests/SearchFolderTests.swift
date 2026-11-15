import AppKit
import CoreGraphics
import Darwin
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Wherever
import WhereverInterface
import os

private final class Answers {
    var replies: [Bool] = []
    var asked: [String] = []
    var beeps = 0

    func ask(_ volume: IndexedVolume) -> Bool {
        asked.append(volume.name)
        return replies.isEmpty ? false : replies.removeFirst()
    }
}

private nonisolated final class IconLoads: Sendable {
    private nonisolated struct State {
        var paths: [String] = []
        var onMain = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let mark: CGImage

    init() throws {
        let context = try #require(CGContext(
            data: nil, width: 7, height: 7, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        mark = try #require(context.makeImage())
    }

    var paths: [String] { state.withLock { $0.paths } }
    var onMain: Int { state.withLock { $0.onMain } }

    func load(_ path: String) -> CGImage? {
        let main = Thread.isMainThread
        state.withLock {
            $0.paths.append(path)
            if main { $0.onMain += 1 }
        }
        return mark
    }
}

private final class Panel {
    var chosen: URL?
    var starts: [URL?] = []

    func choose(_ start: URL?) -> URL? {
        starts.append(start)
        return chosen
    }
}

private struct Harness: View {
    @ObservedObject var model: SearchModel
    let make: @MainActor (Binding<String?>) -> SearchFolderBox

    var body: some View {
        make($model.filters.folder).frame(width: NormalMetrics.fieldWidth, height: NormalMetrics.controlHeight)
    }
}

private func folderBox(in root: NSView) -> FormFolderField? {
    for view in root.subviews {
        if let found = (view as? FormFolderField).flatMap({ $0.identifier?.rawValue == SearchFolderBox.id ? $0 : nil }) ?? folderBox(in: view) {
            return found
        }
    }
    return nil
}

private final class FolderRig {
    let fake: FakeSearchClient
    let index: IndexModel
    let model: SearchModel
    let store: UserDefaults
    let root: URL
    let answers: Answers
    let panel = Panel()
    let host: SearchHost
    private let make: @MainActor (Binding<String?>) -> SearchFolderBox

    init(_ name: String, bundle: Bundle = .main, icon: @escaping AppIconLoader = { _ in nil }) throws {
        let suite = "com.writronic.wherever.tests.searchfolder.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        store.set([String](), forKey: LocationsModel.Key.excluded)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wherever-searchfolder-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = FakeSearchClient()
        fake.setVolumes(.success([]))
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        let answers = Answers()
        let panel = panel
        let make: @MainActor (Binding<String?>) -> SearchFolderBox = { folder in
            SearchFolderBox(
                folder: folder, bundle: bundle, store: store, client: fake, confirmIndex: { answers.ask($0) }, chooseFolder: { panel.choose($0) },
                beep: { answers.beeps += 1 }, icon: icon
            )
        }
        host = SearchHost(root: AnyView(Harness(model: model, make: make)))
        self.fake = fake
        self.answers = answers
        self.store = store
        self.root = root
        self.index = index
        self.model = model
        self.make = make
    }

    func close() {
        host.close()
        try? FileManager.default.removeItem(at: root)
    }

    func shown() -> String? { folderBox(in: host.view)?.stringValue }

    func browse(_ url: URL?) throws {
        panel.chosen = url
        let menu = try #require(folderBox(in: host.view)).diskMenu
        menu.delegate?.menuNeedsUpdate?(menu)
        let item = try #require(menu.items.first { $0.identifier?.rawValue == "search-folder-item-browse" })
        menu.performActionForItem(at: menu.index(of: item))
    }

    func makeFolders(_ names: String...) throws -> [String] {
        try names.map { name in
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
    }

    func dropBox() -> SearchFolderBox {
        make(Binding(get: { self.model.filters.folder }, set: { self.model.filters.folder = $0 }))
    }

    var storedDisks: [String]? { store.stringArray(forKey: LocationsModel.Key.indexedVolumes) }
}

@Suite(.serialized) struct SearchFolderTests {
    @Test func menuSentencesIsolateNamesAndPickingKeepsTheRawPath() async throws {
        let rig = try FolderRig("bidi")
        defer { rig.close() }
        let paths = try rig.makeFolders("Disk 1", "قرص 2")
        let volumes = [
            IndexedVolume(id: "BIDI-DISK", name: "Disk 1", path: paths[0], indexed: false),
            IndexedVolume(id: paths[1], name: "قرص 2", path: paths[1], indexed: false, indexable: false),
        ]
        rig.fake.setVolumes(.success(volumes))
        rig.model.query = "report"
        try await rig.host.until("the box") { rig.shown() != nil }
        for language in ["en", "ar"] {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)))
            let box = SearchFolderBox(
                folder: Binding(get: { rig.model.filters.folder }, set: { rig.model.filters.folder = $0 }),
                bundle: bundle, store: rig.store, client: rig.fake, confirmIndex: { rig.answers.ask($0) }
            )
            for volume in volumes {
                let entry = try #require(box.choices().first { if case .notIndexed(volume) = $0.choice { true } else { false } })
                #expect(entry.title.contains("\u{2068}\(volume.name)\u{2069}"))
                box.commit(entry.choice)
                #expect(rig.model.filters.folder == volume.path)
                try await rig.host.until("the raw path and scope") {
                    rig.shown() == volume.path && rig.fake.queries.last == "report in:\"\(volume.path)\""
                }
            }
        }
        #expect(rig.answers.asked == ["Disk 1", "Disk 1"])
        #expect(rig.fake.switchedOn.isEmpty && rig.storedDisks == nil)
    }

    @Test func aDroppedFolderSetsItAndAFileIsRefused() async throws {
        let rig = try FolderRig("dropped")
        defer { rig.close() }
        let file = rig.root.appendingPathComponent("note.txt")
        try Data().write(to: file)
        let folder = try #require(rig.makeFolders("sf-drop").first)
        let box = rig.dropBox()
        try await rig.host.until("the box") { rig.shown() != nil }
        for refused in [file, URL(string: "https://example.com/folder")!] {
            #expect(!box.accept(refused), "\(refused)")
        }
        #expect(rig.model.filters.folder == nil)
        #expect(box.accept(URL(fileURLWithPath: folder)))
        #expect(rig.model.filters.folder == folder)
        rig.model.query = "report"
        try await rig.host.until("the query of the dropped folder; sent \(rig.fake.queries)") {
            rig.fake.queries.last == "report in:\"\(folder)\"" && rig.shown() == folder
        }
        let sent = rig.fake.queries.count
        #expect(!box.accept(file))
        #expect(rig.model.filters.folder == folder)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.fake.queries.count == sent)
        #expect(rig.answers.asked.isEmpty)
    }

    @Test func aFinderDropOfAFileURLProviderSetsTheFolderAndATextOrFileDropDoesNotAndAFileBeeps() async throws {
        let rig = try FolderRig("provider")
        defer { rig.close() }
        let file = rig.root.appendingPathComponent("note.txt")
        try Data().write(to: file)
        let folder = try #require(rig.makeFolders("sf-provider").first)
        let box = rig.dropBox()
        rig.model.query = "report"
        try await rig.host.until("the box") { rig.shown() != nil }

        func finder(_ url: URL) -> NSItemProvider {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
                done(url.dataRepresentation, nil)
                return nil
            }
            return provider
        }
        #expect(!box.drop([NSItemProvider(object: folder as NSString)]))
        #expect(rig.answers.beeps == 0)
        #expect(box.drop([finder(file)]))
        try await rig.host.until("the beep of the dropped file") { rig.answers.beeps == 1 }
        #expect(rig.model.filters.folder == nil)
        #expect(rig.shown() == "")

        #expect(box.drop([finder(URL(fileURLWithPath: folder))]))
        try await rig.host.until("the dropped folder; sent \(rig.fake.queries)") {
            rig.model.filters.folder == folder && rig.shown() == folder && rig.fake.queries.last == "report in:\"\(folder)\""
        }
        #expect(rig.answers.beeps == 1)
        let sent = rig.fake.queries.count
        #expect(box.drop([finder(file)]))
        try await rig.host.until("the beep of the second dropped file") { rig.answers.beeps == 2 }
        #expect(rig.model.filters.folder == folder && rig.shown() == folder)
        #expect(rig.fake.queries.count == sent)
        #expect(rig.answers.asked.isEmpty)
    }

    @Test func theDiskButtonHasItsOwnVoiceOverLabel() async throws {
        for (language, field, button) in [("en", "Search folder:", "Choose a disk"), ("de", "Suchordner:", "Festplatte wählen")] {
            let bundle = try #require(Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)))
            let rig = try FolderRig("label-\(language)", bundle: bundle)
            defer { rig.close() }
            try await rig.host.until("the box") { rig.shown() != nil }
            let box = try #require(folderBox(in: rig.host.view))
            #expect(box.accessibilityLabel() == field && box.cell?.accessibilityLabel() == field, "\(language)")
            #expect(box.chevron.accessibilityLabel() == button && box.chevron.cell?.accessibilityLabel() == button, "\(language)")
            #expect(box.chevron.accessibilityLabel() != box.accessibilityLabel(), "\(language)")
        }
    }

    @Test func theFirstMenuOpenLoadsEachDiskIconOnceOffTheMainThread() async throws {
        let loads = try IconLoads()
        let rig = try FolderRig("icons", icon: { loads.load($0) })
        defer { rig.close() }
        let paths = try rig.makeFolders("Archive", "Backup")
        rig.fake.setVolumes(.success([
            IndexedVolume(id: "0A0A0A0A-0000-4000-8000-00000000000A", name: "Archive", path: paths[0], indexed: true),
            IndexedVolume(id: "0B0B0B0B-0000-4000-8000-00000000000B", name: "Backup", path: paths[1], indexed: false),
        ]))
        try await rig.host.until("the box") { rig.shown() != nil }
        let menu = try #require(folderBox(in: rig.host.view)).diskMenu
        let disks = ["/"] + paths
        func loaded(_ path: String) -> Bool {
            menu.items.first { $0.identifier?.rawValue == "search-folder-item-" + path }?.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 7
        }

        menu.delegate?.menuNeedsUpdate?(menu)
        #expect(loads.onMain == 0)
        for path in disks {
            let item = try #require(menu.items.first { $0.identifier?.rawValue == "search-folder-item-" + path }, "\(path)")
            #expect(item.image != nil && !loaded(path), "\(path)")
        }
        try await rig.host.until("every disk icon in the open menu; loaded \(loads.paths)") { disks.allSatisfy(loaded) }
        #expect(loads.paths.sorted() == disks.sorted() && loads.onMain == 0)

        menu.delegate?.menuNeedsUpdate?(menu)
        #expect(disks.allSatisfy(loaded))
        #expect(loads.paths.count == disks.count)
    }

    @Test func aDroppedFolderWithAQuoteIsSearched() async throws {
        let rig = try FolderRig("quoted")
        defer { rig.close() }
        let folder = try #require(rig.makeFolders("Notes \"draft\"").first)
        let box = rig.dropBox()
        rig.model.query = "report"
        try await rig.host.until("the box") { rig.shown() != nil }
        #expect(box.accept(URL(fileURLWithPath: folder)))
        #expect(rig.model.filters.folder == folder)
        let written = folder.replacingOccurrences(of: "\"", with: "\"\"")
        try await rig.host.until("the query of the quoted folder; sent \(rig.fake.queries)") {
            rig.fake.queries.last == "report in:\"\(written)\"" && rig.shown() == folder
        }
        #expect(SearchFolderBox.scope(" \(folder)\n") == folder)
    }

    @Test func aDropOnAnIgnoredDiskAsksFirst() async throws {
        let rig = try FolderRig("ignored")
        defer { rig.close() }
        let paths = try rig.makeFolders("Backup", "Backup/Photos", "Backup2", "Archive/Photos")
        let backup = IndexedVolume(id: "0B0B0B0B-0000-4000-8000-00000000000B", name: "Backup", path: paths[0], indexed: false)
        let archive = IndexedVolume(id: "0A0A0A0A-0000-4000-8000-00000000000A", name: "Archive", path: rig.root.appendingPathComponent("Archive").path, indexed: true)
        rig.fake.setVolumes(.success([archive, backup]))
        let box = rig.dropBox()
        rig.model.query = "report"
        try await rig.host.until("the box") { rig.shown() != nil }

        for path in [paths[2], paths[3]] {
            #expect(box.accept(URL(fileURLWithPath: path)))
            try await rig.host.until("the query of \(path); sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"\(path)\"" }
        }
        #expect(rig.answers.asked.isEmpty)

        #expect(box.accept(URL(fileURLWithPath: paths[1])))
        #expect(rig.answers.asked == ["Backup"])
        #expect(rig.model.filters.folder == paths[1])
        try await rig.host.until("the query of Backup/Photos after Cancel; sent \(rig.fake.queries)") {
            rig.fake.queries.last == "report in:\"\(paths[1])\"" && rig.shown() == paths[1]
        }
        #expect(rig.fake.switchedOn.isEmpty && rig.storedDisks == nil)

        #expect(box.accept(URL(fileURLWithPath: paths[3])))
        try await rig.host.until("the query of Archive/Photos again; sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"\(paths[3])\"" }
        rig.answers.replies = [true]
        #expect(box.accept(URL(fileURLWithPath: paths[1])))
        #expect(rig.answers.asked == ["Backup", "Backup"])
        #expect(rig.storedDisks == [backup.id])
        #expect(rig.fake.switchedOn.last == Set([backup.id]))
        try await rig.host.until("the query of Backup/Photos; sent \(rig.fake.queries)") {
            rig.fake.queries.last == "report in:\"\(paths[1])\"" && rig.shown() == paths[1]
        }
    }

    @Test func aDiskUnderAnExcludedRowIsNotIndexedAndAsksNothing() async throws {
        let rig = try FolderRig("covered")
        defer { rig.close() }
        let paths = try rig.makeFolders("Backup", "Backup/Photos", "Archive").map { path in
            try #require(realpath(path, nil).map { p -> String in defer { free(p) }; return String(cString: p) })
        }
        let backup = IndexedVolume(id: "0B0B0B0B-0000-4000-8000-00000000000B", name: "Backup", path: paths[0], indexed: false)
        let archive = IndexedVolume(id: "0A0A0A0A-0000-4000-8000-00000000000A", name: "Archive", path: paths[2], indexed: true)
        rig.fake.setVolumes(.success([archive, backup]))
        rig.store.set([rig.root.path], forKey: LocationsModel.Key.excluded)
        rig.answers.replies = [true, true, true]
        let box = rig.dropBox()
        rig.model.query = "report"
        try await rig.host.until("the box") { rig.shown() != nil }

        let titles = box.choices().map(\.title)
        #expect(titles.contains("\(Bidi.name("Archive")) (Not indexed)") && !titles.contains("Archive"), "\(titles)")
        #expect(titles.contains("\(Bidi.name("Backup")) (Not indexed)"), "\(titles)")
        for volume in [archive, backup] {
            let entry = try #require(box.choices().first { if case .notIndexed(volume) = $0.choice { true } else { false } })
            box.commit(entry.choice)
            #expect(rig.model.filters.folder == volume.path)
            try await rig.host.until("the query of \(volume.name); sent \(rig.fake.queries)") {
                rig.fake.queries.last == "report in:\"\(volume.path)\""
            }
        }
        #expect(box.accept(URL(fileURLWithPath: paths[1])))
        #expect(rig.model.filters.folder == paths[1])
        #expect(rig.answers.asked.isEmpty, "a disk its row keeps out was asked about")
        #expect(rig.fake.switchedOn.isEmpty && rig.storedDisks == nil)

        rig.store.set([String](), forKey: LocationsModel.Key.excluded)
        #expect(box.choices().map(\.title).contains("Archive"))
        let entry = try #require(box.choices().first { if case .notIndexed(backup) = $0.choice { true } else { false } })
        box.commit(entry.choice)
        #expect(rig.answers.asked == ["Backup"])
        #expect(rig.storedDisks == [backup.id])
    }

    @Test func aDiskWithoutAVolumeIDIsAPlainPathChoice() async throws {
        let rig = try FolderRig("nouuid")
        defer { rig.close() }
        let paths = try rig.makeFolders("CARD", "CARD/DCIM")
        let card = IndexedVolume(id: paths[0], name: "CARD", path: paths[0], indexed: false, indexable: false)
        let dock = IndexedVolume(id: "DOCK-UUID", name: "DOCK", path: paths[0] + "-dock", indexed: false, indexable: true)
        rig.fake.setVolumes(.success([card, dock]))
        rig.answers.replies = [true, true]
        let box = rig.dropBox()
        rig.model.query = "report"
        try await rig.host.until("the box") { rig.shown() != nil }

        #expect(box.choices().contains { $0.title == "\(Bidi.name("DOCK")) (Not indexed)" })
        let entry = try #require(box.choices().first { if case .notIndexed(card) = $0.choice { true } else { false } })
        #expect(entry.title == "\(Bidi.name("CARD")) (Can’t be indexed)")
        box.commit(entry.choice)
        #expect(rig.model.filters.folder == paths[0])
        try await rig.host.until("the query of the card; sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"\(paths[0])\"" }
        #expect(box.accept(URL(fileURLWithPath: paths[1])))
        #expect(rig.model.filters.folder == paths[1])
        try await rig.host.until("the query of CARD/DCIM; sent \(rig.fake.queries)") {
            rig.fake.queries.last == "report in:\"\(paths[1])\"" && rig.shown() == paths[1]
        }
        #expect(rig.answers.asked.isEmpty)
        #expect(rig.fake.switchedOn.isEmpty && rig.storedDisks == nil)
    }

    @Test func browseSetsTheFolderAndTheBoxAndSendsOneQueryAndCancelChangesNothing() async throws {
        let rig = try FolderRig("browse")
        defer { rig.close() }
        let folders = try rig.makeFolders("Notes \"draft\" 2", "plain")
        rig.model.query = "report"
        try await rig.host.until("the box") { rig.shown() != nil }
        let before = rig.fake.queries.count

        try rig.browse(URL(fileURLWithPath: folders[0]))
        #expect(rig.panel.starts.count == 1 && rig.panel.starts[0] == nil)
        #expect(rig.model.filters.folder == folders[0])
        let written = folders[0].replacingOccurrences(of: "\"", with: "\"\"")
        try await rig.host.until("the query of the browsed folder; sent \(rig.fake.queries)") {
            rig.fake.queries.last == "report in:\"\(written)\"" && rig.shown() == folders[0]
        }
        #expect(rig.fake.queries.count == before + 1)

        let file = rig.root.appendingPathComponent("note.txt")
        try Data().write(to: file)
        try rig.browse(file)
        #expect(rig.model.filters.folder == folders[0])

        try rig.browse(URL(string: "file://" + folders[1] + "/"))
        #expect(rig.panel.starts.last??.path == folders[0])
        #expect(rig.model.filters.folder == folders[1] && !folders[1].hasSuffix("/"))
        try await rig.host.until("the query of the second folder; sent \(rig.fake.queries)") {
            rig.fake.queries.last == "report in:\"\(folders[1])\"" && rig.shown() == folders[1]
        }

        let box = try #require(folderBox(in: rig.host.view))
        #expect(rig.host.window.makeFirstResponder(box))
        let editor = try #require(box.currentEditor() as? NSTextView)
        editor.string = "/tmp "
        box.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: box))
        try await rig.host.until("the typed scope; sent \(rig.fake.queries)") { rig.fake.queries.last == "report in:\"/tmp\"" }
        let sent = rig.fake.queries.count
        try rig.browse(nil)
        #expect(rig.panel.starts.last??.path == "/tmp")
        #expect(editor.string == "/tmp " && rig.model.filters.folder == "/tmp")
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.fake.queries.count == sent)
        #expect(rig.answers.asked.isEmpty)
    }

    @Test func browseOnAnIgnoredDiskAsksFirstAndAlwaysSetsTheFolderAndACoveredDiskAsksNothing() async throws {
        let rig = try FolderRig("browse-ignored")
        defer { rig.close() }
        let paths = try rig.makeFolders("Backup", "Backup/Photos", "Archive", "Archive/Photos").map { path in
            try #require(realpath(path, nil).map { p -> String in defer { free(p) }; return String(cString: p) })
        }
        let backup = IndexedVolume(id: "0B0B0B0B-0000-4000-8000-00000000000B", name: "Backup", path: paths[0], indexed: false)
        let archive = IndexedVolume(id: "0A0A0A0A-0000-4000-8000-00000000000A", name: "Archive", path: paths[2], indexed: true)
        rig.fake.setVolumes(.success([archive, backup]))
        rig.model.query = "report"
        try await rig.host.until("the box") { rig.shown() != nil }

        try rig.browse(URL(fileURLWithPath: paths[3]))
        #expect(rig.model.filters.folder == paths[3] && rig.answers.asked.isEmpty)

        try rig.browse(URL(fileURLWithPath: paths[1]))
        #expect(rig.answers.asked == ["Backup"])
        #expect(rig.model.filters.folder == paths[1])
        try await rig.host.until("the query after Cancel; sent \(rig.fake.queries)") {
            rig.fake.queries.last == "report in:\"\(paths[1])\"" && rig.shown() == paths[1]
        }
        #expect(rig.fake.switchedOn.isEmpty && rig.storedDisks == nil)

        rig.answers.replies = [true]
        try rig.browse(URL(fileURLWithPath: paths[1]))
        #expect(rig.answers.asked == ["Backup", "Backup"])
        #expect(rig.storedDisks == [backup.id] && rig.fake.switchedOn.last == Set([backup.id]))
        #expect(rig.model.filters.folder == paths[1])

        rig.store.set([rig.root.path], forKey: LocationsModel.Key.excluded)
        rig.answers.replies = [true]
        try rig.browse(URL(fileURLWithPath: paths[1]))
        #expect(rig.answers.asked == ["Backup", "Backup"], "a disk its Excluded Paths row keeps out was asked about")
        #expect(rig.model.filters.folder == paths[1])
    }
}
