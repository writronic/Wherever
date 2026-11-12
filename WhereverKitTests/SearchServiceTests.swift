import Foundation
import Testing
import WhereverInterface
@testable import WhereverKit

@Suite(.serialized) struct SearchServiceTests {
    @Test func findsTheExactNamesOfARealTreeThroughTheBridge() async throws {
        let tree = try makeTree(
            files: ["alpha.txt": 5, "Alphabet.md": 3, "beta.txt": 1, "Alpha Folder/ALPHA-notes.rtf": 7, "Alpha Folder/gamma.txt": 2],
            links: ["alpha-link": "beta.txt"]
        )
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()

        let generation = try session.search("alpha", sort: .bestMatch)
        let seen = try await events(in: client.events, until: generation)
        #expect(seen.contains(.stateChanged(IndexState(phase: .ready, indexed: 7))))
        #expect(seen.last == .resultsReady(generation, count: 5))

        let hits = try session.rows(generation, in: 0..<10)
        #expect(hits.map(\.name).sorted() == ["ALPHA-notes.rtf", "Alpha Folder", "Alphabet.md", "alpha-link", "alpha.txt"])
        let byName = Dictionary(hits.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let notes = try #require(byName["ALPHA-notes.rtf"])
        let folder = try #require(byName["Alpha Folder"])
        let link = try #require(byName["alpha-link"])
        let root = try realPath(tree.root)
        #expect(notes.folder == root + "/Alpha Folder")
        #expect(notes.size == 7)
        #expect(notes.kind == .file)
        #expect(abs(notes.modified.timeIntervalSinceNow) < 600)
        #expect(folder.folder == root)
        #expect(folder.kind == .folder)
        #expect(link.kind == .link)
    }

    @Test func anOlderGenerationThrowsStaleGeneration() async throws {
        let tree = try makeTree(files: ["alpha.txt": 1, "Alphabet.md": 1, "gamma.txt": 1])
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()

        let first = try session.search("alpha", sort: .bestMatch)
        _ = try await events(in: client.events, until: first)
        #expect(try session.rows(first, in: 0..<10).count == 2)

        let second = try session.search("gamma", sort: .bestMatch)
        _ = try await events(in: client.events, until: second)
        #expect(try session.rows(second, in: 0..<10).map(\.name) == ["gamma.txt"])
        #expect(throws: WhereverError.staleGeneration) { try session.rows(first, in: 0..<10) }
    }

    @Test func oneHundredRowsFitOneFrameAt120Hz() async throws {
        let names = (0..<300).map { "match-\($0).txt" }
        let tree = try makeTree(files: Dictionary(uniqueKeysWithValues: names.map { ($0, 1) }))
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()

        let generation = try session.search("match", sort: .bestMatch)
        let seen = try await events(in: client.events, until: generation)
        #expect(seen.last == .resultsReady(generation, count: 300))
        let page = try session.rows(generation, in: 0..<100)
        #expect(Set(page.map(\.name)).count == 100)
        #expect(Set(page.map(\.name)).isSubset(of: names))
        #expect(try session.rows(generation, in: -2..<2).map(\.name) == page.prefix(2).map(\.name))
        #expect(try session.rows(generation, in: -5..<(-2)).isEmpty)

        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<51 {
            times.append(try clock.measure { _ = try session.rows(generation, in: 0..<100) })
        }
        let median = times.sorted()[times.count / 2]
        let report = String(format: "rows frame budget: median %.3f ms over %d fetches of 100 rows, limit 8.33 ms", median / .milliseconds(1), times.count)
        print(report)
        print(timingLine("Kit rows, 100 of 300 hits through the bridge", times, warmup: 0, limit: .microseconds(8330)))
        #expect(median <= .microseconds(8330), Comment(rawValue: report))
    }

    @Test func aCancelledConsumerFinishesTheStreamForEveryLaterOne() async throws {
        let tree = try makeTree(files: ["alpha.txt": 1])
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()

        let first = Task { for await _ in client.events {} }
        first.cancel()
        await first.value
        _ = try session.search("alpha", sort: .bestMatch)
        #expect(try await ends(client.events))
    }

    @Test func releasingTheServiceStopsTheEngineAndEndsTheStream() async throws {
        let tree = try makeTree(files: ["alpha.txt": 1])
        defer { tree.remove() }
        var client: SearchService? = try tree.services()
        let stream = try #require(client).events
        var session: (any SearchSessionClient)? = try #require(client).makeSession()

        let generation = try #require(session).search("alpha", sort: .bestMatch)
        _ = try await events(in: stream, until: generation)
        session = nil
        client = nil
        #expect(try await ends(stream))
    }

    @Test func aSecondServiceLoadsTheSavedIndexWithoutCrawling() async throws {
        let tree = try makeTree(files: ["alpha.txt": 5, "Sub/alpha-notes.md": 2])
        defer { tree.remove() }
        var first: SearchService? = try tree.services()
        let stream = try #require(first).events
        var firstSession: (any SearchSessionClient)? = try #require(first).makeSession()
        let generation = try #require(firstSession).search("alpha", sort: .bestMatch)
        let crawled = try await events(in: stream, until: generation)
        #expect(phases(crawled) == [.crawling, .finishing, .ready])
        let rows = try #require(firstSession).rows(generation, in: 0..<10)
        #expect(rows.count == 2)
        firstSession = nil
        first = nil
        #expect(try await ends(stream))

        let second = try tree.services()
        let secondSession = try second.makeSession()
        let again = try secondSession.search("alpha", sort: .bestMatch)
        let loaded = try await events(in: second.events, until: again)
        #expect(phases(loaded) == [.loading, .ready])
        #expect(loaded.contains(.stateChanged(IndexState(phase: .ready, indexed: 3))))
        #expect(try secondSession.rows(again, in: 0..<10) == rows)
    }

    @Test func anOpenLiftsTheSecondOfATieAndAClearPutsItBack() async throws {
        let tree = try makeTree(files: ["alpha-1.txt": 1, "alpha-2.txt": 1])
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()

        let first = try session.search("alpha-", sort: .bestMatch)
        _ = try await events(in: client.events, until: first)
        let before = try session.rows(first, in: 0..<10)
        try #require(before.count == 2)
        try client.recordOpen(before[1].path)

        let lifted = try session.search("alpha-", sort: .bestMatch)
        _ = try await events(in: client.events, until: lifted)
        #expect(try session.rows(lifted, in: 0..<10) == [before[1], before[0]])

        try client.clearOpens()
        let cleared = try session.search("alpha-", sort: .bestMatch)
        let seen = try await events(in: client.events, until: cleared)
        #expect(seen.contains(.resultsChanged))
        #expect(try session.rows(cleared, in: 0..<10) == before)
    }

    @Test func theTypoSwitchAsksEveryWindowToSearchAgain() async throws {
        let tree = try makeTree(files: ["alpha.txt": 1])
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()

        let first = try session.search("alpha", sort: .bestMatch)
        _ = try await events(in: client.events, until: first)

        try client.setTypoSearch(true)
        let again = try session.search("alpha", sort: .bestMatch)
        let seen = try await events(in: client.events, until: again)
        #expect(seen.contains(.resultsChanged))
    }

    @Test func theCommandLineSocketAnswersOnlyWhileServing() async throws {
        let tree = try makeTree(files: ["alpha.txt": 1, "beta.txt": 1])
        let short = Tree(root: tree.root, data: "/private/tmp/whv-\(UUID().uuidString.prefix(8))")
        defer { short.remove() }
        let home = "/Users/" + String(repeating: "u", count: 193)
        #expect(home.utf8.count == 200)
        let client = try WhereverServices(root: short.root, home: home, dataFolder: short.data, excluded: []).search
        #expect(try await indexed(client.events))
        let socket = short.data + "/wherever.sock"
        #expect(!FileManager.default.fileExists(atPath: socket))

        try client.setCommandLine(true)
        #expect(FileManager.default.fileExists(atPath: socket))
        let answer = try ask(socket, fields(["WHV1", "alpha", "best", "0", "0", "0"]))
        #expect(answer.starts(with: fields(["WHV1", "ok", "1", ""])))
        #expect(String(decoding: answer, as: UTF8.self).contains("\0alpha.txt\0f\0"))
        #expect(answer.suffix(2) == [0, 0])

        try client.setCommandLine(false)
        #expect(!FileManager.default.fileExists(atPath: socket))
    }

    @Test func aRelativeOpenThrows() async throws {
        let tree = try makeTree(files: ["alpha.txt": 1])
        defer { tree.remove() }
        let client = try tree.services()

        #expect(throws: WhereverError.io) { try client.recordOpen("alpha.txt") }
    }

    @Test func aThrowingSetVolumesRestoresTheSwitchedOnSet() async throws {
        let tree = try makeTree(files: ["alpha.txt": 1])
        let disk = try makeTree(files: ["ondisk.txt": 1])
        defer {
            tree.remove()
            disk.remove()
        }
        let on = "0A0A0A0A-0000-4000-8000-00000000000A"
        let refused = "0B0B0B0B-0000-4000-8000-00000000000B"
        let real = try realPath(disk.root)
        let volumes = [MountedVolume(path: real, id: on), MountedVolume(path: "Volumes/Relative", id: refused)]
        let client = try WhereverServices(root: tree.root, home: tree.root + "-home", dataFolder: tree.data, excluded: [], volumes: volumes, indexedVolumes: [on]).search

        #expect(throws: WhereverError.io) { try client.setIndexedVolumes([on, refused]) }
        #expect(client.disks.current.indexed == [on])
        #expect(try client.volumes().map(\.indexed) == [true, false])
        try client.disks.update { _ in }
    }

    @Test func aHitPathJoinsItsFolderAndNameWithOneSlash() {
        let modified = Date(timeIntervalSince1970: 0)
        #expect(SearchHit(name: "x", folder: "/", size: 0, modified: modified, created: .distantPast, opened: .distantPast, kind: .file).path == "/x")
        let folder = URL.temporaryDirectory.appending(component: "WhereverKitTests-\(UUID().uuidString)").path(percentEncoded: false)
        #expect(SearchHit(name: "a b.txt", folder: folder, size: 0, modified: modified, created: .distantPast, opened: .distantPast, kind: .file).path == folder + "/a b.txt")
    }

    @Test func aRepeatedResultsReadyKeepsItsLineAndAnotherSessionsEarlyArrival() {
        var timings = EngineEvents.Timings()
        let a = SearchSessionID(rawValue: 1)
        let b = SearchSessionID(rawValue: 2)
        let start = ContinuousClock.now
        let early = start + .milliseconds(1)
        let first = EngineEvents.Timing(generation: 7, call: .search, start: start)
        let pending = timings.start(a, first)
        let page = timings.ready(7, count: 128, at: start)
        #expect(pending == nil)
        #expect(page == first)

        let waiting = timings.ready(9, count: 5, at: early)
        let repeated = timings.ready(7, count: 300, at: early)
        let claimed = timings.start(b, EngineEvents.Timing(generation: 9, call: .search, start: start))
        #expect(waiting == nil)
        #expect(repeated == nil)
        #expect(claimed?.count == 5)
        #expect(claimed?.at == early)

        let before = timings.ready(11, count: 128, at: start)
        let whole = timings.ready(11, count: 300, at: early)
        let late = timings.start(a, EngineEvents.Timing(generation: 11, call: .search, start: start))
        let after = timings.ready(11, count: 300, at: early)
        #expect(before == nil)
        #expect(whole == nil)
        #expect(late?.count == 128)
        #expect(late?.at == start)
        #expect(after == nil)
    }

    @Test func openedOnlyCallbacksKeepTheirMeaningAcrossTheBridge() async {
        let (stream, continuation) = AsyncStream<SearchEvent>.makeStream()
        let events = EngineEvents(continuation, dataFolder: NSTemporaryDirectory())
        events.resultsChanged(openedOnly: true)
        events.resultsChanged(openedOnly: false)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        #expect(first == .openedChanged)
        #expect(second == .resultsChanged)
    }

    private func engineState(_ phase: EnginePhase, boot: EnginePhase, indexed: UInt64 = 0) -> EngineState {
        EngineState(phase: phase, bootPhase: boot, indexing: [], troubles: [], indexed: indexed)
    }

    @Test func theBootLinesFollowTheStartupDisksOwnPhase() {
        var log = EngineEvents.BootLog()
        #expect(log.line(for: engineState(.loading, boot: .loading)) == .loading)
        #expect(log.line(for: engineState(.crawling, boot: .crawling, indexed: 5)) == .crawling)
        #expect(log.line(for: engineState(.crawling, boot: .crawling, indexed: 9)) == nil)
        #expect(log.line(for: engineState(.crawling, boot: .ready, indexed: 40)) == .ready)
        #expect(log.line(for: engineState(.loading, boot: .ready)) == nil)
        #expect(log.line(for: engineState(.crawling, boot: .live)) == nil)
        #expect(log.line(for: engineState(.ready, boot: .live, indexed: 90)) == .diskReady)
        #expect(log.line(for: engineState(.live, boot: .live)) == nil)
    }
}

private func phases(_ events: [SearchEvent]) -> [IndexPhase] {
    var seen = events.compactMap { event -> IndexPhase? in
        guard case let .stateChanged(state) = event else { return nil }
        return state.phase
    }
    while seen.last == .live { seen.removeLast() }
    return seen
}

private struct Tree {
    let root: String
    let data: String

    func services() throws -> SearchService {
        try WhereverServices(root: root, home: root + "-home", dataFolder: data, excluded: []).search
    }

    func remove() {
        for path in [root, data] { try? FileManager.default.removeItem(atPath: path) }
    }
}

private func makeTree(files: [String: Int], links: [String: String] = [:]) throws -> Tree {
    let root = URL.temporaryDirectory.appending(component: "WhereverKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, size) in files {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: file)
    }
    for (path, target) in links {
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: path).path(percentEncoded: false), withDestinationPath: target)
    }
    let path = root.path(percentEncoded: false)
    return Tree(root: path, data: path + "-data")
}

private func realPath(_ path: String) throws -> String {
    let resolved = try #require(realpath(path, nil))
    defer { free(resolved) }
    return String(cString: resolved)
}

private func events(in stream: AsyncStream<SearchEvent>, until generation: SearchGeneration) async throws -> [SearchEvent] {
    let seen = try await withThrowingTaskGroup(of: [SearchEvent]?.self) { group in
        group.addTask {
            var seen: [SearchEvent] = []
            for await event in stream {
                seen.append(event)
                if case .resultsReady(generation, _) = event { return seen }
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            return nil
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
    return try #require(seen, "no resultsReady for generation \(generation.rawValue) within 10 s")
}

private func ends(_ stream: AsyncStream<SearchEvent>) async throws -> Bool {
    try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in stream {}
            return true
        }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            return false
        }
        defer { group.cancelAll() }
        return try await group.next() ?? false
    }
}

private func indexed(_ stream: AsyncStream<SearchEvent>) async throws -> Bool {
    try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await event in stream {
                if case let .stateChanged(state) = event, [.ready, .live].contains(state.bootPhase) { return true }
            }
            return false
        }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            return false
        }
        defer { group.cancelAll() }
        return try await group.next() ?? false
    }
}

private func fields(_ values: [String]) -> [UInt8] {
    Array((values.joined(separator: "\0") + "\0").utf8)
}

private func ask(_ path: String, _ request: [UInt8]) throws -> [UInt8] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    var on: Int32 = 1
    try #require(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0)
    var wait = timeval(tv_sec: 10, tv_usec: 0)
    try #require(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size)) == 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let name = Array(path.utf8)
    try #require(name.count < MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: name) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    try #require(connected == 0)
    let sent = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    try #require(sent == request.count)
    try #require(shutdown(fd, SHUT_WR) == 0)
    var answer: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { return answer }
        answer += buffer.prefix(count)
    }
}
