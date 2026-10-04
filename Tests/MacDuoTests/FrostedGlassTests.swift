import Foundation
import Testing
@testable import MacDuo

struct FrostedGlassTests {

    private let degree = Double.pi / 180

    @Test
    func testFlatGlassKeepsAllTheLight() {
        let grid = FrostedGlass.brightnessGrid(lift: 0, width: 160, height: 100, columns: 5, rows: 4)
        #expect(grid.count == 20)
        #expect(grid.allSatisfy { $0 == 1 })
    }

    @Test(arguments: [10.0, 30, 60, 88])
    func testUnboundedPageGivesTheTiltedViewFactor(degrees: Double) {
        // From a point near the hinge of a vast page, the page is a half
        // plane, and the light that lands is (1 + cos lift) / 2.
        let brightness = FrostedGlass.brightness(x: 5e5, along: 1, width: 1e6, height: 1e6, lift: degrees * degree)
        #expect(abs(brightness - (1 + cos(degrees * degree)) / 2) < 1e-4)
    }

    @Test(arguments: [
        (5.0, 80.0, 95.0), (20, 3, 50), (30, 150, 40), (45, 80, 99), (70, 10, 10),
    ])
    func testClosedFormMatchesTracedRays(degrees: Double, x: Double, along: Double) {
        let closedForm = FrostedGlass.brightness(x: x, along: along, width: 160, height: 100, lift: degrees * degree)
        let traced = tracedBrightness(x: x, along: along, width: 160, height: 100, lift: degrees * degree)
        #expect(abs(closedForm - traced) < 0.004, "closed form \(closedForm), traced \(traced)")
    }

    @Test
    func testLiftedGlassDarkensTowardTheFarEdgeAndCorners() {
        let columns = 9, rows = 7
        let grid = FrostedGlass.brightnessGrid(lift: 40 * degree, width: 160, height: 100, columns: columns, rows: rows)
        let middle = columns / 2
        let hinge = grid[middle]
        let farEdge = grid[(rows - 1) * columns + middle]
        let farCorner = grid[(rows - 1) * columns]
        #expect(hinge > farEdge)
        #expect(farEdge > farCorner)
        // Left and right mirror each other.
        for row in 0..<rows {
            #expect(abs(grid[row * columns] - grid[row * columns + columns - 1]) < 1e-9)
        }
    }

    @Test
    func testMoreLiftLosesMoreLight() {
        var previous = 1.0
        for degrees in stride(from: 5.0, through: 85, by: 10) {
            let brightness = FrostedGlass.brightness(x: 80, along: 90, width: 160, height: 100, lift: degrees * degree)
            #expect(brightness < previous)
            previous = brightness
        }
    }

    @Test
    func testParallelBlurMatchesTheSheetsHalfContrastFrequency() {
        // A Gaussian halves contrast at sqrt(2 ln 2) / sigma.
        let sigma = FrostedGlass.gaussianSigmaPerHeight(lift: 0)
        #expect(abs(sqrt(2 * log(2.0)) / sigma - 1.2572) < 1e-9)
    }

    @Test(arguments: [(30.0, 1.198), (45, 1.110), (60, 0.995), (88, 0.749)])
    func testLiftedBlurMatchesTracedHalfContrastFrequency(degrees: Double, traced: Double) {
        // Half contrast frequencies of the traced spot, geometric mean of
        // across and along the hinge, from two million rays per angle.
        let sigma = FrostedGlass.gaussianSigmaPerHeight(lift: degrees * degree)
        let frequency = sqrt(2 * log(2.0)) / sigma
        #expect(abs(frequency / traced - 1) < 0.012)
    }

    @Test
    func testBlurGrowsWithHeightAndLift() {
        #expect(FrostedGlass.height(along: 0, lift: 0.5) == 0)
        #expect(FrostedGlass.height(along: 100, lift: .pi / 2) == 100)
        var previous = 0.0
        for degrees in stride(from: 0.0, through: 90, by: 15) {
            let sigma = FrostedGlass.gaussianSigmaPerHeight(lift: degrees * degree)
            #expect(sigma >= previous)
            previous = sigma
        }
    }

    /// The share of cosine weighted rays about the sheet normal that land on
    /// the page, over a stratified grid of directions. Independent of the
    /// closed form: it follows each ray to the page.
    private func tracedBrightness(x: Double, along: Double, width: Double, height: Double, lift: Double) -> Double {
        let side = 400
        let qy = along * cos(lift), qz = along * sin(lift)
        let normal = (y: sin(lift), z: -cos(lift))
        let tangent = (y: cos(lift), z: sin(lift))
        var landed = 0
        for i in 0..<side {
            for j in 0..<side {
                let u = (Double(i) + 0.5) / Double(side)
                let v = (Double(j) + 0.5) / Double(side)
                let r = u.squareRoot(), phi = 2 * Double.pi * v
                let up = (1 - u).squareRoot()
                let dx = r * cos(phi)
                let dy = tangent.y * r * sin(phi) + normal.y * up
                let dz = tangent.z * r * sin(phi) + normal.z * up
                guard dz < -1e-12 else { continue }
                let t = -qz / dz
                let px = x + dx * t, py = qy + dy * t
                if px >= 0, px <= width, py >= 0, py <= height { landed += 1 }
            }
        }
        return Double(landed) / Double(side * side)
    }
}
