import Foundation
import Testing
@testable import DuoFold

/// A lid resting still, read with the sensor's noise: does the angle the
/// effect draws hold still, or wander a hair from frame to frame? Only a
/// report: run with `FIDELITY_PROBE` set.
struct StillLidJitterReport {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FIDELITY_PROBE"] != nil))
    func testTheDrawnAngleOfAStillLid() {
        var estimator = LidAngleEstimator(tuning: .sensor(resolution: 0.01))
        var random = SystemRandomNumberGenerator()
        func noise() -> Double {
            // Gaussian, sigma 0.03 degrees, rounded to the sensor's hundredths.
            let u1 = Double.random(in: 1e-9..<1, using: &random), u2 = Double.random(in: 0..<1, using: &random)
            return 0.03 * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        let refresh = 0.1043
        var reading = 95.0, nextSample = 0.0, t = 0.0, frame = 0.0
        var drawn: [Double] = []
        while t < 20 {
            t += 1.0 / 30
            if t >= nextSample { reading = ((95 + noise()) * 100).rounded() / 100; nextSample += refresh }
            estimator.observe(reading, at: t)
            while frame < t { frame += 1.0 / 120; drawn.append(estimator.frame(at: frame + 1.0 / 120).angle) }
        }
        let settled = Array(drawn.dropFirst(240))
        var changes = 0, biggest = 0.0
        for (a, b) in zip(settled, settled.dropFirst()) where abs(b - a) > 1e-9 {
            changes += 1
            biggest = max(biggest, abs(b - a))
        }
        print(String(format: "still lid: %d of %d frames change the drawn angle; biggest step %.4f deg; range %.4f deg",
                     changes, settled.count - 1, biggest, (settled.max() ?? 0) - (settled.min() ?? 0)))
    }
}
