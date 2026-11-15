import Foundation
import OSLog
import os
import WhereverInterface

nonisolated final class EngineEvents: EngineListener {
    private let continuation: AsyncStream<SearchEvent>.Continuation
    private let started = ContinuousClock.now
    private let indexFile: URL
    private let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "index")
    private let boot = OSAllocatedUnfairLock(initialState: BootLog())
    private let timings = OSAllocatedUnfairLock(initialState: Timings())
    private let presses = OSAllocatedUnfairLock(initialState: [SearchSessionID: (generation: UInt64, start: ContinuousClock.Instant)]())
    private let lastCount = OSAllocatedUnfairLock(initialState: UInt32(0))

    enum Line: Equatable {
        case loading, crawling, ready, diskReady
    }

    struct BootLog {
        private var booted = false
        private var crawlLogged = false

        mutating func line(for state: EngineState) -> Line? {
            guard !booted else { return state.phase == .ready ? .diskReady : nil }
            switch state.bootPhase {
            case .loading:
                return .loading
            case .crawling where !crawlLogged:
                crawlLogged = true
                return .crawling
            case .ready:
                booted = true
                return .ready
            case .crawling, .finishing, .live, .failed:
                return nil
            }
        }
    }

    struct Timings {
        private var pending: [SearchSessionID: Timing] = [:]
        private var claimed: [SearchSessionID: UInt64] = [:]
        private var arrived: (generation: UInt64, count: UInt32, at: ContinuousClock.Instant)?

        mutating func ready(_ generation: UInt64, count: UInt32, at now: ContinuousClock.Instant) -> Timing? {
            guard let (session, timing) = pending.first(where: { $0.value.generation == generation }) else {
                if !claimed.values.contains(generation), arrived?.generation != generation {
                    arrived = (generation, count, now)
                }
                return nil
            }
            pending[session] = nil
            claimed[session] = generation
            return timing
        }

        mutating func start(_ session: SearchSessionID, _ timing: Timing) -> (count: UInt32, at: ContinuousClock.Instant)? {
            if let arrived, arrived.generation == timing.generation {
                self.arrived = nil
                pending[session] = nil
                claimed[session] = timing.generation
                return (arrived.count, arrived.at)
            }
            pending[session] = timing
            return nil
        }

        mutating func forget(_ session: SearchSessionID) {
            pending[session] = nil
            claimed[session] = nil
        }
    }

    struct Timing: Equatable {
        enum Call { case search, sort, refresh }

        let generation: UInt64
        let call: Call
        let start: ContinuousClock.Instant
    }

    init(_ continuation: AsyncStream<SearchEvent>.Continuation, dataFolder: String) {
        self.continuation = continuation
        indexFile = URL(filePath: dataFolder).appending(component: "wherever.index")
    }

    deinit {
        continuation.finish()
    }

    func stateChanged(state: EngineState) {
        record(state)
        continuation.yield(.stateChanged(IndexState(state)))
    }

    private func record(_ state: EngineState) {
        let ms = Int(((ContinuousClock.now - started) / .milliseconds(1)).rounded())
        switch boot.withLock({ $0.line(for: state) }) {
        case .loading:
            log.notice("loading the saved index, \(ms) ms after start")
        case .crawling:
            log.notice("crawling, \(ms) ms after start")
        case .diskReady:
            log.notice("disk ready: \(state.indexed) entries on all volumes, \(ms) ms after start")
        case .ready:
            let size = (try? FileManager.default.attributesOfItem(atPath: indexFile.path(percentEncoded: false))[.size] as? Int) ?? 0
            let usage = Self.usage()
            log.notice("ready: \(state.indexed) entries, \(ms) ms after start, index file \(size) bytes, resident memory \(usage?.ri_resident_size ?? 0) bytes, peak \(usage?.ri_lifetime_max_phys_footprint ?? 0) bytes")
        case nil:
            break
        }
    }

    private static func usage() -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return read == 0 ? usage : nil
    }

    func resultsChanged(openedOnly: Bool) {
        log.notice("results changed: opened only \(openedOnly)")
        continuation.yield(openedOnly ? .openedChanged : .resultsChanged)
    }

    func resultsReady(generation: UInt64, count: UInt32) {
        let now = ContinuousClock.now
        lastCount.withLock { $0 = count }
        let timing = timings.withLock { $0.ready(generation, count: count, at: now) }
        if let timing { time(timing, count: count, until: now) }
        continuation.yield(.resultsReady(SearchGeneration(rawValue: generation), count: Int(count)))
    }

    func searchFailed(generation: UInt64) {
        continuation.yield(.searchFailed(SearchGeneration(rawValue: generation)))
    }

    func started(_ session: SearchSessionID, generation: UInt64, call: Timing.Call, at start: ContinuousClock.Instant) {
        let timing = Timing(generation: generation, call: call, start: start)
        let early = timings.withLock { $0.start(session, timing) }
        if let early { time(timing, count: early.count, until: early.at) }
    }

    func forget(_ session: SearchSessionID) {
        timings.withLock { $0.forget(session) }
        presses.withLock { $0[session] = nil }
    }

    func pressed(_ session: SearchSessionID, generation: UInt64, at start: ContinuousClock.Instant) {
        presses.withLock { $0[session] = (generation, start) }
    }

    func contentProgress(generation: UInt64, read: UInt64, total: UInt64, notDownloaded: UInt64, unreadable: UInt64, done: Bool) {
        if done { recordContent(generation, read: read, total: total, notDownloaded: notDownloaded, unreadable: unreadable) }
        continuation.yield(.contentProgress(
            SearchGeneration(rawValue: generation), read: Int(clamping: read), total: Int(clamping: total),
            notDownloaded: Int(clamping: notDownloaded), unreadable: Int(clamping: unreadable), done: done))
    }

    private func recordContent(_ generation: UInt64, read: UInt64, total: UInt64, notDownloaded: UInt64, unreadable: UInt64) {
        let now = ContinuousClock.now
        let start = presses.withLock { presses in
            let session = presses.first { $0.value.generation == generation }?.key
            return session.flatMap { presses.removeValue(forKey: $0)?.start }
        }
        let ms = start.map { ($0.duration(to: now)) / .milliseconds(1) } ?? 0
        let holding = lastCount.withLock { $0 }
        let usage = Self.usage()
        log.notice("content: read \(read) of \(total) files, \(notDownloaded) not downloaded, \(unreadable) unreadable, in \(ms, format: .fixed(precision: 2)) ms, \(holding) holding, resident memory \(usage?.ri_resident_size ?? 0) bytes, peak \(usage?.ri_lifetime_max_phys_footprint ?? 0) bytes")
    }

    private func time(_ timing: Timing, count: UInt32, until end: ContinuousClock.Instant) {
        let ms = (end - timing.start) / .milliseconds(1)
        switch timing.call {
        case .search: log.notice("search: \(count) hits in \(ms, format: .fixed(precision: 2)) ms")
        case .sort: log.notice("sort: \(count) hits in \(ms, format: .fixed(precision: 2)) ms")
        case .refresh: log.notice("refresh: \(count) hits in \(ms, format: .fixed(precision: 2)) ms")
        }
    }

    func fault(message: String) {
        Logger(subsystem: AppIdentity.bundleIdentifier, category: "engine").fault("\(message, privacy: .private)")
    }
}

private extension IndexState {
    init(_ state: EngineState) {
        self.init(
            phase: Self.phase(state.phase), bootPhase: Self.phase(state.bootPhase),
            indexingDisks: state.indexing.map { ($0 as NSString).lastPathComponent },
            troubles: state.troubles.map { DiskTrouble(path: $0.root, kind: Self.kind($0.kind)) },
            indexed: Int(clamping: state.indexed)
        )
    }

    static func phase(_ phase: EnginePhase) -> IndexPhase {
        switch phase {
        case .loading: .loading
        case .crawling: .crawling
        case .finishing: .finishing
        case .ready: .ready
        case .live: .live
        case .failed: .failed
        }
    }

    static func kind(_ kind: EngineTroubleKind) -> DiskTrouble.Kind {
        switch kind {
        case .unreadable: .unreadable
        case .liveUpdatesOff: .liveUpdatesOff
        }
    }
}
