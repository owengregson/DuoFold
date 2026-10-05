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
        // Counting a shut lid to the end of its run.
        #expect(needs(isActive: true, isShut: true))
        #expect(!needs(isActive: false, isShut: true))
    }

    @Test
    func testListensForMacOSReportingTheLidOpen() {
        // Registering only listens: nothing on screen or in power changes.
        #expect(LidClamshellWatch { _ in }.start())
    }

    @Test
    func testAShutLidWithNoRunWaitsForItToOpen() {
        // The flicker of a shut lid is no reason to poll.
        #expect(!needs(isShut: true, sinceMovement: 0.1))
        #expect(!needs(isPrewarming: true, isShut: true))
        // The settings panel still shows the live angle.
        #expect(needs(isPanelOpen: true, isShut: true))
    }

    @Test
    func testACaptureWarmedUpForACloseKeepsPolling() {
        // The lid stopped short of the start angle within the pre-warm's
        // linger. Only a poll can end the capture, so polling carries on
        // even though the lid is still and the effect is not showing.
        #expect(needs(isPrewarming: true, capturesScreen: true))
        #expect(!needs(isPrewarming: false, capturesScreen: true))
    }

    @Test
    func testDwellFitsInsideTheSettle() {
        // A slow opening must still be polled long enough to release.
        #expect(LidWakePolicy.settleDuration > 1)
    }

    @Test
    func testPushesAtTheSensorsRefreshWhileTheEffectIsOn() {
        #expect(policy.pushInterval(isEnabled: true) == LidWakePolicy.enabledPushInterval)
        #expect(policy.pushInterval(isEnabled: false) == LidWakePolicy.disabledPushInterval)
        // The sensor refreshes about every 100 ms; asking faster gains nothing.
        #expect(LidWakePolicy.enabledPushInterval == 0.1)
        #expect(LidWakePolicy.enabledPushInterval < LidWakePolicy.disabledPushInterval)
    }

    private func needs(
        isPreviewing: Bool = false,
        isClosingOut: Bool = false,
        isPanelOpen: Bool = false,
        isCapturePending: Bool = false,
        isPrewarming: Bool = false,
        isActive: Bool = false,
        capturesScreen: Bool = false,
        isTimeoutEnabled: Bool = false,
        isShut: Bool = false,
        isPictureSettled: Bool = true,
        sinceMovement: Double = 10
    ) -> Bool {
        policy.needsFreshAngles(
            isPreviewing: isPreviewing,
            isClosingOut: isClosingOut,
            isPanelOpen: isPanelOpen,
            isCapturePending: isCapturePending,
            isPrewarming: isPrewarming,
            isActive: isActive,
            capturesScreen: capturesScreen,
            isTimeoutEnabled: isTimeoutEnabled,
            isShut: isShut,
            isPictureSettled: isPictureSettled,
            sinceMovement: sinceMovement
        )
    }
}
