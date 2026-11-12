import AppKit
import SwiftUI

struct HotkeyRecorder: View {
    @ObservedObject var model: HotkeyModel
    var post: Announcer.Post = Announcer.voiceOver
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    private enum Metrics {
        static let buttonMinWidth: CGFloat = 140
    }

    private var title: Text {
        if model.isRecording { return Text("Press a shortcut…", tableName: "Hotkey") }
        if let hotkey = model.hotkey { return Text(verbatim: hotkey.displayString) }
        return Text("Record Shortcut", tableName: "Hotkey")
    }

    private var problem: String? {
        if let refusal = model.refusal { return refusal.message }
        return model.registrationFailed && !model.isRecording
            ? String(localized: "Wherever could not register this shortcut. Try another.", table: "Hotkey") : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
            Button {
                if model.isRecording { model.stopRecording() } else { model.startRecording() }
            } label: {
                title.font(textSize.formText).frame(minWidth: textSize.width(Metrics.buttonMinWidth))
            }
            .accessibilityLabel(Text("Launcher shortcut", tableName: "Hotkey"))
            .accessibilityValue(problem.map { title + Text(verbatim: " " + $0) } ?? title)
            .accessibilityHint(Text("Click, then press the new shortcut. Escape cancels. Delete removes it.", tableName: "Hotkey"))
            if let problem {
                Text(verbatim: problem).font(textSize.caption).foregroundStyle(Color(nsColor: Theme.problem))
            }
        }
        .background(ResignKeyWatcher(model: model))
        .background(ProblemNotice(text: problem, post: post).frame(width: 0, height: 0).accessibilityHidden(true))
        .onDisappear { model.stopRecording() }
    }
}

extension Hotkey.Refusal {
    var message: String {
        switch self {
        case .needsModifier: String(localized: "Hold Control, Option or Command with the key.", table: "Hotkey")
        case .systemKey: String(localized: "macOS already uses this shortcut.", table: "Hotkey")
        case .appKey: String(localized: "Wherever already uses this shortcut.", table: "Hotkey")
        case .unsupportedKey: String(localized: "Use a letter, number or symbol key.", table: "Hotkey")
        }
    }
}

private struct ProblemNotice: NSViewRepresentable {
    let text: String?
    let post: Announcer.Post

    func makeNSView(context: Context) -> NoticeAnnouncer { NoticeAnnouncer() }

    func updateNSView(_ view: NoticeAnnouncer, context: Context) {
        view.post = post
        view.text = text
        view.announce()
    }
}

private struct ResignKeyWatcher: NSViewRepresentable {
    let model: HotkeyModel

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        model.recorderArea = view
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) { view.onResign = { [weak model] in model?.stopRecording() } }

    final class WatcherView: NSView {
        var onResign: () -> Void = {}

        override func viewDidMoveToWindow() {
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: NSWindow.didResignKeyNotification, object: window)
        }

        @objc private func resigned() { onResign() }
    }
}
