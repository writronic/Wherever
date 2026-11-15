import Foundation

final class HelperWake {
    static let tick: TimeInterval = 3600
    static let checkInterval: TimeInterval = 86400
    static let mountDelay: TimeInterval = 1
    static let answersThatAct = ["notification", "index"]

    private let sender: HelperSender
    private let wherever: UserDefaults
    private let own: UserDefaults
    private let synchronize: () -> Void
    private let later: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    private var mounts: [String] = []

    init(
        sender: HelperSender, wherever: UserDefaults, own: UserDefaults, synchronize: @escaping () -> Void = { HelperLink.synchronize() },
        later: @escaping (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    ) {
        self.sender = sender
        self.wherever = wherever
        self.own = own
        self.synchronize = synchronize
        self.later = later
    }

    static func checkDue(checksOn: Bool, lastCheck: Date?, lastWake: Date?, now: Date) -> Bool {
        guard checksOn else { return false }
        guard let last = [lastCheck, lastWake].compactMap({ $0 }).filter({ $0 <= now }).max() else { return true }
        return now.timeIntervalSince(last) >= checkInterval
    }

    static func mountWakes(answer: String?) -> Bool {
        answersThatAct.contains(answer ?? "")
    }

    func timerFired(now: Date = Date()) {
        synchronize()
        let due = Self.checkDue(
            checksOn: wherever.bool(forKey: HelperLink.Key.automaticChecks),
            lastCheck: wherever.object(forKey: HelperLink.Key.lastUpdateCheck) as? Date,
            lastWake: own.object(forKey: HelperLink.Key.lastWake) as? Date,
            now: now
        )
        guard due else { return }
        own.set(now, forKey: HelperLink.Key.lastWake)
        sender.wake()
    }

    func diskMounted(at path: String) {
        synchronize()
        guard Self.mountWakes(answer: wherever.string(forKey: HelperLink.Key.newDiskChoice)) else { return }
        if mounts.isEmpty { later(Self.mountDelay) { [weak self] in self?.sendMounts() } }
        mounts.append(path)
    }

    private func sendMounts() {
        let paths = mounts
        mounts = []
        sender.wake(mounted: paths)
    }
}
