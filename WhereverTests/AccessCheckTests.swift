import Foundation
import Testing
@testable import Wherever
import WhereverKit

@Suite struct AccessCheckTests {
    @Test func theInProcessCheckAgreesWithTheFreshChildProbe() throws {
        let child = AccessModel.probeInChild()
        try #require(child != .failed, "the child probe failed")
        #expect(WhereverServices.hasFullDiskAccess() == (child == .granted), "child \(child)")
    }
}
