import Foundation
import SwiftUI
import Testing
import WhereverInterface
import WhereverKit

@Suite struct KitWiringTests {
    @Test func missingArchiveClientTrapsOnUseNotOnRead() async throws {
        _ = EnvironmentValues().archiveClient
        let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = try EnvironmentValues().archiveClient.archiveExtensions()
        }
        #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("Inject \\.archiveClient into the environment before using it."))
    }

    @Test func kitLoadsAsItsOwnFrameworkOnTheInterface() {
        #expect(KitIdentity.bundleIdentifier == AppIdentity.bundleIdentifier + ".kit")
        #expect(Bundle(identifier: KitIdentity.bundleIdentifier) != nil)
    }

    @Test func theDataFolderIsExcludedFromBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: "kitwiring-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        WhereverServices.prepareDataFolder(folder.path(percentEncoded: false))
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
