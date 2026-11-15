import AppKit
import Foundation
import Quartz
import SwiftUI
import WhereverInterface

struct ResultActions {
    var open: (URL) -> Void
    var reveal: ([URL]) -> Void
    var quickLook: QuickLook
    var copyPath: (String) -> Void
    var recordOpen: (String) -> Void
    var confirmOpen: (Int) -> Bool
    var confirmReveal: (Int) -> Bool
    var refuse: () -> Void
    var inside: Inside?
    var previewItem: (SearchHit) -> URL? = { $0.fileURL }
    var dragItem: (SearchHit) -> (any NSPasteboardWriting)? = { $0.fileURL as NSURL }
    var moreMenu: ((NSMenu, SearchHit) -> Void)?
    var remove: (([SearchHit]) -> Void)?
    var accept: (([URL]) -> Void)?

    static let askLimit = 25

    struct Inside {
        var allows: (SearchHit) -> Bool
        var enter: (SearchHit) -> Void
        var enclosing: (() -> Void)?
    }

    struct QuickLook {
        var isOpen: () -> Bool
        var show: (URL?) -> Void
        var hide: () -> Void
        var refresh: (URL?) -> Void
    }

    static let missing = ResultActions(
        open: { _ in ResultActions.trap() }, reveal: { _ in ResultActions.trap() },
        quickLook: QuickLook(isOpen: { false }, show: { _ in ResultActions.trap() }, hide: { ResultActions.trap() }, refresh: { _ in ResultActions.trap() }),
        copyPath: { _ in ResultActions.trap() }, recordOpen: { _ in ResultActions.trap() },
        confirmOpen: { _ in ResultActions.trap() }, confirmReveal: { _ in ResultActions.trap() }, refuse: { ResultActions.trap() }
    )

    static let inert = ResultActions(
        open: { _ in }, reveal: { _ in }, quickLook: QuickLook(isOpen: { false }, show: { _ in }, hide: {}, refresh: { _ in }),
        copyPath: { _ in }, recordOpen: { _ in }, confirmOpen: { _ in false }, confirmReveal: { _ in false }, refuse: {}
    )

    static func live(
        client: any SearchClient, inside: Inside? = nil, preview: Bool = WhereverApp.usesPreviewServices, pasteboard: NSPasteboard = .general
    ) -> ResultActions {
        if preview { return .inert }
        return ResultActions(
            open: { url in
                if !NSWorkspace.shared.open(url) { NSSound.beep() }
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting($0) },
            quickLook: QuickLook(
                isOpen: { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible },
                show: { _ in QLPreviewPanel.shared().makeKeyAndOrderFront(nil) },
                hide: { QLPreviewPanel.shared().orderOut(nil) },
                refresh: { _ in QLPreviewPanel.shared().reloadData() }
            ),
            copyPath: { path in
                pasteboard.clearContents()
                pasteboard.setString(path, forType: .string)
            },
            recordOpen: { _ = try? client.recordOpen($0) },
            confirmOpen: {
                ask(String(localized: "Are you sure you want to open \($0) items?", table: "Results"), String(localized: "Open", table: "Results"))
            },
            confirmReveal: {
                ask(
                    String(localized: "Are you sure you want to show \($0) items in Finder?", table: "Results"),
                    String(localized: "Show in Finder", table: "Results")
                )
            },
            refuse: { NSSound.beep() },
            inside: inside
        )
    }

    private static func ask(_ message: String, _ confirm: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: confirm).setAccessibilityIdentifier("results-ask-confirm")
        let cancel = alert.addButton(withTitle: String(localized: "Cancel", table: "Normal"))
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("results-ask-cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func openAndRecord(_ hit: SearchHit) {
        open(hit.fileURL)
        recordOpen(hit.path)
    }

    private static func trap() -> Never {
        fatalError("Inject \\.resultActions into the environment before using it.")
    }
}

extension SearchHit {
    var fileURL: URL { URL(filePath: path, directoryHint: kind == .folder ? .isDirectory : .notDirectory) }
}

extension EnvironmentValues {
    @Entry var resultActions = ResultActions.missing
}
