import AppKit
import QuartzCore
import Testing
@testable import MacDuo

/// The window server widens what it redraws under a backdrop by the radius
/// the backdrop's first blur-like filter reports (`Update::all_backdrop_info`
/// → SkyLight `adjust_update_shapes_for_backdrops`). A `displacementMap`
/// reports `|inputAmount|` whatever it draws, so the bands carry one that
/// moves nothing, ahead of their blur (`WindowServerBlur.makeReach`): it must
/// leave every band's picture as the blur alone draws it.
@MainActor
struct GlassDisplacementFilterTests {

    static let size = CGSize(width: 320, height: 200)

    /// A band over the rig's desktop as `setRadius` sets it up, or with its
    /// blur alone, leaning when `lean`.
    static func render(withReach: Bool, lean: Bool, rig: GlassFidelityRig) throws -> GlassFidelityRig.Frame {
        let root = GlassMeshPlacementTests.desktop(rig: rig)
        let band = try #require(WindowServerBlur.makeBand(groupName: "reach-\(withReach)-\(lean)", samplesOtherWindows: false))
        band.anchorPoint = .zero
        band.contentsScale = 2
        band.frame = root.bounds
        WindowServerBlur.setRadius(8, of: band)
        if !withReach, let blur = WindowServerBlur.blurFilter(of: band) {
            band.filters = [blur]
        }
        root.addSublayer(band)
        if lean {
            let lean = GlassMeshPlacementTests.lean(for: size)
            GlassMesh.apply(GlassMeshPlacementTests.meshParts(lean: lean, frame: band.frame), to: band)
        }
        return try #require(rig.render(root))
    }

    @Test(.enabled(if: WindowServerBlur.isAvailable))
    func testTheReachFilterLeavesTheBandsPictureAlone() throws {
        let rig = try #require(GlassFidelityRig(screen: Self.size, scale: 2))
        for lean in [false, true] {
            let blurAlone = try Self.render(withReach: false, lean: lean, rig: rig)
            let withReach = try Self.render(withReach: true, lean: lean, rig: rig)
            let difference = GlassFidelityRig.difference(blurAlone, withReach)
            #expect(difference.mean < 1, "\(lean ? "leaning" : "flat"): \(difference)")
            #expect(difference.p99 <= 3, "\(lean ? "leaning" : "flat"): \(difference)")
        }
    }
}
