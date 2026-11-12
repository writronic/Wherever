import Darwin
import Foundation
import Testing
import WhereverInterface
@testable import WhereverKit

@Suite(.serialized) struct ArchiveServiceTests {
    @Test func opensAZipAndPagesRows() async throws {
        let tree = try Tree([.init("beta.txt", Data([1, 2, 3])), .init("alpha.txt", Data([4]))])
        defer { tree.remove() }
        let services = try tree.services()
        #expect(Set(try services.archive.archiveExtensions()) == ["zip", "jar", "aar", "apk", "cbz", "tar", "tgz", "tar.gz", "tbz", "tbz2", "tar.bz2", "txz", "tar.xz", "rar", "cbr", "pkg", "dmg"])
        let session = try services.archive.openArchive(path: tree.archive.path, shownAs: "/virtual/sample.zip")
        defer { try? session.close() }
        let results: any ResultsSessionClient = session
        let generation = try results.search("", sort: SearchSort(column: .name, ascending: true))
        #expect(try await ready(services.search.events, generation) == 2)
        let first = try #require(results.rows(generation, in: 0..<1).first)
        #expect(first.name == "alpha.txt")
        #expect(first.size == 1)
        #expect(first.kind == .file)
        #expect(first.path == "/virtual/sample.zip/alpha.txt")
        let second = try #require(results.rows(generation, in: 1..<2).first)
        #expect(second.name == "beta.txt")
        #expect(second.size == 3)
        #expect(try results.rows(generation, in: 2..<5).isEmpty)
        let summary = try session.summary()
        #expect(summary.path == tree.archive.path)
        #expect(summary.format == "zip")
        #expect(summary.items == 2 && summary.bytes == 4)
        #expect(!summary.encrypted && summary.skipped == 0 && summary.problem == nil)

        let search = try services.search.makeSession()
        #expect(search.id != session.id)
        let searched = try search.search("sample", sort: .bestMatch)
        #expect(searched != generation)
        #expect(try await ready(services.search.events, searched) == 1)
        #expect(try search.rows(searched, in: 0..<2).map(\.name) == ["sample.zip"])
        #expect(try results.rows(generation, in: 0..<1) == [first])

        let sorted = try results.sort(SearchSort(column: .size, ascending: false))
        #expect(sorted != generation && sorted != searched)
        #expect(try await ready(services.search.events, sorted) == 2)
        #expect(try results.rows(sorted, in: 0..<2).map(\.name) == ["beta.txt", "alpha.txt"])
        #expect(try results.refresh("", sort: .bestMatch) == sorted)
        #expect(try results.rows(sorted, in: 0..<2).map(\.size) == [3, 1])
    }

    @Test func browseIntoAFolderListsItsChildren() async throws {
        let tree = try Tree([.init("root.txt"), .init("folder/çocuk.txt", Data([7, 8])), .init("folder/deeper/leaf.txt")])
        defer { tree.remove() }
        let services = try tree.services()
        let session = try services.archive.openArchive(path: tree.archive.path, shownAs: "/virtual/outer.zip/inner.zip")
        defer { try? session.close() }
        let root = try session.browse("")
        #expect(try await ready(services.search.events, root) == 2)
        #expect(try session.rows(root, in: 0..<5).map(\.name) == ["folder", "root.txt"])
        let child = try session.browse("folder")
        #expect(try await ready(services.search.events, child) == 2)
        let rows = try session.rows(child, in: 0..<5)
        #expect(rows.map(\.name) == ["deeper", "çocuk.txt"])
        #expect(rows.last?.path == "/virtual/outer.zip/inner.zip/folder/çocuk.txt")
        #expect(rows.last?.size == 2)
        let back = try session.browse("")
        #expect(try await ready(services.search.events, back) == 2)
        #expect(try session.rows(back, in: 0..<5).map(\.name) == ["folder", "root.txt"])
    }

    @Test func extractWritesIntoTheGivenFolder() async throws {
        let bytes = Data([0, 1, 2, 127, 128, 255])
        let tree = try Tree([.init("folder/data.bin", bytes), .init("leave.txt", Data([9]))])
        defer { tree.remove() }
        let services = try tree.services()
        let session = try services.archive.openArchive(path: tree.archive.path, shownAs: tree.archive.path)
        defer { try? session.close() }
        let generation = try session.browse("")
        #expect(try await ready(services.search.events, generation) == 2)
        let destination = tree.base.appending(component: "expanded")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let id = try session.extract(entries: ["folder/data.bin"], folder: destination.path, readOnly: true)
        let job = try await finished(session, id)
        #expect(job.problem == nil && job.finished)
        #expect(job.doneBytes == 6 && job.totalBytes == 6)
        #expect(job.doneItems == 1 && job.totalItems == 1)
        let output = destination.appending(path: "folder/data.bin")
        #expect(job.written == [output.path])
        #expect(try Data(contentsOf: output) == bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o444)
        #expect(!FileManager.default.fileExists(atPath: destination.appending(component: "leave.txt").path))
        #expect(!FileManager.default.fileExists(atPath: tree.root.appending(component: "folder").path))
        let failed = try session.extract(entries: ["leave.txt"], folder: tree.base.appending(component: "missing-destination").path, readOnly: false)
        await #expect(throws: WhereverError.io) { try await finished(session, failed) }
    }

    @Test func expandWritesTheArchiveIntoAFolderNamedAfterIt() async throws {
        let tree = try Tree([.init("folder/data.bin", Data([1, 2, 3])), .init("top.txt", Data([4]))])
        defer { tree.remove() }
        let services = try tree.services()
        let session = try services.archive.openArchive(path: tree.archive.path, shownAs: tree.archive.path)
        defer { try? session.close() }
        let generation = try session.browse("")
        #expect(try await ready(services.search.events, generation) == 2)
        let destination = tree.base.appending(component: "expanded")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let whole = try await finished(session, try session.expand(entries: [], folder: destination.path, whole: true))
        #expect(whole.problem == nil && whole.finished && whole.skipped == 0)
        let container = destination.appending(component: "sample")
        #expect(whole.written == [container.path])
        #expect(try Data(contentsOf: container.appending(path: "folder/data.bin")) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: container.appending(path: "top.txt")) == Data([4]))
        let picked = try await finished(session, try session.expand(entries: ["folder/data.bin"], folder: destination.path, whole: false))
        #expect(picked.problem == nil)
        #expect(picked.written == [destination.appending(component: "data.bin").path])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == ["data.bin", "sample"])
    }

    @Test func missingArchiveReportsGone() async throws {
        let tree = try Tree([.init("present.txt", Data([1]))])
        defer { tree.remove() }
        let services = try tree.services()
        let present = try services.archive.openArchive(path: tree.archive.path, shownAs: tree.archive.path)
        defer { try? present.close() }
        let good = try present.browse("")
        #expect(try await ready(services.search.events, good) == 1)
        #expect(try present.summary().items == 1)
        let path = tree.root.appending(component: "missing.zip").path
        let missing = try services.archive.openArchive(path: path, shownAs: "/missing.zip")
        defer { try? missing.close() }
        let generation = try missing.browse("")
        #expect(try await ready(services.search.events, generation) == 0)
        #expect(try missing.summary().problem == .gone(name: path))
    }

    @Test func closedSessionThrowsStopped() async throws {
        let tree = try Tree([.init("present.txt", Data([1]))])
        defer { tree.remove() }
        let services = try tree.services()
        let session = try services.archive.openArchive(path: tree.archive.path, shownAs: tree.archive.path)
        let generation = try session.browse("")
        #expect(try await ready(services.search.events, generation) == 1)
        #expect(try session.rows(generation, in: 0..<1).map(\.name) == ["present.txt"])
        try session.close()
        #expect(throws: WhereverError.stopped) { try session.summary() }
        #expect(throws: WhereverError.stopped) { try session.browse("") }
        #expect(throws: WhereverError.stopped) { try session.rows(generation, in: 0..<1) }
    }

    @Test func clearArchiveCacheRemovesTheFolder() throws {
        let tree = try Tree([])
        defer { tree.remove() }
        let folder = tree.base.appending(path: "Caches/Archives/key/open")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appending(component: "copy.txt"))
        let cache = tree.base.appending(path: "Caches/Archives")
        clearAndWait(cache)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(FileManager.default.fileExists(atPath: tree.archive.path))
        clearAndWait(cache)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func clearArchiveCacheRemovesReadOnlyFoldersCopiedFromAnArchive() throws {
        let tree = try Tree([])
        let cache = tree.base.appending(path: "Caches/Archives")
        let locked = cache.appending(path: "key/open/dir")
        let closed = cache.appending(path: "key/preview/sealed")
        defer {
            for folder in [locked, locked.appending(component: "inner"), closed] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            }
            tree.remove()
        }
        try FileManager.default.createDirectory(at: locked.appending(component: "inner"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        for file in [locked.appending(component: "f.txt"), locked.appending(path: "inner/g.txt"), closed.appending(component: "h.txt")] {
            try Data([1]).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.appending(component: "inner").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: locked) }

        clearAndWait(cache)

        #expect(!FileManager.default.fileExists(atPath: cache.path), "the clear left the read-only copies behind")
        #expect(FileManager.default.fileExists(atPath: tree.archive.path))
    }

    @Test func clearArchiveCacheDetachesAStaleMountFirst() throws {
        let tree = try Tree([])
        defer { tree.remove() }
        let cache = tree.base.appending(path: "Caches/Archives")
        let mounts = cache.appending(component: "Mounts")
        let source = tree.base.appending(component: "image")
        let image = tree.base.appending(component: "stale.dmg")
        try FileManager.default.createDirectory(at: mounts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache.appending(component: "other"), withIntermediateDirectories: true)
        try Data([1]).write(to: source.appending(component: "hello.txt"))
        try Data([2]).write(to: cache.appending(path: "other/x.txt"))
        try #require(WhereverServices.hdiutil(["create", "-quiet", "-size", "2m", "-fs", "HFS+", "-volname", "Stale", "-srcfolder", source.path, image.path], timeout: 60) != nil, "hdiutil create failed")
        let prefix = canonical(mounts.path) + "/"
        let imagePath = canonical(image.path)
        defer {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: mounts.path)) ?? [] {
                _ = WhereverServices.hdiutil(["detach", "-force", mounts.appending(component: name).path], timeout: 30)
            }
        }
        let attached = try #require(WhereverServices.hdiutil(["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountrandom", mounts.path, "-plist", image.path], timeout: 60), "hdiutil attach failed")
        #expect(attachedMounts(in: attached, under: prefix).count == 1, "the image did not mount under the test's Mounts folder")

        clearAndWait(cache)

        #expect(!FileManager.default.fileExists(atPath: cache.path), "the clear left the cache folder behind")
        let info = try #require(WhereverServices.hdiutil(["info", "-plist"], timeout: 30), "hdiutil info failed")
        #expect(attachedMounts(in: info, under: prefix).isEmpty, "a mount stayed under the cache")
        #expect(!attachedImages(in: info).contains(imagePath), "the image stayed attached")
    }

    @Test func clearArchiveCacheReturnsBeforeItRemovesAnything() throws {
        let tree = try Tree([])
        defer { tree.remove() }
        let cache = tree.base.appending(path: "Caches/Archives")
        try FileManager.default.createDirectory(at: cache.appending(path: "key/open"), withIntermediateDirectories: true)
        let queue = DispatchQueue(label: "archive-cache-test")
        queue.suspend()
        WhereverServices.clearArchiveCache(at: cache.path, on: queue)
        #expect(FileManager.default.fileExists(atPath: cache.path), "the cleanup ran on the caller's thread")
        queue.resume()
        #expect(WhereverServices.archiveCacheCleanup.wait(timeout: .now() + 60) == .success, "the cache cleanup did not finish")
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @MainActor @Test func clearArchiveCacheLeavesTheMainThreadFree() throws {
        let tree = try Tree([])
        defer { tree.remove() }
        let cache = tree.base.appending(path: "Caches/Archives")
        try FileManager.default.createDirectory(at: cache.appending(path: "key/open"), withIntermediateDirectories: true)
        WhereverServices.clearArchiveCache(at: cache.path)
        #expect(WhereverServices.archiveCacheCleanup.wait(timeout: .now() + 30) == .success, "the cleanup waits for the main thread")
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func anExtractionWrittenAfterTheCleanupStartsSurvivesIt() async throws {
        let tree = try Tree([.init("kept.txt", Data([7]))])
        defer { tree.remove() }
        let services = try tree.services()
        let cache = tree.base.appending(path: "Caches/Archives")
        let stale = cache.appending(path: "old/open/stale.txt")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: stale)
        let queue = DispatchQueue(label: "archive-cache-test")
        queue.suspend()
        WhereverServices.clearArchiveCache(at: cache.path, on: queue)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { queue.resume() }
        let session = try services.archive.openArchive(path: tree.archive.path, shownAs: tree.archive.path)
        defer { try? session.close() }
        let generation = try session.browse("")
        #expect(try await ready(services.search.events, generation) == 1)
        let open = cache.appending(path: "key/open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        let job = try await finished(session, session.extract(entries: ["kept.txt"], folder: open.path, readOnly: true))
        #expect(job.problem == nil)
        let deadline = ContinuousClock.now + .seconds(30)
        while FileManager.default.fileExists(atPath: stale.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: stale.path), "the cleanup never ran")
        #expect(FileManager.default.fileExists(atPath: open.appending(component: "kept.txt").path), "the cleanup removed an extraction written after it started")
    }

    @Test func cacheFolderIsUnderCachesNotApplicationSupport() {
        let folder = URL(filePath: WhereverServices.archiveCacheFolder)
        #expect(folder.lastPathComponent == "Archives")
        #expect(folder.deletingLastPathComponent().lastPathComponent == AppIdentity.bundleIdentifier)
        #expect(folder.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == URL.cachesDirectory.standardizedFileURL)
        #expect(!folder.path.hasPrefix(WhereverServices.dataFolder + "/"))
    }

    @Test func zip64FixtureListsMoreThan65535Entries() async throws {
        let tree = try Tree((0..<65_536).map { .init(String(format: "item-%05d.txt", $0)) })
        defer { tree.remove() }
        let services = try tree.services()
        let session = try services.archive.openArchive(path: tree.archive.path, shownAs: tree.archive.path)
        defer { try? session.close() }
        let generation = try session.browse("")
        #expect(try await ready(services.search.events, generation) == 65_536)
        #expect(try session.summary().items == 65_536)
        #expect(try session.rows(generation, in: 65_535..<65_536).map(\.name) == ["item-65535.txt"])
    }

    @Test func emptyArchiveReportsItsProblem() async throws {
        let tree = try Tree([])
        defer { tree.remove() }
        let services = try tree.services()
        let session = try services.archive.openArchive(path: tree.archive.path, shownAs: tree.archive.path)
        defer { try? session.close() }
        let generation = try session.browse("")
        #expect(try await ready(services.search.events, generation) == 0)
        #expect(try session.summary().problem == .empty)
    }

    @Test func unlockWithAWrongPasswordReturnsFalse() async throws {
        let tree = try Tree([])
        defer { tree.remove() }
        let bytes = Data("locked body".utf8)
        let archive = try lockedZip(bytes, password: "right-password", in: tree)
        let services = try tree.services()
        let session = try services.archive.openArchive(path: archive.path, shownAs: archive.path)
        defer { try? session.close() }
        let generation = try session.browse("")
        #expect(try await ready(services.search.events, generation) == 1)
        #expect(try session.summary().encrypted)
        #expect(try session.encrypted("secret.txt"))
        let destination = tree.base.appending(component: "expanded")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let extract = { try session.extract(entries: ["secret.txt"], folder: destination.path, readOnly: false) }
        #expect(try await finished(session, extract()).problem == .passwordNeeded)
        #expect(try session.unlock("wrong-password") == false)
        #expect(try await finished(session, extract()).problem == .passwordNeeded)
        #expect(!FileManager.default.fileExists(atPath: destination.appending(component: "secret.txt").path))
        #expect(try session.unlock("right-password"))
        let job = try await finished(session, extract())
        #expect(job.problem == nil && job.doneItems == 1)
        #expect(try Data(contentsOf: destination.appending(component: "secret.txt")) == bytes)
    }

    @Test func setChangesAndWriteEditedRoundTripTheBridge() async throws {
        let tree = try Tree([.init("alpha.txt", Data([1])), .init("beta.txt", Data([2, 3]))])
        defer { tree.remove() }
        let added = tree.base.appending(component: "gamma.txt")
        try Data([4, 5, 6]).write(to: added)
        let services = try tree.services()
        let session = try services.archive.openArchive(path: tree.archive.path, shownAs: tree.archive.path)
        defer { try? session.close() }
        #expect(try await ready(services.search.events, session.browse("")) == 2)
        let changed = try session.setChanges([.delete(path: "beta.txt"), .add(source: added.path, folder: "", name: "gamma.txt")])
        #expect(try await ready(services.search.events, changed) == 2)
        let rows = try session.rows(changed, in: 0..<5)
        #expect(rows.map(\.name) == ["alpha.txt", "gamma.txt"])
        #expect(rows.last?.size == 3)
        #expect(
            try session.clashes(folder: "", names: ["ALPHA.txt", "new.txt"])
                == [WhereverInterface.ArchiveClash(name: "ALPHA.txt", existing: "alpha.txt", folder: false, freeName: "ALPHA 2.txt")]
        )
        let out = tree.root.appending(component: "edited.zip")
        let job = try await finished(session, session.writeEdited(to: out.path))
        #expect(job.problem == nil && job.written == [out.path])
        let copy = try services.archive.openArchive(path: out.path, shownAs: out.path)
        defer { try? copy.close() }
        let listed = try copy.browse("")
        #expect(try await ready(services.search.events, listed) == 2)
        #expect(try copy.rows(listed, in: 0..<5).map(\.name) == ["alpha.txt", "gamma.txt"])
        #expect(try copy.summary().bytes == 4)
    }

    @Test func newProblemsMapOnce() async throws {
        #expect(WhereverInterface.ArchiveProblem(WhereverKit.ArchiveProblem.linkedItem(name: "dir/a.txt")) == .linkedItem(name: "dir/a.txt"))
        #expect(WhereverInterface.ArchiveProblem(WhereverKit.ArchiveProblem.oldEncryption) == .oldEncryption)
        #expect(WhereverInterface.ArchiveProblem(WhereverKit.ArchiveProblem.duplicate(name: "note.txt")) == .duplicate(name: "note.txt"))
        let tree = try Tree([.init("note.txt", Data([1]))])
        defer { tree.remove() }
        let locked = try lockedZip(Data("locked".utf8), password: "right-password", in: tree)
        let note = tree.base.appending(component: "note.txt")
        try Data([9]).write(to: note)
        let services = try tree.services()
        let sealed = try services.archive.openArchive(path: locked.path, shownAs: locked.path)
        defer { try? sealed.close() }
        #expect(try await ready(services.search.events, sealed.browse("")) == 1)
        #expect(try await ready(services.search.events, sealed.setChanges([.delete(path: "secret.txt")])) == 0)
        let refused = tree.root.appending(component: "refused.zip")
        #expect(try await finished(sealed, sealed.writeEdited(to: refused.path)).problem == .oldEncryption)
        #expect(!FileManager.default.fileExists(atPath: refused.path))
        let plain = try services.archive.openArchive(path: tree.archive.path, shownAs: tree.archive.path)
        defer { try? plain.close() }
        #expect(try await ready(services.search.events, plain.browse("")) == 1)
        #expect(try await ready(services.search.events, plain.setChanges([.add(source: note.path, folder: "", name: "note.txt")])) == 2)
        let doubled = tree.root.appending(component: "doubled.zip")
        #expect(try await finished(plain, plain.writeEdited(to: doubled.path)).problem == .duplicate(name: "note.txt"))
        #expect(!FileManager.default.fileExists(atPath: doubled.path))
    }

    @Test func editingStateCrossesTheBridge() async throws {
        let tree = try Tree([.init("a.txt", Data([1]))])
        defer { tree.remove() }
        let jar = tree.root.appending(component: "sample.jar")
        try FileManager.default.copyItem(at: tree.archive, to: jar)
        let locked = try lockedZip(Data("locked".utf8), password: "right-password", in: tree)
        let services = try tree.services()
        let cases: [(String, WhereverInterface.ArchiveEditing)] = [(tree.archive.path, .all), (locked.path, .oldEncryption), (jar.path, .none)]
        for (path, editing) in cases {
            let session = try services.archive.openArchive(path: path, shownAs: path)
            defer { try? session.close() }
            #expect(try await ready(services.search.events, session.browse("")) == 1)
            #expect(try session.summary().editing == editing, "\(path)")
        }
    }

    @Test func thrownErrorsNeverDescribeThePassword() async throws {
        let password = "Kit-secret-\(UUID().uuidString)"
        let tree = try Tree([])
        defer { tree.remove() }
        let archive = try lockedZip(Data("locked".utf8), password: password, in: tree)
        let (events, continuation) = AsyncStream<SearchEvent>.makeStream()
        let dataFolder = tree.base.appending(component: "engine").path
        let engine = try Engine(
            config: EngineConfig(root: tree.root.path, home: tree.root.path, dataFolder: dataFolder, socketFolder: nil, excluded: [], indexedVolumes: []),
            listener: EngineEvents(continuation, dataFolder: dataFolder)
        )
        let session = try engine.openArchive(path: archive.path, shownAs: archive.path)
        #expect(try await ready(events, SearchGeneration(rawValue: session.browse(folder: ""))) == 1)
        #expect(try session.unlock(password: password + "!") == false)
        #expect(try session.unlock(password: password))
        var failures: [any Error] = []
        let missing = try session.extract(entries: ["secret.txt"], folder: tree.base.appending(component: "missing").path, readOnly: false)
        let deadline = ContinuousClock.now + .seconds(10)
        while failures.isEmpty, ContinuousClock.now < deadline {
            do {
                _ = try session.job(id: missing)
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                failures.append(error)
            }
        }
        try session.close()
        do { _ = try session.unlock(password: password) } catch { failures.append(error) }
        do { _ = try session.summary() } catch { failures.append(error) }
        #expect(failures.count == 3)
        for failure in failures {
            for text in [String(describing: failure), String(reflecting: failure), "\(WhereverError(engine: failure))"] {
                #expect(!text.contains(password) && !text.contains("Kit-secret"), "\(text)")
            }
        }
    }
}

private func clearAndWait(_ cache: URL) {
    WhereverServices.clearArchiveCache(at: cache.path)
    #expect(WhereverServices.archiveCacheCleanup.wait(timeout: .now() + 60) == .success, "the cache cleanup did not finish")
}

private func canonical(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func plist(_ data: Data) -> [String: Any] {
    (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
}

private func attachedMounts(in data: Data, under prefix: String) -> [String] {
    let top = plist(data)
    let images = top["images"] as? [[String: Any]] ?? []
    let entities = (top["system-entities"] as? [[String: Any]] ?? []) + images.flatMap { $0["system-entities"] as? [[String: Any]] ?? [] }
    return entities.compactMap { $0["mount-point"] as? String }.filter { canonical($0).hasPrefix(prefix) }
}

private func attachedImages(in data: Data) -> [String] {
    (plist(data)["images"] as? [[String: Any]] ?? []).compactMap { $0["image-path"] as? String }.map(canonical)
}

private func lockedZip(_ bytes: Data, password: String, in tree: Tree) throws -> URL {
    let folder = tree.base.appending(component: "plain")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try bytes.write(to: folder.appending(component: "secret.txt"))
    let archive = tree.root.appending(component: "locked.zip")
    let zip = Process()
    zip.executableURL = URL(filePath: "/usr/bin/zip")
    zip.currentDirectoryURL = folder
    zip.arguments = ["-q", "-P", password, archive.path, "secret.txt"]
    try zip.run()
    zip.waitUntilExit()
    try #require(zip.terminationStatus == 0, "/usr/bin/zip exited with \(zip.terminationStatus)")
    return archive
}

private struct Tree {
    let base = URL.temporaryDirectory.appending(component: "ArchiveServiceTests-\(UUID().uuidString)").resolvingSymlinksInPath()
    var root: URL { base.appending(component: "files") }
    var archive: URL { root.appending(component: "sample.zip") }

    init(_ entries: [ZipFixture.Entry]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ZipFixture.write(entries, to: archive)
    }

    func services() throws -> WhereverServices {
        try WhereverServices(root: root.path, home: root.path, dataFolder: base.appending(component: "index").path, excluded: [])
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

private func ready(_ stream: AsyncStream<SearchEvent>, _ generation: SearchGeneration) async throws -> Int {
    let count = try await withThrowingTaskGroup(of: Int?.self) { group in
        group.addTask {
            for await event in stream {
                if case .resultsReady(generation, let count) = event { return count }
                if case .searchFailed(generation) = event { throw WhereverError.unknown }
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
    return try #require(count, "no archive results for generation \(generation.rawValue) within 10 s")
}

private func finished(_ session: any ArchiveSessionClient, _ id: ArchiveJobID) async throws -> WhereverInterface.ArchiveJob {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        let job = try session.job(id)
        if job.finished { return job }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw WhereverError.unknown
}
