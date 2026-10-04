import CoreGraphics
import Metal

/// Gaussian blurs of one picture, half an octave apart.
///
/// Level n holds the picture on its black margin blurred to a sigma of
/// 2^(1 + n / 2) picture pixels. Even levels sit in slice 0 of a 2D array
/// texture and odd levels in slice 1, both at mip n / 2, so every level is
/// stored with its own blur close to one texel. The first mip is half the
/// picture's resolution; anything finer comes from the sharp picture itself.
///
/// Each level is built from the one before by adding only the missing blur,
/// with separable taps on linear samples. That keeps every pass to a handful
/// of samples, and the whole stack costs less than reading the picture a few
/// times over.
final class BlurStack: @unchecked Sendable {

    /// Taps a pass can take. Matches the shader's array.
    static let maximumTaps = DepthShaders.maximumTaps

    /// Mips per slice. The coarsest level then has a sigma of 2^8.5, past
    /// the widest blur the settings allow.
    static let levels = 8

    /// Sigma the shader's B-spline read adds, in texels.
    private static let readSigmaSquared = 1.0 / 3.0

    /// Stored sigma of the even and odd levels, in texels of their mip. With
    /// the read added they come to exactly 1 and the square root of 2.
    private static let evenSigma = (1 - readSigmaSquared).squareRoot()
    private static let oddSigma = (2 - readSigmaSquared).squareRoot()

    /// Level 0 from the sharp picture, halving both ways. Its stored sigma is
    /// `evenSigma` texels of the half-size mip, twice that in picture pixels.
    private static let firstTaps = taps(sigma: 2 * evenSigma, between: true)

    /// Even to odd, at the same size: the variances differ by exactly one
    /// texel squared.
    private static let oddTaps = taps(
        sigma: (oddSigma * oddSigma - evenSigma * evenSigma).squareRoot(),
        between: false
    )

    /// Odd to the next even, halving: the even level's sigma is `evenSigma`
    /// of the half-size texels, `2 * evenSigma` of these.
    private static let halvingTaps = taps(
        sigma: (4 * evenSigma * evenSigma - oddSigma * oddSigma).squareRoot(),
        between: true
    )

    /// One pipeline per distinct count.
    private static let tapCounts = Set([
        firstTaps.count, oddTaps.count, halvingTaps.count,
    ])

    /// Half-size columns the first pass keeps on each side of the picture:
    /// the reach of `firstTaps`, rounded up.
    private static let scratchColumnMargin = 3

    /// Where the picture sits in the stack. Sizes are in picture pixels.
    struct Layout: Equatable {
        let pictureWidth: Int
        let pictureHeight: Int
        /// The picture plus its margin, rounded so every mip is exactly half
        /// the one before. Otherwise the levels drift against each other.
        let paddedWidth: Int
        let paddedHeight: Int
        /// The margin left of and above the picture.
        let leftMargin: Int
        let topMargin: Int

        init?(pictureWidth: Int, pictureHeight: Int, minimumMargin: Int) {
            guard pictureWidth > 0, pictureHeight > 0, minimumMargin >= 0 else { return nil }
            let alignment = 1 << BlurStack.levels
            func padded(_ size: Int) -> Int {
                (size + 2 * minimumMargin + alignment - 1) / alignment * alignment
            }
            self.pictureWidth = pictureWidth
            self.pictureHeight = pictureHeight
            paddedWidth = padded(pictureWidth)
            paddedHeight = padded(pictureHeight)
            leftMargin = (paddedWidth - pictureWidth) / 2
            topMargin = (paddedHeight - pictureHeight) / 2
        }

        var baseWidth: Int { paddedWidth / 2 }
        var baseHeight: Int { paddedHeight / 2 }

        /// The half-size columns the first pass writes: the picture and the
        /// reach of its blur, not the black margin beyond.
        var scratchColumns: Range<Int> {
            let margin = BlurStack.scratchColumnMargin
            let first = max(leftMargin / 2 - margin, 0)
            let end = min((leftMargin + pictureWidth + 1) / 2 + margin, baseWidth)
            return first..<end
        }

        /// The highest level the shader may ask for.
        var topLevel: Int { 2 * BlurStack.levels - 1 }

        /// The stack's extent in screen points, with the origin at the bottom
        /// left as the geometry has it.
        func paddedFrame(screenSize: CGSize) -> CGRect {
            let scaleX = screenSize.width / CGFloat(pictureWidth)
            let scaleY = screenSize.height / CGFloat(pictureHeight)
            let bottomMargin = paddedHeight - pictureHeight - topMargin
            return CGRect(
                x: -CGFloat(leftMargin) * scaleX,
                y: -CGFloat(bottomMargin) * scaleY,
                width: CGFloat(paddedWidth) * scaleX,
                height: CGFloat(paddedHeight) * scaleY
            )
        }

        /// Maps stack coordinates to picture coordinates: scale, then offset.
        var pictureMapping: SIMD4<Float> {
            SIMD4(
                Float(paddedWidth) / Float(pictureWidth),
                Float(paddedHeight) / Float(pictureHeight),
                -Float(leftMargin) / Float(pictureWidth),
                -Float(topMargin) / Float(pictureHeight)
            )
        }
    }

    /// The stack for one layout, and the scratch textures that build it.
    /// Reuse it for every frame of the same size.
    struct Textures {
        let layout: Layout
        let stack: MTLTexture
        /// Single-level 2D views of the stack, indexed by level.
        fileprivate let levelViews: [MTLTexture]
        /// The first, horizontal half of the first level, over the picture's
        /// rows at full resolution so the vertical half can halve them.
        fileprivate let rowScratch: MTLTexture
        /// The horizontal half of each odd level.
        fileprivate let mipScratch: [MTLTexture]
        /// The horizontal half of each even level after the first.
        fileprivate let halvingScratch: [MTLTexture]
        fileprivate let passes: [Pass]
    }

    fileprivate enum Target {
        case rowScratch
        case mipScratch(Int)
        case halvingScratch(Int)
        case level(Int)
    }

    fileprivate enum Input {
        case picture
        case rowScratch
        case mipScratch(Int)
        case halvingScratch(Int)
        case level(Int)
    }

    fileprivate struct Pass {
        let input: Input
        let target: Target
        let taps: Int
        var uniforms: PassUniforms

        init(input: Input, target: Target, uniforms: PassUniforms) {
            self.input = input
            self.target = target
            taps = Int(uniforms.count.x)
            self.uniforms = uniforms
        }
    }

    /// Mirrors `PassUniforms` in the shader.
    fileprivate struct PassUniforms {
        var frame: SIMD4<Float>
        var count: SIMD4<Float>
        var taps: (
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
        )

        init(frame: SIMD4<Float>, outputWidth: Int, outputHeight: Int, taps list: [SIMD4<Float>]) {
            precondition(list.count <= BlurStack.maximumTaps)
            self.frame = frame
            count = SIMD4(Float(list.count), 0, 1 / Float(outputWidth), 1 / Float(outputHeight))
            taps = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
            withUnsafeMutableBytes(of: &taps) { raw in
                let slots = raw.bindMemory(to: SIMD4<Float>.self)
                for (index, tap) in list.enumerated() { slots[index] = tap }
            }
        }
    }

    private let device: MTLDevice
    private let pipelines: [Int: MTLRenderPipelineState]

    init?(device: MTLDevice, library: MTLLibrary) {
        var pipelines: [Int: MTLRenderPipelineState] = [:]
        for taps in Self.tapCounts {
            let constants = MTLFunctionConstantValues()
            var count = Int32(taps)
            constants.setConstantValue(&count, type: .int, index: 0)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "depthVertex")
            descriptor.fragmentFunction = try? library.makeFunction(name: "blurPass", constantValues: constants)
            // Drawn rather than computed: Intel and AMD GPUs cannot write
            // sRGB textures from a shader, and on Apple GPUs the passes run
            // a little faster this way too.
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            pipelines[taps] = pipeline
        }
        self.device = device
        self.pipelines = pipelines
    }

    func makeTextures(for layout: Layout) -> Textures? {
        let levels = Self.levels
        // sRGB, so every pass reads and writes light rather than encoded
        // values, as the blur of a lens would.
        let stackDescriptor = MTLTextureDescriptor()
        stackDescriptor.textureType = .type2DArray
        stackDescriptor.pixelFormat = .bgra8Unorm_srgb
        stackDescriptor.width = layout.baseWidth
        stackDescriptor.height = layout.baseHeight
        stackDescriptor.arrayLength = 2
        stackDescriptor.mipmapLevelCount = levels
        stackDescriptor.usage = [.shaderRead, .renderTarget]
        stackDescriptor.storageMode = .private
        guard let stack = device.makeTexture(descriptor: stackDescriptor) else { return nil }

        var levelViews: [MTLTexture] = []
        for level in 0..<(2 * levels) {
            guard let view = stack.makeTextureView(
                pixelFormat: .bgra8Unorm_srgb,
                textureType: .type2D,
                levels: (level / 2)..<(level / 2 + 1),
                slices: (level % 2)..<(level % 2 + 1)
            ) else { return nil }
            levelViews.append(view)
        }

        func scratch(width: Int, height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        guard let rowScratch = scratch(width: layout.scratchColumns.count, height: layout.pictureHeight) else {
            return nil
        }
        var mipScratch: [MTLTexture] = []
        for mip in 0..<levels {
            guard let texture = scratch(width: layout.baseWidth >> mip, height: layout.baseHeight >> mip) else {
                return nil
            }
            mipScratch.append(texture)
        }
        var halvingScratch: [MTLTexture] = []
        for mip in 0..<(levels - 1) {
            guard let texture = scratch(width: layout.baseWidth >> (mip + 1), height: layout.baseHeight >> mip) else {
                return nil
            }
            halvingScratch.append(texture)
        }

        return Textures(
            layout: layout,
            stack: stack,
            levelViews: levelViews,
            rowScratch: rowScratch,
            mipScratch: mipScratch,
            halvingScratch: halvingScratch,
            passes: Self.plan(layout)
        )
    }

    /// Rebuilds every level from `picture`, which covers the layout's picture
    /// area at any resolution.
    func encode(from picture: MTLTexture, into commands: MTLCommandBuffer, textures: Textures) {
        func resolve(_ pass: Pass) -> (input: MTLTexture, output: MTLTexture) {
            let input: MTLTexture
            switch pass.input {
            case .picture: input = picture
            case .rowScratch: input = textures.rowScratch
            case .mipScratch(let mip): input = textures.mipScratch[mip]
            case .halvingScratch(let mip): input = textures.halvingScratch[mip]
            case .level(let level): input = textures.levelViews[level]
            }
            let output: MTLTexture
            switch pass.target {
            case .rowScratch: output = textures.rowScratch
            case .mipScratch(let mip): output = textures.mipScratch[mip]
            case .halvingScratch(let mip): output = textures.halvingScratch[mip]
            case .level(let level): output = textures.levelViews[level]
            }
            return (input, output)
        }

        for pass in textures.passes {
            guard let pipeline = pipelines[pass.taps] else { continue }
            let (input, output) = resolve(pass)
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = output
            // The triangle covers every pixel.
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            var uniforms = pass.uniforms
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PassUniforms>.stride, index: 0)
            encoder.setFragmentTexture(input, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    // MARK: - Planning

    /// Linear taps for a Gaussian of `sigma` input texels. `between` centres
    /// it between two texels, as halving the resolution does; otherwise it
    /// sits on a texel centre. Neighbouring texels share one linear sample,
    /// which weighs them exactly when it lands at their weighted mean.
    static func taps(sigma: Double, between: Bool) -> [(offset: Double, weight: Double)] {
        let reach = 3 * sigma
        let first = between ? 0.5 : 1.0
        // Texel centres on one side, nearest first.
        var side: [Double] = []
        var position = first
        while position <= reach + 0.5 {
            side.append(position)
            position += 1
        }
        func weight(_ x: Double) -> Double { exp(-x * x / (2 * sigma * sigma)) }

        var right: [(offset: Double, weight: Double)] = []
        var index = 0
        while index < side.count {
            let a = side[index]
            if index + 1 < side.count {
                let b = side[index + 1]
                let total = weight(a) + weight(b)
                right.append(((a * weight(a) + b * weight(b)) / total, total))
            } else {
                right.append((a, weight(a)))
            }
            index += 2
        }

        var all = right.reversed().map { (-$0.offset, $0.weight) } + right
        if !between { all.insert((0, weight(0)), at: right.count) }
        let sum = all.reduce(0) { $0 + $1.weight }
        return all.map { ($0.offset, $0.weight / sum) }
    }

    private static func plan(_ layout: Layout) -> [Pass] {
        var passes: [Pass] = []
        let pictureWidth = Float(layout.pictureWidth)
        let pictureHeight = Float(layout.pictureHeight)
        let columns = layout.scratchColumns
        let scratchWidth = Float(columns.count)

        // Scratch column i is half-size column i + first, centred on picture
        // pixel 2 (i + first) + 1 - leftMargin: between two pixels, as
        // `firstTaps` expects.
        passes.append(Pass(
            input: .picture,
            target: .rowScratch,
            uniforms: PassUniforms(
                frame: SIMD4(
                    2 * scratchWidth / pictureWidth, 1,
                    Float(2 * columns.lowerBound - layout.leftMargin) / pictureWidth, 0
                ),
                outputWidth: columns.count,
                outputHeight: layout.pictureHeight,
                taps: firstTaps.map { SIMD4(Float($0.offset) / pictureWidth, 0, Float($0.weight), 0) }
            )
        ))
        passes.append(Pass(
            input: .rowScratch,
            target: .level(0),
            uniforms: PassUniforms(
                frame: SIMD4(
                    Float(layout.baseWidth) / scratchWidth, Float(layout.paddedHeight) / pictureHeight,
                    -Float(columns.lowerBound) / scratchWidth, -Float(layout.topMargin) / pictureHeight
                ),
                outputWidth: layout.baseWidth,
                outputHeight: layout.baseHeight,
                taps: firstTaps.map { SIMD4(0, Float($0.offset) / pictureHeight, Float($0.weight), 0) }
            )
        ))

        let identity = SIMD4<Float>(1, 1, 0, 0)
        for mip in 0..<levels {
            let width = layout.baseWidth >> mip
            let height = layout.baseHeight >> mip
            passes.append(Pass(
                input: .level(2 * mip),
                target: .mipScratch(mip),
                uniforms: PassUniforms(
                    frame: identity,
                    outputWidth: width,
                    outputHeight: height,
                    taps: oddTaps.map { SIMD4(Float($0.offset) / Float(width), 0, Float($0.weight), 0) }
                )
            ))
            passes.append(Pass(
                input: .mipScratch(mip),
                target: .level(2 * mip + 1),
                uniforms: PassUniforms(
                    frame: identity,
                    outputWidth: width,
                    outputHeight: height,
                    taps: oddTaps.map { SIMD4(0, Float($0.offset) / Float(height), Float($0.weight), 0) }
                )
            ))
            guard mip + 1 < levels else { break }
            passes.append(Pass(
                input: .level(2 * mip + 1),
                target: .halvingScratch(mip),
                uniforms: PassUniforms(
                    frame: identity,
                    outputWidth: width / 2,
                    outputHeight: height,
                    taps: halvingTaps.map { SIMD4(Float($0.offset) / Float(width), 0, Float($0.weight), 0) }
                )
            ))
            passes.append(Pass(
                input: .halvingScratch(mip),
                target: .level(2 * mip + 2),
                uniforms: PassUniforms(
                    frame: identity,
                    outputWidth: width / 2,
                    outputHeight: height / 2,
                    taps: halvingTaps.map { SIMD4(0, Float($0.offset) / Float(height), Float($0.weight), 0) }
                )
            ))
        }
        return passes
    }
}
