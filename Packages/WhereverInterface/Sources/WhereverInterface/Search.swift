import Foundation
import SwiftUI

public protocol SearchClient: Sendable {
    var events: AsyncStream<SearchEvent> { get }
    func makeSession() throws -> any SearchSessionClient
    func recordOpen(_ path: String) throws
    func clearOpens() throws
    func flushOpens() throws
    func isSettling() throws -> Bool
    func setExcludedFolders(_ paths: [String]) throws
    func setTypoSearch(_ on: Bool) throws
    func setLiveUpdates(_ on: Bool) throws
    func setIndexedVolumes(_ ids: Set<String>) throws
    func volumes() throws -> [IndexedVolume]
}

public enum SearchEvent: Sendable, Equatable {
    case stateChanged(IndexState)
    case resultsChanged
    case openedChanged
    case resultsReady(SearchGeneration, count: Int)
    case searchFailed(SearchGeneration)
    case contentProgress(SearchGeneration, read: Int, total: Int, notDownloaded: Int, unreadable: Int, done: Bool)
    case volumesChanged
}

public struct IndexState: Sendable, Equatable {
    public let phase: IndexPhase
    public let bootPhase: IndexPhase
    public let indexingDisks: [String]
    public let troubles: [DiskTrouble]
    public let indexed: Int

    public init(phase: IndexPhase, bootPhase: IndexPhase? = nil, indexingDisks: [String] = [], troubles: [DiskTrouble] = [], indexed: Int) {
        self.phase = phase
        self.bootPhase = bootPhase ?? phase
        self.indexingDisks = indexingDisks
        self.troubles = troubles
        self.indexed = indexed
    }
}

public enum IndexPhase: Sendable, Equatable {
    case loading
    case crawling
    case finishing
    case ready
    case live
    case failed
}

public struct DiskTrouble: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case unreadable
        case liveUpdatesOff
    }

    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

public struct IndexedVolume: Sendable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public let indexed: Bool
    public let indexable: Bool

    public init(id: String, name: String, path: String, indexed: Bool, indexable: Bool = true) {
        self.id = id
        self.name = name
        self.path = path
        self.indexed = indexed
        self.indexable = indexable
    }
}

public struct SearchHit: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case file
        case folder
        case link
    }

    public let name: String
    public let folder: String
    public let size: Int64
    public let modified: Date
    public let created: Date
    public let opened: Date
    public let kind: Kind
    public let matches: [Range<Int>]

    public init(name: String, folder: String, size: Int64, modified: Date, created: Date, opened: Date, kind: Kind, matches: [Range<Int>] = []) {
        self.name = name
        self.folder = folder
        self.size = size
        self.modified = modified
        self.created = created
        self.opened = opened
        self.kind = kind
        self.matches = matches
    }
}

public extension SearchHit {
    var path: String { (folder as NSString).appendingPathComponent(name) }
}

public struct SearchGeneration: Hashable, Sendable, RawRepresentable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public protocol ResultsSessionClient: Sendable {
    var id: SearchSessionID { get }
    func search(_ query: String, sort: SearchSort) throws -> SearchGeneration
    func refresh(_ query: String, sort: SearchSort) throws -> SearchGeneration
    func sort(_ sort: SearchSort) throws -> SearchGeneration
    func rows(_ generation: SearchGeneration, in range: Range<Int>) throws -> [SearchHit]
}

public protocol SearchSessionClient: ResultsSessionClient {
    func searchContent(_ query: String, terms: [String], matchAll: Bool, sort: SearchSort) throws -> SearchGeneration
    func narrow(_ query: String, sort: SearchSort) throws -> SearchGeneration
    func stopContent() throws
}

public struct SearchSessionID: Hashable, Sendable, RawRepresentable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public enum SearchColumn: Sendable, Hashable {
    case relevance
    case name
    case folder
    case size
    case modified
    case created
    case opened
    case kind
}

public struct SearchSort: Sendable, Hashable {
    public let column: SearchColumn
    public let ascending: Bool
    public let foldersFirst: Bool

    public init(column: SearchColumn, ascending: Bool, foldersFirst: Bool = false) {
        self.column = column
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    public static let bestMatch = SearchSort(column: .relevance, ascending: false)
}

public extension EnvironmentValues {
    @Entry var searchClient: any SearchClient = MissingSearchClient()
}
