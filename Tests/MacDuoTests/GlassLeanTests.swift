import AppKit
import QuartzCore
import Testing
@testable import MacDuo

/// The glass leans exactly as the captured picture does, and its edges and
/// margin come out as the captured picture's black margin makes them.
@MainActor
struct GlassLeanTests {

    static let screen = CGSize(width: 1512, height: 982)

    static func lean(progress: Double) -> GlassLean {
        let start = 85.0, span = 60.0, recession = 0.6
        let ramp = LidEffectRamp(startAngle: start, span: span, maxLean: 70, recession: recession)
        let corners = DepthGeometry().corners(
            startAngle: start, currentAngle: ramp.pictureAngle(for: start - progress * span),
            viewingDistanceRatio: 6, recession: recession, screenSize: screen
        )
        return GlassLean(corners: corners, screenSize: screen, padded: DepthRenderer.paddedFrame(screenSize: screen, pixelScale: 2))
    }

    private func isClose(_ a: CGPoint, _ b: CGPoint, within tolerance: Double = 1e-6) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    @Test
    func testThePictureLandsOnTheCapturedPicturesCorners() {
        let lean = Self.lean(progress: 0.7)
        let picture = [CGPoint(x: 0, y: 0), CGPoint(x: Self.screen.width, y: 0),
                       CGPoint(x: Self.screen.width, y: Self.screen.height), CGPoint(x: 0, y: Self.screen.height)]
        for (point, corner) in zip(picture, lean.corners) {
            #expect(isClose(lean.screenPoint(point), corner, within: 1e-6))
        }
        // Rows stay level and the hinge stays put, as the lean is a tilt
        // about the hinge.
        #expect(abs(lean.screenPoint(CGPoint(x: 100, y: 500)).y - lean.screenPoint(CGPoint(x: 1400, y: 500)).y) < 1e-6)
        #expect(isClose(lean.screenPoint(CGPoint(x: 300, y: 0)), CGPoint(x: 300, y: 0)))
        #expect(!lean.isFlat)
        #expect(Self.lean(progress: 0).isFlat)
    }

    @Test
    func testTheMarginIsTheCapturedPicturesOwn() {
        // The blur stack pads the picture to a multiple of its coarsest mip,
        // by at least 120 points a side.
        let padded = DepthRenderer.paddedFrame(screenSize: Self.screen, pixelScale: 2)
        #expect(padded.minX <= -120 && padded.maxX >= Self.screen.width + 120)
        #expect(padded.minY <= -120 && padded.maxY >= Self.screen.height + 120)
        #expect(abs(padded.midX - Self.screen.width / 2) < 1)
    }

    @Test
    func testABandsMeshCoversItsRowsAndStretchesItsEdgesIntoTheMargin() {
        let lean = Self.lean(progress: 0.5)
        let grid = lean.pictureGrid(bottom: 200, top: 982, rows: 8)
        // Its own rows, then one up to the end of the margin, as it reaches
        // the top.
        #expect(grid.rows.count == 10)
        for row in grid.rows {
            #expect(row.count == 4)
            // The outer columns read the layer's own edges.
            #expect(row[0].from.x == 0 && row[1].from.x == 0 && row[2].from.x == 1 && row[3].from.x == 1)
            #expect(row[0].picture.x < lean.padded.minX && row[3].picture.x > lean.padded.maxX)
        }
        #expect(grid.rows.last!.picture(0).y > lean.padded.maxY)
        #expect(grid.rows.last!.allSatisfy { $0.from.y == 1 })
        // A band short of the top stops at its own top.
        #expect(lean.pictureGrid(bottom: 0, top: 400, rows: 4).rows.count == 5)

        let frame = CGRect(x: 0, y: 200, width: Self.screen.width, height: 782)
        let parts = lean.meshParts(for: grid, layerFrame: frame)
        #expect(parts.vertices.count == 40 && parts.faces.count == 27)
        // Each vertex lands where the lean puts its picture point, in the
        // layer's own unit square.
        let vertex = parts.vertices[5]
        let expected = lean.screenPoint(grid.rows[1][1].picture)
        #expect(abs(vertex.to.0 * frame.width + frame.minX - expected.x) < 1e-9)
        #expect(abs(vertex.to.1 * frame.height + frame.minY - expected.y) < 1e-9)
    }

    @Test
    func testEdgesDarkenByTheShareOfTheBlurOnTheMargin() {
        let profile = FrostedGlassView.edgeProfile()
        #expect(profile.first!.position == 0 && profile.last!.position == 1)
        // From clear well inside to black well out. At the edge half the
        // light is kept, which is 0.5^(1 / 2.2) of the encoded value.
        #expect(profile.first!.opacity < 1e-4 && profile.last!.opacity > 1 - 1e-2)
        #expect(abs(profile[profile.count / 2].opacity - (1 - pow(0.5, 1 / 2.2))) < 1e-12)
        for (a, b) in zip(profile, profile.dropFirst()) { #expect(b.opacity > a.opacity) }
        // One sigma inside, a Gaussian has 84.1% of itself on the picture.
        let oneInside = profile.min { abs($0.position - 0.375) < abs($1.position - 0.375) }!
        #expect(abs(oneInside.position - 0.375) < 1e-9 && abs(oneInside.opacity - (1 - pow(0.8413, 1 / 2.2))) < 1e-4)
    }

    @Test
    func testEdgesSpanTheirBlurAndReachTheEndOfTheMargin() throws {
        let lean = Self.lean(progress: 0.6)
        let grids = FrostedGlassView.edgeGrids(lean: lean) { height in 3 + 20 * height / 982 }
        #expect(grids.count == 4)
        let left = try #require(grids[0])
        // Four sigmas each side of the edge, then on out past the margin.
        for row in left.rows {
            let sigma = 3 + 20 * min(row[0].picture.y, 982) / 982
            #expect(abs(row[0].picture.x - 4 * sigma) < 1e-9 && abs(row[1].picture.x + 4 * sigma) < 1e-9)
            #expect(row[2].picture.x < lean.padded.minX)
        }
        let top = try #require(grids[2])
        #expect(top.rows.last!.allSatisfy { $0.picture.y > lean.padded.maxY })
        // No blur: a step at the edge, and the margin beyond it still black.
        let sharp = FrostedGlassView.edgeGrids(lean: lean) { _ in 0 }
        #expect(sharp.allSatisfy { $0 != nil })
        for row in try #require(sharp[0]).rows {
            #expect(row[0].picture.x > 0 && row[0].picture.x <= 0.25 && row[1].picture.x < 0 && row[1].picture.x >= -0.25)
            #expect(row[2].picture.x < lean.padded.minX)
        }
        #expect(try #require(sharp[2]).rows.last!.allSatisfy { $0.picture.y > lean.padded.maxY })
    }

    @Test
    func testAStretchedMeshEdgeReadsTheEdgeItself() throws {
        // A layer black at its right edge, stretched past it: the stretch
        // must show black, not the half-transparent beyond that a mesh reads
        // unless its edges are replicated.
        let size = CGSize(width: 200, height: 40)
        let rig = try #require(GlassFidelityRig(screen: size, scale: 1))
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = CGColor(gray: 1, alpha: 1)
        let gradient = CAGradientLayer()
        gradient.anchorPoint = .zero
        gradient.frame = root.bounds
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)]
        root.addSublayer(gradient)
        let lean = GlassLean.flat(screenSize: size, pixelScale: 1)
        func row(_ y: Double) -> [GlassLean.Vertex] {
            let v = y / 40
            return [
                GlassLean.Vertex(from: CGPoint(x: 0, y: v), picture: CGPoint(x: 20, y: y)),
                GlassLean.Vertex(from: CGPoint(x: 1, y: v), picture: CGPoint(x: 100, y: y)),
                GlassLean.Vertex(from: CGPoint(x: 1, y: v), picture: CGPoint(x: 190, y: y)),
            ]
        }
        let rows = [row(0), row(40)]
        GlassMesh.apply(lean.meshParts(for: GlassLean.Grid(rows: rows), layerFrame: gradient.frame), to: gradient)
        let frame = try #require(rig.render(root))
        let green = { (x: Int) in Int(frame.pixels[(20 * frame.width + x) * 4 + 1]) }
        #expect(green(10) == 255)
        #expect(abs(green(60) - 128) < 8)
        for x in stride(from: 110, through: 180, by: 10) { #expect(green(x) <= 2, "at \(x): \(green(x))") }
        #expect(green(195) == 255)
    }
}

extension GlassLeanTests {

    /// The band layout rests on how Core Animation masks a meshed layer: the
    /// mask is read where the layer shows, not where it is laid out, and the
    /// layer is clipped to its frame.
    @Test
    func testAMeshedLayersMaskIsReadWhereItShows() throws {
        let size = CGSize(width: 40, height: 200)
        let rig = try #require(GlassFidelityRig(screen: size, scale: 1))
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = CGColor(gray: 1, alpha: 1)
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.frame = CGRect(origin: .zero, size: size)
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // Opaque from y 0 to 25 and from 100 to 125, clear elsewhere.
        let mask = CAGradientLayer()
        mask.anchorPoint = .zero
        mask.frame = layer.bounds
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        let on = CGColor(gray: 0, alpha: 1), off = CGColor(gray: 0, alpha: 0)
        mask.colors = [on, on, off, off, on, on, off, off]
        mask.locations = [0, 0.125, 0.1251, 0.4999, 0.5, 0.625, 0.6251, 1]
        layer.mask = mask
        root.addSublayer(layer)
        // The layer's rows 0 to 50, shown at 100 to 150.
        func row(_ y: Double) -> [GlassLean.Vertex] {
            [GlassLean.Vertex(from: CGPoint(x: 0, y: y / 200), picture: CGPoint(x: 0, y: 100 + y)),
             GlassLean.Vertex(from: CGPoint(x: 1, y: y / 200), picture: CGPoint(x: 40, y: 100 + y))]
        }
        let lean = GlassLean.flat(screenSize: size, pixelScale: 1)
        GlassMesh.apply(lean.meshParts(for: GlassLean.Grid(rows: [row(0), row(50)]), layerFrame: layer.frame), to: layer)
        let frame = try #require(rig.render(root))
        let blue = { (y: Int) in Int(frame.pixels[((199 - y) * frame.width + 20) * 4]) }
        // Shown, and masked where it shows, at 100 to 125; nothing where it
        // is laid out.
        #expect(blue(110) == 0 && blue(120) == 0)
        #expect(blue(135) == 255 && blue(145) == 255)
        #expect(blue(10) == 255 && blue(40) == 255)
    }
}


private extension Array where Element == GlassLean.Vertex {
    func picture(_ index: Int) -> CGPoint { self[index].picture }
}
