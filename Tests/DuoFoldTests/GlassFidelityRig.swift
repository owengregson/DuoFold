import AppKit
import CoreText
import Metal
import QuartzCore
import UniformTypeIdentifiers
@testable import DuoFold

/// Draws one frame of the effect both ways, offscreen, from the same picture
/// of a screen: through the captured picture's Metal renderer, and through
/// the window server's glass, rendered by `CARenderer`, which runs the same
/// Core Animation renderer as the window server. Nothing goes on screen and
/// nothing is captured.
///
/// Both come back as 8-bit sRGB pixels, bottom row last, so they can be told
/// apart pixel by pixel.
@MainActor
struct GlassFidelityRig {

    struct Frame {
        let width: Int
        let height: Int
        /// BGRA, top row first.
        var pixels: [UInt8]
    }

    let screen: CGSize
    let scale: CGFloat
    let picture: CGImage
    private let device: MTLDevice
    fileprivate let queue: MTLCommandQueue

    init?(screen: CGSize, scale: CGFloat) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let picture = Self.desktop(width: Int(screen.width * scale), height: Int(screen.height * scale), scale: scale)
        else { return nil }
        self.screen = screen
        self.scale = scale
        self.picture = picture
        self.device = device
        self.queue = queue
    }

    var pixelWidth: Int { Int(screen.width * scale) }
    var pixelHeight: Int { Int(screen.height * scale) }

    // MARK: - The two renderers

    /// The captured picture, as `DepthOverlay.update` has the renderer draw it.
    func capture(corners: [CGPoint], progress: Double, tuning: DepthTuning, gradient: BlurGradient = BlurGradient()) -> Frame? {
        guard let renderer = DepthRenderer(),
              let prepared = renderer.makePicture(image: picture, screenSize: screen, pixelScale: scale) else { return nil }
        let uniforms = DepthRenderer.uniforms(
            corners: corners,
            layout: prepared.stack.layout,
            screenSize: screen,
            pixelScale: scale,
            blurStrength: gradient.blurStrength(progress: progress),
            dimStrength: gradient.dimStrength(progress: progress),
            hingeFloor: tuning.blurEvenness,
            dimHingeFloor: gradient.dimHingeFloor,
            dimReach: tuning.dimReach,
            maxBlurRadius: tuning.maxBlurRadius,
            maxDim: tuning.maxDim
        )
        guard let target = makeTarget(format: .bgra8Unorm_srgb),
              let commands = queue.makeCommandBuffer(),
              renderer.encodeFrame(uniforms, picture: prepared.picture, stack: prepared.stack, target: target, into: commands)
        else { return nil }
        commands.commit()
        commands.waitUntilCompleted()
        return read(target)
    }

    /// The glass over the same picture, set up by `apply` as
    /// `DepthOverlay.update` would.
    func glass(_ apply: (FrostedGlassView) -> Void) -> Frame? {
        let view = FrostedGlassView(frame: NSRect(origin: .zero, size: screen), scale: scale, samplesOtherWindows: false)
        guard let root = view.layer else { return nil }
        root.frame = CGRect(origin: .zero, size: screen)
        let backdrop = CALayer()
        backdrop.anchorPoint = .zero
        backdrop.frame = CGRect(origin: .zero, size: screen)
        backdrop.contents = picture
        backdrop.contentsScale = scale
        root.insertSublayer(backdrop, at: 0)
        apply(view)
        return render(root)
    }

    /// A renderer kept across frames, so later frames can redraw only part
    /// of the screen, as the window server does when something changes.
    @MainActor
    final class LiveRenderer {
        let renderer: CARenderer
        let host = CALayer()
        let target: MTLTexture
        let rig: GlassFidelityRig

        init?(rig: GlassFidelityRig, root: CALayer) {
            guard let target = rig.makeTarget(format: .bgra8Unorm) else { return nil }
            self.rig = rig
            self.target = target
            renderer = CARenderer(mtlTexture: target, options: [
                kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                kCARendererMetalCommandQueue: rig.queue,
            ])
            host.anchorPoint = .zero
            host.frame = CGRect(x: 0, y: 0, width: CGFloat(rig.pixelWidth), height: CGFloat(rig.pixelHeight))
            host.sublayerTransform = CATransform3DMakeScale(rig.scale, rig.scale, 1)
            host.addSublayer(root)
            renderer.layer = host
            renderer.bounds = host.frame
        }

        /// One frame, redrawing only `update`, in screen points from the
        /// bottom left, or everything.
        func frame(update: CGRect? = nil) -> Frame? {
            CATransaction.flush()
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            let rect = update.map {
                CGRect(x: $0.minX * rig.scale, y: $0.minY * rig.scale, width: $0.width * rig.scale, height: $0.height * rig.scale)
            } ?? renderer.bounds
            renderer.addUpdate(rect)
            renderer.render()
            renderer.endFrame()
            guard let fence = rig.queue.makeCommandBuffer() else { return nil }
            fence.commit()
            fence.waitUntilCompleted()
            var frame = rig.read(target)
            let row = rig.pixelWidth * 4
            for y in 0..<rig.pixelHeight / 2 {
                let top = y * row, bottom = (rig.pixelHeight - 1 - y) * row
                for i in 0..<row { frame.pixels.swapAt(top + i, bottom + i) }
            }
            return frame
        }
    }

    /// Renders a layer tree the way the window server would, into 8-bit sRGB.
    func render(_ root: CALayer) -> Frame? {
        guard let target = makeTarget(format: .bgra8Unorm) else { return nil }
        // On this queue, so the fence below waits for its drawing.
        let renderer = CARenderer(mtlTexture: target, options: [
            kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            kCARendererMetalCommandQueue: queue,
        ])
        // CARenderer draws in points and the target is in pixels.
        let host = CALayer()
        host.anchorPoint = .zero
        host.frame = CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        host.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)
        host.addSublayer(root)
        renderer.layer = host
        renderer.bounds = host.frame
        for _ in 0..<3 {
            CATransaction.flush()
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
        }
        guard let fence = queue.makeCommandBuffer() else { return nil }
        fence.commit()
        fence.waitUntilCompleted()
        // CARenderer puts the bottom row first.
        var frame = read(target)
        let row = pixelWidth * 4
        for y in 0..<pixelHeight / 2 {
            let top = y * row, bottom = (pixelHeight - 1 - y) * row
            for i in 0..<row { frame.pixels.swapAt(top + i, bottom + i) }
        }
        return frame
    }

    fileprivate func makeTarget(format: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: pixelWidth, height: pixelHeight, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    fileprivate func read(_ texture: MTLTexture) -> Frame {
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        texture.getBytes(&pixels, bytesPerRow: pixelWidth * 4,
                         from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight), mipmapLevel: 0)
        return Frame(width: pixelWidth, height: pixelHeight, pixels: pixels)
    }

    // MARK: - Comparing

    struct Difference: CustomStringConvertible {
        var mean: Double
        var rms: Double
        var p99: Double
        var maximum: Double
        var description: String {
            String(format: "mean %.2f  rms %.2f  p99 %.1f  max %.0f  (of 255)", mean, rms, p99, maximum)
        }
    }

    /// Per-pixel difference over the pixels `include` picks (x, y from the
    /// top left, in pixels), the largest of the three channels.
    static func difference(_ a: Frame, _ b: Frame, include: (Int, Int) -> Bool = { _, _ in true }) -> Difference {
        var errors: [Double] = []
        errors.reserveCapacity(a.width * a.height)
        for y in 0..<a.height {
            for x in 0..<a.width where include(x, y) {
                let i = (y * a.width + x) * 4
                let e = (0..<3).map { abs(Double(a.pixels[i + $0]) - Double(b.pixels[i + $0])) }.max()!
                errors.append(e)
            }
        }
        guard !errors.isEmpty else { return Difference(mean: 0, rms: 0, p99: 0, maximum: 0) }
        let sorted = errors.sorted()
        let mean = errors.reduce(0, +) / Double(errors.count)
        let rms = sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count))
        return Difference(mean: mean, rms: rms, p99: sorted[Int(Double(sorted.count - 1) * 0.99)], maximum: sorted.last!)
    }

    /// Mean of `a - b` per channel (B, G, R) over a rectangle of pixels.
    static func signedMean(_ a: Frame, _ b: Frame, x: Range<Int>, y: Range<Int>) -> (Double, Double, Double) {
        var sums = (0.0, 0.0, 0.0), count = 0.0
        for row in y { for column in x {
            let i = (row * a.width + column) * 4
            sums.0 += Double(a.pixels[i]) - Double(b.pixels[i])
            sums.1 += Double(a.pixels[i + 1]) - Double(b.pixels[i + 1])
            sums.2 += Double(a.pixels[i + 2]) - Double(b.pixels[i + 2])
            count += 1
        } }
        return (sums.0 / count, sums.1 / count, sums.2 / count)
    }

    /// A crop of each frame, side by side, magnified `zoom` times.
    static func writeCrop(_ frames: [Frame], x: Range<Int>, y: Range<Int>, zoom: Int, to url: URL) {
        let cropped = frames.map { frame -> Frame in
            var pixels: [UInt8] = []
            pixels.reserveCapacity(x.count * y.count * zoom * zoom * 4)
            for row in y { for _ in 0..<zoom { for column in x {
                let i = (row * frame.width + column) * 4
                for _ in 0..<zoom { pixels.append(contentsOf: frame.pixels[i..<i + 4]) }
            } } }
            return Frame(width: x.count * zoom, height: y.count * zoom, pixels: pixels)
        }
        write(cropped, to: url)
    }

    /// The two side by side over their difference, amplified.
    static func write(_ frames: [Frame], to url: URL) {
        guard let first = frames.first else { return }
        let width = first.width, height = first.height
        var canvas = [UInt8](repeating: 0, count: width * frames.count * height * 4)
        for (index, frame) in frames.enumerated() {
            for y in 0..<height {
                let source = y * width * 4
                let destination = (y * width * frames.count + index * width) * 4
                canvas.replaceSubrange(destination..<destination + width * 4, with: frame.pixels[source..<source + width * 4])
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: &canvas, width: width * frames.count, height: height, bitsPerComponent: 8,
            bytesPerRow: width * frames.count * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The difference of two frames as a frame, amplified `gain` times.
    static func amplified(_ a: Frame, _ b: Frame, gain: Double) -> Frame {
        var out = a
        for i in stride(from: 0, to: a.pixels.count, by: 4) {
            for c in 0..<3 {
                let d = abs(Double(a.pixels[i + c]) - Double(b.pixels[i + c])) * gain
                out.pixels[i + c] = UInt8(min(d, 255))
            }
            out.pixels[i + 3] = 255
        }
        return out
    }

    // MARK: - A screen to blur

    /// A desktop with what blurs tell apart: text, thin lines, fine checks,
    /// saturated blocks against each edge and corner, smooth gradients, and
    /// light windows on a dark wallpaper.
    static func desktop(width: Int, height: Int, scale: CGFloat) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let w = CGFloat(width) / scale, h = CGFloat(height) / scale

        // Wallpaper.
        let wallpaper = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.10, green: 0.12, blue: 0.35, alpha: 1),
            CGColor(srgbRed: 0.45, green: 0.15, blue: 0.40, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.55, blue: 0.30, alpha: 1),
        ] as CFArray, locations: [0, 0.6, 1])!
        // A screen is opaque everywhere; the gradient runs on past its ends.
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.drawLinearGradient(wallpaper, start: .zero, end: CGPoint(x: w * 0.3, y: h),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // A black patch, as the screen can have.
        context.fill(CGRect(x: w * 0.42, y: h * 0.86, width: w * 0.14, height: h * 0.05))

        func fill(_ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            context.fill(rect)
        }
        func text(_ string: String, at point: CGPoint, size: CGFloat, colour: CGColor) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributed = NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
            ])
            context.textPosition = point
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }

        // A light window with lines of text.
        fill(CGRect(x: w * 0.06, y: h * 0.18, width: w * 0.5, height: h * 0.68), 0.98, 0.98, 0.97)
        fill(CGRect(x: w * 0.06, y: h * 0.82, width: w * 0.5, height: h * 0.04), 0.86, 0.86, 0.88)
        let ink = CGColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        for line in 0..<18 {
            text("The quick brown fox jumps over the lazy dog 0123456789 — line \(line)",
                 at: CGPoint(x: w * 0.08, y: h * 0.78 - CGFloat(line) * h * 0.032), size: 13 + CGFloat(line % 3) * 2, colour: ink)
        }

        // A dark window with coloured text.
        fill(CGRect(x: w * 0.6, y: h * 0.3, width: w * 0.36, height: h * 0.5), 0.12, 0.12, 0.14)
        let colours = [CGColor(srgbRed: 0.4, green: 0.8, blue: 1, alpha: 1), CGColor(srgbRed: 1, green: 0.5, blue: 0.4, alpha: 1),
                       CGColor(srgbRed: 0.7, green: 1, blue: 0.5, alpha: 1)]
        for line in 0..<12 {
            text("let value = blur(at: \(line)) // comment", at: CGPoint(x: w * 0.62, y: h * 0.75 - CGFloat(line) * h * 0.035),
                 size: 12, colour: colours[line % 3])
        }

        // Saturated blocks against every edge and corner.
        fill(CGRect(x: 0, y: h * 0.4, width: w * 0.04, height: h * 0.2), 1, 0.1, 0.1)
        fill(CGRect(x: w * 0.96, y: h * 0.45, width: w * 0.04, height: h * 0.2), 0.1, 1, 0.2)
        fill(CGRect(x: w * 0.4, y: h * 0.96, width: w * 0.2, height: h * 0.04), 1, 0.95, 0.1)
        fill(CGRect(x: 0, y: h * 0.95, width: w * 0.05, height: h * 0.05), 1, 1, 1)
        fill(CGRect(x: w * 0.95, y: h * 0.95, width: w * 0.05, height: h * 0.05), 0.2, 0.4, 1)
        fill(CGRect(x: 0, y: 0, width: w * 0.06, height: h * 0.06), 1, 1, 1)
        fill(CGRect(x: w * 0.94, y: 0, width: w * 0.06, height: h * 0.06), 1, 0.4, 0.8)

        // Fine checks and thin lines, near the hinge where the blur is least.
        let cell = 1 / scale
        for row in 0..<Int(h * 0.1 / cell) {
            for column in 0..<Int(w * 0.12 / cell) where (row + column) % 2 == 0 {
                fill(CGRect(x: w * 0.62 + CGFloat(column) * cell, y: h * 0.05 + CGFloat(row) * cell, width: cell, height: cell), 1, 1, 1)
            }
        }
        for index in 0..<24 {
            fill(CGRect(x: w * 0.78 + CGFloat(index) * 4, y: h * 0.04, width: 1, height: h * 0.14), 0.95, 0.95, 0.95)
        }

        // A menu bar along the top.
        fill(CGRect(x: 0, y: h - 24, width: w, height: 24), 0.92, 0.92, 0.93)
        text("  File   Edit   View   Window   Help", at: CGPoint(x: 8, y: h - 17), size: 13, colour: ink)
        return context.makeImage()
    }
}
