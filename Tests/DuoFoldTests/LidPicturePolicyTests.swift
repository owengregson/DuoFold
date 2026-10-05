import CoreGraphics
import Foundation
import Testing
@testable import DuoFold

/// What a run shows first, and how the captured picture takes over from the
/// glass without a visible join.
struct LidPicturePolicyTests {

    private let policy = LidPicturePolicy()

    @Test
    func testGlassModeShowsTheGlassAtOnce() {
        let plan = policy.plan(capturesScreen: false, isGlassAvailable: true, isLivePicture: true, hasStreamFrame: false)
        #expect(plan.first == .glass)
        #expect(!plan.seedsFromScreenshot)
        // At the start angle it blurs and dims nothing, so there is nothing
        // to fade in.
        #expect(plan.fadeIn == 0)
    }

    @Test(arguments: [true, false])
    func testCaptureModeBridgesWithTheGlass(isLivePicture: Bool) {
        let plan = policy.plan(capturesScreen: true, isGlassAvailable: true, isLivePicture: isLivePicture, hasStreamFrame: false)
        #expect(plan.first == .glassUnderPicture)
        // The glass covers the wait, and a screenshot would only slow the
        // starting stream down.
        #expect(!plan.seedsFromScreenshot)
        // The picture takes over showing the same frame, so it cuts in.
        #expect(plan.fadeIn == 0)
    }

    @Test
    func testWithoutTheGlassTheLivePictureStartsFromAScreenshot() {
        let waiting = policy.plan(capturesScreen: true, isGlassAvailable: false, isLivePicture: true, hasStreamFrame: false)
        #expect(waiting.first == .pictureAlone)
        #expect(waiting.seedsFromScreenshot)
        #expect(waiting.fadeIn == LidPicturePolicy.fadeInDuration)

        // A frame already there needs no screenshot.
        let ready = policy.plan(capturesScreen: true, isGlassAvailable: false, isLivePicture: true, hasStreamFrame: true)
        #expect(ready.first == .pictureAlone)
        #expect(!ready.seedsFromScreenshot)
    }

    @Test
    func testTheStillPictureIsItsOwnScreenshot() {
        let plan = policy.plan(capturesScreen: true, isGlassAvailable: false, isLivePicture: false, hasStreamFrame: false)
        #expect(plan.first == .pictureAlone)
        #expect(!plan.seedsFromScreenshot)
        #expect(plan.fadeIn == LidPicturePolicy.fadeInDuration)
    }
}

struct LidLeanCatchUpTests {

    @Test
    func testWithNoHandoverThePictureLeansWithTheLid() {
        let catchUp = LidLeanCatchUp()
        #expect(catchUp.share(at: 0) == 1)
        #expect(catchUp.share(at: 100) == 1)
        #expect(catchUp.pictureAngle(92.5, startAngle: 100, at: 5) == 92.5)
    }

    @Test
    func testThePictureTakesOverFlatWhereTheGlassWas() {
        var catchUp = LidLeanCatchUp()
        catchUp.begin(at: 10)
        #expect(catchUp.share(at: 10) == 0)
        // The lid is 7.5° past the start angle, and the picture shows none of it.
        #expect(catchUp.pictureAngle(92.5, startAngle: 100, at: 10) == 100)
        // Flat is the screen itself: the frame the glass tests pin the glass to.
        let corners = DepthGeometry().corners(
            startAngle: 100, currentAngle: catchUp.pictureAngle(92.5, startAngle: 100, at: 10),
            viewingDistanceRatio: 2.7, recession: 2, screenSize: CGSize(width: 1512, height: 982)
        )
        let flat = [CGPoint(x: 0, y: 0), CGPoint(x: 1512, y: 0), CGPoint(x: 1512, y: 982), CGPoint(x: 0, y: 982)]
        for (corner, expected) in zip(corners, flat) {
            #expect(abs(corner.x - expected.x) < 1e-9 && abs(corner.y - expected.y) < 1e-9)
        }
    }

    @Test
    func testTheLeanEasesInAndIsTheLidsFromTheDurationOn() {
        var catchUp = LidLeanCatchUp()
        catchUp.begin(at: 10)
        let duration = LidLeanCatchUp.duration
        var last = 0.0
        for step in 1...20 {
            let share = catchUp.share(at: 10 + duration * Double(step) / 20)
            #expect(share >= last)
            last = share
        }
        #expect(abs(catchUp.share(at: 10 + duration / 2) - 0.5) < 1e-12)
        #expect(catchUp.share(at: 10 + duration) == 1)
        #expect(catchUp.share(at: 10 + duration * 3) == 1)
        // Flat and no faster than the lid where it starts, the lid's own lean
        // and no slower where it ends: nothing to see at either join.
        let early = catchUp.share(at: 10 + duration * 0.01)
        let late = 1 - catchUp.share(at: 10 + duration * 0.99)
        #expect(early < 0.001 && late < 0.001)
        // The picture ends up at the lid's angle.
        #expect(catchUp.pictureAngle(80, startAngle: 100, at: 10 + duration) == 80)
        #expect(abs(catchUp.pictureAngle(80, startAngle: 100, at: 10 + duration / 2) - 90) < 1e-9)
    }

    @Test
    func testResetForgetsTheHandover() {
        var catchUp = LidLeanCatchUp()
        catchUp.begin(at: 10)
        catchUp.reset()
        #expect(catchUp.share(at: 10) == 1)
    }
}

struct GlassHandoverTests {

    @Test
    func testTheGlassStaysUnderThePicturesFirstFrame() {
        var handover = GlassHandover()
        #expect(!handover.isComplete)
        // The window shows with its first frame still on its way.
        handover.drewFrame()
        #expect(!handover.isComplete)
        // A frame later the first is on screen, and the glass can go.
        handover.drewFrame()
        #expect(handover.isComplete)
    }
}
