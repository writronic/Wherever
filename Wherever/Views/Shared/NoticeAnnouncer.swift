import AppKit

final class NoticeAnnouncer: NSView {
    var text: String?
    var post: Announcer.Post = Announcer.voiceOver
    private var announced: String?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        announce()
    }

    func announce() {
        guard let window, text != announced else { return }
        announced = text
        if let text { post(window, text) }
    }
}
