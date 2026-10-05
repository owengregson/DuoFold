import AppKit
import QuartzCore
import Testing
@testable import DuoFold

@MainActor
struct ScreenCornerTests {

    static let screen = CGSize(width: 1512, height: 982)
    static let radius = ScreenCorner.notchedRadius

    @Test
    func testTheCapIsTheCornerOutsideTheCurve() {
        let side = ScreenCorner.boxSide(radius: Self.radius)
        let cap = ScreenCorner.capPath(radius: Self.radius)
        #expect(cap.contains(CGPoint(x: 0.5, y: side - 0.5)))
        #expect(!cap.contains(CGPoint(x: side - 0.5, y: 0.5)))
        // Along the edges, past where the curve leaves them.
        #expect(!cap.contains(CGPoint(x: 1.6 * Self.radius, y: side - 0.1)))
        #expect(!cap.contains(CGPoint(x: 0.1, y: side - 1.6 * Self.radius)))
        // The same either side of the corner's diagonal.
        for x in stride(from: 0.25, to: side, by: 1.5) {
            for y in stride(from: 0.25, to: side, by: 1.5) {
                let point = CGPoint(x: x, y: y), reflected = CGPoint(x: side - y, y: side - x)
                if abs(x - (side - y)) > 0.3 {
                    #expect(cap.contains(point) == cap.contains(reflected), "\(point)")
                }
            }
        }
        #expect(ScreenCorner.capPath(radius: 0).isEmpty)
    }

    static func lean(_ preset: EffectPreset, progress: Double) -> GlassLean {
        let s = preset.settings
        let ramp = LidEffectRamp(startAngle: s.thresholdAngle, span: s.blurSpan, maxLean: s.maxLean, recession: s.recession)
        let corners = DepthGeometry().corners(
            startAngle: s.thresholdAngle,
            currentAngle: ramp.pictureAngle(for: s.thresholdAngle - progress * s.blurSpan),
            viewingDistanceRatio: s.viewingDistance, recession: s.recession, screenSize: screen
        )
        return GlassLean(corners: corners, screenSize: screen, padded: DepthRenderer.paddedFrame(screenSize: screen, pixelScale: 2))
    }

    // MARK: - Drawn

    static func tuning(_ preset: EffectPreset) -> DepthTuning {
        let s = preset.settings
        return DepthTuning(viewingDistance: s.viewingDistance, recession: s.recession, blurEvenness: s.blurEvenness,
                           dimReach: s.dimReach, maxBlurRadius: s.maxBlurRadius, maxDim: s.maxDim)
    }

    /// Brightness 0...255 at a picture point, through the lean.
    static func brightness(_ frame: GlassFidelityRig.Frame, at picture: CGPoint, lean: GlassLean, scale: CGFloat) -> Double {
        let point = lean.screenPoint(picture)
        let column = Int(point.x * scale), row = Int((screen.height - point.y) * scale)
        let i = (row * frame.width + column) * 4
        return (Double(frame.pixels[i]) + Double(frame.pixels[i + 1]) + Double(frame.pixels[i + 2])) / 3
    }

    /// Just past the start, where the blur is still slight: the picture's
    /// top-left corner is black, as the panel's rounding is, and a little
    /// way in along the diagonal the picture shows as it did.
    @Test(arguments: [false, true])
    func testTheLeaningPictureKeepsTheTopCornersRounded(captured: Bool) throws {
        let rig = try #require(GlassFidelityRig(screen: Self.screen, scale: 2))
        let progress = 0.02
        let lean = Self.lean(.deep, progress: progress)
        #expect(!lean.isFlat)
        let tuning = Self.tuning(.deep)
        func draw(_ radius: Double) throws -> GlassFidelityRig.Frame {
            if captured {
                return try #require(rig.capture(corners: lean.corners, progress: progress, tuning: tuning, cornerRadius: radius))
            }
            return try #require(rig.glass(cornerRadius: radius) {
                $0.apply(progress: progress, tuning: tuning, gradient: BlurGradient(), lean: lean)
            })
        }
        let rounded = try draw(Self.radius), square = try draw(0)
        let top = Self.screen.height
        for (point, label) in [(CGPoint(x: 1.5, y: top - 1.5), "left"), (CGPoint(x: Self.screen.width - 1.5, y: top - 1.5), "right")] {
            #expect(Self.brightness(square, at: point, lean: lean, scale: 2) > 120, "\(label) corner of the square picture")
            #expect(Self.brightness(rounded, at: point, lean: lean, scale: 2) < 40, "\(label) corner of the rounded picture")
        }
        let inside = CGPoint(x: 2 * Self.radius, y: top - 2 * Self.radius)
        #expect(abs(Self.brightness(rounded, at: inside, lean: lean, scale: 2) - Self.brightness(square, at: inside, lean: lean, scale: 2)) < 6)
    }

    static func luminance(_ frame: GlassFidelityRig.Frame, _ column: Int, _ row: Int) -> Double {
        let i = (row * frame.width + column) * 4
        return (0..<3).reduce(0.0) { $0 + Double(frame.pixels[i + $1]) } / 3
    }

    /// The share of each pixel's brightness rounding keeps near a top
    /// corner, where the square frame has enough light to tell. The two
    /// renderers light the square picture's edge pixels differently, so a
    /// share compares them where a difference would not.
    static func kept(_ rounded: GlassFidelityRig.Frame, _ square: GlassFidelityRig.Frame, column: Int, row: Int) -> Double? {
        let base = luminance(square, column, row)
        return base >= 24 ? min(luminance(rounded, column, row) / base, 1) : nil
    }

    /// The picture point a screen pixel's centre shows, by Newton's method
    /// on the lean.
    static func picturePoint(column: Int, row: Int, lean: GlassLean, scale: Double) -> CGPoint {
        let target = CGPoint(x: (Double(column) + 0.5) / scale, y: Double(screen.height) - (Double(row) + 0.5) / scale)
        var point = target
        for _ in 0..<12 {
            let here = lean.screenPoint(point), step = 1e-3
            let alongX = lean.screenPoint(CGPoint(x: point.x + step, y: point.y))
            let alongY = lean.screenPoint(CGPoint(x: point.x, y: point.y + step))
            let j = (a: (alongX.x - here.x) / step, b: (alongY.x - here.x) / step,
                     c: (alongX.y - here.y) / step, d: (alongY.y - here.y) / step)
            let determinant = j.a * j.d - j.b * j.c
            let dx = target.x - here.x, dy = target.y - here.y
            point.x += (j.d * dx - j.b * dy) / determinant
            point.y += (j.a * dy - j.c * dx) / determinant
        }
        return point
    }

    /// The light a Gaussian blur of `sigma` of the rounded picture keeps at
    /// `inward` points from the left edge and `down` from the top, and the
    /// share of it each edge keeps, which the square picture keeps the
    /// product of. The light kept is summed where it falls, never found as
    /// the difference of two near equal sums: the picture past the cap's box
    /// in closed form, the box less its cap in cells far finer than the blur.
    struct ExactCorner {
        let sigma: Double
        private let side: Double
        private let cell: Double
        private let count: Int
        /// Row by row from the top, whether each cell of the box shows the
        /// picture rather than the cap.
        private var shows: [Bool] = []

        init(radius: Double, sigma: Double) {
            self.sigma = sigma
            side = ScreenCorner.boxSide(radius: radius)
            cell = min(0.2, sigma / 5)
            count = Int((side / cell).rounded(.up))
            let cap = ScreenCorner.capPath(radius: radius)
            for row in 0..<count {
                for column in 0..<count {
                    let centre = CGPoint(x: (Double(column) + 0.5) * cell, y: side - (Double(row) + 0.5) * cell)
                    shows.append(!cap.contains(centre))
                }
            }
        }

        /// The share of a blur centred at `point` that lies past `edge`,
        /// along one axis.
        func share(past edge: Double, from point: Double) -> Double {
            0.5 * erfc((edge - point) / (sigma * 2.squareRoot()))
        }

        func light(inward: Double, down: Double) -> Double {
            let pastLeft = share(past: 0, from: inward), pastTop = share(past: 0, from: down)
            let square = pastLeft * pastTop
            let insideBoxAcross = pastLeft - share(past: side, from: inward)
            let insideBoxDown = pastTop - share(past: side, from: down)
            let outsideBox = square - insideBoxAcross * insideBoxDown
            // Past five sigmas a cell's share is under a hundred thousandth.
            let reach = 5 * sigma
            func within(_ centre: Double) -> Range<Int> {
                let first = min(max(Int(((centre - reach) / cell).rounded(.down)), 0), count)
                return first..<min(max(Int(((centre + reach) / cell).rounded(.up)), first), count)
            }
            let columns = within(inward), rows = within(down)
            let spread = 2 * sigma * sigma
            var inBox = 0.0
            for row in rows {
                let dy = (Double(row) + 0.5) * cell - down
                for column in columns where shows[row * count + column] {
                    let dx = (Double(column) + 0.5) * cell - inward
                    inBox += exp(-(dx * dx + dy * dy) / spread)
                }
            }
            inBox *= cell * cell / (.pi * spread)
            return max(outsideBox, 0) + inBox
        }
    }

    /// The share of light the glass's rounded outline keeps over its square
    /// one, through the 1 / 2.2 power the screen shows it in: the core's
    /// blur and the skirt's, each by its weight, over the edges' product.
    struct ExactOutline {
        let core: ExactCorner
        let skirt: ExactCorner

        init(radius: Double, sigma: Double) {
            core = ExactCorner(radius: radius, sigma: FrostedGlassView.outlineCore * sigma)
            skirt = ExactCorner(radius: radius, sigma: sigma)
        }

        func kept(inward: Double, down: Double) -> Double {
            let weight = FrostedGlassView.outlineSkirt
            let light = (1 - weight) * core.light(inward: inward, down: down) + weight * skirt.light(inward: inward, down: down)
            func edge(_ point: Double) -> Double {
                (1 - weight) * core.share(past: 0, from: point) + weight * skirt.share(past: 0, from: point)
            }
            let square = edge(inward) * edge(down)
            return square > 0 ? pow(min(light / square, 1), 1 / 2.2) : 1
        }
    }

    /// As the blur grows, the glass's corner fades as its rounded outline
    /// does, through the crisp core and the soft skirt: no square marks
    /// along the edges, the margin's glow rounded too.
    // Past about 0.55 of Deep's close its top corners lean off the top of the screen.
    @Test(arguments: [0.15, 0.3, 0.45])
    func testTheGlassCornerBlursAsARoundedPictureDoes(progress: Double) throws {
        let rig = try #require(GlassFidelityRig(screen: Self.screen, scale: 2))
        let lean = Self.lean(.deep, progress: progress)
        let tuning = Self.tuning(.deep)
        let glass = try [Self.radius, 0].map { radius in
            try #require(rig.glass(cornerRadius: radius) { $0.apply(progress: progress, tuning: tuning, gradient: BlurGradient(), lean: lean) })
        }
        let s = EffectPreset.deep.settings
        let sigma = BlurGradient().sigma(progress: progress, height: 1, maxBlurRadius: s.maxBlurRadius, evenness: s.blurEvenness)
        let exact = ExactOutline(radius: Self.radius, sigma: sigma)
        let corner = lean.screenPoint(CGPoint(x: 0, y: Self.screen.height))
        let left = max(Int(corner.x * 2) - 60, 0), top = max(Int((Self.screen.height - corner.y) * 2) - 60, 0)
        var errors: [Double] = []
        // In the screen's own levels, which a share near black overstates.
        var levels: [Double] = []
        for row in stride(from: top, to: top + 260, by: 6) {
            for column in stride(from: left, to: left + 260, by: 6) {
                guard let share = Self.kept(glass[0], glass[1], column: column, row: row) else { continue }
                let point = Self.picturePoint(column: column, row: row, lean: lean, scale: 2)
                let truth = exact.kept(inward: Double(point.x), down: Double(Self.screen.height - point.y))
                errors.append(abs(share - truth))
                levels.append(abs(share - truth) * Self.luminance(glass[1], column, row))
            }
        }
        errors.sort()
        let mean = errors.reduce(0, +) / Double(errors.count)
        levels.sort()
        print("corner blur at \(progress), sigma \(sigma): share kept, glass against exact: mean \(mean) p99 \(errors[errors.count * 99 / 100]); levels p99 \(levels[levels.count * 99 / 100]) max \(levels.last!), over \(errors.count)")
        #expect(mean < 0.01)
        #expect(errors[errors.count * 99 / 100] < 0.05)
        #expect(levels.last! < 4)
    }

    /// Each corner is drawn for the screen where it shows: no mesh, no
    /// transform, one of its pixels to each of the layer's, wherever the lid
    /// is, so nothing resamples it on its way to the screen.
    @Test(arguments: [0.0, 0.02, 0.22, 0.4, 0.5])
    func testTheCornersAreShownAsDrawn(progress: Double) throws {
        let view = FrostedGlassView(
            frame: NSRect(origin: .zero, size: Self.screen), scale: 2, cornerRadius: Self.radius, samplesOtherWindows: false
        )
        view.apply(progress: progress, tuning: Self.tuning(.deep), gradient: BlurGradient(), lean: Self.lean(.deep, progress: progress))
        for cap in view.caps {
            #expect(!cap.isHidden)
            #expect(cap.value(forKey: "meshTransform") == nil)
            #expect(CATransform3DIsIdentity(cap.transform))
            let image = try #require(cap.contents.map { $0 as! CGImage })
            #expect(abs(Double(image.width) - Double(cap.frame.width * cap.contentsScale)) < 0.01)
            #expect(abs(Double(image.height) - Double(cap.frame.height * cap.contentsScale)) < 0.01)
            #expect(cap.contentsScale <= 2)
        }
    }

    /// Across an edge of a plain screen, the outline keeps the light its
    /// crisp core and soft skirt keep: a step a quarter as soft as the
    /// picture's blur, carrying three tenths of the light, inside a skirt as
    /// soft as it, carrying the rest.
    @Test
    func testTheOutlineFadesThroughACrispCoreAndASoftSkirt() throws {
        let plain = try #require(GlassFidelityRig.plainPicture(size: Self.screen, scale: 2, gray: 0.8))
        let rig = try #require(GlassFidelityRig(screen: Self.screen, scale: 2, picture: plain))
        let progress = 0.45
        let lean = Self.lean(.deep, progress: progress)
        let glass = try #require(rig.glass(cornerRadius: Self.radius) {
            $0.apply(progress: progress, tuning: Self.tuning(.deep), gradient: BlurGradient(), lean: lean)
        })
        let height = 600.0
        let s = EffectPreset.deep.settings
        let sigma = BlurGradient().sigma(
            progress: progress, height: height / Self.screen.height,
            maxBlurRadius: s.maxBlurRadius, evenness: s.blurEvenness
        )
        func brightness(inward: Double) -> Double {
            let point = lean.screenPoint(CGPoint(x: inward, y: height))
            return Self.luminance(glass, Int(point.x * 2), Int((Self.screen.height - point.y) * 2))
        }
        let inside = brightness(inward: 6 * sigma)
        for sigmas in [-2.0, -1, -0.5, -0.25, 0, 0.25, 0.5, 1, 2] {
            let expected = pow(FrostedGlassView.outlineKept(sigmas), 1 / 2.2)
            let measured = brightness(inward: sigmas * sigma) / inside
            print("outline \(sigmas) sigmas in: \(measured) of the light, \(expected) expected")
            #expect(abs(measured - expected) < 0.06, "\(sigmas) sigmas in")
        }
    }

    /// Nearly sharp, the captured picture's corner is exact to the pixel,
    /// and the glass's curve lies on it, right up to the edges: the light
    /// the glass takes that the captured picture keeps, along each curve,
    /// comes to well under a pixel's width.
    @Test
    func testTheGlassCurveLiesOnTheCapturedPicturesCurve() throws {
        let rig = try #require(GlassFidelityRig(screen: Self.screen, scale: 2))
        let progress = 0.02
        let lean = Self.lean(.deep, progress: progress)
        let tuning = Self.tuning(.deep)
        let glass = try [Self.radius, 0].map { radius in
            try #require(rig.glass(cornerRadius: radius) { $0.apply(progress: progress, tuning: tuning, gradient: BlurGradient(), lean: lean) })
        }
        let captured = try [Self.radius, 0].map { radius in
            try #require(rig.capture(corners: lean.corners, progress: progress, tuning: tuning, cornerRadius: radius))
        }
        // A continuous corner's curve runs about 1.2 quarter circles.
        let curvePixels = 1.2 * Double.pi / 2 * Self.radius * 2
        for (x, y) in [(0.0, Self.screen.height), (Self.screen.width, Self.screen.height)] {
            let corner = lean.screenPoint(CGPoint(x: x, y: y))
            let left = max(Int(corner.x * 2) - 100, 0), top = max(Int((Self.screen.height - corner.y) * 2) - 10, 0)
            var missing = 0.0
            for row in top..<(top + 100) {
                for column in left..<(left + 200) {
                    guard let fromGlass = Self.kept(glass[0], glass[1], column: column, row: row),
                          let fromCapture = Self.kept(captured[0], captured[1], column: column, row: row) else { continue }
                    missing += pow(fromCapture, 2.2) - pow(fromGlass, 2.2)
                }
            }
            let offset = missing / curvePixels
            print("corner curve at x \(x): the glass's lies \(offset) px further in than the captured picture's")
            #expect(abs(offset) < 0.1)
        }
    }
}
