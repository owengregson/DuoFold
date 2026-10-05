import Foundation
import Testing
@testable import DuoFold

struct LidAngleEstimatorTests {

    /// The sensor as measured: a reading every 104.3 ms of the lid where it
    /// was then, scattered and rounded, found by a poll, and a frame at 120
    /// a second asking where the lid is as it reaches the screen.
    private struct Run {
        var angle: (Double) -> Double
        var duration: Double
        var phase: Double = 0.037
        var refresh: Double = 0.1043
        var pollInterval: Double = 1.0 / 30
        var noise: Double = 0.03
        var resolution: Double = 0.01
        var seed: UInt64 = 1
        /// No more polls after this, as if the sensor stopped answering.
        var pollsUntil: Double = .infinity

        struct Frame {
            var time: Double
            var shown: Double
            var speed: Double
            var truth: Double
        }

        func frames(with tuning: LidAngleEstimator.Tuning) -> (frames: [Frame], estimator: LidAngleEstimator) {
            var estimator = LidAngleEstimator(tuning: tuning)
            var random = seed
            func gaussian() -> Double {
                func next() -> Double {
                    random = random &* 6364136223846793005 &+ 1442695040888963407
                    return Double(random >> 11) / Double(1 << 53)
                }
                return (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * .pi * next())
            }
            var readings: [(time: Double, value: Double)] = []
            var sample = phase - refresh
            while sample < duration + 1 {
                let value = angle(max(sample, 0)) + noise * gaussian()
                readings.append((sample, resolution > 0 ? (value / resolution).rounded() * resolution : value))
                sample += refresh
            }
            func latest(at time: Double) -> Double {
                readings.last { $0.time <= time }?.value ?? readings[0].value
            }
            var frames: [Frame] = []
            var poll = 0.0
            var time = 0.0
            while time < duration {
                while poll <= time {
                    if poll < pollsUntil { estimator.observe(latest(at: poll), at: poll) }
                    poll += pollInterval
                }
                let target = time + 1.0 / 120
                if estimator.hasReading {
                    let shown = estimator.frame(at: target)
                    frames.append(Frame(time: target, shown: shown.angle, speed: shown.speed, truth: angle(target)))
                }
                time += 1.0 / 120
            }
            return (frames, estimator)
        }
    }

    private static let sensor = LidAngleEstimator.Tuning.sensor(resolution: 0.01)

    /// A hand easing the lid from one angle to another, as people move.
    private static func ease(from start: Double, to end: Double, at begin: Double, over duration: Double) -> (Double) -> Double {
        { time in
            let s = min(max((time - begin) / duration, 0), 1)
            return start + (end - start) * s * s * s * (10 - 15 * s + 6 * s * s)
        }
    }

    /// How far past `rest` the picture went, in the direction it travelled,
    /// and how many times after `stop` it crossed back over by more than a
    /// quarter of a degree: a lid easing in still moves by a tenth or so.
    private static func overshoot(_ frames: [Run.Frame], rest: Double, closing: Bool, after stop: Double) -> (distance: Double, crossings: Int) {
        let sign = closing ? -1.0 : 1.0
        let after = frames.filter { $0.time >= stop - 0.2 }
        let distance = after.map { ($0.shown - rest) * sign }.max() ?? 0
        var crossings = 0
        var side = 0.0
        for frame in after where abs(frame.shown - rest) > 0.25 {
            let current = frame.shown > rest ? 1.0 : -1.0
            if side != 0, current != side { crossings += 1 }
            side = current
        }
        return (distance, crossings)
    }

    @Test(arguments: [0.0, 0.026, 0.052, 0.078])
    func testAHandSlowingToAStopIsNotRunPast(phase: Double) {
        // Polled as often as the controller polls a moving lid under a
        // picture.
        let run = Run(angle: Self.ease(from: 110, to: 45, at: 0.3, over: 0.8), duration: 2, phase: phase, pollInterval: 1.0 / 60)
        let frames = run.frames(with: Self.sensor).frames
        let result = Self.overshoot(frames, rest: 45, closing: true, after: 1.1)
        #expect(result.distance < 2.5, "ran \(result.distance) degrees past")
        // It arrives from above and stays there, or dips once and comes back.
        #expect(result.crossings <= 1)
        let settled = frames.filter { $0.time > 1.6 }
        #expect(settled.allSatisfy { abs($0.shown - 45) < 0.2 })
    }

    @Test(arguments: [0.0, 0.026, 0.052, 0.078])
    func testADeadStopSettlesWithoutRinging(phase: Double) {
        // 60 degrees a second, then nothing: the stop is only seen a refresh
        // later, so the picture runs on by about that much, and comes back
        // once.
        let run = Run(angle: { max(100 - 60 * max($0 - 0.3, 0), 60) }, duration: 2, phase: phase)
        let frames = run.frames(with: Self.sensor).frames
        let stop = 0.3 + 40.0 / 60
        let result = Self.overshoot(frames, rest: 60, closing: true, after: stop)
        #expect(result.distance < 10, "ran \(result.distance) degrees past")
        #expect(result.crossings <= 1)
        let settled = frames.filter { $0.time > stop + 0.6 }
        #expect(settled.allSatisfy { abs($0.shown - 60) < 0.2 })
        // The return is critically damped: once back at rest it stays.
        let tail = frames.filter { $0.time > stop + 0.3 }
        for (earlier, later) in zip(tail, tail.dropFirst()) {
            #expect(abs(later.shown - 60) <= abs(earlier.shown - 60) + 0.02)
        }
    }

    @Test
    func testASteadyCloseIsFollowedSmoothlyAndCloseBehind() {
        let speed = -100.0
        let run = Run(angle: { 110 + speed * max($0 - 0.2, 0) }, duration: 1.2)
        let frames = run.frames(with: Self.sensor).frames.filter { $0.time > 0.6 }
        // Behind by the trail and no more, on average.
        let lag = frames.map { ($0.shown - $0.truth) / -speed }.reduce(0, +) / Double(frames.count)
        #expect(abs(lag - Self.sensor.trail) < 0.012, "lags by \(lag * 1000) ms")
        // And smoothly: the speed stays near the lid's from frame to frame.
        #expect(frames.allSatisfy { abs($0.speed - speed) < 25 })
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            #expect(later.shown < earlier.shown)
        }
    }

    @Test
    func testAStepIsTakenWithoutRinging() {
        // Ten degrees within one refresh reads as a lid moving at 96 degrees
        // a second until the next reading shows it still, so the picture
        // runs on about as far as a dead stop at that speed would take it.
        let run = Run(angle: { $0 < 0.5 ? 90 : 80 }, duration: 1.6)
        let frames = run.frames(with: Self.sensor).frames
        let result = Self.overshoot(frames, rest: 80, closing: true, after: 0.5)
        #expect(result.crossings <= 1)
        #expect(result.distance < 12.5)
        #expect(frames.filter { $0.time > 1.1 }.allSatisfy { abs($0.shown - 80) < 0.2 })
    }

    @Test(arguments: [UInt64(1), 2, 3])
    func testAStillLidsFlickeringReadingsHoldThePictureStill(seed: UInt64) {
        let run = Run(angle: { _ in 72.34 }, duration: 4, seed: seed)
        let frames = run.frames(with: Self.sensor).frames
        let changes = zip(frames, frames.dropFirst()).filter { $0.shown != $1.shown }.count
        // A picture that holds still is not redrawn, bar a rare re-settle.
        #expect(changes < frames.count / 10, "\(changes) of \(frames.count) frames moved")
        #expect(frames.allSatisfy { abs($0.shown - 72.34) < 0.15 })
    }

    @Test
    func testWholeDegreeReadingsOfAStillLidDoNotJitter() {
        // A lid resting between two whole degrees reads one, then the other.
        let run = Run(angle: { _ in 109.5 }, duration: 4, noise: 0.2, resolution: 1)
        let frames = run.frames(with: .sensor(resolution: 1)).frames.filter { $0.time > 0.5 }
        let changes = zip(frames, frames.dropFirst()).filter { $0.shown != $1.shown }.count
        #expect(changes < frames.count / 20, "\(changes) of \(frames.count) frames moved")
        #expect(frames.allSatisfy { abs($0.shown - 109.5) < 1.2 })
    }

    @Test
    func testWholeDegreeReadingsOfASlowCloseAreFollowedSmoothly() {
        let run = Run(angle: { 100 - 10 * $0 }, duration: 3, noise: 0.05, resolution: 1)
        let frames = run.frames(with: .sensor(resolution: 1)).frames.filter { $0.time > 0.5 }
        // Never backwards by more than a hair, and never far off: about a
        // step, since 10 degrees a second is one step a refresh.
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            #expect(later.shown <= earlier.shown + 0.05)
        }
        #expect(frames.allSatisfy { abs($0.shown - $0.truth) < 2.5 })
    }

    @Test
    func testReadingsThatStopComingLevelOff() {
        // The lid closes at 100 degrees a second and the polls stop.
        let run = Run(angle: { 110 - 100 * $0 }, duration: 2.5, pollsUntil: 0.6)
        let (frames, estimator) = run.frames(with: Self.sensor)
        let lastReading = run.angle(0.6)
        let reach = frames.map(\.shown).min() ?? 0
        let limit = Self.sensor.horizon + Self.sensor.horizonFade
        #expect(lastReading - reach < 100 * limit + 2)
        // Long after, it rests: no drift.
        #expect(abs(estimator.speed(at: 3)) < 1e-6)
        #expect(abs((estimator.angle(at: 3) ?? 0) - (estimator.angle(at: 10) ?? 1)) < 1e-6)
    }

    @Test
    func testResetForgetsAndStartsAtTheNextReading() {
        var estimator = LidAngleEstimator(tuning: Self.sensor)
        for index in 0..<20 {
            estimator.observe(110 - Double(index) * 10, at: Double(index) * 0.1043)
        }
        #expect(estimator.isMoving)
        estimator.reset()
        #expect(estimator.angle(at: 3) == nil)
        #expect(!estimator.isMoving)
        estimator.observe(42, at: 3)
        #expect(estimator.angle(at: 3) == 42)
        #expect(estimator.angle(at: 3.5) == 42)
        #expect(estimator.isSettled(at: 3.5))
    }

    @Test
    func testResumeCarriesOnFromWhereThePictureRests() throws {
        var estimator = LidAngleEstimator(tuning: Self.sensor)
        for index in 0..<10 {
            estimator.observe(80 + (index.isMultiple(of: 2) ? 0.01 : -0.01), at: Double(index) * 0.1043)
        }
        let resting = try #require(estimator.angle(at: 1.2))
        #expect(estimator.isSettled(at: 1.2))
        // A push wakes the controller: the lid is closing at 40 a second.
        estimator.resume(speed: -40, variance: 100, at: 20)
        #expect(estimator.angle(at: 20) == resting)
        #expect(abs(estimator.speed(at: 20)) < 1e-9)
        estimator.observe(78, at: 20.001)
        let moved = try #require(estimator.angle(at: 20.15))
        #expect(moved < resting)
        #expect(estimator.speed(at: 20.15) < 0)
    }

    @Test
    func testRepeatedAndBrokenReadingsAddNothing() throws {
        var estimator = LidAngleEstimator(tuning: Self.sensor)
        estimator.observe(90, at: 0)
        estimator.observe(90.02, at: 0.1043)
        let before = try #require(estimator.angle(at: 0.2))
        // The same reading found again within a refresh, and nonsense.
        estimator.observe(90.02, at: 0.12)
        estimator.observe(.nan, at: 0.13)
        estimator.observe(90.02, at: .infinity)
        #expect(estimator.angle(at: 0.2) == before)
    }

    @Test(arguments: [(109.0, 5.0), (130.0, 40.0)])
    func testThePreviewSweepIsFollowedWithoutRunningPastItsCorners(open: Double, shut: Double) {
        func sweep(_ time: Double) -> Double {
            if time < 1.4 { return open + (shut - open) * time / 1.4 }
            if time < 2.2 { return shut }
            if time < 2.8 { return shut + (open - shut) * (time - 2.2) / 0.6 }
            return open
        }
        let poll = 1.0 / 30
        let run = Run(angle: sweep, duration: 3.2, phase: 0, refresh: 1e-4, pollInterval: poll, noise: 0, resolution: 0)
        let frames = run.frames(with: .script(pollInterval: poll)).frames
        #expect(frames.allSatisfy { $0.shown >= shut - 0.01 && $0.shown <= open + 0.01 })
        // One poll behind the script while it moves.
        let closing = frames.filter { $0.time > 0.2 && $0.time < 1.3 }
        let lag = closing.map { ($0.shown - $0.truth) / ((open - shut) / 1.4) }.reduce(0, +) / Double(closing.count)
        #expect(abs(lag - poll) < 0.01)
        #expect(abs(frames.last!.shown - open) < 0.05)
    }

    @Test
    func testTheRefreshClockFindsWhenReadingsArrived() {
        // A sensor on a 104.4 ms clock with half a millisecond of jitter,
        // polled 30 times a second by a timer that runs a little late.
        var clock = RefreshClock()
        var random: UInt64 = 7
        func uniform() -> Double {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Double(random >> 11) / Double(1 << 53)
        }
        let period = 0.1044
        let arrivals = (0..<60).map { 0.013 + Double($0) * period + (uniform() - 0.5) * 0.001 }
        var polls: [Double] = []
        var time = 0.0
        while time < 6.3 {
            polls.append(time)
            time += 1.0 / 30 + uniform() * 0.002
        }
        var errors: [Double] = []
        var spreads: [Double] = []
        for arrival in arrivals.dropLast() {
            guard let found = polls.firstIndex(where: { $0 >= arrival }), found > 0 else { continue }
            let placed = clock.place(polls[found - 1]...polls[found], period: 0.1043, jitter: 0.001)
            // Wherever it is placed, the reading really did arrive in range.
            #expect(abs(placed.time - arrival) <= placed.spread / 2 + 1e-9)
            errors.append(abs(placed.time - arrival))
            spreads.append(placed.spread)
        }
        // Once the polls have drifted across the sensor's clock a few times,
        // readings are placed to within a few milliseconds, against a window
        // of a whole poll interval.
        let settled = errors.suffix(20)
        #expect(settled.reduce(0, +) / Double(settled.count) < 0.003)
        #expect(spreads.suffix(20).allSatisfy { $0 < 0.0334 })
    }
}
