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
    func testGlassBuildsBandsAndShadeOnlyOnceLifted() throws {
        let view = FrostedGlassView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        let root = try #require(view.layer)
        view.apply(lift: 0, frost: 0.7, darkness: 1)
        let visible = { root.sublayers?.filter { !$0.isHidden } ?? [] }
        #expect(visible().isEmpty)

        view.apply(lift: 20 * .pi / 180, frost: 0.7, darkness: 1)
        let bands = visible().filter { NSStringFromClass(type(of: $0)) == "CABackdropLayer" }
        #expect(!bands.isEmpty)
        #expect(bands.count <= FrostBandLayout().maximumBands)
        // The darkening layer, above the bands, reaches past the glass.
        let shade = try #require(visible().last)
        #expect(shade.contents != nil)
        #expect(shade.frame.minY < 0 && shade.frame.maxY > 982)

        // Flat again, everything hides and the screen shows as it is.
        view.apply(lift: 0, frost: 0.7, darkness: 1)
        #expect(visible().isEmpty)
    }
}
