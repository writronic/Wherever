import AppKit
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers
import WhereverInterface

extension ArchiveWindowModel {
    struct Saving: Equatable {
        let name: String
        var fraction: Double?
    }

    struct SaveJob {
        let session: any ArchiveSessionClient
        var id: ArchiveJobID?
        let source: String
        let target: String
        let out: String
        let inPlace: Bool
        var done: (Bool) -> Void
    }

    static let savePanelID = "archive-save-as-panel"
    static let saveFailedID = "archive-save-failed-alert"
    static let saveFailedOKID = "archive-save-failed-ok"
    static let saveFailedSaveAsID = "archive-save-failed-save-as"
    static let quarantine = "com.apple.quarantine"

    var canSaveAs: Bool { edits != nil && !busy && expandJob == nil && asking == nil && (depth > 0 || (!reading && blocked == nil)) }

    var canSave: Bool { edits?.edited == true && canSaveAs }

    func save(done: @escaping (Bool) -> Void = { _ in }) {
        guard canSave else {
            base.refuse()
            return done(false)
        }
        write(to: ArchiveWindows.resolved(outermost), done: done)
    }

    func saveAs() {
        guard canSaveAs else { return base.refuse() }
        let archive = URL(filePath: ArchiveWindows.resolved(outermost))
        place(Self.saveAsPanel(for: archive)) { [weak self] url in
            guard let self, let url else { return }
            let target = Self.named(url, like: archive)
            guard target == url || !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
                let error = CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path(percentEncoded: false)]) as NSError
                return showFailure(name: target.lastPathComponent, reason: error.localizedFailureReason ?? error.localizedDescription, offersSaveAs: true)
            }
            guard !heldElsewhere(target) else {
                let reason = String(localized: "“\(Bidi.name(target.lastPathComponent))” is open in another window. Close it first.", table: "Archive")
                return showFailure(name: target.lastPathComponent, reason: reason, offersSaveAs: true)
            }
            saveAs(to: target)
        }
    }

    func saveAs(to url: URL, done: @escaping (Bool) -> Void = { _ in }) {
        guard canSaveAs else {
            base.refuse()
            return done(false)
        }
        write(to: url.path(percentEncoded: false), done: done)
    }

    static func saveAsPanel(for archive: URL) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.identifier = NSUserInterfaceItemIdentifier(savePanelID)
        panel.directoryURL = archive.deletingLastPathComponent()
        panel.nameFieldStringValue = archive.lastPathComponent
        if tarball(archive.lastPathComponent) == nil, let type = UTType(filenameExtension: archive.pathExtension) { panel.allowedContentTypes = [type] }
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        return panel
    }

    static func tarball(_ name: String) -> String? {
        let name = name.lowercased()
        return ["tar.gz", "tar.bz2", "tar.xz"].first { name.count > $0.count + 1 && name.hasSuffix("." + $0) }
    }

    static func named(_ url: URL, like archive: URL) -> URL {
        let original = archive.lastPathComponent
        guard let suffix = tarball(original) else { return url }
        var name = url.lastPathComponent
        guard !name.lowercased().hasSuffix("." + suffix) else { return url }
        for tail in ["." + (suffix as NSString).pathExtension, ".tar"] where name.lowercased().hasSuffix(tail) { name.removeLast(tail.count) }
        return url.deletingLastPathComponent().appending(path: name + String(original.suffix(suffix.count + 1)))
    }

    private func write(to target: String, done: @escaping (Bool) -> Void) {
        guard let edits else {
            base.refuse()
            return done(false)
        }
        let source = ArchiveWindows.resolved(outermost)
        let inPlace = Self.same(target, source)
        let destination = inPlace ? source : (ArchiveWindows.resolved((target as NSString).deletingLastPathComponent) as NSString)
            .appendingPathComponent((target as NSString).lastPathComponent)
        let folder = (destination as NSString).deletingLastPathComponent
        let name = (destination as NSString).lastPathComponent
        let out = (folder as NSString).appendingPathComponent(".\(name).wherever-\(UUID().uuidString)")
        let start = Date()
        saveJob = SaveJob(session: edits.session, source: source, target: destination, out: out, inPlace: inPlace, done: done)
        saving = Saving(name: (outermost as NSString).lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            Self.sweep(folder: folder, name: name, before: start)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.begin(out) } }
        }
    }

    private func begin(_ out: String) {
        guard let job = saveJob, job.out == out, job.id == nil else { return }
        guard let id = try? job.session.writeEdited(to: out) else {
            saveJob = nil
            saving = nil
            base.refuse()
            return job.done(false)
        }
        saveJob?.id = id
        poll(job.session, id) { model, read in model.savePolled(read, id: id) }
    }

    private func passwordEnded(retrying target: String?) {
        guard asking == nil, let done = waitingSave else { return }
        waitingSave = nil
        jobsWatch = nil
        guard let target else { return done(false) }
        write(to: target, done: done)
    }

    func saveWhenFree(done: @escaping (Bool) -> Void) {
        waitingSave = done
        jobsWatch = objectWillChange.sink { [weak self] _ in
            let model = self
            DispatchQueue.main.async { MainActor.assumeIsolated { model?.saveIfFree() } }
        }
        saveIfFree()
    }

    private func saveIfFree() {
        guard let done = waitingSave, edits == nil || canSaveAs else { return }
        waitingSave = nil
        jobsWatch = nil
        edits?.edited == true ? save(done: done) : done(true)
    }

    func afterSaving(_ next: @escaping (Bool) -> Void) {
        if let waiting = waitingSave {
            waitingSave = {
                waiting($0)
                next($0)
            }
            return
        }
        guard let done = saveJob?.done else { return next(edits?.edited != true) }
        saveJob?.done = {
            done($0)
            next($0)
        }
    }

    func stopSaving() {
        guard let job = saveJob else { return }
        saveJob = nil
        saving = nil
        if let id = job.id { try? job.session.cancel(id) }
        Self.discard(job.out)
        job.done(false)
    }

    private func savePolled(_ read: Result<ArchiveJob, any Error>, id: ArchiveJobID) {
        guard let job = saveJob, job.id == id else { return }
        let value: ArchiveJob
        switch read {
        case .failure:
            return failed(job, reason: Self.line(.damaged, name: (job.source as NSString).lastPathComponent), offersSaveAs: false)
        case let .success(read) where !read.finished:
            let fraction = read.totalBytes > 0 ? min(Double(read.doneBytes) / Double(read.totalBytes), 1) : nil
            if saving?.fraction != fraction { saving?.fraction = fraction }
            return
        case let .success(read):
            value = read
        }
        saveJob = nil
        saving = nil
        switch value.problem {
        case .passwordNeeded?:
            Self.discard(job.out)
            leaveNested()
            waitingSave = job.done
            askPassword { [weak self] in self?.passwordEnded(retrying: job.target) }
            jobsWatch = $asking.sink { [weak self] asking in
                guard asking == nil else { return }
                let model = self
                DispatchQueue.main.async { MainActor.assumeIsolated { model?.passwordEnded(retrying: nil) } }
            }
        case let .gone(path)?:
            failed(job, reason: Self.line(.gone(name: path), name: (path as NSString).lastPathComponent), offersSaveAs: false)
        case let problem?:
            failed(job, reason: Self.line(problem, name: (job.source as NSString).lastPathComponent), offersSaveAs: false)
        case nil:
            do {
                if job.inPlace {
                    try Self.swap(job.source, with: job.out)
                } else {
                    try Self.install(job.out, at: job.target, from: job.source)
                }
            } catch {
                let error = error as NSError
                return failed(
                    job, reason: error.localizedFailureReason ?? error.localizedDescription,
                    offersSaveAs: error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError
                )
            }
            reopen(path: job.target, shownAs: job.inPlace ? outermost : job.target)
            job.done(true)
        }
    }

    private func failed(_ job: SaveJob, reason: String, offersSaveAs: Bool) {
        saveJob = nil
        saving = nil
        Self.discard(job.out)
        defer { job.done(false) }
        showFailure(name: (job.target as NSString).lastPathComponent, reason: reason, offersSaveAs: offersSaveAs)
    }

    private func showFailure(name: String, reason: String, offersSaveAs: Bool) {
        guard let window = controller?.window else { return }
        let alert = Self.saveFailedAlert(name: name, reason: reason, offersSaveAs: offersSaveAs)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            let model = self
            DispatchQueue.main.async { MainActor.assumeIsolated { model?.saveAs() } }
        }
    }

    static func saveFailedAlert(name: String, reason: String, offersSaveAs: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "The archive “\(Bidi.name(name))” could not be saved. \(reason)", table: "Archive")
        let ok = alert.addButton(withTitle: String(localized: "OK", table: "Archive"))
        ok.setAccessibilityIdentifier(saveFailedOKID)
        if offersSaveAs {
            alert.addButton(withTitle: String(localized: "Save As…", table: "Archive")).setAccessibilityIdentifier(saveFailedSaveAsID)
        }
        ArchiveWindows.escapeClicks(ok, in: alert)
        alert.window.identifier = NSUserInterfaceItemIdentifier(saveFailedID)
        alert.window.setAccessibilityIdentifier(saveFailedID)
        return alert
    }

    static func same(_ path: String, _ other: String) -> Bool {
        if ArchiveWindows.resolved(path) == other { return true }
        guard let one = ArchiveWindows.identity(path), let two = ArchiveWindows.identity(other) else { return false }
        return one.isEqual(two)
    }

    nonisolated static func sweep(folder: String, name: String, before start: Date) {
        let prefix = ".\(name).wherever-"
        let manager = FileManager.default
        for item in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] where item.hasPrefix(prefix) {
            guard UUID(uuidString: String(item.dropFirst(prefix.count))) != nil else { continue }
            let path = (folder as NSString).appendingPathComponent(item)
            guard let date = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date, date < start else { continue }
            discard(path)
        }
    }

    nonisolated static func discard(_ path: String) {
        _ = lchflags(path, 0)
        if let empty = acl_init(0) {
            _ = acl_set_file(path, ACL_TYPE_EXTENDED, empty)
            _ = acl_free(UnsafeMutableRawPointer(empty))
        }
        _ = unlink(path)
    }

    static func swap(_ original: String, with out: String) throws {
        var info = stat()
        guard stat(original, &info) == 0 else { throw posixError() }
        let quarantine = quarantineBytes(original)
        guard copyfile(original, out, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0 else { throw posixError() }
        let result = try FileManager.default.replaceItemAt(URL(filePath: original), withItemAt: URL(filePath: out), backupItemName: nil, options: [])
        let path = result?.path(percentEncoded: false) ?? original
        _ = chflags(path, info.st_flags & UInt32(UF_SETTABLE))
        if let quarantine { _ = setxattr(path, Self.quarantine, quarantine, quarantine.count, 0, 0) }
    }

    static func install(_ out: String, at target: String, from source: String) throws {
        let quarantine = quarantineBytes(source)
        guard copyfile(source, out, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0 else { throw posixError() }
        _ = chflags(out, 0)
        let manager = FileManager.default
        var path = target
        if manager.fileExists(atPath: target) {
            let result = try manager.replaceItemAt(URL(filePath: target), withItemAt: URL(filePath: out), backupItemName: nil, options: [])
            path = result?.path(percentEncoded: false) ?? target
        } else {
            try manager.moveItem(atPath: out, toPath: target)
        }
        if let quarantine { _ = setxattr(path, Self.quarantine, quarantine, quarantine.count, 0, 0) }
    }

    static func quarantineBytes(_ path: String) -> [UInt8]? {
        let size = getxattr(path, quarantine, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, quarantine, &bytes, size, 0, 0)
        return read >= 0 ? Array(bytes.prefix(read)) : nil
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

final class ArchiveSaveMenu: ObservableObject {
    static let shared = ArchiveSaveMenu()

    @Published private(set) var canSave = false
    @Published private(set) var canSaveAs = false
    @Published private(set) var canExpand = false
    @Published private(set) var canAdd = false
    private weak var key: ArchiveWindowController?

    func follow(_ controller: ArchiveWindowController) {
        key = controller
        if !controller.model.checkingAccess { controller.model.checkAccess() }
        refresh(controller)
    }

    func leave(_ controller: ArchiveWindowController) {
        guard key === controller else { return }
        key = nil
        show(save: false, saveAs: false, expand: false, add: false)
    }

    func refresh(_ controller: ArchiveWindowController) {
        guard key === controller else { return }
        let model = controller.model
        let add = model.editable && !model.busy
        show(save: model.canSave, saveAs: model.canSaveAs, expand: true, add: add)
    }

    private func show(save: Bool, saveAs: Bool, expand: Bool, add: Bool) {
        if canSave != save { canSave = save }
        if canSaveAs != saveAs { canSaveAs = saveAs }
        if canExpand != expand { canExpand = expand }
        if canAdd != add { canAdd = add }
    }
}
