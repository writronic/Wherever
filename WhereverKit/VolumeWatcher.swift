import AppKit
import DiskArbitration
import Dispatch
import OSLog
import os
import WhereverInterface

public struct MountedVolume: Sendable, Equatable {
    public let path: String
    public let id: String?

    public init(path: String, id: String?) {
        self.path = path
        self.id = id
    }
}

struct Mount: Equatable {
    let path: String
    let local: Bool
    let browsable: Bool
    let rootFileSystem: Bool
    var image = false
}

func volumes(_ mounts: [Mount], unmounting: Set<String>, uuid: (String) -> String??) -> [MountedVolume] {
    let gone = Set(unmounting.map(normalized))
    return mounts.compactMap { mount in
        let path = normalized(mount.path)
        guard mount.local, mount.browsable, !mount.rootFileSystem, !mount.image, !gone.contains(path), let id = uuid(path) else { return nil }
        return MountedVolume(path: path, id: id)
    }
}

func normalized(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return path
}

final class Disks: Sendable {
    struct State {
        var mounted: [MountedVolume]
        var indexed: Set<String>
        var unmounting: Set<String> = []

        var ids: [String: String?] { Dictionary(mounted.map { ($0.path, $0.id) }, uniquingKeysWith: { first, _ in first }) }
    }

    private let engine: Engine
    private let continuation: AsyncStream<SearchEvent>.Continuation
    private let state: OSAllocatedUnfairLock<State>

    init(engine: Engine, continuation: AsyncStream<SearchEvent>.Continuation, mounted: [MountedVolume], indexed: Set<String>) {
        self.engine = engine
        self.continuation = continuation
        state = OSAllocatedUnfairLock(initialState: State(mounted: mounted, indexed: indexed))
    }

    var list: [IndexedVolume] { state.withLockUnchecked { listed($0) } }

    var current: State { state.withLockUnchecked { $0 } }

    func update(_ change: (inout State) -> Void) throws {
        try state.withLockUnchecked { state in
            let before = listed(state)
            let indexed = state.indexed
            defer {
                if listed(state) != before {
                    continuation.yield(.volumesChanged)
                }
            }
            change(&state)
            let on = state.mounted.compactMap { disk in disk.id.map { EngineVolume(root: disk.path, id: $0) } }
                .filter { state.indexed.contains($0.id) }
            do {
                try WhereverError.mapping { try engine.setVolumes(volumes: on) }
            } catch {
                state.indexed = indexed
                throw error
            }
        }
    }

    private func listed(_ state: State) -> [IndexedVolume] {
        state.mounted.map { disk in
            IndexedVolume(
                id: disk.id ?? disk.path, name: (disk.path as NSString).lastPathComponent, path: disk.path,
                indexed: disk.id.map { state.indexed.contains($0) } ?? false, indexable: disk.id != nil
            )
        }
    }
}

final class VolumeWatcher: Sendable {
    struct Operations: Sendable {
        let mounts: @Sendable () -> [Mount]
        let uuid: @Sendable (String) -> String?

        static let live = Operations(mounts: { kernelMounts() }, uuid: { path in
            let id = try? URL(filePath: path, directoryHint: .isDirectory).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            if id == nil {
                Logger(subsystem: AppIdentity.bundleIdentifier, category: "index").notice("cannot be indexed, no volume UUID: \(path, privacy: .private)")
            }
            return id
        })
    }

    private let disks: Disks
    private let operations: Operations
    private let center: NotificationCenter
    let queue = DispatchQueue(label: AppIdentity.bundleIdentifier + ".volumes")
    private let observers = OSAllocatedUnfairLock(uncheckedState: [any NSObjectProtocol]())
    private let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "index")

    init(disks: Disks, operations: Operations = .live, center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.disks = disks
        self.operations = operations
        self.center = center
        let names = [
            NSWorkspace.didMountNotification,
            NSWorkspace.willUnmountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        observers.withLockUnchecked { observers in
            observers = names.map { name in
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                    let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL).map { normalized($0.path(percentEncoded: false)) }
                    self?.changed(name, path)
                }
            }
        }
        read(nil)
    }

    deinit {
        observers.withLockUnchecked { observers in
            for observer in observers {
                center.removeObserver(observer)
            }
        }
    }

    private func changed(_ name: Notification.Name, _ path: String?) {
        let mounted = name == NSWorkspace.didMountNotification
        apply(fresh: [:], forget: mounted ? path : nil, reads: .zero) { unmounting in
            guard let path else { return }
            switch name {
            case NSWorkspace.willUnmountNotification: unmounting.insert(path)
            case NSWorkspace.didUnmountNotification, NSWorkspace.didMountNotification: unmounting.remove(path)
            default: break
            }
        }
        if mounted || name == NSWorkspace.didRenameVolumeNotification {
            read(path)
        }
    }

    private func read(_ path: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let started = clock.now
            let state = disks.current
            let known = state.ids
            var fresh: [String: String?] = [:]
            _ = volumes(operations.mounts(), unmounting: state.unmounting) { mount in
                if mount != path, case let id?? = known[mount] { return id }
                let id = operations.uuid(mount)
                fresh.updateValue(id, forKey: mount)
                return id
            }
            apply(fresh: fresh, forget: nil, reads: clock.now - started) { _ in }
        }
    }

    private func apply(fresh: [String: String?], forget: String?, reads: Duration, _ change: (inout Set<String>) -> Void) {
        let clock = ContinuousClock()
        let started = clock.now
        var count = 0
        _ = try? disks.update { state in
            change(&state.unmounting)
            var known = state.ids
            if let forget {
                known[forget] = nil
            }
            state.mounted = volumes(operations.mounts(), unmounting: state.unmounting) { fresh[$0] ?? known[$0] }
            count = state.mounted.count
        }
        let read = reads / .milliseconds(1)
        let set = (clock.now - started) / .milliseconds(1)
        let main = Thread.isMainThread
        log.info("setVolumes: \(count) disks, uuid reads \(read, format: .fixed(precision: 1)) ms, setVolumes \(set, format: .fixed(precision: 1)) ms, main thread \(main)")
    }
}

private func kernelMounts() -> [Mount] {
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count > 0 else { return [] }
    var stats: [statfs] = Array(repeating: statfs(), count: Int(count) + 4)
    let filled = stats.withUnsafeMutableBufferPointer { buffer in
        getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
    }
    guard filled > 0 else { return [] }
    let session = DASessionCreate(kCFAllocatorDefault)
    return stats.prefix(Int(filled)).map { stat in
        let path = withUnsafeBytes(of: stat.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let device = withUnsafeBytes(of: stat.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let flags = stat.f_flags
        var mount = Mount(
            path: path,
            local: flags & UInt32(MNT_LOCAL) != 0,
            browsable: flags & UInt32(MNT_DONTBROWSE) == 0,
            rootFileSystem: flags & UInt32(MNT_ROOTFS) != 0
        )
        if mount.local, mount.browsable, !mount.rootFileSystem {
            mount.image = isDiskImage(device: device, session: session)
        }
        return mount
    }
}

func isDiskImage(device: String, session: DASession?) -> Bool {
    guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device.replacingOccurrences(of: "/dev/", with: "")),
          let description = DADiskCopyDescription(disk) as? [String: Any]
    else { return false }
    return description[kDADiskDescriptionDeviceModelKey as String] as? String == "Disk Image"
}
