import SwiftUI
import WhereverInterface

private func statusBar(_ phase: IndexPhase, bootPhase: IndexPhase? = nil, disks: [String] = [], indexed: Int) -> some View {
    let state = IndexState(phase: phase, bootPhase: bootPhase, indexingDisks: disks, indexed: indexed)
    let index = IndexModel(client: PreviewSearchClient(state: state))
    return StatusBarView(index: index, model: index.makeModel()).frame(width: SearchMetrics.windowMinWidth)
}

#Preview("Status loading") { statusBar(.loading, indexed: 0) }
#Preview("Status crawling") { statusBar(.crawling, indexed: 100_000) }
#Preview("Status ready") { statusBar(.ready, indexed: 1_234_567) }
#Preview("Status live") { statusBar(.live, indexed: 1_234_568) }
#Preview("Status live, disks indexing") { statusBar(.crawling, bootPhase: .live, disks: ["Disk 1", "Disk 2"], indexed: 1_234_568) }
