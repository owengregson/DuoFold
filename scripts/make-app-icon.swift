#!/usr/bin/env swift
//
// Renders the Mac Duo app icon and packs it into Resources/AppIcon.icns.
//
//   swift scripts/make-app-icon.swift [output directory]
//
// The iconset and a 1024 px preview go to the output directory (default
// `build`, which git ignores). Needs only the Command Line Tools: the icon is
// drawn with Core Graphics and Core Image, then packed with `iconutil`.
//
// The picture is the effect itself: a MacBook whose screen leans back as the
// lid closes, sharp at the hinge and blurring and dimming towards the far
// edge, the same way the renderer draws it.

import AppKit
import CoreImage

// MARK: - Grid

/// Everything below is laid out on Apple's 1024 pt macOS icon grid: an
/// 824 pt continuous-corner body with a 100 pt margin for the shadow.
let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185.4

/// The lid as seen from the front, leaning back: the top edge is further away,
/// so it is narrower and the lid looks shorter than it is.
struct Lid {
    static let hingeY: CGFloat = 350
    static let topY: CGFloat = 744
    static let bottomHalfWidth: CGFloat = 300
    static let topHalfWidth: CGFloat = 240
    /// The aluminium edge around the glass.
    static let rim: CGFloat = 6
    /// Black bezel inside the rim. The top one is foreshortened with the lid.
    static let sideBezel: CGFloat = 14
    static let topBezel: CGFloat = 12
    static let chin: CGFloat = 22
}

/// The base seen almost edge on, so only its front lip shows.
struct Base {
    static let halfWidth: CGFloat = 346
    static let top: CGFloat = Lid.hingeY
    static let height: CGFloat = 40
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: sRGB,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ]
    )!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: sRGB,
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0)
    )!
}

// MARK: - Shapes

/// Apple's continuous corner: the curvature ramps up instead of jumping from
/// a straight edge onto a circle, which is what makes the macOS icon shape
/// read as a squircle rather than a plain rounded rectangle. The constants
/// are the usual Bézier fit of that curve, for one corner in units of the
/// radius, measured inwards from the corner along each edge.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let limit = min(rect.width, rect.height) / 2 / 1.52866483
    let r = min(radius, limit)
    // (along the edge we arrive on, along the edge we leave on) per point.
    let half: [(CGFloat, CGFloat)] = [
        (1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06549600),
        (0.63149399, 0.07491100),
        (0.37282392, 0.16905899), (0.16905899, 0.37282392), (0.07491100, 0.63149399),
        (0.06549600, 0.66993427),
        (0, 0.86840689), (0, 1.08849323), (0, 1.52866483),
    ]
    let path = CGMutablePath()
    // Corners in drawing order, each with the directions of the edge it
    // arrives on and the edge it leaves on, in a y-up space.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    for (index, (corner, arriving, leaving)) in corners.enumerated() {
        func point(_ back: CGFloat, _ forward: CGFloat) -> CGPoint {
            CGPoint(
                x: corner.x - arriving.dx * back * r + leaving.dx * forward * r,
                y: corner.y - arriving.dy * back * r + leaving.dy * forward * r
            )
        }
        let start = point(1.52866483, 0)
        if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
        path.addCurve(to: point(half[2].0, half[2].1), control1: point(half[0].0, half[0].1), control2: point(half[1].0, half[1].1))
        path.addLine(to: point(half[3].0, half[3].1))
        path.addCurve(to: point(half[6].0, half[6].1), control1: point(half[4].0, half[4].1), control2: point(half[5].0, half[5].1))
        path.addLine(to: point(half[7].0, half[7].1))
        path.addCurve(to: point(half[10].0, half[10].1), control1: point(half[8].0, half[8].1), control2: point(half[9].0, half[9].1))
    }
    path.closeSubpath()
    return path
}

/// A quadrilateral with rounded corners, for the leaning lid.
func roundedQuad(_ points: [CGPoint], radii: [CGFloat]) -> CGPath {
    let path = CGMutablePath()
    let count = points.count
    for index in 0..<count {
        let previous = points[(index + count - 1) % count]
        let current = points[index]
        let next = points[(index + 1) % count]
        let r = radii[index]
        func toward(_ target: CGPoint, by distance: CGFloat) -> CGPoint {
            let dx = target.x - current.x, dy = target.y - current.y
            let length = hypot(dx, dy)
            return CGPoint(x: current.x + dx / length * distance, y: current.y + dy / length * distance)
        }
        let entry = toward(previous, by: r)
        let exit = toward(next, by: r)
        if index == 0 { path.move(to: entry) } else { path.addLine(to: entry) }
        path.addQuadCurve(to: exit, control: current)
    }
    path.closeSubpath()
    return path
}

/// Corners listed bottom left, bottom right, top right, top left.
func lidCorners(inset: (side: CGFloat, top: CGFloat, bottom: CGFloat) = (0, 0, 0)) -> [CGPoint] {
    let centre = canvas / 2
    let bottomY = Lid.hingeY + inset.bottom
    let topY = Lid.topY - inset.top
    // Moving an edge inwards along the slanted side shifts it sideways too.
    func halfWidth(at y: CGFloat) -> CGFloat {
        let t = (y - Lid.hingeY) / (Lid.topY - Lid.hingeY)
        return Lid.bottomHalfWidth + (Lid.topHalfWidth - Lid.bottomHalfWidth) * t - inset.side
    }
    return [
        CGPoint(x: centre - halfWidth(at: bottomY), y: bottomY),
        CGPoint(x: centre + halfWidth(at: bottomY), y: bottomY),
        CGPoint(x: centre + halfWidth(at: topY), y: topY),
        CGPoint(x: centre - halfWidth(at: topY), y: topY),
    ]
}

// MARK: - Screen picture

let ciContext = CIContext(options: [
    .workingColorSpace: sRGB,
    .outputColorSpace: sRGB,
    .cacheIntermediates: false,
])

/// A wallpaper in the app's own colours: night blue above, a magenta and
/// peach glow rising from below. Drawn flat; the lid's perspective comes later.
func wallpaper(width: Int, height: Int, detailed: Bool) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let w = CGFloat(width), h = CGFloat(height)
    context.drawLinearGradient(
        gradient([
            (0, colour(0x2A1E78)),
            (0.55, colour(0x101A5C)),
            (1, colour(0x060B2E)),
        ]),
        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: []
    )
    // Overlapping glows, so the blur has shapes to soften.
    func glow(_ centre: CGPoint, _ radius: CGFloat, _ stops: [(CGFloat, CGColor)]) {
        context.drawRadialGradient(
            gradient(stops),
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: radius, options: []
        )
    }
    glow(CGPoint(x: w * 0.78, y: h * 0.18), w * 0.62, [
        (0, colour(0xFF5FA2, 0.95)), (0.45, colour(0xD63F8C, 0.55)), (1, colour(0xD63F8C, 0)),
    ])
    glow(CGPoint(x: w * 0.12, y: -h * 0.05), w * 0.55, [
        (0, colour(0xFFE2C4, 1)), (0.35, colour(0xFFB08A, 0.75)), (1, colour(0xFF8A7A, 0)),
    ])
    glow(CGPoint(x: w * 0.30, y: h * 0.62), w * 0.30, [
        (0, colour(0x6F5BFF, 0.6)), (1, colour(0x6F5BFF, 0)),
    ])
    guard detailed else { return context.makeImage()! }

    // Two windows: the one standing on the hinge stays crisp, the one near
    // the far edge melts into the blur. Without hard edges the blur would
    // have nothing to show. Tinted, so they dim to violet rather than grey.
    func window(_ frame: CGRect, photoShare: CGFloat) {
        let radius = w * 0.028
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -w * 0.008), blur: w * 0.035, color: colour(0x0A0530, 0.45))
        context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(colour(0xF6F1FF, 0.96))
        context.fillPath()
        context.restoreGState()
        // Traffic lights.
        let light = w * 0.0125
        for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            let centre = CGPoint(x: frame.minX + w * 0.03 + CGFloat(index) * light * 2.9, y: frame.maxY - w * 0.03)
            context.setFillColor(colour(hex))
            context.fillEllipse(in: CGRect(x: centre.x - light, y: centre.y - light, width: 2 * light, height: 2 * light))
        }
        // A picture under a few lines of text.
        let inset = w * 0.03
        let photo = CGRect(x: frame.minX + inset, y: frame.minY + inset, width: frame.width - 2 * inset, height: frame.height * photoShare)
        context.saveGState()
        context.addPath(CGPath(roundedRect: photo, cornerWidth: w * 0.012, cornerHeight: w * 0.012, transform: nil))
        context.clip()
        context.drawLinearGradient(
            gradient([(0, colour(0xFFA27E)), (0.5, colour(0xE0559A)), (1, colour(0x7B5CFF))]),
            start: CGPoint(x: photo.minX, y: photo.minY), end: CGPoint(x: photo.maxX, y: photo.maxY), options: []
        )
        context.restoreGState()
        let lineHeight = w * 0.018
        var y = photo.maxY + lineHeight * 1.3
        for fraction in [CGFloat(0.9), 0.66, 0.8, 0.52, 0.72] {
            guard y + lineHeight < frame.maxY - w * 0.062 else { break }
            let line = CGRect(x: frame.minX + inset, y: y, width: (frame.width - 2 * inset) * fraction, height: lineHeight)
            context.addPath(CGPath(roundedRect: line, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
            context.setFillColor(colour(0x8E84B8, 0.65))
            context.fillPath()
            y += lineHeight * 2
        }
    }
    window(CGRect(x: w * 0.53, y: h * 0.47, width: w * 0.37, height: h * 0.42), photoShare: 0.42)
    window(CGRect(x: w * 0.09, y: h * 0.07, width: w * 0.48, height: h * 0.56), photoShare: 0.40)
    return context.makeImage()!
}

/// The lid's picture as the renderer would show it: blurred and dimmed
/// towards the far edge, then put into perspective.
func screenPicture(scale: CGFloat, corners: [CGPoint], detailed: Bool) -> (CGImage, CGRect) {
    let flatWidth = max(Int((corners[1].x - corners[0].x) * scale), 4)
    let flatHeight = max(Int(CGFloat(flatWidth) * 0.66), 4)
    let flat = CIImage(cgImage: wallpaper(width: flatWidth, height: flatHeight, detailed: detailed))

    // The shader's curve: blur grows with height to the power 2.25, so the
    // hinge stays nearly sharp.
    let mask = CGContext(
        data: nil, width: flatWidth, height: flatHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    let steps = 16
    mask.drawLinearGradient(
        CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: (0...steps).map { step -> CGColor in
                CGColor(gray: pow(CGFloat(step) / CGFloat(steps), 2.25), alpha: 1)
            } as CFArray,
            locations: (0...steps).map { CGFloat($0) / CGFloat(steps) }
        )!,
        start: .zero, end: CGPoint(x: 0, y: flatHeight), options: []
    )
    let blurred = flat.clampedToExtent()
        .applyingFilter("CIMaskedVariableBlur", parameters: [
            "inputMask": CIImage(cgImage: mask.makeImage()!),
            kCIInputRadiusKey: CGFloat(flatWidth) * 0.06,
        ])
        .cropped(to: flat.extent)

    // Dimming deepens towards the far edge as the renderer's does, but into
    // deep indigo rather than black, which stays richer at icon sizes.
    let dimmed = blurred.applyingFilter("CISourceOverCompositing", parameters: [
        kCIInputBackgroundImageKey: blurred,
        kCIInputImageKey: CIImage(cgImage: {
            let shade = CGContext(
                data: nil, width: flatWidth, height: flatHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            shade.drawLinearGradient(
                gradient([(0, colour(0x07041F, 0)), (0.35, colour(0x07041F, 0.1)), (1, colour(0x07041F, 0.66))]),
                start: .zero, end: CGPoint(x: 0, y: flatHeight), options: []
            )
            return shade.makeImage()!
        }()),
    ])

    let pixel = corners.map { CIVector(x: $0.x * scale, y: $0.y * scale) }
    let leaning = dimmed.applyingFilter("CIPerspectiveTransform", parameters: [
        "inputBottomLeft": pixel[0],
        "inputBottomRight": pixel[1],
        "inputTopRight": pixel[2],
        "inputTopLeft": pixel[3],
    ])
    let extent = leaning.extent.integral
    let image = ciContext.createCGImage(leaning, from: extent, format: .RGBA8, colorSpace: sRGB)!
    return (image, CGRect(
        x: extent.minX / scale, y: extent.minY / scale,
        width: extent.width / scale, height: extent.height / scale
    ))
}

// MARK: - Icon

/// Draws the icon at one pixel size. Small sizes drop the finest details and
/// thicken lines, so the silhouette stays clean instead of turning to mush.
func renderIcon(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(pixels) / canvas
    let isSmall = pixels <= 32
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high

    // Body with Apple's template shadow.
    let shape = continuousRoundedRect(body, radius: bodyRadius)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale, color: colour(0x000000, 0.30))
    context.addPath(shape)
    context.setFillColor(colour(0x1B1F5E))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawLinearGradient(
        gradient([(0, colour(0x0B1033)), (0.55, colour(0x1E2370)), (1, colour(0x3A3196))]),
        start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: []
    )
    // A pink haze behind the laptop ties the body to the screen's glow.
    let hazeCentre = CGPoint(x: canvas / 2, y: 420)
    context.drawRadialGradient(
        gradient([(0, colour(0xE0559A, 0.42)), (0.5, colour(0xB2468F, 0.16)), (1, colour(0xB2468F, 0))]),
        startCenter: hazeCentre, startRadius: 0, endCenter: hazeCentre, endRadius: 470, options: []
    )
    context.restoreGState()

    // A hairline of light along the top rim gives the body some thickness.
    if !isSmall {
        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.addPath(continuousRoundedRect(body.insetBy(dx: 1.5, dy: 1.5), radius: bodyRadius - 1.5))
        context.setLineWidth(3)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(
            gradient([(0, colour(0xFFFFFF, 0)), (0.7, colour(0xFFFFFF, 0.05)), (1, colour(0xFFFFFF, 0.22))]),
            start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: []
        )
        context.restoreGState()
    }

    // Soft contact shadow under the base, an ellipse squashed flat.
    context.saveGState()
    let contact = CGPoint(x: canvas / 2, y: Base.top - Base.height - 4)
    context.translateBy(x: contact.x, y: contact.y)
    context.scaleBy(x: 1, y: 0.09)
    context.drawRadialGradient(
        gradient([(0, colour(0x000000, 0.55)), (0.7, colour(0x000000, 0.25)), (1, colour(0x000000, 0))]),
        startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: Base.halfWidth * 1.08, options: []
    )
    context.restoreGState()

    // Lid: aluminium edge, black bezel, then the picture. Small sizes keep
    // the edge at least a pixel wide and a shade lighter, or the lid melts
    // into the background.
    let outer = lidCorners()
    let bezelRadii: [CGFloat] = [6, 6, 30, 30]
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 18 * scale, color: colour(0x000000, 0.35))
    context.addPath(roundedQuad(outer, radii: bezelRadii))
    context.setFillColor(colour(pixels <= 64 ? 0xC3C7D3 : 0xA4A9BA))
    context.fillPath()
    context.restoreGState()

    let rim = max(Lid.rim, 0.9 / scale)
    let bezel = lidCorners(inset: (rim, rim * 0.85, 0))
    context.addPath(roundedQuad(bezel, radii: bezelRadii.map { max($0 - rim, 2) }))
    context.setFillColor(colour(0x0A0B10))
    context.fillPath()

    // Small sizes get a thinner bezel so the picture keeps its share of pixels.
    let bezelScale: CGFloat = isSmall ? 0.5 : 1
    let display = lidCorners(inset: (
        rim + Lid.sideBezel * bezelScale,
        rim * 0.85 + Lid.topBezel * bezelScale,
        Lid.chin * bezelScale
    ))
    let (picture, frame) = screenPicture(scale: scale, corners: display, detailed: !isSmall)
    context.saveGState()
    context.addPath(roundedQuad(display, radii: [2, 2, 12, 12]))
    context.clip()
    context.draw(picture, in: frame)
    context.restoreGState()

    // Base: the front lip of the aluminium deck with its thumb scoop.
    let baseRect = CGRect(x: canvas / 2 - Base.halfWidth, y: Base.top - Base.height, width: 2 * Base.halfWidth, height: Base.height)
    let basePath = CGMutablePath()
    let bottomRadius: CGFloat = Base.height * 0.62
    basePath.move(to: CGPoint(x: baseRect.minX, y: baseRect.maxY))
    basePath.addLine(to: CGPoint(x: baseRect.maxX, y: baseRect.maxY))
    basePath.addLine(to: CGPoint(x: baseRect.maxX, y: baseRect.minY + bottomRadius))
    basePath.addQuadCurve(to: CGPoint(x: baseRect.maxX - bottomRadius * 1.6, y: baseRect.minY), control: CGPoint(x: baseRect.maxX, y: baseRect.minY))
    basePath.addLine(to: CGPoint(x: baseRect.minX + bottomRadius * 1.6, y: baseRect.minY))
    basePath.addQuadCurve(to: CGPoint(x: baseRect.minX, y: baseRect.minY + bottomRadius), control: CGPoint(x: baseRect.minX, y: baseRect.minY))
    basePath.closeSubpath()
    context.saveGState()
    context.addPath(basePath)
    context.clip()
    context.drawLinearGradient(
        gradient([(0, colour(0x7C8194)), (0.45, colour(0xC4C8D4)), (0.8, colour(0xE9EBF1)), (1, colour(0xF7F8FB))]),
        start: CGPoint(x: 0, y: baseRect.minY), end: CGPoint(x: 0, y: baseRect.maxY), options: []
    )
    if !isSmall {
        // Thumb scoop, a shallow dip in the lip.
        let scoop = CGRect(x: canvas / 2 - 62, y: baseRect.maxY - 13, width: 124, height: 26)
        context.addPath(CGPath(roundedRect: scoop, cornerWidth: 13, cornerHeight: 13, transform: nil))
        context.clip()
        context.drawLinearGradient(
            gradient([(0, colour(0xB9BDCA)), (1, colour(0x8E93A5))]),
            start: CGPoint(x: 0, y: scoop.minY), end: CGPoint(x: 0, y: baseRect.maxY), options: []
        )
    }
    context.restoreGState()

    // The hinge: a dark seam where the lid meets the deck.
    context.setFillColor(colour(0x2A2D38))
    context.fill(CGRect(
        x: canvas / 2 - Lid.bottomHalfWidth + 18, y: Base.top - (isSmall ? 4 : 3),
        width: 2 * (Lid.bottomHalfWidth - 18), height: isSmall ? 6 : 5
    ))

    return context.makeImage()!
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: image.width, height: image.height)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    : root.appendingPathComponent("build")
let iconset = output.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Every size is drawn on its own rather than scaled down from 1024 px.
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 1 ? "" : "@2x"
        let name = "icon_\(points)x\(points)\(suffix).png"
        try writePNG(renderIcon(pixels: points * factor), to: iconset.appendingPathComponent(name))
    }
}
try writePNG(renderIcon(pixels: 1024), to: output.appendingPathComponent("AppIcon-1024.png"))

let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let packer = Process()
packer.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
packer.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try packer.run()
packer.waitUntilExit()
guard packer.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(icns.path)")
