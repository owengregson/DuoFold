import AppKit
import QuartzCore
import Testing
@testable import MacDuo

/// Where the mesh that leans a backdrop may live, drawn offscreen by
/// `CARenderer`, which runs the window server's renderer without the window
/// server's surfaces.
///
/// What the renderer does with meshes and backdrops (QuartzCore, macOS 26):
/// - A mesh on the backdrop itself (the glass today) captures the flat
///   screen under the layer's frame and draws the blurred capture through
///   the mesh. The capture is clipped to what is being redrawn, and the
///   damage is never mapped through the mesh, so a partial redraw reads
///   black outside the capture and leaves the moved content stale.
/// - A plain backdrop under a meshed parent captures from the parent's
///   detached surface, which has nothing behind it: offscreen it draws
///   nothing of the picture.
/// - `inverseMeshed` is Core Animation's one mesh-aware backdrop mode, and
///   the one the window server uses for the blur under a warped window
///   (`WS::CAWindowContent::ensure_background_blur_layer`): the updater
///   gives the backdrop's group the nearest meshed ancestor's mesh, the
///   capture covers that mesh's screen footprint and is drawn through the
///   inverse mesh, so after the ancestor's mesh the blur sits where the
///   screen is. It keeps a blur screen-locked under a warp, the opposite of
///   a leaning blur. Nested meshes do not change that: the capture is read
///   from below the nearest mesh-detached surface.
///
/// These draw each placement for the record and check the two facts an
/// offscreen render can show: a mesh on the backdrop leans the blur, and
/// `inverseMeshed` draws a blur that stays put.
@MainActor
struct GlassMeshPlacementTests {

    enum Placement: String, CaseIterable {
        case onBackdrop, onParent, onRasterizedParent, onRasterizedParentInverse, inverseUnderIdentityMesh
    }

    static let size = CGSize(width: 400, height: 240)
    static let radius = 8.0

    /// The strip's picture lands on a trapezoid: hinge along the bottom, top
    /// edge narrowed and lowered.
    static func lean(for size: CGSize) -> GlassLean {
        let w = size.width, h = size.height
        return GlassLean(
            corners: [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w * 0.86, y: h * 0.82), CGPoint(x: w * 0.14, y: h * 0.82)],
            screenSize: size,
            padded: CGRect(origin: .zero, size: size)
        )
    }

    /// A mesh carrying a layer's unit square row by row onto the lean.
    static func meshParts(lean: GlassLean, frame: CGRect, rows: Int = 16) -> (vertices: [GlassMesh.Vertex], faces: [GlassMesh.Face]) {
        let w = Double(lean.screenSize.width), h = Double(lean.screenSize.height)
        let grid = GlassLean.Grid(rows: (0...rows).map { row in
            let v = Double(row) / Double(rows)
            return [GlassLean.Vertex(from: CGPoint(x: 0, y: v), picture: CGPoint(x: 0, y: v * h)),
                    GlassLean.Vertex(from: CGPoint(x: 1, y: v), picture: CGPoint(x: w, y: v * h))]
        })
        return lean.meshParts(for: grid, layerFrame: frame)
    }

    static func desktop(rig: GlassFidelityRig) -> CALayer {
        let root = CALayer()
        root.anchorPoint = .zero
        root.frame = CGRect(origin: .zero, size: size)
        let desktop = CALayer()
        desktop.anchorPoint = .zero
        desktop.frame = root.bounds
        desktop.contents = rig.picture
        desktop.contentsScale = 2
        root.addSublayer(desktop)
        return root
    }

    /// A blurred backdrop over the rig's desktop, leaning by `placement`.
    static func render(_ placement: Placement, rig: GlassFidelityRig) throws -> GlassFidelityRig.Frame {
        let root = desktop(rig: rig)
        let band = try #require(WindowServerBlur.makeBand(groupName: "placement-\(placement.rawValue)", samplesOtherWindows: false))
        band.anchorPoint = .zero
        band.contentsScale = 2
        band.frame = root.bounds
        WindowServerBlur.setRadius(radius, of: band)
        let lean = Self.lean(for: size)
        switch placement {
        case .onBackdrop:
            root.addSublayer(band)
            GlassMesh.apply(meshParts(lean: lean, frame: band.frame), to: band)
        case .onParent, .onRasterizedParent, .onRasterizedParentInverse, .inverseUnderIdentityMesh:
            let parent = CALayer()
            parent.anchorPoint = .zero
            parent.frame = root.bounds
            parent.contentsScale = 2
            if placement != .onParent {
                parent.shouldRasterize = true
                parent.rasterizationScale = 2
            }
            if placement == .onRasterizedParentInverse {
                band.setValue(true, forKey: "inverseMeshed")
            }
            if placement == .inverseUnderIdentityMesh {
                band.setValue(true, forKey: "inverseMeshed")
                let flat = CALayer()
                flat.anchorPoint = .zero
                flat.frame = parent.bounds
                flat.contentsScale = 2
                GlassMesh.apply(meshParts(lean: GlassLean.flat(screenSize: size, pixelScale: 1), frame: flat.frame), to: flat)
                flat.addSublayer(band)
                parent.addSublayer(flat)
            } else {
                parent.addSublayer(band)
            }
            root.addSublayer(parent)
            GlassMesh.apply(meshParts(lean: lean, frame: parent.frame), to: parent)
        }
        return try #require(rig.render(root))
    }

    @Test(.enabled(if: GlassMesh.isAvailable && WindowServerBlur.isAvailable))
    func testWhereAMeshMayLeanABackdrop() throws {
        let rig = try #require(GlassFidelityRig(screen: Self.size, scale: 2))
        let unleaned = try #require(rig.render(Self.desktop(rig: rig)))
        var frames: [Placement: GlassFidelityRig.Frame] = [:]
        for placement in Placement.allCases {
            let frame = try Self.render(placement, rig: rig)
            frames[placement] = frame
            print("mesh placement \(placement.rawValue): against the flat desktop \(GlassFidelityRig.difference(unleaned, frame))")
            if let directory = GlassFidelityTests.directory {
                GlassFidelityRig.write([unleaned, frame, GlassFidelityRig.amplified(unleaned, frame, gain: 8)],
                                       to: URL(fileURLWithPath: directory).appendingPathComponent("placement-\(placement.rawValue).png"))
            }
        }
        let onBackdrop = try #require(frames[.onBackdrop])
        // A mesh on the backdrop leans the blur: a real change to the picture.
        #expect(GlassFidelityRig.difference(onBackdrop, unleaned).mean > 4)
        // A plain backdrop under a meshed parent shows nothing of the
        // picture offscreen: the frame is the flat desktop.
        for placement in [Placement.onParent, .onRasterizedParent, .inverseUnderIdentityMesh] {
            #expect(GlassFidelityRig.difference(try #require(frames[placement]), unleaned).mean < 0.5, "\(placement.rawValue)")
        }
        // inverseMeshed draws a blur, but one that stays where the screen
        // is: inside the trapezoid it is the flat blur, not the leaning one.
        let inverse = try #require(frames[.onRasterizedParentInverse])
        let w = rig.pixelWidth, h = rig.pixelHeight
        let inside = { (x: Int, y: Int) in x > w / 4 && x < w * 3 / 4 && y > h * 3 / 10 && y < h * 9 / 10 }
        let blurredFlat = try #require(rig.render({
            let root = Self.desktop(rig: rig)
            let band = WindowServerBlur.makeBand(groupName: "placement-flat", samplesOtherWindows: false)!
            band.anchorPoint = .zero
            band.contentsScale = 2
            band.frame = root.bounds
            WindowServerBlur.setRadius(Self.radius, of: band)
            root.addSublayer(band)
            return root
        }()))
        let againstFlatBlur = GlassFidelityRig.difference(inverse, blurredFlat, include: inside)
        let againstLean = GlassFidelityRig.difference(inverse, onBackdrop, include: inside)
        print("inverseMeshed inside the trapezoid: against the flat blur \(againstFlatBlur); against the leaning blur \(againstLean)")
        #expect(againstFlatBlur.mean < againstLean.mean / 3)
    }
}
