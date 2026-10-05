import Foundation
import Testing
@testable import MacDuo

struct LidHingeLimitTests {
    @Test
    func testHeldReadingSetsTheLimit() {
        var hinge = LidHingeLimit()
        let early = [10, 10.5].map { hinge.observe(131, at: $0) }
        #expect(early == [false, false])
        #expect(hinge.angle == nil)

        let held = hinge.observe(131, at: 11)
        #expect(held)
        #expect(hinge.angle == 131)
    }

    @Test
    func testOneStrayReadingDoesNotRaiseTheLimit() {
        var hinge = hold(120, from: 0)
        hinge.observe(175, at: 2)
        hinge.observe(120, at: 2.1)
        hinge.observe(120, at: 4)
        #expect(hinge.angle == 120)
    }

    @Test
    func testBriefExcursionDoesNotRaiseTheLimit() {
        var hinge = hold(120, from: 0)
        for step in 0..<5 {
            hinge.observe(175, at: 2 + Double(step) * 0.1)
        }
        hinge.observe(120, at: 2.5)
        #expect(hinge.angle == 120)
    }

    @Test
    func testLowerHoldNeverShrinksTheLimit() {
        var hinge = hold(132, from: 0)
        let raised = (0...50).map { hinge.observe(100, at: 2 + Double($0) * 0.1) }
        #expect(!raised.contains(true))
        #expect(hinge.angle == 132)
    }

    @Test
    func testRestingBetweenTwoReadingsCountsAsTheLowerOne() {
        // A whole-degree sensor on a half-degree boundary.
        var hinge = LidHingeLimit()
        for step in 0...12 {
            hinge.observe(step.isMultiple(of: 2) ? 132 : 131, at: Double(step) * 0.1)
        }
        #expect(hinge.angle == 131)
    }

    @Test
    func testMovingLidHasNotBeenHeld() {
        var hinge = LidHingeLimit()
        for step in 0...30 {
            hinge.observe(100 + Double(step), at: Double(step) * 0.1)
        }
        #expect(hinge.angle == nil)
    }

    @Test
    func testImplausibleAnglesAreIgnored() {
        let hinge = hold(200, from: 0)
        #expect(hinge.angle == nil)

        #expect(LidHingeLimit(angle: 250).angle == nil)
        #expect(LidHingeLimit(angle: -1).angle == nil)
        #expect(LidHingeLimit(angle: 131).angle == 131)
    }

    @Test
    func testInterruptDropsTheHoldInProgress() {
        var hinge = LidHingeLimit()
        hinge.observe(130, at: 0)
        hinge.interrupt()
        // A reading after sleep starts a new hold rather than finishing one.
        hinge.observe(130, at: 5)
        #expect(hinge.angle == nil)
        hinge.observe(130, at: 6)
        #expect(hinge.angle == 130)
    }

    @Test
    func testHingeLimitLowersAThresholdItCannotRelease() {
        // The two hinges reported in the lockout issues.
        #expect(LidEffectPolicy(threshold: 130, hysteresis: 4, hingeLimit: 132).threshold == 128)
        #expect(LidEffectPolicy(threshold: 130, hysteresis: 4, hingeLimit: 133).threshold == 129)
    }

    @Test
    func testSettingStandsWithRoomToRelease() {
        #expect(LidEffectPolicy(threshold: 90, hysteresis: 4, hingeLimit: 132).threshold == 90)
        #expect(LidEffectPolicy(threshold: 128, hysteresis: 4, hingeLimit: 132).threshold == 128)
    }

    @Test
    func testSettingStandsBeforeTheLimitIsKnown() {
        #expect(LidEffectPolicy(threshold: 130, hysteresis: 4, hingeLimit: nil).threshold == 130)
    }

    /// The lockout fix in one property: whatever the setting, a lid held at
    /// its limit releases through the ordinary rule alone, with no opening
    /// speed and no dwell to help.
    @Test(arguments: [100.0, 118, 125, 128, 131, 132, 133, 135])
    func testLidHeldAtTheHingeLimitAlwaysReleases(limit: Double) {
        for configured in stride(from: 5.0, through: 130, by: 0.5) {
            let policy = LidEffectPolicy(threshold: configured, hysteresis: 4, hingeLimit: limit)
            let wanted = policy.wantsEffect(
                isEnabled: true,
                isActive: true,
                angle: limit,
                estimatedAngle: limit,
                riseSinceLowest: 0,
                hasBeenAboveThreshold: true,
                wasClosingRecently: false,
                isClearlyOpening: false,
                hasDwelledOpen: false,
                minimumDurationElapsed: true
            )
            #expect(!wanted, "start angle \(configured) holds at a \(limit)° hinge")
            // The opening and dwell rules keep the whole hysteresis as margin.
            #expect(policy.dwellAngle <= limit - 4)
        }
    }

    /// A limit learned from `angle` held for longer than a hold needs.
    private func hold(_ angle: Double, from start: TimeInterval) -> LidHingeLimit {
        var hinge = LidHingeLimit()
        for step in 0...12 {
            hinge.observe(angle, at: start + Double(step) * 0.1)
        }
        return hinge
    }
}
