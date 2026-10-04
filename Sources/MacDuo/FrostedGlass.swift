import Foundation

/// The optics the window server effect draws: a frosted sheet hinged along
/// the bottom edge of a page, lifted off it as the lid closes.
///
/// The page is the screen as it was when the effect began, and it stays
/// where it is. The sheet is the glass. Frosted, it scatters like a perfectly
/// diffuse (Lambertian) transmitter: each point shows the light reaching it
/// from the page behind, cosine weighted about the sheet's own normal. That
/// does not depend on where the eye is, so nothing slides across the hinge
/// and no black margin opens at the sides.
///
/// A point `s` from the hinge on a sheet lifted by `lift` sits
/// `s · sin(lift)` above the page. Its light comes from a spot on the page
/// that widens with that height, which is the blur, and some of it misses the
/// page, past its top or side edges or away from it altogether, which is the
/// darkening.
///
/// Checked against a Monte Carlo trace of two million cosine weighted rays
/// per angle:
/// - Parallel to the page, the blur halves the contrast of detail at
///   `k · height = 1.2572`, the root of `x · K₁(x) = ½`.
/// - Lifted, the spot stretches, and that frequency falls to
///   `1.2572 · ((1 + cos lift) / 2)^0.8`, within 1% up to 88°.
/// - The spot's centre sits less than its own blur radius from straight
///   under the point, about half of it at 30°, so the picture is drawn where
///   it is rather than stretched.
/// - Over an unbounded page `brightness` gives `(1 + cos lift) / 2`, the
///   textbook view factor of a tilted surface.
enum FrostedGlass {

    /// Frequency, in radians per unit of height above the page, at which a
    /// sheet parallel to the page halves the contrast of detail.
    static let parallelHalfContrastFrequency = 1.2572

    /// A Gaussian of sigma `σ` halves contrast at `√(2 ln 2) / σ`.
    private static let gaussianHalfContrastSigmas = sqrt(2 * log(2.0))

    /// Height above the page of the point `along` from the hinge.
    static func height(along: Double, lift: Double) -> Double {
        along * sin(clamped(lift))
    }

    /// Sigma of the Gaussian blur that washes out detail as fast as the
    /// sheet does, per unit of height above the page.
    ///
    /// The two are matched where they halve contrast. The sheet's blur has a
    /// sharper core and longer tails than a Gaussian, so it keeps a little
    /// more fine detail and a little less coarse detail than this.
    static func gaussianSigmaPerHeight(lift: Double) -> Double {
        let share = (1 + cos(clamped(lift))) / 2
        let frequency = parallelHalfContrastFrequency * pow(share, 0.8)
        return gaussianHalfContrastSigmas / frequency
    }

    /// The share of the light reaching the sheet point `x` across and
    /// `along` up from the hinge corner that comes from the page, for a
    /// `width` by `height` sheet lifted by `lift` radians. One where all of
    /// it does.
    ///
    /// For a diffuse sheet this is the view factor from the point to the
    /// page, which for a polygon has a closed form (Lambert's): a sum over
    /// its edges of the angle each subtends, weighted by how squarely its
    /// plane faces the point's normal. The whole page lies in front of the
    /// sheet, so no clipping is needed.
    static func brightness(x: Double, along: Double, width: Double, height: Double, lift: Double) -> Double {
        let lift = clamped(lift)
        guard lift > 1e-6, width > 0, height > 0 else { return 1 }
        // On the hinge itself the formula meets a zero length edge; the
        // limit is reached from just above it.
        let s = max(along, height * 1e-6)
        // Axes: x across the hinge, y along the page away from it, z up off
        // the page. The point, and its normal toward the page.
        let point = SIMD3(x, s * cos(lift), s * sin(lift))
        let normal = SIMD3(0, sin(lift), -cos(lift))
        let corners = [
            SIMD3(0.0, 0, 0), SIMD3(width, 0, 0), SIMD3(width, height, 0), SIMD3(0.0, height, 0),
        ]
        var sum = 0.0
        for index in corners.indices {
            let a = corners[index] - point
            let b = corners[(index + 1) % corners.count] - point
            let cross = SIMD3(
                a.y * b.z - a.z * b.y,
                a.z * b.x - a.x * b.z,
                a.x * b.y - a.y * b.x
            )
            let crossLength = (cross * cross).sum().squareRoot()
            guard crossLength > 1e-12 else { continue }
            let angle = atan2(crossLength, (a * b).sum())
            sum += angle * (normal * cross).sum() / crossLength
        }
        return min(max(abs(sum) / (2 * .pi), 0), 1)
    }

    /// `brightness` on a `columns` by `rows` grid of points that includes the
    /// edges and corners, rows from the hinge up.
    static func brightnessGrid(lift: Double, width: Double, height: Double, columns: Int, rows: Int) -> [Double] {
        guard columns > 1, rows > 1 else { return [] }
        var grid = [Double](repeating: 1, count: columns * rows)
        guard clamped(lift) > 1e-6 else { return grid }
        for row in 0..<rows {
            let along = Double(row) / Double(rows - 1) * height
            for column in 0..<columns {
                let x = Double(column) / Double(columns - 1) * width
                grid[row * columns + column] = brightness(
                    x: x, along: along, width: width, height: height, lift: lift
                )
            }
        }
        return grid
    }

    /// Past a quarter turn the sheet would face away from the page.
    private static func clamped(_ lift: Double) -> Double {
        min(max(lift, 0), .pi / 2)
    }
}
