import Darwin
import Dispatch
import Foundation
import os
import OSLog
import WhereverInterface

public final class WhereverServices {
    public let search: SearchService
    public var archive: any ArchiveClient { ArchiveAfterCleanup(service: search.archive) }

    public init(root: String, home: String, dataFolder: String, excluded: [String], volumes: [MountedVolume] = [], indexedVolumes: Set<String> = [], liveUpdatesPaused: Bool = false) throws {
        let config = EngineConfig(root: root, home: home, dataFolder: dataFolder, socketFolder: dataFolder, excluded: excluded, indexedVolumes: indexedVolumes.sorted(), liveUpdatesPaused: liveUpdatesPaused)
        search = try SearchService(config: config, volumes: volumes, watch: false, indexedVolumes: indexedVolumes)
    }

    public init(excluded: [String] = [], indexedVolumes: Set<String> = [], liveUpdatesPaused: Bool = false) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let dataFolder = Self.dataFolder
        Self.prepareDataFolder(dataFolder)
        let config = EngineConfig(root: "/", home: home, dataFolder: dataFolder, socketFolder: nil, excluded: excluded, indexedVolumes: indexedVolumes.sorted(), liveUpdatesPaused: liveUpdatesPaused)
        search = try SearchService(config: config, volumes: [], watch: true, indexedVolumes: indexedVolumes)
    }

    public static let dataFolder = URL.applicationSupportDirectory.appending(component: AppIdentity.bundleIdentifier).path(percentEncoded: false)

    public static let archiveCacheFolder = URL.cachesDirectory.appending(path: AppIdentity.bundleIdentifier + "/Archives", directoryHint: .isDirectory).path(percentEncoded: false)

    static let archiveCacheCleanup = DispatchGroup()

    public static func clearArchiveCache(at path: String = archiveCacheFolder, on queue: DispatchQueue = .global(qos: .userInitiated)) {
        queue.async(group: archiveCacheCleanup) { removeArchiveCache(at: path) }
    }

    private static func removeArchiveCache(at path: String) {
        detachStaleMounts(in: path + "/Mounts")
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        if let walk = manager.enumerator(at: URL(filePath: path, directoryHint: .isDirectory), includingPropertiesForKeys: keys) {
            for case let url as URL in walk {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let folder = url.path(percentEncoded: false)
                if isMounted(folder) {
                    walk.skipDescendants()
                    continue
                }
                try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
            }
        }
        removeDataFolder(at: path)
    }

    static func detachStaleMounts(in folder: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder), !names.isEmpty,
              let info = hdiutil(["info", "-plist"]),
              let plist = (try? PropertyListSerialization.propertyList(from: info, format: nil)) as? [String: Any]
        else { return }
        let prefix = realPath(folder) + "/"
        let images = plist["images"] as? [[String: Any]] ?? []
        let points = images.flatMap { $0["system-entities"] as? [[String: Any]] ?? [] }.compactMap { $0["mount-point"] as? String }
        for point in points where realPath(point).hasPrefix(prefix) {
            for options in [[], ["-force"]] where isMounted(point) {
                _ = hdiutil(["detach"] + options + [point])
            }
        }
    }

    static func isMounted(_ point: String) -> Bool {
        let parent = (point as NSString).deletingLastPathComponent
        guard let device = try? FileManager.default.attributesOfItem(atPath: point)[.systemNumber] as? Int,
              let parentDevice = try? FileManager.default.attributesOfItem(atPath: parent)[.systemNumber] as? Int
        else { return false }
        return device != parentDevice
    }

    static func hdiutil(_ arguments: [String], timeout: Double = 5) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return nil }
        let reader = output.fileHandleForReading
        let drained = DispatchSemaphore(value: 0)
        let bytes = OSAllocatedUnfairLock(initialState: Data())
        DispatchQueue.global(qos: .userInitiated).async {
            let data = reader.readDataToEndOfFile()
            bytes.withLock { $0 = data }
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = exited.wait(timeout: .now() + 1)
            Logger(subsystem: AppIdentity.bundleIdentifier, category: "archive").error("hdiutil \(arguments.first ?? "", privacy: .public) killed after \(timeout, privacy: .public) s")
            return nil
        }
        guard drained.wait(timeout: .now() + 1) == .success, process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return bytes.withLock { $0 }
    }

    public static func removeDataFolder(at path: String) {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            Logger(subsystem: AppIdentity.bundleIdentifier, category: "index").error("data folder removal failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func prepareDataFolder(_ path: String) {
        var folder = URL(filePath: path, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        } catch {
            Logger(subsystem: AppIdentity.bundleIdentifier, category: "index").error("data folder backup exclusion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func hasFullDiskAccess() -> Bool {
        (try? WhereverKit.hasFullDiskAccess(home: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))) ?? false
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

struct ArchiveAfterCleanup: ArchiveClient {
    let service: ArchiveService

    func archiveExtensions() throws -> [String] {
        try service.archiveExtensions()
    }

    func openArchive(path: String, shownAs: String) throws -> any ArchiveSessionClient {
        WhereverServices.archiveCacheCleanup.wait()
        return try service.openArchive(path: path, shownAs: shownAs)
    }
}
