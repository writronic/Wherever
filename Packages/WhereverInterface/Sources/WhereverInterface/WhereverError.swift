public enum WhereverError: Error, Sendable, Equatable {
    case io
    case staleGeneration
    case stopped
    case unknown
}
