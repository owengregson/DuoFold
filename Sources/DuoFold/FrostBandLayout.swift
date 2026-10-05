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
/// Knots are evenly spaced in blur (see `blurFloor`), so they gather where
/// the blur grows fastest relative to itself. Below the first knot the plain
/// screen shows through, which is radius zero, unless the hinge itself is
/// blurred: then the first band is that blur, opaque from the hinge up.
///
/// Between two knots the fade is not an S-curve. Two blurs mixed by `w` keep
/// detail as `(1 - w) · C₁ + w · C₂`, where `Cᵢ` is how much contrast each
/// keeps, and `w` is chosen so the mix halves contrast at the same frequency
/// as the true blur at that height. An S-curve holds each band alone around
/// its knot, so the blur pauses there and then catches up.
///
/// Measured row by row offscreen (gratings behind the real bands, rendered by
/// `CARenderer`), in `log(radius + 2)`: for a blur rising evenly to 60 points
/// over 400, these eight bands stay within 0.03 rms of the true blur (worst
/// 0.07) and grow evenly to 0.026 in second difference, where an S-curve
/// fade on the same knots reaches 0.053, and eight quadratically spaced
/// S-curve bands 0.064 with a worst error of 0.18 over a quarter more area.
struct FrostBandLayout: Equatable {

    /// A blur that rises up the glass, in points of radius:
    /// `floor + rise · (position / height)^exponent`.
    struct Profile: Equatable {
        /// The blur at the hinge.
        var floor: Double
        /// How much more the top of the glass gets.
        var rise: Double
        var exponent: Double
        /// The glass's height, in points.
        var height: Double

        func radius(at position: Double) -> Double {
            floor + rise * pow(min(max(position / height, 0), 1), exponent)
        }

        /// The lowest point the blur reaches `radius`: the hinge for a
        /// radius it already has there, the top for one it never reaches.
        func position(ofRadius radius: Double) -> Double {
            guard rise > 0, radius > floor else { return 0 }
            return height * pow(min((radius - floor) / rise, 1), 1 / exponent)
        }
    }

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

    /// The bands for `profile`, with no band blurring more than
    /// `maximumRadius`. Lowest band first.
    func bands(for profile: Profile, maximumRadius: Double) -> [Band] {
        let height = profile.height
        guard height > 0, profile.rise >= 0 else { return [] }
        let topRadius = min(profile.radius(at: height), maximumRadius)
        guard topRadius >= minimumRadius else { return [] }

        // Radii at the knots, evenly spaced from the blur at the hinge, or
        // the smallest visible one, up to the top one, with bigger steps if
        // the bands run out. A blur the same all the way up is one band.
        let lowRadius = min(max(profile.floor, minimumRadius), topRadius)
        let low = log(lowRadius + blurFloor)
        let span = log(topRadius + blurFloor) - low
        let steps = span > 1e-9 ? max(Int(ceil(span / log(ratio) - 1e-9)), 1) : 0
        let count = min(steps, max(maximumBands - 1, 1))
        let radii = (0...count).map { index in
            // Exact at both ends, so the bottom band starts at the hinge
            // and the top one reaches the top.
            if index == count { return topRadius }
            if index == 0 { return lowRadius }
            return exp(low + span * Double(index) / Double(count)) - blurFloor
        }
        let knots = count > 0 ? radii.map { profile.position(ofRadius: $0) } : [0]

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
                    profile: profile
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
        profile: Profile
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
                    target: profile.radius(at: position)
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
