import Foundation
import QuartzCore
import simd

/// Where the glass lays the picture on screen as it leans back, and the
/// meshes that put each of its layers there.
///
/// The captured picture maps every screen pixel back into the picture
/// through `Homography` and reads a blur stack that holds the picture on a
/// black margin. The glass runs the same mapping forward: each layer is laid
/// out flat, in picture points, and a mesh carries its points to where the
/// homography puts them. The margin is the captured picture's own
/// (`DepthRenderer.paddedFrame`), so the black beyond it starts where the
/// captured picture's does.
struct GlassLean: Equatable {

    /// The picture's corners on screen, bottom left, bottom right, top
    /// right, top left, as `DepthGeometry.corners` gives them.
    var corners: [CGPoint]
    var screenSize: CGSize
    /// The picture and its black margin, in picture points, hinge at y = 0.
    var padded: CGRect

    /// A picture lying flat on the screen, with the captured picture's
    /// margin at `pixelScale`.
    static func flat(screenSize: CGSize, pixelScale: CGFloat) -> GlassLean {
        GlassLean(
            corners: [CGPoint(x: 0, y: 0), CGPoint(x: screenSize.width, y: 0),
                      CGPoint(x: screenSize.width, y: screenSize.height), CGPoint(x: 0, y: screenSize.height)],
            screenSize: screenSize,
            padded: DepthRenderer.paddedFrame(screenSize: screenSize, pixelScale: pixelScale)
        )
    }

    /// True when the picture lies flat, so nothing needs to move.
    var isFlat: Bool {
        let flat = GlassLean.flat(screenSize: screenSize, pixelScale: 1).corners
        return zip(corners, flat).allSatisfy { abs($0.x - $1.x) < 1e-3 && abs($0.y - $1.y) < 1e-3 }
    }

    private var matrix: simd_double3x3 {
        Homography.matrix(
            width: Double(screenSize.width),
            height: Double(screenSize.height),
            to: corners.map { SIMD2(Double($0.x), Double($0.y)) }
        )
    }

    /// Where a picture point lands on screen. Points of the margin land past
    /// the picture's corners, as the captured picture's margin does.
    func screenPoint(_ point: CGPoint) -> CGPoint {
        let mapped = matrix * SIMD3(Double(point.x), Double(point.y), 1)
        return CGPoint(x: mapped.x / mapped.z, y: mapped.y / mapped.z)
    }

    /// How many picture points one screen point spans at a picture point,
    /// along the tighter axis, squared: past 1 the lean squeezes the picture.
    func squeeze(at point: CGPoint) -> Double {
        let m = matrix
        let p = SIMD3(Double(point.x), Double(point.y), 1)
        let mapped = m * p
        let w = mapped.z
        let screen = SIMD2(mapped.x, mapped.y) / w
        // Derivatives of the screen point along picture x and y.
        let alongX = (SIMD2(m[0].x, m[0].y) - screen * m[0].z) / w
        let alongY = (SIMD2(m[1].x, m[1].y) - screen * m[1].z) / w
        // Picture points per screen point is the inverse of the shorter one.
        let shortest = min(simd_length(alongX), simd_length(alongY))
        return shortest > 0 ? 1 / (shortest * shortest) : 1
    }

    // MARK: - Meshes

    /// One vertex of a mesh: a point of the layer's own unit square, and the
    /// picture point it shows at.
    struct Vertex: Equatable {
        var from: CGPoint
        var picture: CGPoint
    }

    /// A grid of vertices, row by row, every row the same length.
    struct Grid: Equatable {
        var rows: [[Vertex]]
    }

    /// The vertices and faces Core Animation takes for a layer at `frame`,
    /// in screen points, laying `grid` where the lean puts it.
    func meshParts(for grid: Grid, layerFrame frame: CGRect) -> (vertices: [GlassMesh.Vertex], faces: [GlassMesh.Face]) {
        var vertices: [GlassMesh.Vertex] = []
        var faces: [GlassMesh.Face] = []
        let width = Double(frame.width), height = Double(frame.height)
        guard let columns = grid.rows.first?.count, columns > 1, grid.rows.count > 1, width > 0, height > 0 else { return ([], []) }
        for row in grid.rows {
            for vertex in row {
                let point = screenPoint(vertex.picture)
                vertices.append(GlassMesh.Vertex(
                    from: vertex.from,
                    to: ((Double(point.x) - Double(frame.minX)) / width, (Double(point.y) - Double(frame.minY)) / height, 0)
                ))
            }
        }
        for row in 0..<grid.rows.count - 1 {
            for column in 0..<columns - 1 {
                let a = UInt32(row * columns + column)
                let below = UInt32((row + 1) * columns + column)
                faces.append(GlassMesh.Face(indices: (a, a + 1, below + 1, below), weights: (0, 0, 0, 0)))
            }
        }
        return (vertices, faces)
    }

    /// The grid for a layer that shows the picture between `bottom` and
    /// `top`, in picture points, the full width of the screen: its own
    /// unit square, row for row, plus the margin beyond each side and, for
    /// a layer that reaches the top, above it. In the margin the layer's
    /// outermost points are stretched, so what shows there is the picture's
    /// edge, as the captured picture's blur spreads it into the margin.
    ///
    /// Reaches `overlap` points past the margin, under the black beyond it,
    /// so no hairline of the screen shows between the two.
    ///
    /// - Parameter layerRows: the layer's frame, bottom and top in points,
    ///   when it reaches past the rows it shows; its own rows by default.
    func pictureGrid(
        bottom: Double, top: Double, rows: Int, layerRows: ClosedRange<Double>? = nil, overlap: Double = 2
    ) -> Grid {
        let width = Double(screenSize.width), height = Double(screenSize.height)
        let left = Double(padded.minX) - overlap, right = Double(padded.maxX) + overlap
        let extent = max(top - bottom, 1e-6)
        let frame = layerRows ?? bottom...top
        let frameExtent = max(frame.upperBound - frame.lowerBound, 1e-6)
        var heights = (0...max(rows, 1)).map { bottom + extent * Double($0) / Double(max(rows, 1)) }
        if top >= height - 1e-6 { heights.append(Double(padded.maxY) + overlap) }
        return Grid(rows: heights.map { y in
            let v = (min(max(y, bottom), top) - frame.lowerBound) / frameExtent
            return [
                Vertex(from: CGPoint(x: 0, y: v), picture: CGPoint(x: left, y: y)),
                Vertex(from: CGPoint(x: 0, y: v), picture: CGPoint(x: 0, y: y)),
                Vertex(from: CGPoint(x: 1, y: v), picture: CGPoint(x: width, y: y)),
                Vertex(from: CGPoint(x: 1, y: v), picture: CGPoint(x: right, y: y)),
            ]
        })
    }
}

/// Core Animation's private mesh transform, looked up by name and checked
/// once, like the rest of the glass (`WindowServerBlur`).
enum GlassMesh {

    /// `CAMeshVertex`: a point of the layer's unit square, and where it goes.
    struct Vertex {
        var from: CGPoint
        var to: (Double, Double, Double)
    }

    /// `CAMeshFace`: four vertex indices, and their weights.
    struct Face {
        var indices: (UInt32, UInt32, UInt32, UInt32)
        var weights: (Float, Float, Float, Float)
    }

    private static let factory = NSSelectorFromString("meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:")
    private static let meshClass: AnyClass? = NSClassFromString("CAMeshTransform")
    private typealias Make = @convention(c) (AnyClass, Selector, UInt, UnsafeRawPointer, UInt, UnsafeRawPointer, NSString) -> Unmanaged<AnyObject>?
    private static let send: Make? = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend").map { unsafeBitCast($0, to: Make.self) }

    /// Whether layers can be meshed on this system.
    static let isAvailable: Bool = {
        guard let meshClass, send != nil, (meshClass as AnyObject).responds(to: factory) else {
            Diagnostics.geometry.notice("glass lean: no mesh transform")
            return false
        }
        guard CALayer().responds(to: NSSelectorFromString("setMeshTransform:")) else {
            Diagnostics.geometry.notice("glass lean: layers take no mesh")
            return false
        }
        return true
    }()

    /// Lays `layer` out by the mesh, or flat again for no vertices.
    static func apply(_ parts: (vertices: [Vertex], faces: [Face]), to layer: CALayer) {
        guard isAvailable else { return }
        guard !parts.vertices.isEmpty, !parts.faces.isEmpty, let meshClass, let send else {
            layer.setValue(nil, forKey: "meshTransform")
            return
        }
        let made = parts.vertices.withUnsafeBytes { vertices in
            parts.faces.withUnsafeBytes { faces in
                send(meshClass, factory, UInt(parts.vertices.count), vertices.baseAddress!,
                     UInt(parts.faces.count), faces.baseAddress!, "none")?.takeUnretainedValue()
            }
        }
        // Left to itself the mesh is smoothed into a curved surface through
        // the vertices, which bends straight runs where the picture meets
        // its margin. Unsubdivided, each face runs straight, as the vertices
        // are placed for. And a face that stretches a layer's edge reads the
        // edge itself only with edges replicated: otherwise it reads halfway
        // into the transparent beyond and shows at half strength.
        var mesh = made
        if let mutable = (made as? NSObject)?.mutableCopy() as? NSObject,
           mutable.responds(to: NSSelectorFromString("setSubdivisionSteps:")),
           mutable.responds(to: NSSelectorFromString("setReplicatesEdges:")) {
            mutable.setValue(0, forKey: "subdivisionSteps")
            mutable.setValue(true, forKey: "replicatesEdges")
            mesh = mutable
        }
        layer.setValue(mesh, forKey: "meshTransform")
    }
}
