import AppKit
import Combine
import Foundation
import WhereverInterface

final class ArchiveEdits {
    let session: any ArchiveSessionClient
    let results: SearchModel
    var undoManager: () -> UndoManager? = { nil }
    var changed: () -> Void = {}
    var busy: () -> Void = {}
    var frozen: () -> Bool = { false }
    private let refuse: () -> Void
    private(set) var changes: [ArchiveChange] = [] {
        didSet {
            stamp = UUID()
            changed()
        }
    }
    private(set) var stamp = UUID()
    private(set) var adding: String? {
        didSet { if adding != oldValue { busy() } }
    }
    private var before: (list: [ArchiveChange], name: String)?
    private var watch: AnyCancellable?

    init(session: any ArchiveSessionClient, results: SearchModel, refuse: @escaping () -> Void) {
        self.session = session
        self.results = results
        self.refuse = refuse
    }

    var edited: Bool { !changes.isEmpty }

    func delete(_ paths: [String]) {
        guard !paths.isEmpty, let list = Self.removing(paths, from: changes) else { return refuse() }
        apply(list, named: String(localized: "Delete", table: "Archive"))
    }

    func add(_ items: [ArchiveChange], replacing paths: [String]) {
        guard !items.isEmpty, let list = Self.removing(paths, from: changes) else { return refuse() }
        apply(list + items, named: paths.isEmpty ? String(localized: "Add", table: "Archive") : String(localized: "Replace", table: "Archive"))
    }

    static func removing(_ paths: [String], from list: [ArchiveChange]) -> [ArchiveChange]? {
        let added = list.enumerated().compactMap { index, change -> (index: Int, path: String)? in
            guard case let .add(_, folder, name) = change else { return nil }
            return (index, folder.isEmpty ? name : folder + "/" + name)
        }
        var dropped = Set<Int>()
        var inside = Set<Int>()
        var deletes: [ArchiveChange] = []
        for path in paths {
            let taken = added.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
            dropped.formUnion(taken.map(\.index))
            if taken.contains(where: { $0.path == path }) { continue }
            if let holder = added.first(where: { path.hasPrefix($0.path + "/") }) {
                inside.insert(holder.index)
            } else {
                deletes.append(.delete(path: path))
            }
        }
        guard inside.isSubset(of: dropped) else { return nil }
        return list.enumerated().filter { !dropped.contains($0.offset) }.map(\.element) + deletes
    }

    func apply(_ list: [ArchiveChange], named name: String, undoable: Bool = true) {
        guard !frozen(), (try? session.setChanges(list)) != nil else { return refuse() }
        let previous = changes
        changes = list
        if let added = Self.firstAdded(list, after: previous) {
            before = (previous, name)
            adding = added
            watch = results.$results.dropFirst().map { _ in () }
                .merge(with: results.$failed.dropFirst().filter { $0 }.map { _ in () })
                .first()
                .sink { [weak self] in
                    self?.before = nil
                    self?.adding = nil
                }
        } else {
            watch = nil
            before = nil
            adding = nil
        }
        results.reload()
        guard undoable, let undo = undoManager() else { return }
        let owns = undo.groupingLevel == 0 && !undo.isUndoing && !undo.isRedoing
        let byEvent = undo.groupsByEvent
        if owns {
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
        }
        undo.registerUndo(withTarget: self) { $0.apply(previous, named: name) }
        undo.setActionName(name)
        if owns {
            undo.endUndoGrouping()
            undo.groupsByEvent = byEvent
        }
    }

    static func firstAdded(_ list: [ArchiveChange], after previous: [ArchiveChange]) -> String? {
        let earlier = Set(previous.compactMap(addKey))
        for change in list {
            guard let key = addKey(change), !earlier.contains(key) else { continue }
            return key.name
        }
        return nil
    }

    private struct AddKey: Hashable {
        let source: String
        let folder: String
        let name: String
    }

    private static func addKey(_ change: ArchiveChange) -> AddKey? {
        guard case let .add(source, folder, name) = change else { return nil }
        return AddKey(source: source, folder: folder, name: name)
    }

    func stopAdding() {
        guard let before else { return }
        if let undo = undoManager(), undo.canUndo, undo.undoActionName == before.name { return undo.undo() }
        apply(before.list, named: before.name, undoable: false)
    }
}

extension ArchiveEdits {
    private static var finish: ((Bool) -> Void)?
    private static var holdsTermination = false

    static var unsaved: Bool { ArchiveWindows.all.contains(where: \.unsaved) }

    static func refresh() {
        let edited = ArchiveWindows.all.contains { $0.model.edits?.edited == true }
        guard edited != holdsTermination else { return }
        holdsTermination = edited
        if edited { ProcessInfo.processInfo.disableSuddenTermination() } else { ProcessInfo.processInfo.enableSuddenTermination() }
    }

    static func resolve(done: @escaping (Bool) -> Void) {
        guard finish == nil else { return done(false) }
        finish = done
        step()
    }

    static func resolved() async -> Bool {
        await withCheckedContinuation { continuation in resolve { continuation.resume(returning: $0) } }
    }

    private static func step() {
        guard let next = ArchiveWindows.all.first(where: \.unsaved) else { return end(true) }
        next.settle { saved in
            guard saved else { return end(false) }
            next.window?.close()
            DispatchQueue.main.async { MainActor.assumeIsolated { step() } }
        }
    }

    private static func end(_ saved: Bool) {
        let done = finish
        finish = nil
        done?(saved)
    }
}

nonisolated struct ArchiveAccess: Equatable, Sendable {
    var readOnlyVolume = false
    var locked = false
    var writable = true
    var folderWritable = true

    static func read(_ path: String) -> ArchiveAccess {
        let url = URL(filePath: path)
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .isUserImmutableKey])
        let manager = FileManager.default
        return ArchiveAccess(
            readOnlyVolume: values?.volumeIsReadOnly == true, locked: values?.isUserImmutable == true,
            writable: manager.isWritableFile(atPath: path),
            folderWritable: manager.isWritableFile(atPath: url.deletingLastPathComponent().path(percentEncoded: false))
        )
    }
}

extension ArchiveWindowModel {
    var editable: Bool { edits != nil && summary != nil && problem == nil && checked != nil && readOnly == nil }

    var readOnly: String? {
        guard let summary, problem == nil else { return nil }
        if depth > 0 { return String(localized: "Items in an archive inside another archive can’t be edited.", table: "Archive") }
        switch summary.editing {
        case .none: return String(localized: "Only .zip files and tarballs can be edited.", table: "Archive")
        case .oldEncryption: return Self.line(.oldEncryption, name: name)
        case .all: break
        }
        guard let checked else { return nil }
        let path = checked.path
        let access = checked.access
        let shown = Bidi.name(name)
        if access.readOnlyVolume { return String(localized: "“\(shown)” is on a read-only volume.", table: "Archive") }
        if access.locked { return String(localized: "“\(shown)” is locked.", table: "Archive") }
        if !access.writable { return String(localized: "You don’t have permission to change “\(shown)”.", table: "Archive") }
        guard access.folderWritable else {
            let folder = Bidi.name(((path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
            return String(localized: "You don’t have permission to change “\(folder)”.", table: "Archive")
        }
        return nil
    }

    func delete(_ hits: [SearchHit]) {
        guard let edits, editable, !busy else { return base.refuse() }
        edits.delete(hits.compactMap { inner($0) })
    }
}
