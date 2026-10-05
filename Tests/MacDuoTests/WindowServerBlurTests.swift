import AppKit
import QuartzCore
import Testing
@testable import MacDuo

/// Runs the private Core Animation path for real wherever it exists, so a
/// macOS release that changes it fails here rather than on a lid.
@MainActor
@Suite(.enabled(if: WindowServerBlur.isAvailable))
struct WindowServerBlurTests {

    @Test
    func testBandsShareOneCaptureOfOtherWindows() throws {
        let band = try #require(WindowServerBlur.makeBand(groupName: "test"))
        #expect(NSStringFromClass(type(of: band)) == "CABackdropLayer")
        #expect(band.value(forKey: "groupName") as? String == "test")
        #expect((band.value(forKey: "windowServerAware") as? NSNumber)?.boolValue == true)
    }

    @Test
    func testRadiusReachesTheFilter() throws {
        let band = try #require(WindowServerBlur.makeBand(groupName: "test"))
        WindowServerBlur.setRadius(12, of: band)
        let filters = try #require(band.filters)
        #expect(filters.count == 1)
        let filter = try #require(filters.first as? NSObject)
        #expect((filter.value(forKey: "inputRadius") as? NSNumber)?.doubleValue == 12)
        // A negative radius is clamped rather than handed on.
        WindowServerBlur.setRadius(-3, of: band)
        let clamped = try #require(band.filters?.first as? NSObject)
        #expect((clamped.value(forKey: "inputRadius") as? NSNumber)?.doubleValue == 0)
    }

    @Test
    func testGlassBuildsBandsAndShadeOnlyPastTheStartAngle() throws {
        let view = FrostedGlassView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        let root = try #require(view.layer)
        let tuning = DepthTuning(blurEvenness: 0, dimReach: 0.5, maxBlurRadius: 135, maxDim: 1)
        view.apply(progress: 0, tuning: tuning, gradient: BlurGradient())
        let visible = { root.sublayers?.filter { !$0.isHidden } ?? [] }
        #expect(visible().isEmpty)

        view.apply(progress: 0.5, tuning: tuning, gradient: BlurGradient())
        let bands = visible().filter { NSStringFromClass(type(of: $0)) == "CABackdropLayer" }
        #expect(!bands.isEmpty)
        #expect(bands.count <= FrostBandLayout().maximumBands)
        // Each band runs the radius its plan gives it.
        let planned = FrostBandLayout().bands(
            for: FrostedGlassView.blurProfile(progress: 0.5, tuning: tuning, gradient: BlurGradient(), height: 982),
            maximumRadius: 491
        )
        #expect(bands.count == planned.count)
        for (band, plan) in zip(bands, planned) {
            let filter = try #require(band.filters?.first as? NSObject)
            #expect((filter.value(forKey: "inputRadius") as? NSNumber)?.doubleValue == plan.radius)
            #expect(abs(band.frame.minY - plan.bottom) < 1e-9 && abs(band.frame.maxY - plan.top) < 1e-9)
        }
        // The darkening layer, above the bands, covers the glass and darkens
        // from the hinge up.
        let shade = try #require(visible().last as? CAGradientLayer)
        #expect(shade.frame == view.bounds)
        #expect(shade.startPoint == CGPoint(x: 0.5, y: 0) && shade.endPoint == CGPoint(x: 0.5, y: 1))
        let alphas = try #require(shade.colors as? [CGColor]).map(\.alpha)
        #expect(alphas.first! < alphas.last!)

        // Back at the start angle, everything hides and the screen shows as
        // it is.
        view.apply(progress: 0, tuning: tuning, gradient: BlurGradient())
        #expect(visible().isEmpty)
    }
}
