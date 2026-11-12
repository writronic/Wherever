import SwiftUI

public protocol ArchiveClient: Sendable {
    func archiveExtensions() throws -> [String]
    func openArchive(path: String, shownAs: String) throws -> any ArchiveSessionClient
}

public protocol ArchiveSessionClient: ResultsSessionClient {
    func browse(_ folder: String) throws -> SearchGeneration
    func summary() throws -> ArchiveSummary
    func unlock(_ password: String) throws -> Bool
    func encrypted(_ entry: String) throws -> Bool
    func extract(entries: [String], folder: String, readOnly: Bool) throws -> ArchiveJobID
    func expand(entries: [String], folder: String, whole: Bool) throws -> ArchiveJobID
    func job(_ id: ArchiveJobID) throws -> ArchiveJob
    func cancel(_ id: ArchiveJobID) throws
    func setChanges(_ changes: [ArchiveChange]) throws -> SearchGeneration
    func clashes(folder: String, names: [String]) throws -> [ArchiveClash]
    func writeEdited(to out: String) throws -> ArchiveJobID
    func close() throws
}

public struct ArchiveJobID: Hashable, Sendable, RawRepresentable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct ArchiveSummary: Sendable, Equatable {
    public let path: String
    public let format: String
    public let items: UInt64
    public let bytes: UInt64
    public let encrypted: Bool
    public let skipped: UInt64
    public let problem: ArchiveProblem?
    public let editing: ArchiveEditing

    public init(
        path: String, format: String, items: UInt64, bytes: UInt64, encrypted: Bool, skipped: UInt64, problem: ArchiveProblem?,
        editing: ArchiveEditing = .none
    ) {
        self.path = path
        self.format = format
        self.items = items
        self.bytes = bytes
        self.encrypted = encrypted
        self.skipped = skipped
        self.problem = problem
        self.editing = editing
    }
}

public enum ArchiveEditing: Sendable, Equatable {
    case all
    case oldEncryption
    case none
}

public enum ArchiveChange: Sendable, Equatable {
    case delete(path: String)
    case add(source: String, folder: String, name: String)
}

public struct ArchiveClash: Sendable, Equatable {
    public let name: String
    public let existing: String
    public let folder: Bool
    public let freeName: String

    public init(name: String, existing: String, folder: Bool, freeName: String) {
        self.name = name
        self.existing = existing
        self.folder = folder
        self.freeName = freeName
    }
}

public struct ArchiveJob: Sendable, Equatable {
    public let doneBytes: UInt64
    public let totalBytes: UInt64
    public let doneItems: UInt64
    public let totalItems: UInt64
    public let finished: Bool
    public let problem: ArchiveProblem?
    public let written: [String]
    public let skipped: UInt64

    public init(
        doneBytes: UInt64, totalBytes: UInt64, doneItems: UInt64, totalItems: UInt64, finished: Bool, problem: ArchiveProblem?, written: [String],
        skipped: UInt64
    ) {
        self.doneBytes = doneBytes
        self.totalBytes = totalBytes
        self.doneItems = doneItems
        self.totalItems = totalItems
        self.finished = finished
        self.problem = problem
        self.written = written
        self.skipped = skipped
    }
}

public enum ArchiveProblem: Sendable, Equatable {
    case damaged
    case encrypted
    case unsupported
    case empty
    case changed
    case gone(name: String)
    case noSpace(needed: UInt64, volume: String)
    case passwordNeeded
    case wrongPassword
    case pointsOutside(name: String)
    case linkedItem(name: String)
    case oldEncryption
    case duplicate(name: String)
}

public extension EnvironmentValues {
    @Entry var archiveClient: any ArchiveClient = MissingArchiveClient()
}
