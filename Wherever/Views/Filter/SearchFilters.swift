import Foundation

struct SearchFilters: Equatable {
    enum NameMode: CaseIterable {
        case contains, matches, beginsWith, endsWith, fileExtension, wildcard, regex
    }

    enum Kind: CaseIterable {
        case any, files, folders, links, images, videos, audio, documents, code, archives, fonts, apps

        var token: String? {
            switch self {
            case .any: nil
            case .files: "kind:file"
            case .folders: "kind:folder"
            case .links: "kind:link"
            case .images: "type:image"
            case .videos: "type:video"
            case .audio: "type:audio"
            case .documents: "type:doc"
            case .code: "type:code"
            case .archives: "type:archive"
            case .fonts: "type:font"
            case .apps: "type:app"
            }
        }
    }

    enum Size: CaseIterable {
        case any, small, medium, large, huge

        var token: String? {
            switch self {
            case .any: nil
            case .small: "size:<=1mb"
            case .medium: "size:1mb..100mb"
            case .large: "size:100mb..1gb"
            case .huge: "size:>=1gb"
            }
        }
    }

    enum Modified: CaseIterable {
        case any, day, week, month, year

        var token: String? {
            switch self {
            case .any: nil
            case .day: "mtime:<1d"
            case .week: "mtime:<7d"
            case .month: "mtime:<30d"
            case .year: "mtime:<365d"
            }
        }
    }

    var extensions = ""
    var kind = Kind.any
    var size = Size.any
    var modified = Modified.any
    var folder: String?
    var hidesHidden = false
    var nameMode = NameMode.contains

    static let hidesHiddenKey = "hidesInvisibleFiles"

    static func extensionToken(_ text: String) -> String? {
        let names = text.lowercased()
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .compactMap { $0.split(separator: ".").last }
            .map { $0.filter { $0.isLetter || $0.isNumber || "_-+".contains($0) } }
            .filter { !$0.isEmpty }
        return names.isEmpty ? nil : "ext:" + names.joined(separator: ",")
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func nameText(_ query: String) -> String {
        guard nameMode != .contains else { return query }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "" }
        return switch nameMode {
        case .contains: query
        case .matches: "whole:" + Self.quoted(text)
        case .beginsWith: "begins:" + Self.quoted(text)
        case .endsWith: "ends:" + Self.quoted(text)
        case .fileExtension: Self.extensionToken(text) ?? ""
        case .wildcard: "glob:" + Self.quoted(text)
        case .regex: "re:" + Self.quoted(text)
        }
    }

    func typedText(_ query: String) -> String {
        let text = nameText(query)
        guard kind != .any else { return text }
        var words: [(range: Range<String.Index>, plain: String)] = []
        var start: String.Index?
        var plain = ""
        var quoted = false
        for index in text.indices {
            let char = text[index]
            if char.isWhitespace, !quoted {
                if let begun = start { words.append((begun..<index, plain)) }
                start = nil
                plain = ""
                continue
            }
            if start == nil { start = index }
            if char == "\"" { quoted.toggle() } else { plain.append(char) }
        }
        if let begun = start { words.append((begun..<text.endIndex, plain)) }
        let kept = words.filter { !$0.plain.hasPrefix("kind:") }
        return kept.count == words.count ? text : kept.map { text[$0.range] }.joined(separator: " ")
    }

    var tokens: String {
        [Self.extensionToken(extensions), kind.token, size.token, modified.token, folder.map { "in:" + Self.quoted($0) }, hidesHidden ? "hidden:no" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    var pills: String {
        var rest = self
        rest.folder = nil
        return rest.tokens
    }

    var narrowsResults: Bool {
        var rest = self
        rest.hidesHidden = false
        return !rest.tokens.isEmpty
    }
}
