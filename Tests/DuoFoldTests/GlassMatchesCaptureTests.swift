import CoreGraphics
import Foundation
import Testing
@testable import DuoFold

/// The window server's glass blurs and dims exactly as the captured picture
/// does, apart from the lean. These pin it to the capture path's own
/// numbers: the uniforms `DepthRenderer` hands its shader, and the formulas
/// `DepthShaders.depthFragment` runs on them.
struct GlassMatchesCaptureTests {

    private let gradient = BlurGradient()
    private static let screen = CGSize(width: 1512, height: 982)

    private static let progresses = [0.0, 0.02, 0.1, 0.3, 0.55, 0.8, 1.0]
    private static let settings: [DepthTuning] = [
        // The factory settings.
        DepthTuning(blurEvenness: 0, dimReach: 0.5, maxBlurRadius: 135, maxDim: 1),
        DepthTuning(blurEvenness: 0.4, dimReach: 0.7, maxBlurRadius: 55, maxDim: 0.4),
        DepthTuning(blurEvenness: 1, dimReach: 1, maxBlurRadius: 160, maxDim: 0.75),
        DepthTuning(blurEvenness: 0.15, dimReach: 0.2, maxBlurRadius: 10, maxDim: 0),
    ]

    /// The capture path's uniforms for a picture lying flat on the screen.
    private func uniforms(progress: Double, tuning: DepthTuning, pixelScale: CGFloat) throws -> DepthRenderer.Uniforms {
        let size = Self.screen
        let layout = try #require(BlurStack.Layout(
            pictureWidth: Int(size.width * pixelScale),
            pictureHeight: Int(size.height * pixelScale),
            minimumMargin: Int(120 * pixelScale)
        ))
        return DepthRenderer.uniforms(
            corners: [
                CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height),
            ],
            layout: layout,
            screenSize: size,
            pixelScale: pixelScale,
            blurStrength: gradient.blurStrength(progress: progress),
            dimStrength: gradient.dimStrength(progress: progress),
            hingeFloor: tuning.blurEvenness,
            dimHingeFloor: gradient.dimHingeFloor,
            dimReach: tuning.dimReach,
            maxBlurRadius: tuning.maxBlurRadius,
            maxDim: tuning.maxDim
        )
    }

    /// The shader's blur at `height`, in points.
    private func capturedSigma(height: Double, uniforms: DepthRenderer.Uniforms, pixelScale: CGFloat) -> Double {
        let hingeSigma = Double(uniforms.blur.x), sigmaRange = Double(uniforms.blur.y)
        return (hingeSigma + sigmaRange * height * height * sqrt(sqrt(height))) / Double(pixelScale)
    }

    /// The share of the encoded value the shader keeps at `height`: it scales
    /// linear light by `light`, and the target encodes it again.
    private func capturedKept(height: Double, uniforms: DepthRenderer.Uniforms) -> Double {
        let maxDim = Double(uniforms.light.x), dimFloor = Double(uniforms.light.y)
        let dimStrength = Double(uniforms.light.z), dimReach = Double(uniforms.light.w)
        let t = min(max(height / max(dimReach, 0.02), 0), 1)
        let spread = t * t * (3 - 2 * t)
        let fade = dimStrength * (dimFloor + (1 - dimFloor) * spread)
        let light = pow(max(1 - maxDim * fade, 0), 2.2)
        return pow(light, 1 / 2.2)
    }

    private func isClose(_ a: Double, _ b: Double, relative: Double = 1e-5) -> Bool {
        abs(a - b) <= relative * max(abs(a), abs(b)) + 1e-6
    }

    @Test(arguments: progresses, settings)
    func testSigmaIsTheCapturedPictures(progress: Double, tuning: DepthTuning) throws {
        for pixelScale: CGFloat in [1, 2] {
            let captured = try uniforms(progress: progress, tuning: tuning, pixelScale: pixelScale)
            let span = gradient.sigmaSpan(
                progress: progress,
                maxBlurRadius: tuning.maxBlurRadius,
                evenness: tuning.blurEvenness
            )
            #expect(isClose(span.hinge, Double(captured.blur.x) / Double(pixelScale)))
            #expect(isClose(span.range, Double(captured.blur.y) / Double(pixelScale)))
            for height in stride(from: 0.0, through: 1, by: 0.05) {
                let sigma = gradient.sigma(
                    progress: progress,
                    height: height,
                    maxBlurRadius: tuning.maxBlurRadius,
                    evenness: tuning.blurEvenness
                )
                #expect(isClose(sigma, capturedSigma(height: height, uniforms: captured, pixelScale: pixelScale)))
            }
        }
    }

    @Test(arguments: progresses, settings)
    func testBandsRunTheCapturedSigma(progress: Double, tuning: DepthTuning) throws {
        let height = Double(Self.screen.height)
        let captured = try uniforms(progress: progress, tuning: tuning, pixelScale: 2)
        let sigma = { (share: Double) in self.capturedSigma(height: share, uniforms: captured, pixelScale: 2) }
        let profile = FrostedGlassView.blurProfile(progress: progress, tuning: tuning, gradient: gradient, height: height)
        let k = WindowServerBlur.sigmaPerRadius

        // At every height the bands aim for the shader's blur.
        for share in stride(from: 0.0, through: 1, by: 0.025) {
            #expect(isClose(profile.radius(at: share * height) * k, sigma(share)))
        }

        let layout = FrostBandLayout()
        let bands = layout.bands(for: profile, maximumRadius: height / 2)
        guard sigma(1) >= layout.minimumRadius * k else {
            // Too little blur anywhere to tell from the screen.
            #expect(bands.isEmpty)
            return
        }
        #expect(!bands.isEmpty)
        #expect(bands.count <= layout.maximumBands)
        // Each band blurs exactly as the shader does where it turns opaque.
        for band in bands {
            let knot = try #require(band.fade.last)
            #expect(knot.opacity == 1)
            #expect(isClose(band.radius * k, sigma(knot.position / height)))
        }
        // The top band is the far edge's blur and reaches the top.
        #expect(isClose(bands.last!.radius * k, sigma(1)))
        #expect(bands.last!.top == height)
        // A blurred hinge is covered from the hinge up; a sharp one shows
        // the screen as it is.
        if sigma(0) >= layout.minimumRadius * k {
            #expect(isClose(bands[0].radius * k, sigma(0)))
            #expect(bands[0].fade == [FrostBandLayout.Stop(position: 0, opacity: 1)])
        } else {
            #expect(bands[0].fade.first == FrostBandLayout.Stop(position: 0, opacity: 0))
        }
    }

    @Test(arguments: progresses, settings)
    func testShadeTakesWhatTheShaderTakes(progress: Double, tuning: DepthTuning) throws {
        let height = Double(Self.screen.height)
        let captured = try uniforms(progress: progress, tuning: tuning, pixelScale: 2)
        // The glass and the shader dim from the same inputs.
        #expect(Double(captured.light.x) == Double(Float(tuning.maxDim)))
        #expect(isClose(Double(captured.light.y), gradient.dimHingeFloor))
        #expect(isClose(Double(captured.light.z), gradient.dimStrength(progress: progress)))
        #expect(isClose(Double(captured.light.w), tuning.dimReach))

        let stops = FrostedGlassView.shadeStops(progress: progress, tuning: tuning, gradient: gradient, height: height)
        #expect(stops.first?.position == 0)
        #expect(stops.last?.position == height)
        for (lower, upper) in zip(stops, stops.dropFirst()) {
            #expect(upper.position > lower.position)
        }
        // The layer runs straight between stops. Everywhere up the glass it
        // takes off what the shader does, within half a step of 8 bits.
        var stop = 0
        for sample in 0...1000 {
            let position = Double(sample) / 1000 * height
            while stop + 2 < stops.count, stops[stop + 1].position < position { stop += 1 }
            let lower = stops[stop], upper = stops[stop + 1]
            let t = min(max((position - lower.position) / (upper.position - lower.position), 0), 1)
            let opacity = lower.opacity + (upper.opacity - lower.opacity) * t
            let expected = 1 - capturedKept(height: position / height, uniforms: captured)
            #expect(abs(opacity - expected) < 0.5 / 255, "at \(position): \(opacity) against \(expected)")
        }
    }

    @Test
    func testTheBlurStartsAtTheStartAngleAndBuildsOverTheFullTravel() {
        let tuning = DepthTuning(blurEvenness: 0, dimReach: 0.5, maxBlurRadius: 135, maxDim: 1)
        let far = { (progress: Double) in
            self.gradient.sigma(progress: progress, height: 1, maxBlurRadius: tuning.maxBlurRadius, evenness: 0)
        }
        #expect(far(0) == 0)
        // A quarter of the way, the far edge has 7% of its blur, and all 90
        // points only at full effect.
        #expect(abs(far(0.25) / far(1) - pow(0.25, 1.6 * 1.2)) < 1e-12)
        #expect(abs(far(1) - 90) < 1e-9)
    }
}
