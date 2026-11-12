import Darwin
import Foundation

nonisolated enum HelperLock {
    static var file: URL {
        var folder = [CChar](repeating: 0, count: Int(PATH_MAX))
        confstr(_CS_DARWIN_USER_CACHE_DIR, &folder, folder.count)
        let path = String(decoding: folder.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).appendingPathComponent("\(HelperLink.whereverID)/helper.lock")
    }

    static func take(at file: URL) -> Int32? {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK else { return descriptor }
        close(descriptor)
        return nil
    }
}
