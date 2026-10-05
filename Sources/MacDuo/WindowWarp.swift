import AppKit
import QuartzCore

/// The window server's own warp of a whole window, as the Dock's genie
/// effect uses it: the glass stays flat inside its window, where backdrops
/// and partial redraws agree, and the server carries the window's composited
/// picture to where the lean puts it.
///
/// Read from SkyLight on macOS 26.3: `SLSSetWindowWarp(cid, wid, w, h, mesh)`
/// takes `w * h` points of four 32-bit floats each (local x, local y, global
/// x, global y), row-major with `w` points per row. Local points are the
/// window's own, from its top-left corner, y down; global points are display
/// coordinates, from the main display's top-left corner, y down. The server
/// accepts the call from any connection that holds rights on the window,
/// which the window's owner does, and applies it as a `CAMeshTransform` on
/// the window's layer with no subdivision. `w` or `h` under 2 clears the
/// warp. The call sends a one-way message and returns 0 whenever the window
/// is known to this process, so its result says nothing about the server.
///
/// Used when the `glassRenderer` default is `warp`.
enum WindowWarp {

    /// A mesh ready for the server: `rows` rows of `columns` points.
    struct Mesh: Equatable {
        var columns: Int
        var rows: Int
        /// `rows * columns * 4` floats.
        var floats: [Float]
    }

    /// Rows of the mesh over the picture's height, as `FrostedGlassView`
    /// meshes its layers: within a hundredth of a point of the lean.
    static let rows = 64

    /// Whether this process should warp the glass window rather than mesh
    /// its layers.
    static var isWanted: Bool { GlassRenderer.current == .warp }

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetWindowWarp = @convention(c) (Int32, UInt32, Int32, Int32, UnsafePointer<Float>?) -> Int32

    private struct Runtime {
        let mainConnectionID: MainConnectionID
        let setWindowWarp: SetWindowWarp
    }

    private static let runtime: Runtime? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let main = dlsym(handle, "SLSMainConnectionID"),
              let warp = dlsym(handle, "SLSSetWindowWarp") else {
            Diagnostics.geometry.notice("window warp: SkyLight symbols missing")
            return nil
        }
        return Runtime(
            mainConnectionID: unsafeBitCast(main, to: MainConnectionID.self),
            setWindowWarp: unsafeBitCast(warp, to: SetWindowWarp.self)
        )
    }()

    static var isAvailable: Bool { runtime != nil }

    /// The mesh that carries a window lying flat over `screen` to where
    /// `lean` puts the picture: two points a row, rows level, every row's
    /// ends on the lean's edges. Rows run from the top of the window down,
    /// `rows` of them over the picture's height.
    ///
    /// - Parameters:
    ///   - screen: the window's frame, in AppKit screen coordinates (bottom
    ///     left origin), the frame the lean's picture points are measured in.
    ///   - primaryHeight: the main display's height in points, which turns
    ///     AppKit's y into the server's.
    ///   - localScale: points per local unit, 1 for a server that takes
    ///     local points in points.
    nonisolated static func mesh(lean: GlassLean, screen: CGRect, primaryHeight: CGFloat, rows: Int, localScale: CGFloat = 1) -> Mesh {
        let width = Double(lean.screenSize.width), height = Double(lean.screenSize.height)
        let count = max(rows, 1)
        var floats: [Float] = []
        floats.reserveCapacity((count + 1) * 2 * 4)
        for row in 0...count {
            // Picture y, hinge at 0: the top row of the window first.
            let y = height * Double(count - row) / Double(count)
            for x in [0.0, width] {
                let shown = lean.screenPoint(CGPoint(x: x, y: y))
                let local = CGPoint(x: CGFloat(x) * localScale, y: CGFloat(height - y) * localScale)
                let global = CGPoint(x: screen.minX + shown.x, y: primaryHeight - (screen.minY + shown.y))
                floats += [Float(local.x), Float(local.y), Float(global.x), Float(global.y)]
            }
        }
        return Mesh(columns: 2, rows: count + 1, floats: floats)
    }

    /// Warps `window` by `mesh`, or lays it flat again for `nil`. Returns the
    /// server call's result, which is 0 even when the server ignores it.
    @MainActor
    @discardableResult
    static func apply(_ mesh: Mesh?, to window: NSWindow) -> Int32? {
        guard let runtime else { return nil }
        let cid = runtime.mainConnectionID()
        let wid = UInt32(window.windowNumber)
        guard let mesh, mesh.columns >= 2, mesh.rows >= 2 else {
            return runtime.setWindowWarp(cid, wid, 0, 0, nil)
        }
        return mesh.floats.withUnsafeBufferPointer {
            runtime.setWindowWarp(cid, wid, Int32(mesh.columns), Int32(mesh.rows), $0.baseAddress)
        }
    }
}
