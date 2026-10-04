import Foundation
import Testing
@testable import MacDuo

struct FrostBandLayoutTests {

    private let layout = FrostBandLayout()

    @Test
    func testNoBandsWithoutVisibleBlur() {
        #expect(layout.bands(radiusPerHeight: 0, height: 900, maximumRadius: 450).isEmpty)
        // The whole glass blurs less than the smallest visible radius.
        #expect(layout.bands(radiusPerHeight: 0.0004, height: 900, maximumRadius: 450).isEmpty)
    }

    @Test(arguments: [0.004, 0.04, 0.15, 0.6])
    func testRadiiGrowInEvenSteps(radiusPerHeight: Double) {
        let bands = layout.bands(radiusPerHeight: radiusPerHeight, height: 900, maximumRadius: 450)
        #expect(!bands.isEmpty)
        #expect(bands.count <= layout.maximumBands)
        let steps = zip(bands, bands.dropFirst()).map { lower, upper in
            (upper.radius + layout.blurFloor) / (lower.radius + layout.blurFloor)
        }
        for step in steps {
            #expect(step > 1)
            // Even steps, no bigger than the ratio unless the bands ran out.
            #expect(abs(step - steps[0]) < 1e-9)
            #expect(step <= layout.ratio + 1e-9 || bands.count == layout.maximumBands)
        }
    }

    @Test
    func testEachBandIsExactWhereItTurnsOpaque() {
        let k = 0.15
        let bands = layout.bands(radiusPerHeight: k, height: 900, maximumRadius: 450)
        for (index, band) in bands.enumerated() {
            let knot = band.fade.last!
            #expect(knot.opacity == 1)
            #expect(abs(knot.position * k - band.radius) < 1e-9)
            #expect(band.fade.first!.opacity < 1e-9)
            if index > 0 {
                // It starts fading in where the band below turns opaque.
                #expect(abs(band.fade.first!.position - bands[index - 1].fade.last!.position) < 1e-9)
            }
        }
        #expect(bands.first!.radius == layout.minimumRadius)
        #expect(bands.first!.fade.first!.position == 0)
    }

    @Test
    func testTheTopBandReachesTheTop() {
        let k = 0.04
        let bands = layout.bands(radiusPerHeight: k, height: 900, maximumRadius: 450)
        #expect(abs(bands.last!.radius - k * 900) < 1e-9)
        #expect(bands.last!.top == 900)
    }

    @Test
    func testTheMaximumRadiusCapsTheBlur() {
        let bands = layout.bands(radiusPerHeight: 0.6, height: 900, maximumRadius: 120)
        #expect(abs(bands.last!.radius - 120) < 1e-9)
        #expect(abs(bands.last!.fade.last!.position - 200) < 1e-9)
        #expect(bands.last!.top == 900)
    }

    @Test
    func testFramesCaptureAMarginAndStayOnTheGlass() {
        let bands = layout.bands(radiusPerHeight: 0.15, height: 900, maximumRadius: 450)
        for band in bands {
            #expect(band.bottom >= 0)
            #expect(band.top <= 900)
            let margin = layout.marginRadii * band.radius
            #expect(band.bottom <= max(band.fade.first!.position - margin, 0) + 1e-9)
            #expect(band.top >= band.fade.last!.position)
        }
    }

    @Test
    func testFadesHalveContrastWhereTheTrueBlurDoes() {
        let k = 0.15
        let bands = layout.bands(radiusPerHeight: k, height: 900, maximumRadius: 450)
        for (lower, upper) in zip(bands, bands.dropFirst()) {
            var previous = 0.0
            for stop in upper.fade {
                let target = stop.position * k
                // What a Gaussian of each radius keeps where one of `target`
                // keeps half.
                let kept = { (radius: Double) in pow(2, -(radius / target) * (radius / target)) }
                let mixed = (1 - stop.opacity) * kept(lower.radius) + stop.opacity * kept(upper.radius)
                #expect(abs(mixed - 0.5) < 1e-6)
                #expect(stop.opacity >= previous)
                previous = stop.opacity
            }
        }
    }
}
