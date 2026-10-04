import Foundation

/// How a blur that rises up the glass is split into bands of uniform blur.
///
/// The window server's own `variableBlur` switches between shrunk copies of
/// the screen as its radius grows, which shows as horizontal lines across a
/// blur that rises up the screen. A uniform blur shows none, so the rising
/// blur is drawn as a stack of them, each fading in over the one below.
///
/// Band `i` is fully opaque at its knot, where its radius is exactly the blur
/// the glass has there, and the band above starts fading in from that knot.
/// Knots are close together by the hinge, where the blur grows fastest
/// relative to itself (see `blurFloor`). Below the first knot the plain
/// screen shows through, which is radius zero.
///
/// Between two knots the fade is not an S-curve. Two blurs mixed by `w` keep
/// detail as `(1 - w) · C₁ + w · C₂`, where `Cᵢ` is how much contrast each
/// keeps, and `w` is chosen so the mix halves contrast at the same frequency
/// as the true blur at that height. An S-curve holds each band alone around
/// its knot, so the blur pauses there and then catches up.
///
/// Measured row by row offscreen (gratings behind the real bands, rendered by
/// `CARenderer`), in `log(radius + 2)`: with the top blur at 60 points over
/// 400, these eight bands stay within 0.03 rms of the true blur (worst
/// 0.07) and grow evenly to 0.026 in second difference, where an S-curve
/// fade on the same knots reaches 0.053, and eight quadratically spaced
/// S-curve bands 0.064 with a worst error of 0.18 over a quarter more area.
struct FrostBandLayout: Equatable {

    struct Stop: Equatable {
        /// Points up from the hinge.
        var position: Double
        var opacity: Double
    }

    struct Band: Equatable {
        /// Blur radius, in the same points as the positions.
        var radius: Double
        /// The band's frame, bottom and top, in points up from the hinge. It
        /// reaches past the visible part, so the blur at its edges takes in
        /// the real screen there rather than nothing.
        var bottom: Double
        var top: Double
        /// Clear below the first stop, opaque above the last.
        var fade: [Stop]
    }

    /// Radius below which a blur cannot be told from the screen, so the
    /// plain screen stands in for it.
    var minimumRadius = 0.5
    /// Knots are evenly spaced in `log(radius + blurFloor)`. Small blurs are
    /// told apart by how many points they differ by, and large ones by their
    /// ratio, and this is roughly where one gives way to the other.
    var blurFloor = 2.0
    /// Largest step between neighbouring knots, in that scale: their
    /// `radius + blurFloor` differ by at most this ratio.
    var ratio = 1.35
    /// Each band is a blur pass over its part of the screen. Past eight, the
    /// blur grows no more evenly.
    var maximumBands = 8
    /// How far past its visible part each band captures, in blur radii.
    var marginRadii = 2.5
    var stopsPerFade = 9

    /// The bands for a blur of `radiusPerHeight` points per point up the
    /// glass, on glass `height` points tall, with no band blurring more
    /// than `maximumRadius`. Lowest band first.
    func bands(radiusPerHeight: Double, height: Double, maximumRadius: Double) -> [Band] {
        guard radiusPerHeight > 0, height > 0 else { return [] }
        let topRadius = min(radiusPerHeight * height, maximumRadius)
        guard topRadius >= minimumRadius else { return [] }

        // Radii at the knots, evenly spaced from the smallest visible blur up
        // to the top one, with bigger steps if the bands run out.
        let low = log(minimumRadius + blurFloor)
        let span = log(topRadius + blurFloor) - low
        let steps = max(Int(ceil(span / log(ratio) - 1e-9)), 1)
        let count = min(steps, max(maximumBands - 1, 1))
        let radii = (0...count).map { exp(low + span * Double($0) / Double(count)) - blurFloor }
        let knots = radii.map { min($0 / radiusPerHeight, height) }

        return radii.indices.map { index in
            let radius = radii[index]
            let knot = knots[index]
            let below = index > 0 ? knots[index - 1] : 0
            let above = index + 1 < knots.count ? knots[index + 1] : height
            let margin = marginRadii * radius
            return Band(
                radius: radius,
                bottom: max(below - margin, 0),
                top: min(max(above, knot) + margin, height),
                fade: fade(
                    from: below,
                    to: knot,
                    radiusBelow: index > 0 ? radii[index - 1] : 0,
                    radius: radius,
                    radiusPerHeight: radiusPerHeight
                )
            )
        }
    }

    /// Opacity of a band of `radius` over the one of `radiusBelow`, from
    /// clear at `from` to opaque at `to`.
    private func fade(
        from: Double,
        to: Double,
        radiusBelow: Double,
        radius: Double,
        radiusPerHeight: Double
    ) -> [Stop] {
        guard to > from else { return [Stop(position: to, opacity: 1)] }
        return (0..<stopsPerFade).map { stop in
            let t = Double(stop) / Double(stopsPerFade - 1)
            let position = from + (to - from) * t
            let opacity: Double
            if stop == 0 || stop == stopsPerFade - 1 {
                // Exact at both ends, so no hairline of the band below
                // shows through at the knot.
                opacity = t
            } else if radiusBelow <= 0 {
                // Over the plain screen, which keeps all detail, no mix halves
                // contrast where a tiny blur would; this fade is under the
                // smallest visible radius anyway.
                opacity = t * t * (3 - 2 * t)
            } else {
                opacity = Self.matchedOpacity(
                    radiusBelow: radiusBelow,
                    radius: radius,
                    target: position * radiusPerHeight
                )
            }
            return Stop(position: position, opacity: opacity)
        }
    }

    /// The `w` for which blurs of `radiusBelow` and `radius` mixed as
    /// `(1 - w, w)` halve contrast at the same frequency as one blur of
    /// `target`. At the frequency where a Gaussian of radius `target` keeps
    /// half the contrast, one of radius `r` keeps `2^-(r / target)²`.
    static func matchedOpacity(radiusBelow: Double, radius: Double, target: Double) -> Double {
        guard target > 0, radius > radiusBelow else { return 1 }
        let kept = { (r: Double) in pow(2, -(r / target) * (r / target)) }
        let below = kept(radiusBelow), own = kept(radius)
        guard below - own > 1e-9 else { return 1 }
        return min(max((below - 0.5) / (below - own), 0), 1)
    }
}
