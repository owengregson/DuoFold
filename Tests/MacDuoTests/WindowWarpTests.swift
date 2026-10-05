import AppKit
import Testing
@testable import MacDuo

/// The window-level warp's mesh is the lean, in the server's terms.
struct WindowWarpTests {

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

    /// Row `row`, point `column` of the mesh, as (local, global).
    private func point(_ mesh: WindowWarp.Mesh, row: Int, column: Int) -> (local: CGPoint, global: CGPoint) {
        let i = (row * mesh.columns + column) * 4
        return (CGPoint(x: Double(mesh.floats[i]), y: Double(mesh.floats[i + 1])),
                CGPoint(x: Double(mesh.floats[i + 2]), y: Double(mesh.floats[i + 3])))
    }

    @Test
    func testTheMeshHasFourFloatsAPointAndTwoPointsARow() {
        let mesh = WindowWarp.mesh(lean: Self.lean(progress: 0.6), screen: CGRect(origin: .zero, size: Self.screen), primaryHeight: 982, rows: 64)
        #expect(mesh.columns == 2)
        #expect(mesh.rows == 65)
        #expect(mesh.floats.count == 65 * 2 * 4)
    }

    /// The window's corners land on the lean's corners, in the server's
    /// top-left coordinates, and rows stay level.
    @Test
    func testTheCornersLandOnTheLeansCorners() {
        let lean = Self.lean(progress: 0.6)
        let height = Self.screen.height
        let mesh = WindowWarp.mesh(lean: lean, screen: CGRect(origin: .zero, size: Self.screen), primaryHeight: height, rows: 32)
        // Top row of the window: the picture's top edge, local y = 0.
        let topLeft = point(mesh, row: 0, column: 0), topRight = point(mesh, row: 0, column: 1)
        #expect(topLeft.local == CGPoint(x: 0, y: 0))
        #expect(topRight.local == CGPoint(x: Self.screen.width, y: 0))
        #expect(abs(topLeft.global.x - lean.corners[3].x) < 0.01)
        #expect(abs(topLeft.global.y - (height - lean.corners[3].y)) < 0.01)
        #expect(abs(topRight.global.x - lean.corners[2].x) < 0.01)
        #expect(abs(topLeft.global.y - topRight.global.y) < 1e-3)
        // Bottom row: the hinge, which stays put.
        let bottomLeft = point(mesh, row: mesh.rows - 1, column: 0), bottomRight = point(mesh, row: mesh.rows - 1, column: 1)
        #expect(bottomLeft.local == CGPoint(x: 0, y: height))
        #expect(abs(bottomLeft.global.x - 0) < 0.01 && abs(bottomLeft.global.y - height) < 0.01)
        #expect(abs(bottomRight.global.x - Self.screen.width) < 0.01)
    }

    /// A window on a screen below the main display's top, or beside it,
    /// is placed in global coordinates.
    @Test
    func testTheScreensPlaceIsAddedInGlobalCoordinates() {
        let lean = GlassLean.flat(screenSize: Self.screen, pixelScale: 2)
        let screen = CGRect(x: 1512, y: -300, width: Self.screen.width, height: Self.screen.height)
        let mesh = WindowWarp.mesh(lean: lean, screen: screen, primaryHeight: 1200, rows: 4)
        let topLeft = point(mesh, row: 0, column: 0)
        #expect(topLeft.global == CGPoint(x: 1512, y: 1200 - (-300 + 982)))
        let bottomRight = point(mesh, row: 4, column: 1)
        #expect(bottomRight.global == CGPoint(x: 1512 + 1512, y: 1200 + 300))
        // Local points scale with `localScale`, global ones do not.
        let pixels = WindowWarp.mesh(lean: lean, screen: screen, primaryHeight: 1200, rows: 4, localScale: 2)
        #expect(point(pixels, row: 4, column: 1).local == CGPoint(x: 3024, y: 1964))
        #expect(point(pixels, row: 4, column: 1).global == bottomRight.global)
    }

    /// Rows between the ends lie on the lean within a hundredth of a point,
    /// as the layer meshes do (`FrostedGlassView.meshRows`).
    @Test
    func testRowsFollowTheLean() {
        let lean = Self.lean(progress: 1)
        let mesh = WindowWarp.mesh(lean: lean, screen: CGRect(origin: .zero, size: Self.screen), primaryHeight: 982, rows: 64)
        for row in 0..<mesh.rows {
            let p = point(mesh, row: row, column: 1)
            let picture = CGPoint(x: Self.screen.width, y: Self.screen.height - p.local.y)
            let shown = lean.screenPoint(picture)
            #expect(abs(p.global.x - shown.x) < 0.01)
            #expect(abs(p.global.y - (982 - shown.y)) < 0.01)
        }
    }
}
