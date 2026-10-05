import AppKit
import Metal
import QuartzCore
import simd

/// Draws the picture with Metal.
///
/// The sharp picture is read in place, and a blur stack built from it holds
/// the picture on a black margin at every blur the effect needs (see
/// `BlurStack`). The stack is rebuilt only when the picture changes; each
/// frame is then one full screen pass, and a frame that would look the same
/// as the last one is not drawn at all.
@MainActor
final class DepthRenderer {

    /// Black margin around the picture, in points, so the blur can spread the
    /// picture edge into black.
    nonisolated private static let paddingInPoints: CGFloat = 120

    /// Converts the settings' blur radius into a Gaussian sigma. It matches
    /// the blur the earlier mip pyramid gave for the same setting.
    nonisolated private static let sigmaPerRadius: Float = 2.0 / 3.0

    struct Uniforms {
        var column0: SIMD4<Float>
        var column1: SIMD4<Float>
        var column2: SIMD4<Float>
        var picture: SIMD4<Float>
        var blur: SIMD4<Float>
        var extent: SIMD4<Float>
        var light: SIMD4<Float>

        /// Close enough that the frame would look the same. An eased angle
        /// approaches its target without reaching it, and redrawing for a
        /// hundredth of a pixel only costs power.
        func matches(_ other: Uniforms) -> Bool {
            func near(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
                let tolerance = max(abs(a), abs(b)) * 2e-6 + 1e-7
                return all(abs(a - b) .<= tolerance)
            }
            return near(column0, other.column0) && near(column1, other.column1)
                && near(column2, other.column2) && near(picture, other.picture)
                && near(blur, other.blur) && near(extent, other.extent) && near(light, other.light)
        }
    }

    /// One held picture, built off the main thread and adopted on it.
    struct PreparedPicture {
        let picture: MTLTexture
        let stack: BlurStack.Textures
        let colourSpace: CGColorSpace
        let pixelScale: CGFloat
        let screenSize: CGSize
    }

    /// Where the next frame goes.
    ///
    /// A layer belongs to one view at a time, so every overlay window needs
    /// its own.
    private(set) var layer = CAMetalLayer()

    nonisolated private let device: MTLDevice
    nonisolated private let queue: MTLCommandQueue
    nonisolated private let blurStack: BlurStack
    nonisolated private let pipeline: MTLRenderPipelineState
    /// Blackens the picture's rounded top corners (`encodeCorners`).
    nonisolated private let cornerPipeline: MTLRenderPipelineState

    /// The sharp picture the next frame reads, and the stack built from it.
    private var picture: MTLTexture?
    private var stack: BlurStack.Textures?
    /// Keeps the capture surface behind `picture` alive while it is drawn.
    private var pictureFrame: CapturedFrame?
    private var screenSize: CGSize = .zero
    private var pixelScale: CGFloat = 2

    /// The stack a live stream builds into, kept between frames of the same
    /// size. `makePicture` builds its own instead, so only one of the two is
    /// in use at a time.
    private var liveStack: BlurStack.Textures?
    /// Holds a seed picture until the stream's first frame replaces it.
    private var seedTexture: MTLTexture?
    /// The live picture's top corner radius, in points.
    private var liveCornerRadius = 0.0
    /// Each live frame, copied so its corners can be blackened: the capture
    /// surface itself is the stream's.
    private var liveCopy: MTLTexture?
    private var isLiveSource = false
    /// The newest live frame, waiting for the next drawn frame to take it.
    private var pendingFrame: CapturedFrame?
    /// A held picture to start from, waiting for the same moment. A live
    /// frame that arrives first wins, since it is the newer of the two.
    private var pendingSeed: (buffer: MTLBuffer, width: Int, height: Int)?

    /// What the last drawn frame was drawn with.
    private var drawnUniforms: Uniforms?
    /// Set when the layer or the picture changed, so the next frame draws
    /// even if its settings match the last one.
    private var needsDraw = true

    var isReady: Bool { picture != nil && stack != nil }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        do {
            let library = try device.makeLibrary(source: DepthShaders.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "depthVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "depthFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let corners = MTLRenderPipelineDescriptor()
            corners.vertexFunction = library.makeFunction(name: "cornerVertex")
            corners.fragmentFunction = library.makeFunction(name: "cornerFragment")
            let attachment = corners.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm_srgb
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.sourceRGBBlendFactor = .zero
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.alphaBlendOperation = .add
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one
            cornerPipeline = try device.makeRenderPipelineState(descriptor: corners)
            guard let blurStack = BlurStack(device: device, library: library) else {
                Diagnostics.geometry.error("metal blur pipeline failed")
                return nil
            }
            self.blurStack = blurStack
        } catch {
            Diagnostics.geometry.error("metal pipeline failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        configure(layer)
    }

    /// A fresh layer for a new overlay window. Later frames go to this one.
    func makeLayer() -> CAMetalLayer {
        let fresh = CAMetalLayer()
        configure(fresh)
        layer = fresh
        needsDraw = true
        return fresh
    }

    private func configure(_ target: CAMetalLayer) {
        target.device = device
        target.pixelFormat = .bgra8Unorm_srgb
        target.framebufferOnly = true
        // An opaque layer covering the screen makes the window server mark
        // every window behind it as hidden, and apps stop drawing. The shader
        // writes alpha 1 everywhere, so blending gives the same picture.
        target.isOpaque = false
        // Waiting for the refresh here blocks the main thread. While a capture
        // stream leaves this app out of its own picture, the window server
        // draws the screen twice, the drawable comes back late, and the wait
        // lands a refresh later: 60 frames per second becomes 32. The display
        // link already paces the drawing.
        target.displaySyncEnabled = false
        target.needsDisplayOnBoundsChange = true
    }

    /// The picture and its black margin, in screen points, hinge at y = 0:
    /// past it the captured picture is black.
    nonisolated static func paddedFrame(screenSize: CGSize, pixelScale: CGFloat) -> CGRect {
        layout(screenSize: screenSize, pixelScale: pixelScale)?.paddedFrame(screenSize: screenSize)
            ?? CGRect(origin: .zero, size: screenSize)
    }

    nonisolated private static func layout(screenSize: CGSize, pixelScale: CGFloat) -> BlurStack.Layout? {
        BlurStack.Layout(
            pictureWidth: Int((screenSize.width * pixelScale).rounded()),
            pictureHeight: Int((screenSize.height * pixelScale).rounded()),
            minimumMargin: Int((paddingInPoints * pixelScale).rounded(.up))
        )
    }

    /// Uploads the picture and builds its blur stack. Call this off the main
    /// thread.
    ///
    /// - Parameter cornerRadius: the panel's top corner radius, in points,
    ///   which the picture keeps as it leans (`ScreenCorner`).
    nonisolated func makePicture(
        image: CGImage, screenSize: CGSize, pixelScale: CGFloat, cornerRadius: Double = 0
    ) -> PreparedPicture? {
        let started = CFAbsoluteTimeGetCurrent()
        guard let layout = Self.layout(screenSize: screenSize, pixelScale: pixelScale) else { return nil }
        let width = layout.pictureWidth
        let height = layout.pictureHeight
        let byteCount = width * height * 4

        guard let staging = device.makeBuffer(length: byteCount, options: .storageModeShared) else { return nil }

        let colourSpace: CGColorSpace
        if let space = image.colorSpace, space.model == .rgb {
            colourSpace = space
        } else {
            colourSpace = CGColorSpaceCreateDeviceRGB()
        }
        guard let context = CGContext(
            data: staging.contents(),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let contextReady = CFAbsoluteTimeGetCurrent()

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let drawn = CFAbsoluteTimeGetCurrent()

        guard let texture = makePictureTexture(width: width, height: height),
              let stackTextures = blurStack.makeTextures(for: layout),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: width * 4,
            sourceBytesPerImage: byteCount,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        encodeCorners(radius: cornerRadius, pixelScale: pixelScale, on: texture, into: commands)
        blurStack.encode(from: texture, into: commands, textures: stackTextures)
        commands.commit()
        commands.waitUntilCompleted()
        let finished = CFAbsoluteTimeGetCurrent()

        Diagnostics.geometry.notice(
            """
            metal picture \(width)x\(height) px, stack \(layout.baseWidth)x\(layout.baseHeight) px: \
            context \((contextReady - started) * 1000, format: .fixed(precision: 1)) ms, \
            draw \((drawn - contextReady) * 1000, format: .fixed(precision: 1)) ms, \
            gpu \((finished - drawn) * 1000, format: .fixed(precision: 1)) ms
            """
        )
        return PreparedPicture(
            picture: texture,
            stack: stackTextures,
            colourSpace: colourSpace,
            pixelScale: pixelScale,
            screenSize: screenSize
        )
    }

    nonisolated private func makePictureTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        // A render target too, for `encodeCorners`.
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Blackens the picture's rounded top corners in `picture`, which covers
    /// the screen at `pixelScale`, so the stack built from it blurs them as
    /// it blurs the black margin.
    nonisolated private func encodeCorners(
        radius: Double, pixelScale: CGFloat, on picture: MTLTexture, into commands: MTLCommandBuffer
    ) {
        guard radius > 0, let cap = makeCapTexture(radius: radius, pixelScale: pixelScale) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = picture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var box = SIMD2<Float>(
            Float(2 * Double(cap.width) / Double(picture.width)),
            Float(2 * Double(cap.height) / Double(picture.height))
        )
        encoder.setRenderPipelineState(cornerPipeline)
        encoder.setVertexBytes(&box, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(cap, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 12)
        encoder.endEncoding()
    }

    /// The top-left corner's cap (`ScreenCorner.capPath`) as coverage, the
    /// corner in the first row and column.
    nonisolated private func makeCapTexture(radius: Double, pixelScale: CGFloat) -> MTLTexture? {
        let side = Int((ScreenCorner.boxSide(radius: radius) * Double(pixelScale)).rounded(.up))
        guard side > 0, let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let pixels = context.data else { return nil }
        context.scaleBy(x: pixelScale, y: pixelScale)
        context.addPath(ScreenCorner.capPath(radius: radius))
        context.setFillColor(gray: 1, alpha: 1)
        context.fillPath()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: pixels, bytesPerRow: side)
        return texture
    }

    // MARK: - Live source

    /// Prepares the stack for a live stream. Nothing is drawn until the first
    /// frame lands.
    @discardableResult
    func beginLive(screenSize: CGSize, pixelScale: CGFloat, cornerRadius: Double = 0) -> Bool {
        guard let layout = Self.layout(screenSize: screenSize, pixelScale: pixelScale) else { return false }
        if liveStack?.layout != layout {
            guard let fresh = blurStack.makeTextures(for: layout) else { return false }
            liveStack = fresh
            seedTexture = nil
        }

        picture = nil
        pictureFrame = nil
        stack = nil
        isLiveSource = true
        liveCornerRadius = cornerRadius
        self.screenSize = screenSize
        self.pixelScale = pixelScale
        needsDraw = true
        layer.colorspace = CGColorSpace(name: ScreenStreamer.colourSpaceName)
        layer.drawableSize = CGSize(
            width: screenSize.width * pixelScale,
            height: screenSize.height * pixelScale
        )
        return true
    }

    /// Starts the live picture from one held frame. The stream's first frame
    /// overwrites it.
    @discardableResult
    func seed(image: CGImage) -> Bool {
        guard isLiveSource, let liveStack else { return false }
        let width = liveStack.layout.pictureWidth
        let height = liveStack.layout.pictureHeight
        let bytesPerRow = width * 4
        if seedTexture == nil { seedTexture = makePictureTexture(width: width, height: height) }
        guard let seedTexture,
              let staging = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              // The stream's own space, so the handover does not shift colour.
              let space = CGColorSpace(name: ScreenStreamer.colourSpaceName),
              let context = CGContext(
                data: staging.contents(),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pendingSeed = (staging, width, height)
        // The texture object is the one the next pass reads, and the upload
        // and the stack are encoded ahead of that pass.
        picture = seedTexture
        pictureFrame = nil
        stack = liveStack
        return true
    }

    /// Takes one live frame. The stack is rebuilt on the same command buffer
    /// as the frame that draws it.
    func absorb(_ frame: CapturedFrame) {
        guard isLiveSource, let liveStack else { return }
        pendingFrame = frame
        pendingSeed = nil
        // The surface is read in place, with no copy, unless the corners
        // need blackening.
        picture = frame.texture
        if liveCornerRadius > 0 {
            let source = frame.texture
            if liveCopy?.width != source.width || liveCopy?.height != source.height {
                liveCopy = makePictureTexture(width: source.width, height: source.height)
            }
            if let liveCopy { picture = liveCopy }
        }
        pictureFrame = frame
        stack = liveStack
    }

    /// Uploads the newest seed or takes the newest frame, and rebuilds the
    /// stack from it.
    private func absorbPending(into commands: MTLCommandBuffer) {
        guard let liveStack, pendingFrame != nil || pendingSeed != nil else { return }
        if let frame = pendingFrame {
            if liveCornerRadius > 0, let liveCopy, let blit = commands.makeBlitCommandEncoder() {
                blit.copy(from: frame.texture, to: liveCopy)
                blit.endEncoding()
                encodeCorners(radius: liveCornerRadius, pixelScale: pixelScale, on: liveCopy, into: commands)
                blurStack.encode(from: liveCopy, into: commands, textures: liveStack)
            } else {
                blurStack.encode(from: frame.texture, into: commands, textures: liveStack)
            }
        } else if let seed = pendingSeed, let seedTexture,
                  let blit = commands.makeBlitCommandEncoder() {
            blit.copy(
                from: seed.buffer,
                sourceOffset: 0,
                sourceBytesPerRow: seed.width * 4,
                sourceBytesPerImage: seed.width * 4 * seed.height,
                sourceSize: MTLSize(width: seed.width, height: seed.height, depth: 1),
                to: seedTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            encodeCorners(radius: liveCornerRadius, pixelScale: pixelScale, on: seedTexture, into: commands)
            blurStack.encode(from: seedTexture, into: commands, textures: liveStack)
        }
        pendingFrame = nil
        pendingSeed = nil
    }

    /// Frees the live picture.
    func discardLive() {
        pendingFrame = nil
        pendingSeed = nil
        if isLiveSource {
            picture = nil
            pictureFrame = nil
            stack = nil
        }
        isLiveSource = false
        liveStack = nil
        seedTexture = nil
        liveCopy = nil
    }

    // MARK: - Still source

    func adopt(_ prepared: PreparedPicture) {
        isLiveSource = false
        picture = prepared.picture
        pictureFrame = nil
        stack = prepared.stack
        needsDraw = true
        // Without a tag the window server treats the drawable as sRGB and
        // converts it to the display space.
        layer.colorspace = prepared.colourSpace
        pixelScale = prepared.pixelScale
        screenSize = prepared.screenSize
        layer.drawableSize = CGSize(
            width: prepared.screenSize.width * prepared.pixelScale,
            height: prepared.screenSize.height * prepared.pixelScale
        )
    }

    func release() {
        picture = nil
        pictureFrame = nil
        stack = nil
        needsDraw = true
    }

    /// - Parameter corners: the picture corners projected onto the screen, in
    ///   points, listed bottom-left, bottom-right, top-right, top-left.
    func render(
        corners: [CGPoint],
        blurStrength: Double,
        dimStrength: Double,
        hingeFloor: Double,
        dimHingeFloor: Double,
        dimReach: Double,
        maxBlurRadius: Double,
        maxDim: Double
    ) {
        guard picture != nil, let layout = stack?.layout,
              screenSize.width > 0, screenSize.height > 0 else { return }
        let uniforms = Self.uniforms(
            corners: corners,
            layout: layout,
            screenSize: screenSize,
            pixelScale: pixelScale,
            blurStrength: blurStrength,
            dimStrength: dimStrength,
            hingeFloor: hingeFloor,
            dimHingeFloor: dimHingeFloor,
            dimReach: dimReach,
            maxBlurRadius: maxBlurRadius,
            maxDim: maxDim
        )
        let hasPending = pendingFrame != nil || pendingSeed != nil
        if !hasPending, !needsDraw, let drawnUniforms, drawnUniforms.matches(uniforms) { return }

        guard let commands = queue.makeCommandBuffer() else { return }
        absorbPending(into: commands)
        if let frame = pictureFrame {
            commands.addCompletedHandler { _ in
                withExtendedLifetime(frame) {}
            }
        }
        guard let picture, let stack, let drawable = layer.nextDrawable(),
              encodeFrame(uniforms, picture: picture, stack: stack, target: drawable.texture, into: commands) else {
            // Anything already encoded still runs; the next frame draws.
            commands.commit()
            needsDraw = true
            return
        }
        commands.present(drawable)
        commands.commit()
        drawnUniforms = uniforms
        needsDraw = false
    }

    /// The frame's settings in the form the shader takes.
    nonisolated static func uniforms(
        corners: [CGPoint],
        layout: BlurStack.Layout,
        screenSize: CGSize,
        pixelScale: CGFloat,
        blurStrength: Double,
        dimStrength: Double,
        hingeFloor: Double,
        dimHingeFloor: Double,
        dimReach: Double,
        maxBlurRadius: Double,
        maxDim: Double
    ) -> Uniforms {
        let forward = Homography.matrix(
            width: Double(screenSize.width),
            height: Double(screenSize.height),
            to: corners.map { SIMD2(Double($0.x), Double($0.y)) }
        )
        let padded = layout.paddedFrame(screenSize: screenSize)
        let transform = DepthTextureTransform(
            screenToPicture: forward.inverse,
            screenSize: screenSize,
            pixelScale: pixelScale,
            paddedOrigin: padded.origin,
            paddedSize: padded.size
        )

        func column(_ index: Int) -> SIMD4<Float> {
            let c = transform.matrix[index]
            return SIMD4(Float(c.x), Float(c.y), Float(c.z), 0)
        }
        // The response is uniform, so calculate it once instead of per pixel.
        let sigmaScale = powf(max(Float(blurStrength), 0), 1.2)
            * Float(maxBlurRadius * Double(pixelScale)) * sigmaPerRadius
        let sharpFilter = isMagnified(
            transform.matrix,
            at: SIMD2(Double(screenSize.width * pixelScale) / 2, Double(screenSize.height * pixelScale) - 0.5),
            extent: SIMD2(Double(layout.paddedWidth), Double(layout.paddedHeight))
        )
        return Uniforms(
            column0: column(0),
            column1: column(1),
            column2: column(2),
            picture: layout.pictureMapping,
            blur: SIMD4(
                sigmaScale * Float(hingeFloor),
                sigmaScale * (1 - Float(hingeFloor)),
                Float(layout.topLevel),
                sharpFilter ? 1 : 0
            ),
            extent: SIMD4(
                Float(layout.paddedWidth),
                Float(layout.paddedHeight),
                Float(layout.baseWidth),
                Float(layout.baseHeight)
            ),
            light: SIMD4(
                Float(maxDim),
                Float(dimHingeFloor),
                Float(dimStrength),
                Float(dimReach)
            )
        )
    }

    /// Whether the picture is magnified at a framebuffer pixel, so that one
    /// linear sample would soften it. The lean magnifies most at the hinge;
    /// at rest the picture lands pixel for pixel and one sample is exact.
    nonisolated private static func isMagnified(
        _ matrix: simd_double3x3,
        at pixel: SIMD2<Double>,
        extent: SIMD2<Double>
    ) -> Bool {
        let mapped = matrix * SIMD3(pixel.x, pixel.y, 1)
        let coordinate = SIMD2(mapped.x, mapped.y) / mapped.z
        let alongX = (SIMD2(matrix[0].x, matrix[0].y) - coordinate * matrix[0].z) / mapped.z * extent
        let alongY = (SIMD2(matrix[1].x, matrix[1].y) - coordinate * matrix[1].z) / mapped.z * extent
        // Picture pixels per screen pixel, squared, along the tighter axis.
        let footprint = min(simd_length_squared(alongX), simd_length_squared(alongY))
        return footprint < 0.94
    }

    /// Encodes the full screen pass that draws one frame into `target`.
    nonisolated func encodeFrame(
        _ uniforms: Uniforms,
        picture: MTLTexture,
        stack: BlurStack.Textures,
        target: MTLTexture,
        into commands: MTLCommandBuffer
    ) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        // The triangle covers every pixel.
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var bytes = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&bytes, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(picture, index: 0)
        encoder.setFragmentTexture(stack.stack, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }
}
