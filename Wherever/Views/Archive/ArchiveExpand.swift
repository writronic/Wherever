import AppKit
import Foundation
import WhereverInterface

extension ArchiveWindowModel {
    enum Expansion: Equatable {
        case running(name: String, fraction: Double?)
        case done(items: UInt64, written: [String], skipped: UInt64)
    }

    struct ExpandJob {
        let session: any ArchiveSessionClient
        let id: ArchiveJobID
        let name: String
        let depth: Int
        let retry: () -> Void
    }

    static let panelID = "archive-expand-panel"
    static let expandPoll: TimeInterval = 0.05
    static let quitWait: TimeInterval = 2

    var canExpand: Bool { session != nil && blocked == nil && !reading && expandJob == nil && saving == nil }

    static func expandPanel(name: String, in folder: URL) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Expand", table: "Archive")
        panel.message = String(localized: "Choose where to expand “\(Bidi.name(name))”.", table: "Archive")
        panel.identifier = NSUserInterfaceItemIdentifier(panelID)
        panel.directoryURL = folder
        return panel
    }

    func expandArchive() {
        askWhere([], whole: true)
    }

    func expandSelected(_ hits: [SearchHit]) {
        let entries = hits.compactMap { inner($0) }
        guard !entries.isEmpty else { return base.refuse() }
        askWhere(entries, whole: false)
    }

    private func askWhere(_ entries: [String], whole: Bool) {
        guard canExpand else { return base.refuse() }
        let panel = Self.expandPanel(name: name, in: URL(filePath: outermost).deletingLastPathComponent())
        choose(panel) { [weak self] folder in
            guard let folder else { return }
            self?.expand(entries, whole: whole, into: folder)
        }
    }

    func expand(_ entries: [String], whole: Bool, into folder: URL) {
        guard canExpand, let session else { return base.refuse() }
        guard let id = try? session.expand(entries: entries, folder: folder.path(percentEncoded: false), whole: whole) else { return base.refuse() }
        let job = ExpandJob(session: session, id: id, name: name, depth: depth) { [weak self] in self?.expand(entries, whole: whole, into: folder) }
        expandJob = job
        notice = nil
        expansion = .running(name: job.name, fraction: nil)
        poll(session, id) { model, read in model.polled(read, id: id) }
    }

    func stopExpanding() {
        guard let job = expandJob else { return }
        expandJob = nil
        expansion = nil
        try? job.session.cancel(job.id)
    }

    func quitExpanding() {
        guard let job = expandJob else { return }
        stopExpanding()
        let deadline = Date(timeIntervalSinceNow: Self.quitWait)
        while Date() < deadline, (try? job.session.job(job.id))?.finished == false {
            Thread.sleep(forTimeInterval: Self.expandPoll / 5)
        }
    }

    func showExpanded() {
        guard case let .done(_, written, _) = expansion else { return }
        base.reveal(written.map { URL(filePath: $0) })
    }

    func poll(
        _ session: any ArchiveSessionClient, _ id: ArchiveJobID,
        then handle: @escaping @MainActor @Sendable (ArchiveWindowModel, Result<ArchiveJob, any Error>) -> Void
    ) {
        let pause = Self.expandPoll
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let read = Result { try session.job(id) }
                let finished = (try? read.get())?.finished ?? true
                DispatchQueue.main.async { MainActor.assumeIsolated { handle(self, read) } }
                if finished { return }
                Thread.sleep(forTimeInterval: pause)
            }
        }
    }

    private func polled(_ read: Result<ArchiveJob, any Error>, id: ArchiveJobID) {
        guard let job = expandJob, job.id == id else { return }
        guard case let .success(value) = read else {
            stopExpanding()
            return base.refuse()
        }
        guard value.finished else {
            let running = Expansion.running(name: job.name, fraction: value.totalBytes > 0 ? Double(value.doneBytes) / Double(value.totalBytes) : nil)
            if expansion != running { expansion = running }
            return
        }
        expandJob = nil
        expansion = nil
        switch value.problem {
        case .passwordNeeded?:
            askPassword(then: job.retry)
        case let .gone(entry)?:
            notice = Self.line(.gone(name: entry), name: (entry as NSString).lastPathComponent)
        case let problem?:
            notice = Self.line(problem, name: job.name)
        case nil:
            expansion = .done(items: value.doneItems, written: value.written, skipped: value.skipped)
        }
    }
}
