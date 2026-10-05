import Foundation
import LidAngleKit
import Testing
@testable import MacDuo

/// A lid pressed shut sits a hair past closed, which the sensor reports as
/// just under 360. The readings here are the sensor's own values, a refresh
/// apart, as the log showed them for a fast close and a fast open.
struct LidShutTests {

    /// Closing past the start angle, snapping shut, resting there for half a
    /// second, then flung open past the start angle.
    private static let reported: [Double] = [
        110, 100, 88, 70, 40, 10, 1.5,
        359.1, 359.0, 359.02, 358.98, 359.0, 359.01,
        0.4, 13, 32, 60, 85, 110, 125, 125, 125,
    ]
    private static let refresh = 0.1043
    private static let policy = LidEffectPolicy(threshold: 84, hysteresis: 4)
    private static let ramp = LidEffectRamp(startAngle: 84, span: 64)

    private static func readings() throws -> [(time: Double, angle: Double)] {
        try reported.enumerated().map { index, value in
            (Double(index) * refresh, try #require(LidAngleSensor.hingeAngle(fromReported: value)))
        }
    }

    @Test
    func testAShutLidReadsJustBelowZero() throws {
        let shut = try #require(LidAngleSensor.hingeAngle(fromReported: 359.11))
        #expect(abs(shut - -0.89) < 1e-9)
        #expect(LidAngleSensor.hingeAngle(fromReported: 359) == -1)
        #expect(LidAngleSensor.hingeAngle(fromReported: 360) == 0)
        // Every angle a hinge can open to reads as it is.
        #expect(LidAngleSensor.hingeAngle(fromReported: 0.36) == 0.36)
        #expect(LidAngleSensor.hingeAngle(fromReported: 133.06) == 133.06)
        #expect(LidAngleSensor.hingeAngle(fromReported: 180) == 180)
        #expect(LidAngleSensor.hingeAngle(fromReported: 360.5) == nil)
        #expect(LidAngleSensor.hingeAngle(fromReported: -1) == nil)
    }

    enum Event: Equatable {
        case start, end, park, unpark
    }

    /// What `LidController` decides on each poll, with every reading found
    /// once: when a run starts and ends, when its picture comes down on a
    /// lid held shut and goes back up as it opens, and at what angle.
    private static func events(
        for readings: [(time: Double, angle: Double)]
    ) -> [(time: Double, angle: Double, event: Event)] {
        var motion = LidMotion()
        var estimator = LidAngleEstimator(tuning: .sensor(resolution: 0.01))
        var dwell = LidOpenDwell()
        var shut = LidShutHold()
        var isActive = false, isParked = false
        var peak = 0.0, lowest = 0.0, startedAt = 0.0
        var events: [(time: Double, angle: Double, event: Event)] = []
        for (now, angle) in readings {
            peak = max(peak, angle)
            if isActive { lowest = min(lowest, angle) }
            estimator.observe(angle, at: now)
            motion.update(with: angle, at: now, prewarmSpeed: 8)
            dwell.update(angle: angle, at: now, dwellAngle: policy.dwellAngle)
            shut.update(angle: angle, at: now)
            let approach = LidApproach(estimator) ?? LidApproach(angle: angle, speed: motion.velocity)
            let wanted = policy.wantsEffect(
                isEnabled: true,
                isActive: isActive,
                angle: angle,
                estimatedAngle: approach.angle,
                riseSinceLowest: angle - lowest,
                hasBeenAboveThreshold: peak >= policy.threshold,
                wasClosingRecently: approach.isClosing || motion.intent.wasClosingRecently(at: now, memoryDuration: 1.5),
                isClearlyOpening: isActive ? motion.isClearlyOpening : approach.isOpening,
                hasDwelledOpen: dwell.hasDwelled(at: now, duration: 1),
                minimumDurationElapsed: now - startedAt > 0.35
            )
            if wanted != isActive {
                isActive = wanted
                isParked = false
                events.append((now, angle, wanted ? .start : .end))
                if wanted {
                    peak = angle
                    lowest = angle
                    dwell.reset()
                    startedAt = now
                }
                continue
            }
            // As `reconcile` parks a run, and unparks it.
            if isActive, shut.hasHeld(at: now) != isParked {
                isParked.toggle()
                events.append((now, angle, isParked ? .park : .unpark))
            }
        }
        return events
    }

    @Test
    func testAFullCloseAndAFastOpenAreOneRun() throws {
        let events = Self.events(for: try Self.readings())
        // Started on the way down, held through the shut, and let go only
        // once the lid opened back past the start angle: no end as it shut,
        // and no second start part way up.
        #expect(events.map(\.event) == [.start, .end], "\(events)")
        #expect(events.last?.angle == 85)
    }

    @Test
    func testALidHeldShutParksTheRunAndTheOpeningStillPlays() throws {
        // Closed past the start angle and pressed shut for three seconds,
        // its reading creeping either side of zero, then opened.
        var reported: [Double] = [110, 100, 88, 70, 40, 10, 1.5]
        reported += (0..<30).map { [359.1, 359.0, 0.44, 0.12, 359.95][$0 % 5] }
        reported += [3, 10, 20, 35, 50, 65, 80, 95, 110, 125, 125]
        let readings = try reported.enumerated().map { index, value in
            (time: Double(index) * Self.refresh, angle: try #require(LidAngleSensor.hingeAngle(fromReported: value)))
        }
        let shutAt = readings[7].time
        let events = Self.events(for: readings)
        // One run: its picture down two seconds after the lid shut, back up
        // on the first reading of the opening, and let go only once the lid
        // is back past the start angle, as an opening after a short shut is.
        #expect(events.map(\.event) == [.start, .park, .unpark, .end], "\(events)")
        guard events.count == 4 else { return }
        #expect(events[1].time - shutAt >= LidShutHold.duration)
        #expect(events[1].time - shutAt < LidShutHold.duration + 1.5 * Self.refresh)
        #expect(events[2].angle == 3)
        #expect(events[3].angle >= Self.policy.threshold)
    }

    @Test
    func testAShutLidCountsFromWhenItShut() {
        var hold = LidShutHold()
        hold.update(angle: 30, at: 0)
        #expect(!hold.isShut)
        // Pressed shut, and resting there either side of zero.
        for (index, angle) in [-0.91, 0.44, -0.05, 0.12].enumerated() {
            hold.update(angle: angle, at: 1 + Double(index))
        }
        #expect(hold.isShut)
        #expect(hold.hasHeld(at: 1 + LidShutHold.duration))
        #expect(!hold.hasHeld(at: 1 + LidShutHold.duration - 0.01))
        // Opened past a degree, the count starts over.
        hold.update(angle: 1.5, at: 5)
        #expect(!hold.isShut && !hold.hasHeld(at: 10))
        hold.update(angle: 0.5, at: 6)
        #expect(!hold.hasHeld(at: 7.9))
        #expect(hold.hasHeld(at: 8))
    }

    @Test
    func testThePictureHoldsWhileShutAndOnlyLetsGoAsTheLidOpens() throws {
        let readings = try Self.readings()
        let shutAt = readings[7].time
        let openAt = readings[13].time
        var estimator = LidAngleEstimator(tuning: .sensor(resolution: 0.01))
        var next = 0
        var frames: [(time: Double, progress: Double)] = []
        var time = 0.0
        while time < readings.last!.time + 0.3 {
            // Each reading found by a poll a few milliseconds after it arrived.
            while next < readings.count, readings[next].time + 0.005 <= time {
                estimator.observe(readings[next].angle, at: readings[next].time + 0.005)
                next += 1
            }
            let target = time + 1.0 / 120
            if estimator.hasReading {
                frames.append((target, Self.ramp.progress(at: estimator.frame(at: target).angle)))
            }
            time += 1.0 / 120
        }
        // Full strength from just after the lid shuts until it opens.
        let shut = frames.filter { $0.time > shutAt + 0.25 && $0.time < openAt }
        #expect(!shut.isEmpty)
        #expect(shut.allSatisfy { $0.progress == 1 }, "\(shut.map(\.progress))")
        // From then on the effect only ever lets go, frame by frame, all the
        // way to none.
        let opening = frames.filter { $0.time >= openAt }
        for (earlier, later) in zip(opening, opening.dropFirst()) {
            #expect(later.progress <= earlier.progress + 1e-9, "at \(later.time)")
        }
        #expect(opening.last?.progress == 0)
    }

    /// What the sensor layer reads for a hinge at `angle`: the report counts
    /// round from zero, so a hinge below it comes in just under 360.
    private static func read(_ angle: Double, step: Double = 0.01) -> Double {
        let counted = (angle / step).rounded() * step
        return LidAngleSensor.hingeAngle(fromReported: counted < 0 ? counted + 360 : counted)!
    }

    /// A fast open from a lid pressed shut with polling asleep, as the
    /// controller sees it: the sensor refreshing every 104.3 ms, whole degree
    /// pushes every 100 ms, one of which wakes polling a millisecond later,
    /// polls at 60 a second and frames at 120 from then on, and the ease
    /// back to flat once the lid is clearly opened past the start angle.
    private struct Opening {
        var rest = -0.91
        var open = 130.0
        var begins = 0.5
        var duration = 0.6
        var pushPhase = 0.0
        var sensorPhase = 0.037
        /// Whether the ease back to flat keeps up with the lid.
        var followsTheLidOut = true

        static let threshold = 84.0

        /// A hand swinging the lid open, as people move.
        func hinge(at time: Double) -> Double {
            let s = min(max((time - begins) / duration, 0), 1)
            return rest + (open - rest) * s * s * s * (10 - 15 * s + 6 * s * s)
        }

        /// When the lid itself passes `angle`.
        func crossing(_ angle: Double) -> Double {
            var low = begins, high = begins + duration
            for _ in 0..<60 {
                let middle = (low + high) / 2
                if hinge(at: middle) < angle { low = middle } else { high = middle }
            }
            return high
        }

        struct Result {
            var wakeTime = 0.0
            var firstFrameTime = 0.0
            /// Lid minus picture at each frame while the picture follows it.
            var lag: [(time: Double, degrees: Double)] = []
            var progress: [(time: Double, value: Double)] = []
            var flatTime = 0.0
        }

        func run() -> Result {
            let ramp = LidEffectRamp(startAngle: Self.threshold, span: 60)
            let policy = LidEffectPolicy(threshold: Self.threshold, hysteresis: 4)
            // The sensor's reading at `time`: the latest sample it took.
            func reading(at time: Double) -> Double {
                let taken = ((time - sensorPhase) / LidShutTests.refresh).rounded(.down) * LidShutTests.refresh + sensorPhase
                return LidShutTests.read(hinge(at: taken))
            }
            var estimator = LidAngleEstimator(tuning: .sensor(resolution: 0.01))
            var filter = PushWakeFilter()
            var motion = LidMotion()
            var spring = CriticallyDampedSpring(frequency: 24)
            var result = Result()

            // The run so far: the lid was closed and pressed shut, the picture
            // settled on it at full effect, and polling went to sleep.
            for time in stride(from: 0, through: 0.3, by: LidShutTests.refresh) {
                estimator.observe(reading(at: time), at: time)
                motion.update(with: reading(at: time), at: time, prewarmSpeed: 8)
            }
            _ = estimator.frame(at: 0.3)
            filter.sleep(at: reading(at: 0.3))
            var lowest = rest
            var isActive = true
            var isClosingOut = false
            var isAwake = false
            var shown = LidAngleEstimator.Motion(angle: rest, speed: 0, acceleration: 0)

            var nextPush = (0.3 / 0.1).rounded(.up) * 0.1 + pushPhase
            var nextPoll = Double.infinity
            var nextFrame = Double.infinity
            let end = begins + duration + 0.5

            func poll(at now: Double) {
                let angle = reading(at: now)
                estimator.observe(angle, at: now)
                motion.update(with: angle, at: now, prewarmSpeed: 8)
                lowest = min(lowest, angle)
                let wanted = policy.wantsEffect(
                    isEnabled: true, isActive: isActive, angle: angle,
                    estimatedAngle: angle,
                    riseSinceLowest: angle - lowest, hasBeenAboveThreshold: true,
                    wasClosingRecently: false, isClearlyOpening: motion.isClearlyOpening,
                    hasDwelledOpen: false, minimumDurationElapsed: true
                )
                if isActive, !wanted {
                    isActive = false
                    isClosingOut = true
                    spring.value = shown.angle
                    spring.velocity = shown.speed
                }
            }

            while true {
                let now = min(nextPush, nextPoll, nextFrame)
                guard now < end else { break }
                if now == nextPush {
                    nextPush += 0.1
                    // The sensor's latest sample, in whole degrees.
                    let pushed = LidShutTests.read(reading(at: now), step: 1)
                    guard !isAwake, let speed = filter.receive(pushed, at: now) else { continue }
                    // The main queue hop, then the wake acts on this reading.
                    let woke = now + 0.001
                    isAwake = true
                    result.wakeTime = woke
                    motion.wake(speed: speed, at: woke, prewarmSpeed: 8)
                    estimator.resume(speed: speed, variance: speed == 0 ? nil : 100, at: woke)
                    poll(at: woke)
                    nextPoll = woke + 1.0 / 60
                    // The display link's first frame is the next refresh.
                    nextFrame = (woke * 120).rounded(.up) / 120
                    result.firstFrameTime = nextFrame
                } else if now == nextPoll {
                    nextPoll += 1.0 / 60
                    poll(at: now)
                } else {
                    nextFrame += 1.0 / 120
                    let target = now + 1.0 / 120
                    if !isClosingOut {
                        shown = estimator.frame(at: target)
                        result.lag.append((target, hinge(at: target) - shown.angle))
                        result.progress.append((target, ramp.progress(at: shown.angle)))
                        continue
                    }
                    // As `LidController.step` eases the picture back to flat.
                    if followsTheLidOut {
                        let lid = estimator.motion(at: target)
                        spring.advance(to: Self.threshold, dt: 1.0 / 120, floor: lid.angle, floorSpeed: lid.speed)
                    } else {
                        spring.advance(to: Self.threshold, dt: 1.0 / 120)
                    }
                    result.progress.append((target, ramp.progress(at: spring.value)))
                    if spring.value >= Self.threshold - 0.05 {
                        result.flatTime = target
                        break
                    }
                }
            }
            return result
        }
    }

    @Test(arguments: [0.0, 0.025, 0.05, 0.075])
    func testAFastOpenFromShutIsFollowedOutWithoutABlurComingBack(pushPhase: Double) {
        let opening = Opening(pushPhase: pushPhase)
        let result = opening.run()
        let eased = Opening(pushPhase: pushPhase, followsTheLidOut: false).run()
        // Woken by the first whole degree push after the lid leaves rest: the
        // hand's first degree and a half, a sensor refresh and a push interval
        // at the worst.
        #expect(result.wakeTime - opening.begins < 0.27, "woke after \((result.wakeTime - opening.begins) * 1000) ms")
        #expect(result.firstFrameTime - result.wakeTime < 0.01)
        // The picture starts at full effect, behind the lid, and only ever
        // catches up: never ahead of it by more than a reading's age.
        #expect(result.progress.first?.value == 1, "first frame at \(result.progress.first?.value ?? -1)")
        #expect(result.lag.allSatisfy { $0.degrees > -15 }, "ran ahead by \(-(result.lag.map(\.degrees).min() ?? 0))°")
        // The effect only ever lifts as the lid opens.
        for (earlier, later) in zip(result.progress, result.progress.dropFirst()) {
            #expect(later.value <= earlier.value + 1e-9, "blur came back in at \(later.time) s")
        }
        // Flat no later than the ease alone gets there, and soon after the
        // lid itself passed the start angle.
        let lidPastThreshold = opening.crossing(Opening.threshold)
        #expect(result.flatTime <= eased.flatTime + 1e-9)
        #expect(result.flatTime - lidPastThreshold < 0.15, "flat \((result.flatTime - lidPastThreshold) * 1000) ms after the lid")
    }

    @Test
    func testAShutLidSleepsThroughItsFlickerAndWakesOpening() throws {
        var filter = PushWakeFilter()
        filter.sleep(at: try #require(LidAngleSensor.hingeAngle(fromReported: 359.02)))
        // Whole degree pushes of a lid resting on the line between two.
        for (index, value) in [359.0, 0, 359, 0, 359].enumerated() {
            let pushed = try #require(LidAngleSensor.hingeAngle(fromReported: value))
            #expect(filter.receive(pushed, at: Double(index) * 0.1) == nil)
        }
        // Flung open.
        let woken = filter.receive(try #require(LidAngleSensor.hingeAngle(fromReported: 6)), at: 0.5)
        let speed = try #require(woken)
        #expect(speed > 0, "woke at \(speed) degrees a second")
    }
}
