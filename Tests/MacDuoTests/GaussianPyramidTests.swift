import Metal
import Testing
@testable import MacDuo

/// The drawn pyramid stands in for MPS on Intel and AMD GPUs, where it cannot
/// be watched, so it is held to MPS and to the filter on an Apple GPU here.
struct GaussianPyramidTests {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let hasMPS = device.map { GaussianPyramid.reasonToAvoidMPS(on: $0) == nil } ?? false

    /// Odd sizes, so some levels drop a trailing row or column.
    private let width = 157
    private let height = 93

    @Test(.enabled(if: hasMPS))
    func testDrawnLevelsMatchMPS() throws {
        let device = try #require(Self.device)
        let queue = try #require(device.makeCommandQueue())
        let picture = noise(width: width, height: height)
        let drawn = try makePyramid(picture, device: device, queue: queue, allowsMPS: false)
        let filtered = try makePyramid(picture, device: device, queue: queue, allowsMPS: true)

        #expect(drawn.mipmapLevelCount == filtered.mipmapLevelCount)
        for level in 1..<drawn.mipmapLevelCount {
            let difference = maxDifference(
                try read(drawn, level: level, queue: queue),
                try read(filtered, level: level, queue: queue)
            )
            #expect(difference <= 1, "level \(level) is \(difference)/255 from MPS")
        }
    }

    /// Each level against the binomial filter of the level below, worked out
    /// in linear light on the CPU. Needs no MPS, so it runs on any GPU.
    @Test(.enabled(if: device != nil))
    func testDrawnLevelsFollowTheBinomialFilter() throws {
        let device = try #require(Self.device)
        let queue = try #require(device.makeCommandQueue())
        let drawn = try makePyramid(
            noise(width: width, height: height), device: device, queue: queue, allowsMPS: false
        )

        var below = try read(drawn, level: 0, queue: queue)
        for level in 1..<drawn.mipmapLevelCount {
            let pixels = try read(drawn, level: level, queue: queue)
            let expected = reduce(
                below,
                width: max(1, width >> (level - 1)),
                height: max(1, height >> (level - 1))
            )
            let difference = maxDifference(pixels, expected)
            #expect(difference <= 1, "level \(level) is \(difference)/255 from the filter")
            below = pixels
        }
    }

    // MARK: - Helpers

    private func makePyramid(
        _ pixels: [UInt8],
        device: MTLDevice,
        queue: MTLCommandQueue,
        allowsMPS: Bool
    ) throws -> MTLTexture {
        // The same texture DepthRenderer builds for a held picture.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget, .pixelFormatView]
        descriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let staging = try #require(
            device.makeBuffer(bytes: pixels, length: pixels.count, options: .storageModeShared)
        )
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: width * 4,
            sourceBytesPerImage: pixels.count,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        let pyramid = GaussianPyramid(device: device, allowsMPS: allowsMPS)
        #expect(pyramid.encode(into: texture, on: commands))
        commands.commit()
        commands.waitUntilCompleted()
        #expect(commands.status == .completed)
        return texture
    }

    private func read(_ texture: MTLTexture, level: Int, queue: MTLCommandQueue) throws -> [UInt8] {
        let levelWidth = max(1, texture.width >> level)
        let levelHeight = max(1, texture.height >> level)
        let length = levelWidth * levelHeight * 4
        let buffer = try #require(texture.device.makeBuffer(length: length, options: .storageModeShared))
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: level,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: levelWidth, height: levelHeight, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: levelWidth * 4,
            destinationBytesPerImage: length
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return Array(UnsafeBufferPointer(
            start: buffer.contents().assumingMemoryBound(to: UInt8.self),
            count: length
        ))
    }

    /// Opaque noise, the hardest case for a filter: every texel differs
    /// from its neighbours.
    private func noise(width: Int, height: Int) -> [UInt8] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<(width * height * 4)).map { index in
            guard index % 4 != 3 else { return 255 }
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
    }

    /// The binomial [1 4 6 4 1] / 16 on the even texels, zero outside.
    private func reduce(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        let weights: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }
        let reducedWidth = max(1, width / 2)
        let reducedHeight = max(1, height / 2)
        var reduced = [UInt8](repeating: 0, count: reducedWidth * reducedHeight * 4)
        for y in 0..<reducedHeight {
            for x in 0..<reducedWidth {
                var sum = [Float](repeating: 0, count: 4)
                for row in 0..<5 {
                    let sourceY = 2 * y + row - 2
                    guard sourceY >= 0, sourceY < height else { continue }
                    for column in 0..<5 {
                        let sourceX = 2 * x + column - 2
                        guard sourceX >= 0, sourceX < width else { continue }
                        let weight = weights[row] * weights[column]
                        let index = (sourceY * width + sourceX) * 4
                        for channel in 0..<4 {
                            let value = Float(pixels[index + channel]) / 255
                            // Alpha is stored linear; the colour is sRGB.
                            sum[channel] += weight * (channel == 3 ? value : Self.linear(value))
                        }
                    }
                }
                let index = (y * reducedWidth + x) * 4
                for channel in 0..<4 {
                    let value = channel == 3 ? sum[channel] : Self.encoded(sum[channel])
                    reduced[index + channel] = UInt8((min(max(value, 0), 1) * 255).rounded())
                }
            }
        }
        return reduced
    }

    private func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    private static func linear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ value: Float) -> Float {
        value <= 0.0031308 ? value * 12.92 : 1.055 * powf(value, 1 / 2.4) - 0.055
    }
}
