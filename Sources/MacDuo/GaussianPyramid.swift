import Foundation
import Metal
import MetalPerformanceShaders

/// Fills every mip level above 0 with the Gaussian pyramid of level 0.
///
/// MPS builds it where it can. MPS writes the levels from a compute kernel,
/// and Intel and AMD GPUs cannot write an sRGB texture from a shader, which
/// matches the black or tinted blur reported from those Macs. There the same
/// filter runs as one small render pass per level instead: every Mac can
/// render to sRGB, and the render target encodes the colour on the way out
/// just as the sRGB write does under MPS.
///
/// Expects a `.bgra8Unorm_srgb` texture with `renderTarget` usage, as both
/// pictures are. Shared by the picture build queue and the main thread; the
/// lock keeps one encode at a time, which is also all an MPS kernel allows.
final class GaussianPyramid: @unchecked Sendable {

    private let device: MTLDevice
    private let lock = NSLock()
    /// `nil` once MPS is ruled out. Never built on a GPU MPS does not
    /// support, where its initialiser hands back nil through a non-optional.
    private var kernel: MPSImageGaussianPyramid?
    /// Built when MPS is ruled out, and only then.
    private var pipeline: MTLRenderPipelineState?
    private var hasReportedBoxFilter = false

    /// - Parameter allowsMPS: false takes the render pass path on any GPU,
    ///   so tests can compare it with MPS.
    init(device: MTLDevice, allowsMPS: Bool = true) {
        self.device = device
        if !allowsMPS {
            pipeline = Self.makePipeline(device: device)
        } else if let reason = Self.reasonToAvoidMPS(on: device) {
            Diagnostics.geometry.notice("pyramid: \(reason, privacy: .public); drawing the levels instead")
            pipeline = Self.makePipeline(device: device)
        } else {
            kernel = MPSImageGaussianPyramid(device: device, centerWeight: 0.375)
        }
    }

    /// Why MPS cannot build the pyramid on this GPU, or nil when it can.
    static func reasonToAvoidMPS(on device: MTLDevice) -> String? {
        if !MPSSupportsMTLDevice(device) {
            return "MPS does not support \(device.name)"
        }
        // The Metal feature set tables give sRGB formats shader write only
        // on Apple GPUs; Intel and AMD GPUs can sample and render them.
        if !device.supportsFamily(.apple2) {
            return "\(device.name) cannot write sRGB from a shader"
        }
        return nil
    }

    /// Encodes the pyramid after whatever already writes level 0.
    ///
    /// - Returns: false when nothing could build it, so the levels the
    ///   shader samples above 0 are not valid.
    func encode(into texture: MTLTexture, on commands: MTLCommandBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let kernel {
            var inPlace = texture
            // A copy allocator would not help: MPS documents that pyramids
            // ignore it, so a refusal here is final rather than a request
            // for a second texture.
            if kernel.encode(commandBuffer: commands, inPlaceTexture: &inPlace, fallbackCopyAllocator: nil) {
                return true
            }
            self.kernel = nil
            Diagnostics.geometry.notice("pyramid: MPS refused to encode in place; drawing the levels instead")
            pipeline = Self.makePipeline(device: device)
        }

        if let pipeline, texture.pixelFormat == .bgra8Unorm_srgb, texture.usage.contains(.renderTarget) {
            return encodeLevels(of: texture, with: pipeline, on: commands)
        }

        // Last resort. A box filter is coarser than the Gaussian and shifts
        // the look, but every level the shader samples is defined, where
        // skipping them would show stale memory.
        if !hasReportedBoxFilter {
            hasReportedBoxFilter = true
            Diagnostics.geometry.error("pyramid: cannot draw the levels; using box-filtered mipmaps")
        }
        guard let blit = commands.makeBlitCommandEncoder() else { return false }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        return true
    }

    /// One pass per level, each reading a view of the level below. The view
    /// keeps the level being read apart from the one being drawn.
    private func encodeLevels(
        of texture: MTLTexture,
        with pipeline: MTLRenderPipelineState,
        on commands: MTLCommandBuffer
    ) -> Bool {
        for level in 1..<texture.mipmapLevelCount {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].level = level
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let source = texture.makeTextureView(
                      pixelFormat: texture.pixelFormat,
                      textureType: .type2D,
                      levels: (level - 1)..<level,
                      slices: 0..<1
                  ),
                  let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        return true
    }

    private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "pyramidVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "pyramidFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Diagnostics.geometry.error("pyramid pipeline failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The filter MPSImageGaussianPyramid applies with `centerWeight: 0.375`:
    /// the binomial [1 4 6 4 1] / 16 along each axis, centred on the even
    /// texels of the level below (it drops the odd rows and columns), with
    /// zero outside the level. Sampling an sRGB view returns linear light,
    /// so the filter runs in linear light, as it does under MPS.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    vertex float4 pyramidVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[vertexID], 0.0, 1.0);
    }

    fragment float4 pyramidFragment(float4 position [[position]],
                                    texture2d<float> below [[texture(0)]]) {
        // clamp_to_zero is MPS's default zero edge mode.
        constexpr sampler linearSampler(filter::linear, address::clamp_to_zero);
        float2 size = float2(below.get_width(), below.get_height());
        // Texel i here is texel 2i below. Positions sit on texel centres.
        float2 centre = 2.0 * floor(position.xy) + 0.5;
        // Each outer pair of taps, weights 1 and 4, is one linear sample
        // 1.2 texels out, so the 5x5 kernel takes nine samples.
        const float3 offsets = float3(-1.2, 0.0, 1.2);
        const float3 weights = float3(5.0, 6.0, 5.0) / 16.0;
        float4 colour = float4(0.0);
        for (int row = 0; row < 3; row++) {
            for (int column = 0; column < 3; column++) {
                float2 texel = centre + float2(offsets[column], offsets[row]);
                colour += below.sample(linearSampler, texel / size)
                    * (weights[column] * weights[row]);
            }
        }
        return colour;
    }
    """
}
