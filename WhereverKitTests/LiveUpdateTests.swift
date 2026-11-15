import Foundation
import Testing
import WhereverInterface
import WhereverKit

@Suite struct LiveUpdateTests {
    @Test func aFileCreatedAfterReadyShowsUpWithoutACrawl() async throws {
        let url = URL.temporaryDirectory.appending(component: "WhereverKitLiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: "Sub"), withIntermediateDirectories: true)
        try Data(count: 1).write(to: url.appending(path: "Sub/old.txt"))
        let root = url.path(percentEncoded: false)
        defer { for path in [root, root + "-data"] { try? FileManager.default.removeItem(atPath: path) } }
        let real = try realPath(root)
        let client = try WhereverServices(root: root, home: root + "-home", dataFolder: root + "-data", excluded: []).search
        let session = try client.makeSession()
        let stream = client.events

        _ = try await events(in: stream) { event in
            if case let .stateChanged(state) = event { state.phase == .ready } else { false }
        }
        let staged = url.deletingLastPathComponent().appending(component: "\(url.lastPathComponent)-new.txt")
        try Data(count: 3).write(to: staged)
        let clock = ContinuousClock()
        let written = clock.now
        try FileManager.default.moveItem(at: staged, to: url.appending(path: "Sub/new.txt"))
        let seen = try await events(in: stream) { $0 == .resultsChanged }
        let latency = clock.now - written
        print(String(format: "live update latency: %.0f ms from the write to resultsChanged", latency / .milliseconds(1)))
        #expect(!seen.contains { event in
            if case let .stateChanged(state) = event { state.phase == .crawling } else { false }
        })

        let generation = try session.search("new", sort: .bestMatch)
        let found = try await events(in: stream) { event in
            if case .resultsReady(generation, _) = event { true } else { false }
        }
        #expect(found.last == .resultsReady(generation, count: 1))
        let hit = try #require(try session.rows(generation, in: 0..<10).first)
        #expect(hit.name == "new.txt")
        #expect(hit.folder == real + "/Sub")
        #expect(hit.size == 3)
        #expect(hit.kind == .file)
    }

    @Test func aFileThatGrowsAfterItShowedUpShowsItsNewSize() async throws {
        let url = URL.temporaryDirectory.appending(component: "WhereverKitLiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: "Sub"), withIntermediateDirectories: true)
        let root = url.path(percentEncoded: false)
        defer { for path in [root, root + "-data"] { try? FileManager.default.removeItem(atPath: path) } }
        let client = try WhereverServices(root: root, home: root + "-home", dataFolder: root + "-data", excluded: []).search
        let session = try client.makeSession()
        let stream = client.events
        _ = try await events(in: stream) { event in
            if case let .stateChanged(state) = event { state.phase == .ready } else { false }
        }
        let file = url.appending(path: "Sub/grown.txt")
        try #require(FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil))
        _ = try await events(in: stream) { $0 == .resultsChanged }
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(count: 3))
        try handle.close()
        var size: Int64?
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            let generation = try session.search("grown", sort: .bestMatch)
            _ = try await events(in: stream) { event in
                if case .resultsReady(generation, _) = event { true } else { false }
            }
            size = try session.rows(generation, in: 0..<10).first?.size
            if size == 3 || ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(size == 3)
    }

    @Test func aPauseHoldsBackANewFileUntilResume() async throws {
        let url = URL.temporaryDirectory.appending(component: "WhereverKitLiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: "Sub"), withIntermediateDirectories: true)
        let root = url.path(percentEncoded: false)
        defer { for path in [root, root + "-data"] { try? FileManager.default.removeItem(atPath: path) } }
        let client = try WhereverServices(root: root, home: root + "-home", dataFolder: root + "-data", excluded: []).search
        let session = try client.makeSession()
        let stream = client.events
        _ = try await events(in: stream) { event in
            if case let .stateChanged(state) = event { state.phase == .ready } else { false }
        }

        try client.setLiveUpdates(false)
        try await Task.sleep(for: .milliseconds(200))
        try Data(count: 1).write(to: url.appending(path: "Sub/paused.txt"))
        try await Task.sleep(for: .seconds(1))
        let held = try session.search("paused", sort: .bestMatch)
        let answer = try await events(in: stream) { event in
            if case .resultsReady(held, _) = event { true } else { false }
        }
        #expect(answer.last == .resultsReady(held, count: 0), "the pause let a new file into the index")

        try client.setLiveUpdates(true)
        var found = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            let generation = try session.search("paused", sort: .bestMatch)
            _ = try await events(in: stream) { event in
                if case .resultsReady(generation, _) = event { true } else { false }
            }
            found = try session.rows(generation, in: 0..<10).count
            if found == 1 || ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(found == 1, "resume did not replay the file made during the pause")
    }

    @Test func aPausedStartHoldsBackANewFileUntilResume() async throws {
        let url = URL.temporaryDirectory.appending(component: "WhereverKitLiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: "Sub"), withIntermediateDirectories: true)
        let root = url.path(percentEncoded: false)
        defer { for path in [root, root + "-data"] { try? FileManager.default.removeItem(atPath: path) } }
        let client = try WhereverServices(root: root, home: root + "-home", dataFolder: root + "-data", excluded: [], liveUpdatesPaused: true).search
        let session = try client.makeSession()
        let stream = client.events
        _ = try await events(in: stream) { event in
            if case let .stateChanged(state) = event { state.phase == .ready } else { false }
        }

        try Data(count: 1).write(to: url.appending(path: "Sub/paused.txt"))
        try await Task.sleep(for: .seconds(1))
        let held = try session.search("paused", sort: .bestMatch)
        let answer = try await events(in: stream) { event in
            if case .resultsReady(held, _) = event { true } else { false }
        }
        #expect(answer.last == .resultsReady(held, count: 0), "a paused start let a new file into the index")

        try client.setLiveUpdates(true)
        var found = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            let generation = try session.search("paused", sort: .bestMatch)
            _ = try await events(in: stream) { event in
                if case .resultsReady(generation, _) = event { true } else { false }
            }
            found = try session.rows(generation, in: 0..<10).count
            if found == 1 || ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(found == 1, "resume did not replay the file made during the paused start")
    }
}

private func realPath(_ path: String) throws -> String {
    let resolved = try #require(realpath(path, nil))
    defer { free(resolved) }
    return String(cString: resolved)
}

private func events(in stream: AsyncStream<SearchEvent>, until done: @escaping @Sendable (SearchEvent) -> Bool) async throws -> [SearchEvent] {
    let seen = try await withThrowingTaskGroup(of: [SearchEvent]?.self) { group in
        group.addTask {
            var seen: [SearchEvent] = []
            for await event in stream {
                seen.append(event)
                if done(event) { return seen }
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
    return try #require(seen, "no awaited event within 10 s")
}
