import Foundation

/// How far out of focus the picture is at a given height, and how much light
/// it has lost. Height is 0 at the hinge edge and 1 at the far edge.
///
/// The captured picture's shader (`DepthShaders.depthFragment`, fed by
/// `DepthRenderer.uniforms`) draws these rules per pixel, and the window
/// server's glass draws them with backdrop bands and a darkening layer, so
/// both modes blur and dim alike.
struct BlurGradient: Equatable {

    /// Exponent on the closing travel. Values above 1 start slowly.
    var blurCurve: Double = 1.6

    /// Exponent on the closing travel for the dimming.
    var dimCurve: Double = 0.7

    /// Dimming at the hinge edge, as a fraction of the dimming at the far
    /// edge.
    var dimHingeFloor: Double = 0.2

    /// Exponent on the blur strength. It keeps modest lid travel from
    /// jumping into a strong blur.
    var blurResponse: Double = 1.2

    /// Exponent on the height. It keeps the hinge edge nearly sharp and
    /// gathers the blur toward the far edge.
    var blurHeightCurve: Double = 2.25

    /// Converts the blur setting, a radius, into a Gaussian sigma.
    static let sigmaPerRadius = 2.0 / 3.0

    func blurStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), blurCurve)
    }

    func dimStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), dimCurve)
    }

    /// Gaussian sigma at the hinge edge, and how much more the far edge
    /// gets, in points: the shader's `hingeSigma` and `sigmaRange`, which it
    /// takes in pixels.
    ///
    /// - Parameters:
    ///   - maxBlurRadius: the blur setting, in points.
    ///   - evenness: the share of the far edge's blur the hinge gets.
    func sigmaSpan(progress: Double, maxBlurRadius: Double, evenness: Double) -> (hinge: Double, range: Double) {
        let far = pow(blurStrength(progress: progress), blurResponse) * maxBlurRadius * Self.sigmaPerRadius
        return (far * evenness, far * (1 - evenness))
    }

    /// Gaussian sigma at `height`, in points.
    func sigma(progress: Double, height: Double, maxBlurRadius: Double, evenness: Double) -> Double {
        let span = sigmaSpan(progress: progress, maxBlurRadius: maxBlurRadius, evenness: evenness)
        return span.hinge + span.range * pow(min(max(height, 0), 1), blurHeightCurve)
    }

    /// The share of its brightness the picture loses at `height`.
    ///
    /// The shader scales linear light by `(1 - dimming)^2.2`, which takes
    /// this share off the encoded value.
    ///
    /// - Parameters:
    ///   - maxDim: the dimming setting, the share lost at full strength.
    ///   - reach: the height from which the dimming is at full strength.
    func dimming(progress: Double, height: Double, maxDim: Double, reach: Double) -> Double {
        // smoothstep rather than a clamped ratio, so the height where the
        // dimming reaches full strength leaves no visible edge.
        let t = min(max(height / max(reach, 0.02), 0), 1)
        let spread = t * t * (3 - 2 * t)
        let fade = dimStrength(progress: progress) * (dimHingeFloor + (1 - dimHingeFloor) * spread)
        return min(max(maxDim * fade, 0), 1)
    }
}
