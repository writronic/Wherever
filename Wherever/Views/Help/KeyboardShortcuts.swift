import Foundation

struct ShortcutRow {
    let keys: String
    let action: String
}

struct ShortcutSection {
    let title: String
    let rows: [ShortcutRow]
}

enum KeyboardShortcuts {
    static func sections(hotkey: Hotkey?) -> [ShortcutSection] {
        let space = String(localized: "Space", table: "Hotkey")
        return [
            ShortcutSection(title: String(localized: "Search window", table: "Help"), rows: [
                ShortcutRow(keys: "↑ ↓", action: String(localized: "Move through the results", table: "Help")),
                ShortcutRow(keys: "↩", action: String(localized: "Open the selected file", table: "Help")),
                ShortcutRow(keys: "↩", action: String(localized: "In File content, start Search Content when no text is left", table: "Help")),
                ShortcutRow(keys: "⌘↩", action: String(localized: "Show the selected file in Finder", table: "Help")),
                ShortcutRow(keys: "⌘↓", action: String(localized: "Show archive contents", table: "Help")),
                ShortcutRow(keys: space, action: String(localized: "Show or close Quick Look", table: "Help")),
                ShortcutRow(keys: "⌘C", action: String(localized: "Copy the path of the selected file", table: "Help")),
                ShortcutRow(keys: "⎋", action: String(localized: "Clear the search text, then the filters", table: "Help")),
                ShortcutRow(keys: "⌘N", action: String(localized: "Open a new window", table: "Help")),
                ShortcutRow(keys: "⌥⌘I", action: String(localized: "Show or hide the inspector", table: "Help")),
                ShortcutRow(keys: "⇧⌘.", action: String(localized: "Hide or show invisible files", table: "Help")),
                ShortcutRow(keys: "⌘,", action: String(localized: "Open Settings", table: "Help")),
                ShortcutRow(keys: "⌘Q", action: String(localized: "Quit Wherever", table: "Help")),
            ]),
            ShortcutSection(title: String(localized: "Wherever search", table: "Help"), rows: [
                ShortcutRow(keys: hotkey?.displayString ?? "–", action: String(localized: "Open or close Wherever search", table: "Help")),
                ShortcutRow(keys: "↑ ↓", action: String(localized: "Move through the results", table: "Help")),
                ShortcutRow(keys: "↩", action: String(localized: "Open the selected file and close Wherever search", table: "Help")),
                ShortcutRow(keys: "⌘↩", action: String(localized: "Show the selected file in Finder and close Wherever search", table: "Help")),
                ShortcutRow(keys: "⌘↓", action: String(localized: "Show archive contents in Wherever", table: "Help")),
                ShortcutRow(keys: space, action: String(localized: "Show or close the preview", table: "Help")),
                ShortcutRow(keys: "⌘C", action: String(localized: "Copy the path of the selected file", table: "Help")),
                ShortcutRow(keys: "⌘N", action: String(localized: "Show all results in a Wherever window", table: "Help")),
                ShortcutRow(keys: "⎋", action: String(localized: "Clear the search text, then close Wherever search", table: "Help")),
                ShortcutRow(keys: "⌘W", action: String(localized: "Close Wherever search", table: "Help")),
            ]),
            ShortcutSection(title: String(localized: "Archive window", table: "Help"), rows: [
                ShortcutRow(keys: "↩", action: String(localized: "Open the item, the folder or the archive", table: "Help")),
                ShortcutRow(keys: "⌘↓", action: String(localized: "Open the item, the folder or the archive", table: "Help")),
                ShortcutRow(keys: "⌘↑", action: String(localized: "Go to the enclosing folder", table: "Help")),
                ShortcutRow(keys: space, action: String(localized: "Show or close Quick Look", table: "Help")),
                ShortcutRow(keys: "⌘↩", action: String(localized: "Show the archive in Finder", table: "Help")),
                ShortcutRow(keys: "⌘C", action: String(localized: "Copy the path inside the archive", table: "Help")),
                ShortcutRow(keys: "⎋", action: String(localized: "Clear the search text", table: "Help")),
                ShortcutRow(keys: "⌫", action: String(localized: "Delete the selected items", table: "Help")),
                ShortcutRow(keys: "⌘S", action: String(localized: "Save the changes", table: "Help")),
                ShortcutRow(keys: "⇧⌘S", action: String(localized: "Save the archive under a new name", table: "Help")),
                ShortcutRow(keys: "⌘Z", action: String(localized: "Undo the last change", table: "Help")),
                ShortcutRow(keys: "⇧⌘Z", action: String(localized: "Redo the last change", table: "Help")),
            ]),
            ShortcutSection(title: String(localized: "Search operators", table: "Help"), rows: [
                example(#"report"#, sets: "word", String(localized: "Names that hold the word, its letters side by side", table: "Help")),
                example(#"'report"#, sets: "exact", String(localized: "Names that hold these exact letters", table: "Help")),
                example(#"^report"#, sets: "prefix", String(localized: "Names that begin with the word", table: "Help")),
                example(#"report$"#, sets: "suffix", String(localized: "Names that end with the word", table: "Help")),
                example(#"^report$"#, sets: "whole-name", String(localized: "Names that are exactly the word", table: "Help")),
                example(#"!draft"#, sets: "exclude", String(localized: "Leave out names that hold the word", table: "Help")),
                example(#""annual report""#, sets: "phrase", String(localized: "Search the words together, space included", table: "Help")),
                example(#"projects/report"#, sets: "under", String(localized: "Names inside a folder whose name matches the first word", table: "Help")),
                example(#"cardinal*.dmg"#, sets: "wildcard", String(localized: "Whole names; * is any letters, ? is one letter. Type ' first to find * or ? as letters", table: "Help")),
                example(#"*.{jpg,png}"#, sets: "glob-ext", String(localized: "Files with one of these extensions", table: "Help")),
                example(#"!*.log"#, sets: "exclude-ext", String(localized: "Leave out files with this extension", table: "Help")),
                example(#"ext:pdf,docx"#, sets: "ext", String(localized: "Files with one of these extensions", table: "Help")),
                example(#"type:image"#, sets: "type", String(localized: "Images; also video, audio, doc, code, archive, font and app", table: "Help")),
                example(#"kind:folder"#, sets: "kind", String(localized: "Folders only; also file and link", table: "Help")),
                example(#"in:~/Documents"#, sets: "in", String(localized: "Only inside this folder", table: "Help")),
                example(#"size:>10mb"#, sets: "size", String(localized: "Size in kb, mb, gb or tb; also <1mb and 1mb..100mb", table: "Help")),
                example(#"modified:<7d"#, sets: "modified", String(localized: "Changed within s, m (minutes), h, d, w, mo or y; also 1w..1mo", table: "Help")),
                example(#"mtime:2w"#, sets: "mtime", String(localized: "The same as modified:", table: "Help")),
                example(#"hidden:no"#, sets: "hidden", String(localized: "Leave out invisible files", table: "Help")),
                example(#"re:^IMG_\d+"#, sets: "re", String(localized: "Names that match a regular expression", table: "Help")),
                example(#"glob:report-??.pdf"#, sets: "glob", String(localized: "Whole names that match a pattern of *, ? and [ ]", table: "Help")),
                example(#"begins:annual"#, sets: "begins", String(localized: "Names that begin with this text", table: "Help")),
                example(#"ends:2026"#, sets: "ends", String(localized: "Names that end with this text", table: "Help")),
                example(#"whole:README.md"#, sets: "whole", String(localized: "Names that are exactly this text", table: "Help")),
            ]),
        ]
    }

    private static func example(_ text: String, sets _: String, _ action: String) -> ShortcutRow {
        ShortcutRow(keys: text, action: action)
    }
}
