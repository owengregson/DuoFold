import Testing
@testable import MacDuo

struct LidWakeTests {

    private let policy = LidWakePolicy()

    @Test
    func testAwakeFilterNeverWakes() {
        var filter = PushWakeFilter()
        #expect(filter.receive(100, at: 0) == nil)
        #expect(filter.receive(90, at: 0.1) == nil)
    }

    @Test
    func testFlickerAroundTheRestingAngleStaysAsleep() {
        var filter = PushWakeFilter()
        filter.sleep(at: 109.43)
        // Whole degree readings of a lid resting between two of them.
        for (index, degrees) in [109.0, 110, 109, 110, 109].enumerated() {
            #expect(filter.receive(degrees, at: Double(index) * 0.1) == nil)
        }
        #expect(filter.restingAngle == 109.43)
    }

    @Test
    func testMovingPastTheMarginWakesOnceWithThePushedSpeed() throws {
        var filter = PushWakeFilter()
        filter.sleep(at: 109.43)
        #expect(filter.receive(109, at: 0) == nil)
        #expect(filter.receive(108, at: 0.1) == nil)
        let woken = filter.receive(107, at: 0.2)
        let speed = try #require(woken)
        #expect(abs(speed - -10) < 1e-9)
        // Awake again until the controller sleeps once more.
        #expect(filter.receive(105, at: 0.3) == nil)
        #expect(filter.restingAngle == nil)
    }

    @Test
    func testAStalePreviousPushMeasuresNoSpeed() {
        var filter = PushWakeFilter()
        _ = filter.receive(109, at: 0)
        filter.sleep(at: 109.2)
        // The next reading lands long after the last.
        #expect(filter.receive(100, at: 2) == 0)
    }

    @Test
    func testAStillLidWithNothingToShowNeedsNoAngles() {
        #expect(!needs())
        #expect(!needs(isActive: true))
    }

    @Test
    func testRecentMovementKeepsPolling() {
        #expect(needs(sinceMovement: 0.2))
        #expect(needs(sinceMovement: LidWakePolicy.settleDuration - 0.01))
        #expect(!needs(sinceMovement: LidWakePolicy.settleDuration))
    }

    @Test
    func testWhatKeepsPollingWhileTheLidIsStill() {
        #expect(needs(isPreviewing: true))
        #expect(needs(isClosingOut: true))
        #expect(needs(isPanelOpen: true))
        #expect(needs(isCapturePending: true))
        // Only while the effect shows.
        #expect(needs(isActive: true, capturesScreen: true))
        #expect(!needs(isActive: false, capturesScreen: true))
        #expect(needs(isActive: true, isTimeoutEnabled: true))
        #expect(needs(isActive: true, isPictureSettled: false))
    }

    @Test
    func testDwellFitsInsideTheSettle() {
        // A slow opening must still be polled long enough to release.
        #expect(LidWakePolicy.settleDuration > 1)
    }

    @Test
    func testPushesFasterNearTheStartAngle() {
        #expect(policy.pushInterval(angle: 95, threshold: 90, isEnabled: true) == LidWakePolicy.nearPushInterval)
        #expect(policy.pushInterval(angle: 125, threshold: 90, isEnabled: true) == LidWakePolicy.farPushInterval)
        #expect(policy.pushInterval(angle: 95, threshold: 90, isEnabled: false) == LidWakePolicy.farPushInterval)
        #expect(LidWakePolicy.nearPushInterval < LidWakePolicy.farPushInterval)
    }

    private func needs(
        isPreviewing: Bool = false,
        isClosingOut: Bool = false,
        isPanelOpen: Bool = false,
        isCapturePending: Bool = false,
        isActive: Bool = false,
        capturesScreen: Bool = false,
        isTimeoutEnabled: Bool = false,
        isPictureSettled: Bool = true,
        sinceMovement: Double = 10
    ) -> Bool {
        policy.needsFreshAngles(
            isPreviewing: isPreviewing,
            isClosingOut: isClosingOut,
            isPanelOpen: isPanelOpen,
            isCapturePending: isCapturePending,
            isActive: isActive,
            capturesScreen: capturesScreen,
            isTimeoutEnabled: isTimeoutEnabled,
            isPictureSettled: isPictureSettled,
            sinceMovement: sinceMovement
        )
    }
}
