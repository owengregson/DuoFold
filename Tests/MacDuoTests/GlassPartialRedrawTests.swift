import AppKit
import QuartzCore
import Testing
@testable import MacDuo

/// The window server redraws only what changed. A window dragged behind the
/// leaning glass must come out as a full redraw of the same scene would.
/// Drawn offscreen by `CARenderer`, told which rectangles changed, as the
/// window server is.
@MainActor
struct GlassPartialRedrawTests {

    struct Scene {
        let rig: GlassFidelityRig
        let root: CALayer
        let window: CALayer
        let view: FrostedGlassView
    }

    /// A leaning glass over a screen with a light window on it at `at`.
    static func scene(windowAt at: CGPoint, progress: Double = 0.6) throws -> Scene {
        let screen = CGSize(width: 504, height: 328)
        let rig = try #require(GlassFidelityRig(screen: screen, scale: 2))
        let view = FrostedGlassView(frame: NSRect(origin: .zero, size: screen), scale: 2, samplesOtherWindows: false)
        let root = try #require(view.layer)
        root.frame = CGRect(origin: .zero, size: screen)
        let desktop = CALayer()
        desktop.anchorPoint = .zero
        desktop.frame = root.bounds
        desktop.contents = rig.picture
        desktop.contentsScale = 2
        root.insertSublayer(desktop, at: 0)
        let window = CALayer()
        window.anchorPoint = .zero
        window.frame = CGRect(origin: at, size: CGSize(width: 120, height: 80))
        window.backgroundColor = CGColor(gray: 0.97, alpha: 1)
        window.borderColor = CGColor(gray: 0.1, alpha: 1)
        window.borderWidth = 3
        root.insertSublayer(window, at: 1)
        let start = 85.0, span = 60.0
        let tuning = DepthTuning(viewingDistance: 4, recession: 0.8, blurEvenness: 0.1, dimReach: 0.6, maxBlurRadius: 30, maxDim: 0.6)
        let ramp = LidEffectRamp(startAngle: start, span: span, maxLean: 60, recession: tuning.recession)
        let corners = DepthGeometry().corners(
            startAngle: start, currentAngle: ramp.pictureAngle(for: start - progress * span),
            viewingDistanceRatio: tuning.viewingDistance, recession: tuning.recession, screenSize: screen
        )
        view.apply(progress: progress, tuning: tuning, gradient: BlurGradient(),
                   lean: GlassLean(corners: corners, screenSize: screen, padded: DepthRenderer.paddedFrame(screenSize: screen, pixelScale: 2)))
        return Scene(rig: rig, root: root, window: window, view: view)
    }

    /// Pixels a partly redrawn frame gets wrong against a full redraw of the
    /// same scene, after dragging the window from `from` to `to`.
    static func wrongPixels(from: CGPoint, to: CGPoint, steps: Int = 6) throws -> (count: Int, worst: Double) {
        let live = try scene(windowAt: from)
        let renderer = try #require(GlassFidelityRig.LiveRenderer(rig: live.rig, root: live.root))
        _ = try #require(renderer.frame())
        var last = from
        var partial: GlassFidelityRig.Frame?
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let next = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            live.window.frame.origin = next
            CATransaction.commit()
            // What changed: where the window was, and where it is.
            let size = live.window.frame.size
            let damage = CGRect(origin: last, size: size).union(CGRect(origin: next, size: size))
            partial = try #require(renderer.frame(update: damage))
            last = next
        }
        let reference = try scene(windowAt: to)
        let full = try #require(GlassFidelityRig.LiveRenderer(rig: reference.rig, root: reference.root)?.frame())
        let difference = GlassFidelityRig.difference(try #require(partial), full)
        var count = 0
        let a = partial!.pixels, b = full.pixels
        for i in stride(from: 0, to: a.count, by: 4) where (0..<3).contains(where: { abs(Int(a[i + $0]) - Int(b[i + $0])) > 24 }) {
            count += 1
        }
        if let directory = GlassFidelityTests.directory {
            GlassFidelityRig.write([partial!, full, GlassFidelityRig.amplified(partial!, full, gain: 4)],
                                   to: URL(fileURLWithPath: directory).appendingPathComponent("partial-redraw.png"))
            print("partial redraw: \(count) pixels off by more than 24, \(difference)")
        }
        return (count, difference.maximum)
    }

    @Test
    func testAWindowDraggedBehindTheLeaningGlassIsDrawnAsAFullRedrawWouldBe() throws {
        let wrong = try Self.wrongPixels(from: CGPoint(x: 60, y: 40), to: CGPoint(x: 300, y: 150))
        #expect(wrong.count == 0, "\(wrong.count) pixels wrong, worst \(wrong.worst)")
    }
}
