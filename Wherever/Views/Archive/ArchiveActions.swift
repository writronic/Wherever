import AppKit
import CryptoKit
import Darwin
import Foundation
import os
import UniformTypeIdentifiers
import WhereverInterface

nonisolated final class ArchiveExtractor: NSObject, NSFilePromiseProviderDelegate, Sendable {
    struct Entry: Sendable {
        let inner: String
        let name: String
    }

    enum Outcome: Sendable, Equatable {
        case done
        case stopped
        case problem(ArchiveProblem)
        case failed
    }

    enum Report: Sendable {
        case activity
        case failed(ArchiveProblem?, name: String)
    }

    private struct Run {
        let name: String
        var job: ArchiveJobID?
        var stopped = false
    }

    private struct State {
        var next = 0
        var runs: [Int: Run] = [:]
        var closed = false
    }

    static let previewFolder = "preview"
    static let openFolder = "open"
    static let dragFolder = "drag"
    private static let poll: TimeInterval = 0.01

    let queue = OperationQueue()
    private let session: any ArchiveSessionClient
    private let root: URL
    private let report: @Sendable (Report) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(session: any ArchiveSessionClient, root: URL, report: @escaping @Sendable (Report) -> Void) {
        self.session = session
        self.root = root
        self.report = report
        super.init()
        queue.name = AppIdentity.bundleIdentifier + ".archive-promises"
        queue.maxConcurrentOperationCount = 1
    }

    var current: String? { state.withLock { $0.runs.max { $0.key < $1.key }?.value.name } }

    func stop() {
        let jobs = state.withLock { state in
            for token in state.runs.keys { state.runs[token]?.stopped = true }
            return state.runs.values.compactMap(\.job)
        }
        for job in jobs { try? session.cancel(job) }
    }

    func close() {
        let idle = state.withLock { state in
            state.closed = true
            return state.runs.isEmpty
        }
        stop()
        if idle { Self.remove(root.appending(path: Self.previewFolder, directoryHint: .isDirectory)) }
    }

    func run(_ name: String, into folder: URL, readOnly: Bool, entries: [String]) -> Outcome {
        guard let token = begin(name) else { return .stopped }
        defer { end(token) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = try session.extract(entries: entries, folder: folder.path(percentEncoded: false), readOnly: readOnly)
            if attach(id, to: token) { try? session.cancel(id) }
            while true {
                let job = try session.job(id)
                if job.finished {
                    if let problem = job.problem { return .problem(problem) }
                    return stopped(token) || job.doneItems < job.totalItems ? .stopped : .done
                }
                Thread.sleep(forTimeInterval: Self.poll)
            }
        } catch {
            return stopped(token) ? .stopped : .failed
        }
    }

    static func remove(_ item: URL) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        if let walk = manager.enumerator(at: item, includingPropertiesForKeys: keys) {
            for case let url as URL in walk {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
            }
        }
        try? manager.removeItem(at: item)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? Entry)?.name ?? ""
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let entry = filePromiseProvider.userInfo as? Entry else { return completionHandler(CocoaError(.fileWriteUnknown)) }
        let manager = FileManager.default
        let taken = (try? manager.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
        let scratch = root.appending(path: Self.dragFolder + "/" + UUID().uuidString, directoryHint: .isDirectory)
        var outcome = run(entry.name, into: scratch, readOnly: false, entries: [entry.inner])
        if outcome == .done {
            do { try manager.copyItem(at: scratch.appending(path: entry.inner), to: url) } catch { outcome = .failed }
        }
        Self.remove(scratch)
        guard outcome != .done else { return completionHandler(nil) }
        if !taken { Self.remove(url) }
        switch outcome {
        case let .problem(problem): report(.failed(problem, name: entry.name))
        case .failed: report(.failed(nil, name: entry.name))
        case .done, .stopped: break
        }
        completionHandler(CocoaError(outcome == .stopped ? .userCancelled : .fileWriteUnknown))
    }

    private func begin(_ name: String) -> Int? {
        let token: Int? = state.withLock { state in
            guard !state.closed else { return nil }
            state.next += 1
            state.runs[state.next] = Run(name: name)
            return state.next
        }
        if token != nil { report(.activity) }
        return token
    }

    private func end(_ token: Int) {
        let idle = state.withLock { state in
            state.runs[token] = nil
            return state.closed && state.runs.isEmpty
        }
        report(.activity)
        if idle { Self.remove(root.appending(path: Self.previewFolder, directoryHint: .isDirectory)) }
    }

    private func attach(_ job: ArchiveJobID, to token: Int) -> Bool {
        state.withLock { state in
            state.runs[token]?.job = job
            return state.runs[token]?.stopped ?? true
        }
    }

    private func stopped(_ token: Int) -> Bool { state.withLock { $0.runs[token]?.stopped ?? true } }
}

extension ArchiveWindowModel {
    enum Purpose: Sendable, Equatable {
        case preview
        case open(hops: Int)

        var folder: String { self == .preview ? ArchiveExtractor.previewFolder : ArchiveExtractor.openFolder }
    }

    static let expandSelectedID = "results-menu-expand-selected"
    static let expandArchiveID = "results-menu-expand-archive"

    var actions: ResultActions {
        var actions = base
        actions.open = { [weak self] in self?.open($0) }
        actions.reveal = { [weak self] _ in self?.showInFinder() }
        actions.confirmReveal = { _ in true }
        actions.recordOpen = { _ in }
        actions.inside = ResultActions.Inside(
            allows: { _ in true }, enter: { [weak self] in self?.open($0.fileURL) }, enclosing: { [weak self] in self?.goEnclosing() }
        )
        actions.previewItem = { [weak self] in self?.previewItem($0) }
        actions.dragItem = { [weak self] in self?.promise($0) }
        actions.remove = editable ? { [weak self] in self?.delete($0) } : nil
        actions.accept = editable && saving == nil ? { [weak self] in self?.add($0) } : nil
        actions.moreMenu = { [weak self] menu, hit in
            guard let self else { return }
            let nested = hit.kind != .folder && inner(hit).map(enters) == true
            for item in menu.items where !nested && item.action == #selector(ThemedTable.showInside(_:)) { menu.removeItem(item) }
            guard let controller else { return }
            menu.addItem(.separator())
            let commands = [
                (String(localized: "Expand Selected Items…", table: "Archive"), #selector(ArchiveWindowController.expandSelected(_:)), Self.expandSelectedID),
                (String(localized: "Expand Archive…", table: "Archive"), #selector(ArchiveWindowController.expandArchive(_:)), Self.expandArchiveID),
            ]
            for (title, action, id) in commands {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = controller
                item.identifier = NSUserInterfaceItemIdentifier(id)
            }
        }
        return actions
    }

    func stopPreparing() {
        extractor?.stop()
    }

    func open(_ url: URL) {
        guard let inner = inner(url.path(percentEncoded: false)) else { return base.refuse() }
        if url.hasDirectoryPath { return browse(inner, selecting: nil) }
        if let ready = prepare(inner, for: .open(hops: 0)) { reach(ready, inner: inner, hops: 0) }
    }

    func previewItem(_ hit: SearchHit) -> URL? {
        guard let root, let inner = inner(hit) else { return nil }
        guard hit.kind == .folder else { return prepare(inner, for: .preview) }
        let folder = root.appending(path: Purpose.preview.folder + "/" + inner, directoryHint: .isDirectory)
        return (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)).map { folder }
    }

    func promise(_ hit: SearchHit) -> NSFilePromiseProvider? {
        guard let extractor, let inner = inner(hit) else { return nil }
        guard !locked || (try? session?.encrypted(inner)) == false else {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.askPassword() } }
            return nil
        }
        let folder = hit.kind == .folder
        let type = folder ? UTType.folder : UTType(filenameExtension: (hit.name as NSString).pathExtension).flatMap { $0.conforms(to: .data) ? $0 : nil } ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: extractor)
        provider.userInfo = ArchiveExtractor.Entry(inner: inner, name: hit.name)
        return provider
    }

    static func resolve(_ target: String, from inner: String) -> String? {
        guard !target.hasPrefix("/") else { return nil }
        var parts = inner.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/") where part != "." {
            if part != ".." {
                parts.append(String(part))
            } else if parts.popLast() == nil {
                return nil
            }
        }
        return parts.joined(separator: "/")
    }

    func received(_ report: ArchiveExtractor.Report) {
        switch report {
        case .activity:
            preparing = extractor?.current
        case .failed(.passwordNeeded?, _):
            askPassword()
        case let .failed(problem?, entry):
            show(problem, entry: entry)
        case let .failed(nil, entry):
            notice = String(localized: "Wherever can’t copy “\(Bidi.name(entry))”.", table: "Archive")
        }
    }

    static func place(_ inner: String, in root: URL, folder: String, edited: UUID? = nil) -> URL {
        let key = inner + (edited.map { "\u{0}" + $0.uuidString } ?? "")
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: folder + "/" + digest, directoryHint: .isDirectory)
    }

    private func edited(_ inner: String) -> UUID? {
        guard depth == 0, let edits else { return nil }
        let touched = edits.changes.contains { change in
            let path = switch change {
            case let .delete(path): path
            case let .add(_, folder, name): folder.isEmpty ? name : folder + "/" + name
            }
            return inner == path || inner.hasPrefix(path + "/")
        }
        return touched ? edits.stamp : nil
    }

    private func prepare(_ inner: String, for purpose: Purpose) -> URL? {
        guard let extractor, let root else { return nil }
        let place = Self.place(inner, in: root, folder: purpose.folder, edited: edited(inner))
        let url = place.appending(path: inner)
        let key = url.path(percentEncoded: false)
        guard !running.contains(key) else { return nil }
        if (try? FileManager.default.attributesOfItem(atPath: key)) != nil { return url }
        running.insert(key)
        notice = nil
        let readOnly = purpose != .preview
        let name = (inner as NSString).lastPathComponent
        if purpose != .preview, enters(inner) { opening = name }
        let results = results
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let outcome = extractor.run(name, into: place, readOnly: readOnly, entries: [inner])
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(inner, purpose, outcome, at: url, in: results) } }
        }
        return nil
    }

    private func finished(_ inner: String, _ purpose: Purpose, _ outcome: ArchiveExtractor.Outcome, at url: URL, in results: SearchModel) {
        running.remove(url.path(percentEncoded: false))
        if purpose != .preview, enters(inner) { opening = nil }
        guard results === self.results else { return }
        switch (outcome, purpose) {
        case (.done, .preview):
            if base.quickLook.isOpen() { base.quickLook.refresh(url) }
        case let (.done, .open(hops)):
            reach(url, inner: inner, hops: hops)
        case (.problem(.passwordNeeded), _):
            if purpose == .preview, base.quickLook.isOpen() { base.quickLook.hide() }
            askPassword { [weak self] in self?.retry(inner, for: purpose) }
        case let (.problem(problem), _):
            show(problem, entry: inner)
        case (.failed, _):
            base.refuse()
        case (.stopped, _):
            break
        }
    }

    private func retry(_ inner: String, for purpose: Purpose) {
        switch purpose {
        case .preview:
            base.quickLook.show(prepare(inner, for: .preview))
        case let .open(hops):
            if let ready = prepare(inner, for: purpose) { reach(ready, inner: inner, hops: hops) }
        }
    }

    private func reach(_ url: URL, inner: String, hops: Int) {
        let path = url.path(percentEncoded: false)
        let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        guard type == .typeSymbolicLink else {
            if type == .typeDirectory { return browse(inner, selecting: nil) }
            return enters(inner) ? enter(url, inner: inner) : base.open(url)
        }
        guard hops < Int(MAXSYMLINKS), let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
              let resolved = Self.resolve(target, from: inner) else { return show(.pointsOutside(name: inner), entry: inner) }
        if resolved.isEmpty || isFolder(resolved) { return browse(resolved, selecting: nil) }
        if let ready = prepare(resolved, for: .open(hops: hops + 1)) { reach(ready, inner: resolved, hops: hops + 1) }
    }

    private func isFolder(_ inner: String) -> Bool {
        let parent = (inner as NSString).deletingLastPathComponent
        let clashes = try? session?.clashes(folder: parent, names: [(inner as NSString).lastPathComponent])
        return clashes?.contains { $0.folder && $0.existing == inner } == true
    }

    private func show(_ problem: ArchiveProblem, entry: String) {
        let shown = if case .gone = problem { (entry as NSString).lastPathComponent } else { name }
        notice = Self.line(problem, name: shown)
    }
}
