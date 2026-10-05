import AppKit
import Accelerate
import SwiftUI
import simd

/// The rounded top corners of a MacBook display with a notch.
///
/// Lying flat, the picture's top corners sit under the panel's own rounded
/// corners. Leaning back it draws away from them, and the picture's square
/// corners would show; so the picture keeps the panel's rounding, in black,
/// as part of the picture. The hinge corners stay where they are and need
/// none.
///
/// The curve is Apple's continuous corner, which eases into the straight
/// edges instead of meeting them with a step in curvature.
enum ScreenCorner {

    /// The panel's corner radius in points: 38 pixels on the 2x panel. No
    /// API reports it.
    static let notchedRadius = 19.0

    /// A `defaults` key that overrides the radius, in points, for a panel
    /// that rounds its corners differently: 0 for square corners.
    static let overrideKey = "screenCornerRadius"

    /// The radius of `screen`'s top corners, in points; 0 for square ones.
    @MainActor
    static func radius(of screen: NSScreen) -> Double {
        if let saved = UserDefaults.standard.object(forKey: overrideKey) as? NSNumber {
            return max(saved.doubleValue, 0)
        }
        return screen.safeAreaInsets.top > 0 ? notchedRadius : 0
    }

    /// The side of the square that holds one corner's cap. A continuous
    /// corner leaves the straight edges about 1.53 radii from the corner.
    static func boxSide(radius: Double) -> Double {
        2 * radius
    }

    /// The part of a box of `boxSide` that the top-left corner cuts away, in
    /// the box's own points, y up: the corner is at the box's top left.
    static func capPath(radius: Double) -> CGPath {
        let side = boxSide(radius: radius)
        guard radius > 0 else { return CGMutablePath() }
        let box = CGPath(rect: CGRect(x: 0, y: 0, width: side, height: side), transform: nil)
        // Its top-left corner at the box's, the rest far outside it.
        let reach = 8 * side
        let rounded = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: CGRect(x: 0, y: side - reach, width: reach, height: reach))
            .cgPath
        return box.subtracting(rounded)
    }

    // MARK: - The glass's corner

    /// The light the rounding leaves at a top corner of the glass, over what
    /// the square corner its edges darken keeps
    /// (`FrostedGlassView.edgeProfile`), in the picture's own points.
    struct Shade {
        /// Shares of light, row by row down from the margin above the
        /// picture, each row from the margin past the side.
        let kept: [Float]
        let count: Int
        /// How far the grid reaches past the picture's edges, in points.
        let margin: Double
        /// Points per cell.
        let step: Double

        /// The share kept `inward` points from the side and `down` from the
        /// top, between the cells' centres; all of it past the grid.
        func kept(inward: Double, down: Double) -> Double {
            let x = (inward + margin) / step - 0.5, y = (down + margin) / step - 0.5
            let last = Double(count - 1)
            guard x > -0.5, y > -0.5, x < last + 0.5, y < last + 0.5 else { return 1 }
            let cx = min(max(x, 0), last), cy = min(max(y, 0), last)
            let left = Int(cx), top = Int(cy)
            let right = min(left + 1, count - 1), bottom = min(top + 1, count - 1)
            let fx = Float(cx - Double(left)), fy = Float(cy - Double(top))
            let upper = kept[top * count + left] * (1 - fx) + kept[top * count + right] * fx
            let lower = kept[bottom * count + left] * (1 - fx) + kept[bottom * count + right] * fx
            return Double(upper * (1 - fy) + lower * fy)
        }
    }

    /// The glass's corner for an outline blurred, at the top, by a core of
    /// `core` times `sigma` points carrying `1 - skirt` of the light, and a
    /// skirt of `sigma` carrying the rest (`FrostedGlassView.outlineKept`).
    ///
    /// For one blur, the captured picture blurs its rounded corner with the
    /// rest of it, so at a point near the corner it keeps the Gaussian's
    /// share of the picture there: `K - D`, where `K` is the share a square
    /// corner keeps and `D` the share that falls on the cap. The outline
    /// keeps each blur's by its weight. The edges already keep the square
    /// corner's, the product of each edge's share, through the 1 / 2.2 power
    /// the window server blends over; the image takes away the rest,
    /// `1 - (kept / square)^(1 / 2.2)`. Both are blurred from the same
    /// pixels, so their ratio holds to the last trace of light in the
    /// margin, where it carries the picture's edge pixels out across the
    /// edge: a screen pixel the lean lays across the edge reads the same
    /// either side of it.
    ///
    /// The screen reads the image at each pixel's centre, between the
    /// image's own pixels, where its opacity, already through the 1 / 2.2
    /// power, would mix darker than the light it stands for. So the image
    /// holds each screen pixel's own share, the cap and the picture blurred
    /// over a pixel's width at the least, as the captured picture's pixels
    /// cover them, and twice as finely as the screen, where a mix of
    /// neighbours stays true to it.
    ///
    /// - Parameter screenScale: the screen's pixels per point.
    nonisolated static func shade(radius: Double, sigma: Double, core: Double, skirt: Double, screenScale: Double) -> Shade? {
        guard radius > 0, screenScale > 0 else { return nil }
        // A box a pixel wide spreads as far as a Gaussian of this sigma.
        let pixel = 1 / (screenScale * 12.squareRoot())
        let skirtSigma = max(sigma, pixel), coreSigma = max(core * sigma, pixel)
        let scale = min(2 * screenScale, max(2.5 / coreSigma, 0.05))
        let step = 1 / scale
        // Past four and a half sigmas less than a 255th of the light is left.
        let reach = 4.5 * skirtSigma + step
        // A whole number of pixels, so the edges fall between two.
        let margin = (reach / step).rounded(.up) * step
        let side = boxSide(radius: radius)
        let count = Int(((margin + side + reach) / step).rounded(.up))
        guard count > 0, count < 4096 else { return nil }

        // The cap's coverage, first row at the top, which is the margin
        // above the picture.
        var coverage = [UInt8](repeating: 0, count: count * count)
        let drew = coverage.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: count, height: count, bitsPerComponent: 8, bytesPerRow: count,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.concatenate(CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: margin * scale, ty: Double(count) - (side + margin) * scale
            ))
            context.addPath(capPath(radius: radius))
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath()
            return true
        }
        guard drew else { return nil }
        let cap = coverage.map { Float($0) / 255 }

        // The picture's side, whose edge falls between pixels, and its top,
        // the same: a square corner's share is the product of the two.
        let firstInside = Int((margin / step).rounded())
        let edge = (0..<count).map { Float($0 >= firstInside ? 1 : 0) }
        let coreEdge = blurred(line: edge, sigma: coreSigma * scale)
        let skirtEdge = blurred(line: edge, sigma: skirtSigma * scale)
        let capCore = blurred(cap, count: count, sigma: coreSigma * scale)
        let capSkirt = skirt > 0 ? blurred(cap, count: count, sigma: skirtSigma * scale) : capCore
        let weight = Float(min(max(skirt, 0), 1))
        let edgeKept = zip(coreEdge, skirtEdge).map { (1 - weight) * $0 + weight * $1 }

        var kept = [Float](repeating: 1, count: count * count)
        for row in 0..<count {
            for column in 0..<count {
                let index = row * count + column
                let square = edgeKept[row] * edgeKept[column]
                // Past every trace of light, nothing to take away.
                guard square > 0 else { continue }
                let left = (1 - weight) * (coreEdge[row] * coreEdge[column] - capCore[index])
                    + weight * (skirtEdge[row] * skirtEdge[column] - capSkirt[index])
                kept[index] = min(max(left, 0) / square, 1)
            }
        }
        return Shade(kept: kept, count: count, margin: margin, step: step)
    }

    /// A top corner's darkening drawn for the screen, where the lean puts
    /// it: black, as opaque as the light the rounding takes,
    /// `1 - kept^(1 / 2.2)`, through the power the window server blends over.
    ///
    /// One pixel for each of the screen's, or fewer where the blur is too
    /// wide to need them, and each worked out at its own centre, back
    /// through the lean. Shown at the size it is drawn, with no mesh,
    /// nothing between it and the screen resamples it.
    ///
    /// - Returns: the image, first row at the top; its frame, in screen
    ///   points from the bottom left; and its pixels per point. `nil` when
    ///   the corner is off screen.
    nonisolated static func image(
        of shade: Shade, right: Bool, lean: GlassLean, screenScale: Double
    ) -> (image: CGImage, frame: CGRect, scale: Double)? {
        let width = Double(lean.screenSize.width), height = Double(lean.screenSize.height)
        let near = -shade.margin, far = Double(shade.count) * shade.step - shade.margin
        func picture(inward: Double, down: Double) -> CGPoint {
            CGPoint(x: right ? width - inward : inward, y: height - down)
        }
        let reach = [(near, near), (far, near), (far, far), (near, far)].map {
            lean.screenPoint(picture(inward: $0.0, down: $0.1))
        }
        let scale = min(screenScale, 1 / shade.step)
        let bounds = CGRect(
            x: reach.map(\.x).min()!, y: reach.map(\.y).min()!,
            width: reach.map(\.x).max()! - reach.map(\.x).min()!,
            height: reach.map(\.y).max()! - reach.map(\.y).min()!
        ).intersection(CGRect(origin: .zero, size: lean.screenSize))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        // On the screen's pixel grid.
        let minX = (Double(bounds.minX) * scale).rounded(.down) / scale
        let minY = (Double(bounds.minY) * scale).rounded(.down) / scale
        let columns = Int(((Double(bounds.maxX) - minX) * scale).rounded(.up))
        let rows = Int(((Double(bounds.maxY) - minY) * scale).rounded(.up))
        guard columns > 0, rows > 0, columns * rows < 4_000_000 else { return nil }
        let maxY = minY + Double(rows) / scale

        let back = lean.screenToPicture
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        for row in 0..<rows {
            let y = maxY - (Double(row) + 0.5) / scale
            for column in 0..<columns {
                let x = minX + (Double(column) + 0.5) / scale
                let mapped = back * SIMD3(x, y, 1)
                let pictureX = mapped.x / mapped.z, pictureY = mapped.y / mapped.z
                let kept = shade.kept(inward: right ? width - pictureX : pictureX, down: height - pictureY)
                let opacity = 1 - pow(min(max(kept, 0), 1), 1 / 2.2)
                pixels[(row * columns + column) * 4 + 3] = UInt8((min(max(opacity, 0), 1) * 255).rounded())
            }
        }
        guard let image = pixels.withUnsafeMutableBytes({ bytes in
            CGContext(
                data: bytes.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )?.makeImage()
        }) else { return nil }
        return (image, CGRect(x: minX, y: minY, width: Double(columns) / scale, height: Double(rows) / scale), scale)
    }

    /// Weights of a Gaussian of `sigma` pixels, to four and a half sigmas
    /// and one neighbour at the least, summing to one.
    nonisolated private static func kernel(sigma: Double) -> [Float] {
        let radius = max(Int((4.5 * sigma).rounded(.up)), 1)
        let weights = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * max(sigma, 1e-3) * max(sigma, 1e-3)))) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }

    /// A Gaussian of `sigma` pixels along a line, black past its ends.
    nonisolated private static func blurred(line values: [Float], sigma: Double) -> [Float] {
        let weights = kernel(sigma: sigma)
        let radius = weights.count / 2
        return values.indices.map { index in
            var sum: Float = 0
            for (offset, weight) in zip(-radius...radius, weights) {
                let source = index + offset
                if source >= 0, source < values.count { sum += values[source] * weight }
            }
            return sum
        }
    }

    /// A Gaussian of `sigma` pixels over a square of `count` pixels, black
    /// past its edges.
    nonisolated private static func blurred(_ values: [Float], count: Int, sigma: Double) -> [Float] {
        let weights = kernel(sigma: sigma)
        var source = values
        var result = [Float](repeating: 0, count: values.count)
        let error = source.withUnsafeMutableBufferPointer { input in
            result.withUnsafeMutableBufferPointer { output in
                var from = vImage_Buffer(
                    data: input.baseAddress, height: vImagePixelCount(count), width: vImagePixelCount(count), rowBytes: count * 4
                )
                var to = vImage_Buffer(
                    data: output.baseAddress, height: vImagePixelCount(count), width: vImagePixelCount(count), rowBytes: count * 4
                )
                return vImageSepConvolve_PlanarF(
                    &from, &to, nil, 0, 0,
                    weights, UInt32(weights.count), weights, UInt32(weights.count),
                    0, 0, vImage_Flags(kvImageBackgroundColorFill)
                )
            }
        }
        if error == kvImageNoError { return result }
        // By rows, then columns.
        let rows = (0..<count).flatMap { row in blurred(line: Array(values[row * count..<(row + 1) * count]), sigma: sigma) }
        var columns = rows
        for column in 0..<count {
            let blurredColumn = blurred(line: (0..<count).map { rows[$0 * count + column] }, sigma: sigma)
            for row in 0..<count { columns[row * count + column] = blurredColumn[row] }
        }
        return columns
    }
}
