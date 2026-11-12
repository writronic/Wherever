import Darwin
import Foundation
import Testing
import WhereverInterface
import WhereverKit

@Suite(.serialized) struct SearchSessionTests {
    @Test func twoSessionsKeepTheirOwnRowsAndGenerations() async throws {
        let tree = try makeTree(files: ["alpha.txt": 1, "alpha-notes.md": 1, "beta.txt": 1, "gamma.txt": 1])
        defer { tree.remove() }
        let client = try tree.services()
        let a = try client.makeSession()
        let b = try client.makeSession()
        #expect(a.id != b.id)
        #expect(a.id == a.id && b.id.rawValue > 0)

        let alpha = try a.search("alpha", sort: .bestMatch)
        #expect(try await ready(client.events, alpha) == 2)
        let beta = try b.search("beta", sort: .bestMatch)
        #expect(try await ready(client.events, beta) == 1)
        #expect(alpha != beta)
        #expect(Set(try a.rows(alpha, in: 0..<10).map(\.name)) == ["alpha.txt", "alpha-notes.md"])
        #expect(try b.rows(beta, in: 0..<10).map(\.name) == ["beta.txt"])
        #expect(throws: WhereverError.staleGeneration) { try a.rows(beta, in: 0..<10) }

        let gamma = try b.search("gamma", sort: .bestMatch)
        #expect(try await ready(client.events, gamma) == 1)
        #expect(Set(try a.rows(alpha, in: 0..<10).map(\.name)) == ["alpha.txt", "alpha-notes.md"])
        #expect(try b.rows(gamma, in: 0..<10).map(\.name) == ["gamma.txt"])
        #expect(throws: WhereverError.staleGeneration) { try b.rows(beta, in: 0..<10) }
    }

    @Test func anOlderGenerationOfTheSessionThrowsStaleGeneration() async throws {
        let tree = try makeTree(files: ["alpha.txt": 1, "gamma.txt": 1])
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()

        let first = try session.search("alpha", sort: .bestMatch)
        #expect(try await ready(client.events, first) == 1)
        let second = try session.search("gamma", sort: .bestMatch)
        #expect(try await ready(client.events, second) == 1)
        #expect(try session.rows(second, in: 0..<10).map(\.name) == ["gamma.txt"])
        #expect(throws: WhereverError.staleGeneration) { try session.rows(first, in: 0..<10) }
    }

    @Test func aSortReordersTheSameHitsUnderANewGeneration() async throws {
        let tree = try makeTree(files: ["match-a.txt": 3, "match-b.txt": 9, "match-c.txt": 1, "other.txt": 5])
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()

        let searched = try session.search("match", sort: SearchSort(column: .name, ascending: true))
        #expect(try await ready(client.events, searched) == 3)
        #expect(try session.rows(searched, in: 0..<10).map(\.name) == ["match-a.txt", "match-b.txt", "match-c.txt"])

        let sorted = try session.sort(SearchSort(column: .size, ascending: false))
        #expect(sorted != searched)
        #expect(try await ready(client.events, sorted) == 3)
        #expect(try session.rows(sorted, in: 0..<10).map(\.size) == [9, 3, 1])
        #expect(try session.rows(sorted, in: 0..<10).map(\.name) == ["match-b.txt", "match-a.txt", "match-c.txt"])
    }

    @Test func everyDateColumnAndKeepFoldersOnTopReachTheEngine() async throws {
        let tree = try makeTree(files: ["item-a": 1, "item-b": 1, "item-c": 1])
        defer { tree.remove() }
        let root = URL(filePath: tree.root)
        try FileManager.default.createDirectory(at: root.appending(path: "item-bdir"), withIntermediateDirectories: false)
        let day = 86_400
        let base = 1_600_000_000
        let days: [(name: String, modified: Int, created: Int, opened: Int)] = [
            ("item-a", 2, 3, 1), ("item-b", 3, 1, 3), ("item-c", 1, 2, 2), ("item-bdir", 4, 4, 4)
        ]
        for entry in days {
            let path = root.appending(path: entry.name).path(percentEncoded: false)
            var times = [timeval(tv_sec: base + entry.opened * day, tv_usec: 0), timeval(tv_sec: base + entry.modified * day, tv_usec: 0)]
            #expect(utimes(path, &times) == 0, "\(entry.name)")
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: TimeInterval(base + entry.created * day))], ofItemAtPath: path)
        }
        let client = try tree.services()
        let session = try client.makeSession()
        let searched = try session.search("item", sort: SearchSort(column: .name, ascending: true))
        #expect(try await ready(client.events, searched) == 4)

        func hits(_ sort: SearchSort) async throws -> [SearchHit] {
            let generation = try session.sort(sort)
            #expect(try await ready(client.events, generation) == 4)
            return try session.rows(generation, in: 0..<10)
        }
        func names(_ sort: SearchSort) async throws -> [String] { try await hits(sort).map(\.name) }
        let files = { (all: [String]) in all.filter { $0 != "item-bdir" } }
        let ascendingOrder: [(SearchColumn, [String])] = [
            (.modified, ["item-c", "item-a", "item-b"]),
            (.created, ["item-b", "item-c", "item-a"]),
            (.opened, ["item-a", "item-c", "item-b"]),
        ]
        for (column, order) in ascendingOrder {
            #expect(files(try await names(SearchSort(column: column, ascending: true))) == order, "\(column) ascending")
            #expect(files(try await names(SearchSort(column: column, ascending: false))) == order.reversed(), "\(column) descending")
        }

        let byName = try await hits(SearchSort(column: .name, ascending: true))
        for entry in days {
            let hit = try #require(byName.first { $0.name == entry.name })
            #expect(hit.modified == Date(timeIntervalSince1970: TimeInterval(base + entry.modified * day)), "\(entry.name) modified")
            #expect(hit.created == Date(timeIntervalSince1970: TimeInterval(base + entry.created * day)), "\(entry.name) created")
        }

        for ascending in [true, false] {
            let off = try await names(SearchSort(column: .name, ascending: ascending))
            let on = try await names(SearchSort(column: .name, ascending: ascending, foldersFirst: true))
            #expect(off.first != "item-bdir", "name \(ascending) must not already start with the folder: \(off)")
            #expect(on == ["item-bdir"] + off.filter { $0 != "item-bdir" }, "name \(ascending) with Keep Folders on Top")
        }
    }

    @Test func matchRangesCutTheMatchedLettersOutOfTheName() async throws {
        let tree = try makeTree(files: ["Ünal Report.TXT": 1, "😀 report.md": 1, "other.txt": 1])
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()

        let generation = try session.search("rep", sort: .bestMatch)
        #expect(try await ready(client.events, generation) == 2)
        let hits = try session.rows(generation, in: 0..<10)
        #expect(hits.count == 2)
        for hit in hits {
            #expect(cut(hit).lowercased() == "rep", "\(hit.name): \(hit.matches)")
        }
        let emoji = try #require(hits.first { $0.name.hasSuffix(" report.md") })
        #expect(emoji.matches.first?.lowerBound == 3)
    }

    @Test func aPressReadsTheFilesAndANarrowReadsNone() async throws {
        let tree = try makeTree(files: [:])
        defer { tree.remove() }
        for (name, text) in ["one.txt": "quartz", "two.txt": "basalt", "three.md": "quartz basalt"] {
            try Data(text.utf8).write(to: URL(filePath: tree.root).appending(path: name))
        }
        let client = try WhereverServices(root: tree.root, home: tree.root, dataFolder: tree.data, excluded: []).search
        let session = try client.makeSession()

        let any = try session.searchContent("", terms: ["quartz"], matchAll: false, sort: .bestMatch)
        #expect(try await done(client.events, any) == Done(count: 2, read: 3, total: 3))
        #expect(Set(try session.rows(any, in: 0..<10).map(\.name)) == ["one.txt", "three.md"])
        let all = try session.searchContent("", terms: ["quartz", " basalt "], matchAll: true, sort: .bestMatch)
        #expect(try await done(client.events, all) == Done(count: 1, read: 3, total: 3))
        #expect(try session.rows(all, in: 0..<10).map(\.name) == ["three.md"])
        let narrow = try session.narrow("one", sort: .bestMatch)
        #expect(try await ready(client.events, narrow) == 0)
        let word = try session.search("text:quartz", sort: .bestMatch)
        #expect(try await ready(client.events, word) == 0)
        #expect(throws: WhereverError.self) { try session.searchContent("", terms: [" "], matchAll: true, sort: .bestMatch) }
        #expect(!FileManager.default.fileExists(atPath: tree.data + "/Text"))
    }

    private static let boxes = [
        "Docs/report-a.txt": "quartz", "Docs/report-b.txt": "basalt", "Docs/plan.txt": "quartz",
        "Other/report-c.txt": "quartz", "Other/notes.txt": "quartz", "top.txt": "quartz",
    ]

    private func press(_ session: any SearchSessionClient, _ events: AsyncStream<SearchEvent>, _ query: String) async throws -> (names: Set<String>, total: Int) {
        let press = try session.searchContent(query, terms: ["quartz"], matchAll: false, sort: .bestMatch)
        let ended = try await done(events, press)
        return (Set(try session.rows(press, in: 0..<20).map(\.name)), ended.total)
    }

    @Test func aFolderAndATermReadThatFolder() async throws {
        let tree = try makeContentTree(Self.boxes)
        defer { tree.remove() }
        let client = try tree.services()
        let got = try await press(try client.makeSession(), client.events, "in:\"\(tree.root)/Docs\"")
        #expect(got.names == ["report-a.txt", "plan.txt"])
        #expect(got.total == 3)
    }

    @Test func aNameAndATermReadTheNamedFiles() async throws {
        let tree = try makeContentTree(Self.boxes)
        defer { tree.remove() }
        let client = try tree.services()
        let got = try await press(try client.makeSession(), client.events, "report")
        #expect(got.names == ["report-a.txt", "report-c.txt"])
        #expect(got.total == 3)
    }

    @Test func aFolderANameAndATermReadTheNamedFilesInThatFolder() async throws {
        let tree = try makeContentTree(Self.boxes)
        defer { tree.remove() }
        let client = try tree.services()
        let got = try await press(try client.makeSession(), client.events, "report in:\"\(tree.root)/Docs\"")
        #expect(got.names == ["report-a.txt"])
        #expect(got.total == 2)
    }

    @Test func aNewNameAfterAPressReadsItsOwnFiles() async throws {
        let tree = try makeContentTree(Self.boxes)
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()
        #expect(try await press(session, client.events, "report").names == ["report-a.txt", "report-c.txt"])
        let narrow = try session.narrow("notes", sort: .bestMatch)
        #expect(try await ready(client.events, narrow) == 0, "the old set holds no such name, which is why this change reads again")
        #expect(try await press(session, client.events, "notes").names == ["notes.txt"])
    }

    @Test func aNewFolderAfterAPressReadsThatFolder() async throws {
        let tree = try makeContentTree(Self.boxes)
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()
        #expect(try await press(session, client.events, "in:\"\(tree.root)/Docs\"").names == ["report-a.txt", "plan.txt"])
        #expect(try await press(session, client.events, "in:\"\(tree.root)/Other\"").names == ["report-c.txt", "notes.txt"])
    }

    @Test func aNameTypedAfterAPressWithNoNameNarrowsWhatItKept() async throws {
        let tree = try makeContentTree(Self.boxes)
        defer { tree.remove() }
        let client = try tree.services()
        let session = try client.makeSession()
        #expect(try await press(session, client.events, "").names == ["report-a.txt", "plan.txt", "report-c.txt", "notes.txt", "top.txt"])
        let narrow = try session.narrow("report", sort: .bestMatch)
        #expect(try await ready(client.events, narrow) == 2)
        #expect(Set(try session.rows(narrow, in: 0..<20).map(\.name)) == ["report-a.txt", "report-c.txt"])
    }
}

private struct Done: Equatable {
    let count: Int
    let read: Int
    let total: Int
}

private func done(_ stream: AsyncStream<SearchEvent>, _ press: SearchGeneration) async throws -> Done {
    let got = try await withThrowingTaskGroup(of: Done?.self) { group in
        group.addTask {
            var last = 0
            for await event in stream {
                switch event {
                case let .resultsReady(_, count): last = count
                case let .contentProgress(generation, read, total, _, _, true) where generation == press:
                    return Done(count: last, read: read, total: total)
                default: break
                }
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
    return try #require(got, "no done progress for press \(press.rawValue) within 10 s")
}

private func cut(_ hit: SearchHit) -> String {
    let units = Array(hit.name.utf16)
    return hit.matches.map { String(decoding: units[$0.clamped(to: 0..<units.count)], as: UTF16.self) }.joined()
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

private func makeTree(files: [String: Int]) throws -> Tree {
    let root = URL.temporaryDirectory.appending(component: "WhereverKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, size) in files {
        try Data(count: size).write(to: root.appending(path: path))
    }
    let path = root.path(percentEncoded: false)
    return Tree(root: path, data: path + "-data")
}

private func makeContentTree(_ files: [String: String]) throws -> Tree {
    let tree = try makeTree(files: [:])
    for (path, text) in files {
        let file = URL(filePath: tree.root).appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    return tree
}

private func ready(_ stream: AsyncStream<SearchEvent>, _ generation: SearchGeneration) async throws -> Int {
    let count = try await withThrowingTaskGroup(of: Int?.self) { group in
        group.addTask {
            for await event in stream {
                if case .resultsReady(generation, let count) = event { return count }
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
    return try #require(count, "no resultsReady for generation \(generation.rawValue) within 10 s")
}
