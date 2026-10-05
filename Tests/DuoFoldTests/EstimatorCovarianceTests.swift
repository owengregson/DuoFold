import Foundation
import Testing
@testable import DuoFold

/// A lid held still reads the same for a while, so the filter sees a new
/// reading only now and then. It must keep following the readings however
/// long the gaps between them.
struct EstimatorCovarianceTests {

    @Test
    func testTheEstimateFollowsALidAfterLongStillSpells() {
        var estimator = LidAngleEstimator(tuning: .sensor(resolution: 0.01))
        var t = 0.0
        var worst = 0.0
        // Held still: the same reading, polled at 30 a second, changing by
        // a hundredth now and then, at gaps of a quarter to half a second.
        var angle = 100.0
        for spell in 0..<200 {
            let gap = 0.25 + 0.25 * Double(spell % 5) / 4
            let polls = Int(gap * 30)
            for _ in 0..<polls {
                t += 1.0 / 30
                estimator.observe(angle, at: t)
            }
            angle += spell % 2 == 0 ? 0.01 : -0.01
            // Now and then the lid moves a little.
            if spell % 40 == 39 {
                for step in 0..<10 {
                    t += 1.0 / 30
                    estimator.observe(angle - Double(step), at: t)
                }
                angle -= 9
            }
            if let latest = estimator.latest { worst = max(worst, abs(latest.angle - angle)) }
        }
        #expect(worst < 5, "the estimate strayed \(worst) degrees from the lid")
    }
}
