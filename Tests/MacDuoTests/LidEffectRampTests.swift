import Foundation
import Testing
@testable import MacDuo

struct LidEffectRampTests {
    /// The default settings: a 90° start angle and full effect 60° on.
    private let ramp = LidEffectRamp(startAngle: 90, span: 60)

    @Test
    func testFullEffectAngleIsTheSpanPastTheStart() {
        #expect(ramp.fullEffectAngle == 30)
        #expect(LidEffectRamp(startAngle: 110, span: 15).fullEffectAngle == 95)
    }

    @Test
    func testPictureFollowsTheLidUpToFullEffect() {
        for angle in stride(from: 130.0, through: 30, by: -0.5) {
            #expect(ramp.pictureAngle(for: angle) == angle, "at \(angle)°")
        }
    }

    @Test
    func testPictureHoldsPastFullEffect() {
        for angle in stride(from: 29.5, through: 0, by: -0.5) {
            #expect(ramp.pictureAngle(for: angle) == 30, "at \(angle)°")
        }
    }

    @Test
    func testNoJumpAtFullEffect() {
        let full = ramp.fullEffectAngle
        #expect(ramp.pictureAngle(for: full) == full)
        // Either side of it the picture is no further from it than the lid.
        for offset in [1e-9, 1e-6, 1e-3, 0.1] {
            #expect(ramp.pictureAngle(for: full + offset) == full + offset)
            #expect(ramp.pictureAngle(for: full - offset) == full)
        }
    }

    @Test
    func testOpeningBackPastFullEffectFollowsTheLidAgain() {
        // Shut past full effect, held, then opened back above it.
        let sweep: [Double] = [60, 40, 30, 20, 5, 5, 20, 30, 35, 50, 90]
        let drawn = sweep.map { ramp.pictureAngle(for: $0) }
        #expect(drawn == [60, 40, 30, 30, 30, 30, 30, 30, 35, 50, 90])
    }

    @Test
    func testFullEffectFollowsALoweredStartAngle() {
        // A 132° hinge holds a 130° setting down to 128°.
        let policy = LidEffectPolicy(threshold: 130, hysteresis: 4, hingeLimit: 132)
        let lowered = LidEffectRamp(startAngle: policy.threshold, span: 20)
        #expect(lowered.fullEffectAngle == 108)
        #expect(lowered.pictureAngle(for: 109) == 109)
        #expect(lowered.pictureAngle(for: 108) == 108)
        #expect(lowered.pictureAngle(for: 100) == 108)
        #expect(lowered.progress(at: 108) == 1)
        #expect(lowered.progress(at: 128) == 0)
    }

    @Test
    func testBlurAndPictureSaturateAtTheSameAngle() {
        let full = ramp.fullEffectAngle
        #expect(ramp.progress(at: 90) == 0)
        #expect(ramp.progress(at: 100) == 0)
        #expect(ramp.progress(at: 60) == 0.5)
        #expect(ramp.progress(at: full) == 1)
        #expect(ramp.progress(at: full + 0.5) < 1)
        #expect(ramp.progress(at: 0) == 1)
    }

    @Test
    func testZeroSpanStillHasARamp() {
        let narrow = LidEffectRamp(startAngle: 90, span: 0)
        #expect(narrow.fullEffectAngle == 89)
        #expect(narrow.progress(at: 89.5) == 0.5)
        #expect(narrow.pictureAngle(for: 60) == 89)
    }

    /// The whole point: past full effect the corners stop moving, while
    /// before it every degree still moves them.
    @Test
    func testCornersStopMovingPastFullEffect() {
        let geometry = DepthGeometry()
        func corners(lid angle: Double) -> [CGPoint] {
            geometry.corners(
                startAngle: ramp.startAngle,
                currentAngle: ramp.pictureAngle(for: angle),
                viewingDistanceRatio: 2.7,
                recession: 2,
                screenSize: CGSize(width: 1512, height: 982)
            )
        }
        let held = corners(lid: ramp.fullEffectAngle)
        for angle in [29.0, 20, 10, 0] {
            #expect(corners(lid: angle) == held, "at \(angle)°")
        }
        #expect(corners(lid: 31) != held)
        #expect(corners(lid: 60) != corners(lid: 50))
    }
}
