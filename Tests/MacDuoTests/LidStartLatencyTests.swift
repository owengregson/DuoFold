import Foundation
import Testing
@testable import MacDuo

/// How soon a run shows after the lid passes the start angle, as
/// `LidController` drives it: the sensor taking a reading every 104.3 ms,
/// whole degree pushes every 100 ms while polling sleeps, one of which wakes
/// it a millisecond later, polls at 30 a second from then on, and frames at
/// 120 a second once a run starts.
struct LidStartLatencyTests {

    static let threshold = 100.0
    static let refresh = 0.1043

    /// A hand on the lid: its speed eases from one value to the next over
    /// each segment, as people move, and holds after the last.
    struct Hand {
        private var table: [Double] = []
        static let step = 2e-4

        init(start: Double, segments: [(duration: Double, speed: Double)], until end: Double = 3) {
            func speed(at time: Double) -> Double {
                var from = 0.0, begin = 0.0
                for segment in segments {
                    if time < begin + segment.duration {
                        let s = (time - begin) / segment.duration
                        return from + (segment.speed - from) * s * s * (3 - 2 * s)
                    }
                    begin += segment.duration
                    from = segment.speed
                }
                return from
            }
            var angle = start
            var time = 0.0
            table = [angle]
            while time < end {
                angle += (speed(at: time) + speed(at: time + Self.step)) / 2 * Self.step
                time += Self.step
                table.append(angle)
            }
        }

        func angle(at time: Double) -> Double {
            table[min(max(Int((time / Self.step).rounded()), 0), table.count - 1)]
        }

        /// When the lid first passes down through `angle` after `after`.
        func crossing(below angle: Double, after: Double) -> Double? {
            var index = Int((after / Self.step).rounded())
            while index < table.count {
                if table[index] <= angle { return Double(index) * Self.step }
                index += 1
            }
            return nil
        }

        /// Resting `above` the start angle, then closed at `speed`.
        static func fromRest(above: Double, speed: Double) -> Hand {
            Hand(start: threshold + above + 0.2, segments: [(1, 0), (0.1, -speed)])
        }

        /// Under a run at 80°, flung open to 106° at 130 degrees a second,
        /// turned round within 100 ms and closed again at `speed`.
        static func reversal(speed: Double) -> Hand {
            Hand(start: 80, segments: [(1, 0), (0.1, 130), (0.125, 130), (0.05, 0), (0.05, -speed)])
        }

        /// Resting at `from`, closed at `speed`, or as fast as so short a
        /// close allows, and brought to a stop `short` of the start angle.
        static func stopsShort(from: Double, short: Double, speed: Double) -> Hand {
            let travel = from - threshold - short
            let speed = min(speed, travel / 0.1)
            return Hand(start: from, segments: [(1, 0), (0.1, -speed), (max(travel / speed - 0.1, 0), -speed), (0.1, 0)])
        }
    }

    enum Beginning {
        /// At rest with polling asleep.
        case asleep
        /// At rest, polled.
        case awake
        /// Under a run.
        case running
    }

    struct Result {
        /// When the lid passed down through the start angle.
        var crossing: Double?
        /// When the first reading past it was taken.
        var firstReadingPast: Double?
        var started: Double?
        /// When the reading the start went on was taken.
        var startReading: Double?
        /// When the run's first frame showed, and its first with any effect.
        var firstFrame: Double?
        var firstEffect: Double?

        var latency: Double? {
            guard let crossing, let firstEffect else { return nil }
            return firstEffect - crossing
        }
    }

    /// The controller's pushes, polls and frames, step by step.
    struct Close {
        var hand: Hand
        var beginning = Beginning.asleep
        var sensorPhase = 0.037
        var pushPhase = 0.0
        var vsyncPhase = 0.0
        /// The scatter of one reading, in degrees.
        var noise = 0.0

        private static let policy = LidEffectPolicy(threshold: threshold, hysteresis: 4)
        private static let ramp = LidEffectRamp(startAngle: threshold, span: 64.6)

        private func takenAt(_ time: Double) -> Double {
            ((time - sensorPhase) / refresh).rounded(.down) * refresh + sensorPhase
        }

        /// The sensor's latest reading at `time`, in hundredths.
        private func reading(at time: Double) -> Double {
            let taken = takenAt(time)
            var value = hand.angle(at: taken)
            if noise > 0 {
                // The same scatter for the same reading, however often read.
                var state = UInt64(bitPattern: Int64((taken / refresh).rounded())) &* 2862933555777941757 &+ 3037000493
                func uniform() -> Double {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    return Double(state >> 11) / Double(1 << 53)
                }
                value += noise * (-2 * log(max(uniform(), 1e-12))).squareRoot() * cos(2 * .pi * uniform())
            }
            return (value * 100).rounded() / 100
        }

        func run() -> Result {
            var estimator = LidAngleEstimator(tuning: .sensor(resolution: 0.01))
            var motion = LidMotion()
            var filter = PushWakeFilter()
            var dwell = LidOpenDwell()
            var isActive = false, isClosingOut = false, isAwake = true, hasLink = false
            var raw = 0.0, peak = 0.0, lowest = 0.0, startedAt = 0.0
            var watchFrom = 0.9
            var pollInterval = 1.0 / 30
            var nextPoll = Double.infinity, nextFrame = Double.infinity
            var nextPush = 1.0 + pushPhase
            var result = Result()

            func setActive(_ active: Bool, at now: Double) {
                isActive = active
                guard active else {
                    // The ease back to flat keeps the link running.
                    isClosingOut = true
                    watchFrom = now
                    return
                }
                peak = raw
                lowest = raw
                dwell.reset()
                isClosingOut = false
                startedAt = now
                estimator.rejoin(at: now)
                if !hasLink {
                    hasLink = true
                    nextFrame = ((now - vsyncPhase) * 120).rounded(.down) / 120 + vsyncPhase + 1.0 / 120
                }
            }

            func poll(at now: Double, settling: Bool = false) {
                raw = reading(at: now)
                estimator.observe(raw, at: now)
                peak = max(peak, raw)
                if isActive { lowest = min(lowest, raw) }
                motion.update(with: raw, at: now, prewarmSpeed: 8)
                dwell.update(angle: raw, at: now, dwellAngle: Self.policy.dwellAngle)
                guard !settling else { return }
                // As `LidController.wantsEffect`.
                let approach = LidApproach(estimator) ?? LidApproach(angle: raw, speed: motion.velocity)
                let wanted = Self.policy.wantsEffect(
                    isEnabled: true,
                    isActive: isActive,
                    angle: raw,
                    estimatedAngle: approach.angle,
                    riseSinceLowest: raw - lowest,
                    hasBeenAboveThreshold: peak >= Self.policy.threshold,
                    wasClosingRecently: approach.isClosing || motion.intent.wasClosingRecently(at: now, memoryDuration: 1.5),
                    isClearlyOpening: isActive ? motion.isClearlyOpening : approach.isOpening,
                    hasDwelledOpen: dwell.hasDwelled(at: now, duration: 1),
                    minimumDurationElapsed: now - startedAt > 0.35
                )
                if wanted, !isActive, result.started == nil, now > watchFrom {
                    result.started = now
                    result.startReading = takenAt(now)
                }
                if wanted != isActive { setActive(wanted, at: now) }
                // As `schedulePolling`.
                let interval = isActive && !isClosingOut && hasLink && estimator.isMoving ? 1.0 / 60 : 1.0 / 30
                if interval != pollInterval {
                    pollInterval = interval
                    nextPoll = now + interval
                }
            }

            // Settled at rest, polled for a while, then asleep, still polled,
            // or under a run.
            for time in stride(from: 0.0, through: 0.9, by: 1.0 / 30) {
                poll(at: time, settling: true)
            }
            switch beginning {
            case .asleep:
                isAwake = false
                filter.sleep(at: raw)
            case .awake:
                nextPoll = 0.9 + pollInterval
            case .running:
                setActive(true, at: 0.9)
                startedAt = 0
                nextPoll = 0.9 + pollInterval
            }

            while true {
                let now = min(nextPush, nextPoll, nextFrame)
                guard now < 2.8, result.firstEffect == nil else { break }
                if now == nextPush {
                    nextPush += 0.1
                    // The sensor's latest reading, in whole degrees.
                    guard let speed = filter.receive(reading(at: now).rounded(), at: now), !isAwake else { continue }
                    // The main queue hop, then `wake(from:)` acts on it.
                    let woke = now + 0.001
                    isAwake = true
                    motion.wake(speed: speed, at: woke, prewarmSpeed: 8)
                    estimator.resume(speed: speed, variance: speed == 0 ? nil : 100, at: woke)
                    pollInterval = 1.0 / 30
                    nextPoll = woke + pollInterval
                    poll(at: woke)
                } else if now == nextPoll {
                    nextPoll += pollInterval
                    poll(at: now)
                } else {
                    nextFrame += 1.0 / 120
                    // Where the lid will be as this frame reaches the screen.
                    let target = now + 1.0 / 120
                    guard isActive, !isClosingOut else { continue }
                    let shown = estimator.frame(at: target)
                    guard result.started != nil else { continue }
                    if result.firstFrame == nil { result.firstFrame = target }
                    if Self.ramp.progress(at: shown.angle) > 0 { result.firstEffect = target }
                }
            }
            result.crossing = hand.crossing(below: threshold, after: watchFrom)
            if let crossing = result.crossing {
                let taken = takenAt(crossing)
                result.firstReadingPast = taken < crossing ? taken + refresh : taken
            }
            return result
        }
    }

    /// Sensor, push and display phases spread across their periods.
    static let phases: [(sensor: Double, push: Double, vsync: Double)] = (0..<16).map { index in
        let sensor = Double(index % 4) * 0.026 + 0.005
        let push = Double(index / 4) * 0.025
        let vsync = Double(index % 3) * 0.0027
        return (sensor, push, vsync)
    }

    static func runs(_ hand: Hand, beginning: Beginning = .asleep, noise: Double = 0) -> [Result] {
        phases.map { phase in
            Close(hand: hand, beginning: beginning, sensorPhase: phase.sensor, pushPhase: phase.push,
                  vsyncPhase: phase.vsync, noise: noise).run()
        }
    }

    @Test(arguments: [3.0, 6.0])
    func testAFirstCloseFromRestShowsTheEffectSoonAfterTheLidPassesTheStartAngle(above: Double) {
        var latencies: [Double] = []
        for speed in [40.0, 80, 150] {
            for result in Self.runs(.fromRest(above: above, speed: speed)) {
                guard let latency = result.latency else {
                    Issue.record("no effect at \(speed) degrees a second")
                    continue
                }
                latencies.append(latency)
                // The run's first frame already shows the lid where it is,
                // past the start angle, rather than easing in from rest.
                #expect(result.firstEffect == result.firstFrame,
                        "first effect \(((result.firstEffect ?? 0) - (result.firstFrame ?? 0)) * 1000) ms after the first frame at \(speed)°/s")
            }
        }
        // Waiting for a reading past the start angle, half a refresh on
        // average, then for its push or poll, and a frame.
        let mean = latencies.reduce(0, +) / Double(latencies.count)
        #expect(mean < 0.12, "\(above)° above: the effect showed \(mean * 1000) ms after the lid passed the start angle, on average")
    }

    @Test(arguments: [40.0, 80, 150])
    func testAReversalRightAfterAnOpeningStartsOnTheFirstReadingPastTheStartAngle(speed: Double) {
        var latencies: [Double] = []
        for result in Self.runs(.reversal(speed: speed), beginning: .running) {
            guard let latency = result.latency else {
                Issue.record("no effect")
                continue
            }
            latencies.append(latency)
            // The speed of the opening a moment before does not hold it off
            // for another reading.
            let late = (result.startReading ?? .infinity) - (result.firstReadingPast ?? 0)
            #expect(abs(late) < 1e-6, "started on a reading \(late * 1000) ms late")
            // A reading only just past the start angle shows on the frame
            // after, the picture trailing the readings as it does.
            #expect((result.firstEffect ?? .infinity) - (result.firstFrame ?? 0) <= 1.0 / 120 + 1e-6)
        }
        let mean = latencies.reduce(0, +) / Double(latencies.count)
        #expect(mean < 0.1, "\(speed)°/s: the effect showed \(mean * 1000) ms after the lid passed the start angle, on average")
    }

    @Test(arguments: [(106.0, 1.0), (106, 2), (115, 1), (115, 2), (130, 5)])
    func testACloseThatStopsShortOfTheStartAngleDoesNotStart(from: Double, short: Double) {
        for speed in [20.0, 40, 80, 150] {
            let starts = Self.runs(.stopsShort(from: from, short: short, speed: speed), noise: 0.03)
                .filter { $0.started != nil }.count
            #expect(starts == 0, "\(starts) of \(Self.phases.count) started at \(speed) degrees a second")
        }
    }

    @Test
    func testAStillOrOpeningLidDoesNotStart() {
        // Resting a hair above the start angle, polled, its readings
        // scattered as the sensor's are.
        let still = Self.runs(Hand(start: Self.threshold + 0.1, segments: [(1, 0)]), beginning: .awake, noise: 0.03)
        #expect(still.allSatisfy { $0.started == nil })
        // Opened from below the start angle to past it.
        for speed in [40.0, 150] {
            let opening = Hand(start: 90, segments: [(1, 0), (0.1, speed), (20 / speed - 0.1, speed), (0.1, 0)])
            #expect(Self.runs(opening, noise: 0.03).allSatisfy { $0.started == nil })
        }
    }
}
