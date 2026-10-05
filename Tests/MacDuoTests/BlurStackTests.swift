import CoreGraphics
import Foundation
import Metal
import Testing
import simd
@testable import MacDuo

struct BlurStackTests {

    @Test(arguments: [0.8, 1.0, 1.29, 1.63, 2.5])
    func testTapsAreANormalisedGaussian(sigma: Double) {
        for between in [false, true] {
            let taps = BlurStack.taps(sigma: sigma, between: between)
            let total = taps.reduce(0) { $0 + $1.weight }
            #expect(abs(total - 1) < 1e-9)
            // Symmetric about the centre.
            for (tap, mirror) in zip(taps, taps.reversed()) {
                #expect(abs(tap.offset + mirror.offset) < 1e-9)
                #expect(abs(tap.weight - mirror.weight) < 1e-9)
            }
            // The variance of the texels the taps stand for, cut off at three
            // sigma, so a little under the full Gaussian. A linear sample
            // splits its weight between the two texel centres around it.
            let phase = between ? 0.5 : 0
            let variance = taps.reduce(0.0) { (total: Double, tap) in
                let below = (tap.offset - phase).rounded(.down) + phase
                let above = below + 1
                let toAbove = tap.offset - below
                return total + tap.weight * ((1 - toAbove) * below * below + toAbove * above * above)
            }
            #expect(variance < sigma * sigma * 1.001)
            #expect(variance > sigma * sigma * 0.9)
        }
    }

    @Test(arguments: [0.8, 1.0, 1.63])
    func testTapsWeighEachTexelLikeTheGaussian(sigma: Double) {
        // Split every linear sample back into its two texels; the result must
        // be the Gaussian sampled at the texel centres, renormalised.
        for between in [false, true] {
            let phase = between ? 0.5 : 0
            var texels: [Double: Double] = [:]
            for tap in BlurStack.taps(sigma: sigma, between: between) {
                let below = (tap.offset - phase).rounded(.down) + phase
                let toAbove = tap.offset - below
                texels[below, default: 0] += tap.weight * (1 - toAbove)
                texels[below + 1, default: 0] += tap.weight * toAbove
            }
            // The texels the taps reach; the cut-off leaves the rest out.
            let reached = texels.filter { $0.value > 1e-12 }
            func gaussian(_ x: Double) -> Double { exp(-x * x / (2 * sigma * sigma)) }
            let total = reached.keys.reduce(0) { $0 + gaussian($1) }
            for (position, weight) in reached {
                #expect(abs(weight - gaussian(position) / total) < 1e-9)
            }
        }
    }

    @Test(arguments: [(3024, 1964), (3456, 2234), (2880, 1800), (1441, 901)])
    func testLayoutHalvesExactlyAndKeepsTheMargin(width: Int, height: Int) throws {
        let layout = try #require(BlurStack.Layout(pictureWidth: width, pictureHeight: height, minimumMargin: 240))
        let alignment = 1 << BlurStack.levels
        #expect(layout.paddedWidth % alignment == 0)
        #expect(layout.paddedHeight % alignment == 0)
        #expect(layout.leftMargin >= 240)
        #expect(layout.topMargin >= 240)
        #expect(layout.paddedWidth - width - layout.leftMargin >= 240)
        #expect(layout.paddedHeight - height - layout.topMargin >= 240)
        // The first pass covers the whole picture, in half-size columns.
        #expect(layout.scratchColumns.lowerBound * 2 <= layout.leftMargin)
        #expect(layout.scratchColumns.upperBound * 2 >= layout.leftMargin + width)
    }

    @Test
    func testPictureMappingPutsThePictureInsideTheStack() throws {
        let layout = try #require(BlurStack.Layout(pictureWidth: 3024, pictureHeight: 1964, minimumMargin: 240))
        let mapping = layout.pictureMapping
        func picture(_ stack: SIMD2<Float>) -> SIMD2<Float> {
            stack * SIMD2(mapping.x, mapping.y) + SIMD2(mapping.z, mapping.w)
        }
        let origin = SIMD2(Float(layout.leftMargin) / Float(layout.paddedWidth),
                           Float(layout.topMargin) / Float(layout.paddedHeight))
        let end = SIMD2(Float(layout.leftMargin + 3024) / Float(layout.paddedWidth),
                        Float(layout.topMargin + 1964) / Float(layout.paddedHeight))
        #expect(simd_length(picture(origin)) < 1e-5)
        #expect(simd_length(picture(end) - SIMD2<Float>(1, 1)) < 1e-5)
    }

    /// Blurs a white square sized for each level and checks the level's
    /// spread, centre and brightness against the design.
    @Test
    func testLevelsHoldTheirGaussian() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let library = try device.makeLibrary(source: DepthShaders.source, options: nil)
        let stack = try #require(BlurStack(device: device, library: library))
        let width = 800, height = 600
        let layout = try #require(BlurStack.Layout(pictureWidth: width, pictureHeight: height, minimumMargin: 64))
        let textures = try #require(stack.makeTextures(for: layout))

        for level in [0, 1, 2, 5, 8] {
            let texel = Double(1 << (level / 2 + 1))
            let stored = (level % 2 == 0 ? (2.0 / 3.0).squareRoot() : (5.0 / 3.0).squareRoot()) * texel
            let side = max(4, Int(stored.rounded()) * 2)
            let centre = (x: 400, y: 300)
            let picture = try makePicture(
                device: device, queue: queue, width: width, height: height,
                square: CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
            )
            let commands = try #require(queue.makeCommandBuffer())
            stack.encode(from: picture, into: commands, textures: textures)
            commands.commit()
            commands.waitUntilCompleted()

            let mip = level / 2
            let levelWidth = layout.baseWidth >> mip
            let levelHeight = layout.baseHeight >> mip
            let bytes = try readLevel(textures.stack, mip: mip, slice: level % 2, device: device, queue: queue)
            var mass = 0.0, sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0
            for y in 0..<levelHeight {
                for x in 0..<levelWidth {
                    let value = Self.decode(bytes[(y * levelWidth + x) * 4 + 1])
                    let px = (Double(x) + 0.5) * texel - Double(layout.leftMargin)
                    let py = (Double(y) + 0.5) * texel - Double(layout.topMargin)
                    mass += value
                    sumX += value * px
                    sumY += value * py
                    sumXX += value * px * px
                    sumYY += value * py * py
                }
            }
            let meanX = sumX / mass, meanY = sumY / mass
            let squareVariance = Double(side * side - 1) / 12
            let sigmaX = (sumXX / mass - meanX * meanX - squareVariance).squareRoot()
            let sigmaY = (sumYY / mass - meanY * meanY - squareVariance).squareRoot()
            #expect(abs(sigmaX / stored - 1) < 0.03, "level \(level) sigma x \(sigmaX), want \(stored)")
            #expect(abs(sigmaY / stored - 1) < 0.03, "level \(level) sigma y \(sigmaY), want \(stored)")
            #expect(abs(meanX - Double(centre.x)) < 0.05 * stored + 0.05)
            #expect(abs(meanY - Double(centre.y)) < 0.05 * stored + 0.05)
            #expect(abs(mass * texel * texel / Double(side * side) - 1) < 0.02)
        }
    }

    private static func decode(_ value: UInt8) -> Double {
        let encoded = Double(value) / 255
        return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    /// A black picture with one white square, `square` in pixels from the top left.
    private func makePicture(
        device: MTLDevice,
        queue: MTLCommandQueue,
        width: Int,
        height: Int,
        square: CGRect
    ) throws -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let lit = square.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                pixels[index] = lit ? 255 : 0
                pixels[index + 1] = lit ? 255 : 0
                pixels[index + 2] = lit ? 255 : 0
                pixels[index + 3] = 255
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4
        )
        return texture
    }

    private func readLevel(
        _ texture: MTLTexture,
        mip: Int,
        slice: Int,
        device: MTLDevice,
        queue: MTLCommandQueue
    ) throws -> [UInt8] {
        let width = texture.width >> mip, height = texture.height >> mip
        let buffer = try #require(device.makeBuffer(length: width * height * 4, options: .storageModeShared))
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: texture,
            sourceSlice: slice,
            sourceLevel: mip,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: width * 4,
            destinationBytesPerImage: width * height * 4
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let pointer = buffer.contents().bindMemory(to: UInt8.self, capacity: width * height * 4)
        return Array(UnsafeBufferPointer(start: pointer, count: width * height * 4))
    }
}
