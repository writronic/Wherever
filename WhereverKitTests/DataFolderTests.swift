import Foundation
import Testing
@testable import WhereverKit

@Suite struct DataFolderTests {
    private func folderWithData() throws -> String {
        let folder = URL.temporaryDirectory.appending(component: "DataFolderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["wherever.index", "wherever.opens", "volume-0A0A0A0A-0000-4000-8000-00000000000A.index"] {
            try Data("x".utf8).write(to: folder.appending(component: name))
        }
        return folder.path(percentEncoded: false)
    }

    @Test func removeTakesIndexOpensAndDiskFiles() throws {
        let folder = try folderWithData()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).count == 3)
        WhereverServices.removeDataFolder(at: folder)
        #expect(!FileManager.default.fileExists(atPath: folder))
        WhereverServices.removeDataFolder(at: folder)
        #expect(!FileManager.default.fileExists(atPath: folder))
    }

    @Test func prepareRecreatesTheRemovedFolder() throws {
        let folder = try folderWithData()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        WhereverServices.removeDataFolder(at: folder)
        WhereverServices.prepareDataFolder(folder)
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).isEmpty)
        let values = try URL(filePath: folder, directoryHint: .isDirectory).resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
