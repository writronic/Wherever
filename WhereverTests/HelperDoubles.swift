import Foundation
@testable import Wherever

struct FakeHelperPost: Equatable {
    let name: Notification.Name
    let object: String
}

struct FakeHelperOpen: Equatable {
    let app: URL
    let arguments: [String]
    let activates: Bool
}

final class FakeHelperSeams {
    let parent: URL
    var state = HelperSender.WhereverState.closed
    private(set) var posts: [FakeHelperPost] = []
    private(set) var opens: [FakeHelperOpen] = []
    private(set) var mounted: [[String]] = []
    private var waiting: [() -> Void] = []

    init(parent: URL = URL(fileURLWithPath: "/Applications/Wherever.app")) {
        self.parent = parent
    }

    var sender: HelperSender {
        HelperSender(
            parent: parent,
            state: { [unowned self] in state },
            whenLaunched: { [unowned self] work in waiting.append(work) },
            post: { [unowned self] name, object in posts.append(FakeHelperPost(name: name, object: object)) },
            open: { [unowned self] app, arguments, activates in
                opens.append(FakeHelperOpen(app: app, arguments: arguments, activates: activates))
            },
            postMounted: { [unowned self] paths, _ in mounted.append(paths) }
        )
    }

    func finishLaunching() {
        state = .running
        let work = waiting
        waiting = []
        work.forEach { $0() }
    }
}
