import OSLog
import WhereverInterface

extension WhereverError {
    static func mapping<T>(_ call: () throws -> T) throws -> T {
        do {
            return try call()
        } catch {
            throw WhereverError(engine: error)
        }
    }

    init(engine error: any Error) {
        switch error {
        case EngineError.Stale: self = .staleGeneration
        case EngineError.Io: self = .io
        case EngineError.Stopped: self = .stopped
        default: self = .unknown
        }
        if self != .staleGeneration {
            Logger(subsystem: AppIdentity.bundleIdentifier, category: "engine").error("\(String(describing: error))")
        }
    }
}
