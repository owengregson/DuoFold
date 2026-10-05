import Foundation
import QuartzCore
import AppKit
import Testing
@testable import DuoFold

/// How close the glass comes to the captured picture, pixel by pixel. Slow
/// and only a report: run with `FIDELITY_DIR=<folder>` set, which also gets
/// the frames side by side.
@MainActor
struct GlassFidelityTests {

    nonisolated static let directory = ProcessInfo.processInfo.environment["FIDELITY_DIR"]
    static let screen = CGSize(width: 1512, height: 982)
    /// The settings on the Mac this was tuned on.
    static let tuning = DepthTuning(
        viewingDistance: 6, recession: 0.6064, blurEvenness: 0.0523,
        dimReach: 0.5522, maxBlurRadius: 84.72, maxDim: 0.8984
    )

    @Test(.enabled(if: directory != nil), arguments: [0.15, 0.5, 1.0])
    func testFlatGlassAgainstTheFlatPicture(progress: Double) throws {
        let rig = try #require(GlassFidelityRig(screen: Self.screen, scale: 2))
        let size = Self.screen
        let flat = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
        let captured = try #require(rig.capture(corners: flat, progress: progress, tuning: Self.tuning))
        let glass = try #require(rig.glass { $0.apply(progress: progress, tuning: Self.tuning, gradient: BlurGradient()) })
        let all = GlassFidelityRig.difference(captured, glass)
        let inner = GlassFidelityRig.difference(captured, glass) { x, y in
            x > 200 && x < captured.width - 200 && y > 200 && y < captured.height - 40
        }
        print("flat progress \(progress): all \(all)\n                    inner \(inner)")
        let url = URL(fileURLWithPath: Self.directory!).appendingPathComponent("flat-\(progress).png")
        GlassFidelityRig.write([captured, glass, GlassFidelityRig.amplified(captured, glass, gain: 8)], to: url)
    }

    /// Where the flat glass and the flat picture part, and which way.
    @Test(.enabled(if: directory != nil && ProcessInfo.processInfo.environment["FIDELITY_REGIONS"] != nil))
    func testWhereTheFlatGlassDiffers() throws {
        let rig = try #require(GlassFidelityRig(screen: Self.screen, scale: 2))
        let size = Self.screen
        let flat = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
        let w = rig.pixelWidth, h = rig.pixelHeight
        for progress in [0.5, 1.0] {
            let captured = try #require(rig.capture(corners: flat, progress: progress, tuning: Self.tuning))
            let glass = try #require(rig.glass { $0.apply(progress: progress, tuning: Self.tuning, gradient: BlurGradient()) })
            // Rows from the top of the screen; the hinge is at the bottom.
            let regions: [(String, Range<Int>, Range<Int>)] = [
                ("white window, high", Int(Double(w) * 0.1)..<Int(Double(w) * 0.5), Int(Double(h) * 0.2)..<Int(Double(h) * 0.35)),
                ("white window, mid", Int(Double(w) * 0.1)..<Int(Double(w) * 0.5), Int(Double(h) * 0.4)..<Int(Double(h) * 0.55)),
                ("white window, low", Int(Double(w) * 0.1)..<Int(Double(w) * 0.5), Int(Double(h) * 0.6)..<Int(Double(h) * 0.75)),
                ("dark window", Int(Double(w) * 0.65)..<Int(Double(w) * 0.9), Int(Double(h) * 0.3)..<Int(Double(h) * 0.6)),
                ("wallpaper low", Int(Double(w) * 0.1)..<Int(Double(w) * 0.5), Int(Double(h) * 0.86)..<Int(Double(h) * 0.95)),
                ("left edge", 0..<40, Int(Double(h) * 0.3)..<Int(Double(h) * 0.7)),
                ("top edge", Int(Double(w) * 0.2)..<Int(Double(w) * 0.8), 0..<40),
            ]
            for (name, x, y) in regions {
                let m = GlassFidelityRig.signedMean(captured, glass, x: x, y: y)
                let d = GlassFidelityRig.difference(captured, glass) { px, py in x.contains(px) && y.contains(py) }
                print(String(format: "region p%.2f %-20@ capture-glass B %+.1f G %+.1f R %+.1f   |%@|", progress, name as NSString, m.0, m.1, m.2, d.description as NSString))
            }
            let dir = URL(fileURLWithPath: Self.directory!)
            GlassFidelityRig.writeCrop([captured, glass], x: Int(Double(w) * 0.05)..<Int(Double(w) * 0.05) + 300,
                                       y: Int(Double(h) * 0.75)..<Int(Double(h) * 0.75) + 200, zoom: 3,
                                       to: dir.appendingPathComponent("crop-low-\(progress).png"))
            GlassFidelityRig.writeCrop([captured, glass], x: Int(Double(w) * 0.05)..<Int(Double(w) * 0.05) + 300,
                                       y: Int(Double(h) * 0.25)..<Int(Double(h) * 0.25) + 200, zoom: 3,
                                       to: dir.appendingPathComponent("crop-high-\(progress).png"))
        }
    }

    /// The picture's corners at `progress`, as `LidController` and
    /// `DepthOverlay` work them out with these settings.
    static func corners(progress: Double, start: Double = 85.4, span: Double = 64.59, maxLean: Double = 70.33) -> [CGPoint] {
        let ramp = LidEffectRamp(startAngle: start, span: span, maxLean: maxLean, recession: tuning.recession)
        return DepthGeometry().corners(
            startAngle: start,
            currentAngle: ramp.pictureAngle(for: start - progress * span),
            viewingDistanceRatio: tuning.viewingDistance,
            recession: tuning.recession,
            screenSize: screen
        )
    }

    /// The leaning glass against the leaning picture.
    @Test(.enabled(if: directory != nil && ProcessInfo.processInfo.environment["FIDELITY_LEAN"] != nil),
          arguments: [0.15, 0.5, 1.0])
    func testLeaningGlassAgainstTheLeaningPicture(progress: Double) throws {
        let rig = try #require(GlassFidelityRig(screen: Self.screen, scale: 2))
        let corners = Self.corners(progress: progress)
        let lean = GlassLean(corners: corners, screenSize: Self.screen, padded: DepthRenderer.paddedFrame(screenSize: Self.screen, pixelScale: 2))
        let captured = try #require(rig.capture(corners: corners, progress: progress, tuning: Self.tuning))
        let glass = try #require(rig.glass { $0.apply(progress: progress, tuning: Self.tuning, gradient: BlurGradient(), lean: lean) })
        print("lean progress \(progress) corners \(corners.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined())  \(GlassFidelityRig.difference(captured, glass))")
        let dir = URL(fileURLWithPath: Self.directory!)
        GlassFidelityRig.write([captured, glass, GlassFidelityRig.amplified(captured, glass, gain: 8)],
                               to: dir.appendingPathComponent("lean-\(progress).png"))
        let w = rig.pixelWidth, h = rig.pixelHeight
        // Rows from the top of the screen; the hinge is at the bottom.
        let crops: [(String, Range<Int>, Range<Int>, Int)] = [
            ("left-edge", 0..<240, h * 4 / 10..<h * 4 / 10 + 160, 4),
            ("top-left", 0..<300, 0..<200, 3),
            ("text", w / 10..<w / 10 + 300, h * 6 / 10..<h * 6 / 10 + 160, 4),
            ("hinge-lines", w * 62 / 100..<w * 62 / 100 + 300, h - 260..<h - 60, 3),
        ]
        for (name, x, y, zoom) in crops {
            let m = GlassFidelityRig.signedMean(captured, glass, x: x, y: y)
            let d = GlassFidelityRig.difference(captured, glass) { px, py in x.contains(px) && y.contains(py) }
            print(String(format: "  crop %@ %-12@ capture-glass B %+.1f G %+.1f R %+.1f  |%@|", "\(progress)", name as NSString, m.0, m.1, m.2, d.description as NSString))
            GlassFidelityRig.writeCrop([captured, glass, GlassFidelityRig.amplified(captured, glass, gain: 8)], x: x, y: y, zoom: zoom,
                                       to: dir.appendingPathComponent("lean-\(progress)-\(name).png"))
        }
    }
}

/// What the leaning glass costs the main thread per frame.
@MainActor
struct GlassLeanCostTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FIDELITY_COST"] != nil))
    func testFrameCost() {
        let view = FrostedGlassView(frame: NSRect(origin: .zero, size: GlassFidelityTests.screen), scale: 2)
        let frames = 240
        let started = CFAbsoluteTimeGetCurrent()
        for frame in 0..<frames {
            let progress = Double(frame) / Double(frames - 1)
            let corners = GlassFidelityTests.corners(progress: progress)
            view.apply(progress: progress, tuning: GlassFidelityTests.tuning, gradient: BlurGradient(),
                       lean: GlassLean(corners: corners, screenSize: GlassFidelityTests.screen,
                                       padded: DepthRenderer.paddedFrame(screenSize: GlassFidelityTests.screen, pixelScale: 2)))
            CATransaction.flush()
        }
        let each = (CFAbsoluteTimeGetCurrent() - started) / Double(frames) * 1000
        print(String(format: "glass lean cost: %.3f ms per frame", each))
    }
}

/// The leaning glass stays close to the leaning picture, pixel by pixel,
/// on a small screen so it runs with every test.
@MainActor
struct GlassFidelityGuardTests {
    @Test(arguments: [0.35, 0.8])
    func testTheLeaningGlassDrawsWhatTheCapturedPictureDraws(progress: Double) throws {
        let screen = CGSize(width: 504, height: 328)
        let rig = try #require(GlassFidelityRig(screen: screen, scale: 2))
        let start = 85.0, span = 60.0
        let tuning = DepthTuning(viewingDistance: 4, recession: 0.8, blurEvenness: 0.1, dimReach: 0.6, maxBlurRadius: 40, maxDim: 0.8)
        let ramp = LidEffectRamp(startAngle: start, span: span, maxLean: 60, recession: tuning.recession)
        let corners = DepthGeometry().corners(
            startAngle: start, currentAngle: ramp.pictureAngle(for: start - progress * span),
            viewingDistanceRatio: tuning.viewingDistance, recession: tuning.recession, screenSize: screen
        )
        let lean = GlassLean(corners: corners, screenSize: screen, padded: DepthRenderer.paddedFrame(screenSize: screen, pixelScale: 2))
        let captured = try #require(rig.capture(corners: corners, progress: progress, tuning: tuning))
        let glass = try #require(rig.glass { $0.apply(progress: progress, tuning: tuning, gradient: BlurGradient(), lean: lean) })
        let difference = GlassFidelityRig.difference(captured, glass)
        if let directory = GlassFidelityTests.directory {
            print("guard \(progress): \(difference)")
            GlassFidelityRig.write([captured, glass, GlassFidelityRig.amplified(captured, glass, gain: 8)],
                                   to: URL(fileURLWithPath: directory).appendingPathComponent("guard-\(progress).png"))
        }
        // What is left is the captured picture blurring and dimming light
        // where the window server works on encoded values, which shows most
        // in fine text, as this small screen is full of.
        #expect(difference.mean < 13, "\(difference)")
        #expect(difference.p99 < 45, "\(difference)")
    }
}

/// Whether a lid moving by a hair changes the glass by a hair, or pops: the
/// window server's blur may switch resolution as its radius grows.
@MainActor
struct GlassShimmerReport {
    @Test(.enabled(if: GlassFidelityTests.directory != nil && ProcessInfo.processInfo.environment["FIDELITY_SHIMMER"] != nil))
    func testSmallStepsChangeTheGlassSmoothly() throws {
        let rig = try #require(GlassFidelityRig(screen: GlassFidelityTests.screen, scale: 2))
        var worst: [(Double, GlassFidelityRig.Difference)] = []
        var frames: [Double: GlassFidelityRig.Frame] = [:]
        var previous: GlassFidelityRig.Frame?
        for step in 0..<40 {
            let progress = 0.55 + Double(step) * 0.0025
            let corners = GlassFidelityTests.corners(progress: progress)
            let lean = GlassLean(corners: corners, screenSize: GlassFidelityTests.screen,
                                 padded: DepthRenderer.paddedFrame(screenSize: GlassFidelityTests.screen, pixelScale: 2))
            let frame = try #require(rig.glass { $0.apply(progress: progress, tuning: GlassFidelityTests.tuning, gradient: BlurGradient(), lean: lean) })
            if let previous {
                worst.append((progress, GlassFidelityRig.difference(previous, frame)))
            }
            previous = frame
        }
        for (progress, difference) in worst {
            print(String(format: "shimmer step to %.4f: %@", progress, difference.description as NSString))
        }
        // Where the pops are, and what the glass holds there.
        for progress in [0.59, 0.5925, 0.595, 0.6375, 0.64, 0.6425] {
            let corners = GlassFidelityTests.corners(progress: progress)
            let lean = GlassLean(corners: corners, screenSize: GlassFidelityTests.screen,
                                 padded: DepthRenderer.paddedFrame(screenSize: GlassFidelityTests.screen, pixelScale: 2))
            let frame = try #require(rig.glass { $0.apply(progress: progress, tuning: GlassFidelityTests.tuning, gradient: BlurGradient(), lean: lean) })
            frames[progress] = frame
        }
        for (a, b) in [(0.59, 0.5925), (0.5925, 0.595), (0.6375, 0.64), (0.64, 0.6425)] {
            let fa = frames[a]!, fb = frames[b]!
            var minX = Int.max, maxX = 0, minY = Int.max, maxY = 0, count = 0
            for y in 0..<fa.height { for x in 0..<fa.width {
                let i = (y * fa.width + x) * 4
                if (0..<3).contains(where: { abs(Int(fa.pixels[i + $0]) - Int(fb.pixels[i + $0])) > 40 }) {
                    count += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            } }
            print("pop \(a) -> \(b): \(count) px over 40, x \(minX)...\(maxX) y \(minY)...\(maxY) (px from top left)")
            if count > 0 {
                GlassFidelityRig.writeCrop([fa, fb, GlassFidelityRig.amplified(fa, fb, gain: 4)],
                                           x: max(minX - 40, 0)..<min(maxX + 40, fa.width), y: max(minY - 40, 0)..<min(maxY + 40, fa.height), zoom: 3,
                                           to: URL(fileURLWithPath: GlassFidelityTests.directory!).appendingPathComponent("pop-\(b).png"))
            }
        }
        let plan = { (p: Double) in FrostBandLayout().bands(for: FrostedGlassView.blurProfile(progress: p, tuning: GlassFidelityTests.tuning, gradient: BlurGradient(), height: 982), maximumRadius: 491) }
        for p in [0.59, 0.5925, 0.595] { print("bands at \(p): \(plan(p).map { String(format: "r%.2f %.0f-%.0f", $0.radius, $0.bottom, $0.top) }.joined(separator: " | "))") }
    }
}
