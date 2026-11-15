import Foundation

final class TimingAnchor {}

let timingMode = (try? String(
    contentsOf: Bundle(for: TimingAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("wherever-measure"),
    encoding: .utf8
))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "gate"

func timingLine(_ label: String, _ times: [Duration], warmup: Int, limit: Duration?) -> String {
    let ms = times.map { $0 / .milliseconds(1) }.sorted()
    let p50 = ms[ms.count / 2]
    let p95 = ms[(ms.count * 95 + 99) / 100 - 1]
    let limitMs = timingMode == "selftest" ? 0 : limit.map { $0 / .milliseconds(1) }
    let shown = limitMs.map { String(format: "%.2f", $0) } ?? "none"
    let verdict = limitMs.map { p95 > $0 ? "LIMIT OVER" : "ok" } ?? "report"
    var loads = [Double](repeating: 0, count: 3)
    _ = getloadavg(&loads, 3)
    #if DEBUG
    let configuration = "Debug"
    #else
    let configuration = "Release"
    #endif
    return "timing: \(label) p50 \(String(format: "%.3f", p50)) p95 \(String(format: "%.3f", p95)) limit \(shown) \(verdict) | \(configuration) | "
        + "\(timingMode) \(times.count) runs, \(warmup) warmup | load \(String(format: "%.2f/%.2f/%.2f", loads[0], loads[1], loads[2]))"
}
