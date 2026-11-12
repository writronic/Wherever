import Foundation

nonisolated enum Bidi {
    static func path(_ path: String) -> String { "\u{2066}\(path)\u{2069}" }
    static func name(_ name: String) -> String { "\u{2068}\(name)\u{2069}" }
}
