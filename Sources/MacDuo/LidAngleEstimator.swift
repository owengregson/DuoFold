import Foundation

/// Turns the lid sensor's sparse readings into an angle for every frame.
///
/// The sensor takes a reading about every 104 ms, and a poll finds each one
/// up to a poll interval after it arrived. A Kalman filter (angle, speed and
/// acceleration) takes each new reading at the moment it most likely
/// arrived, and a frame asks where the lid is at the moment it shows: the
/// filtered angle carried along the filtered speed.
///
/// What keeps it stable:
/// - The filter forgets old readings over `memory` instead of assuming white
///   noise acceleration. With readings this precise, white noise
///   acceleration gives the gains of an alpha-beta filter that rings after
///   a stop; fading memory gives critically damped ones that settle in a few
///   readings.
/// - The acceleration only ever slows the lid down, and never past a
///   standstill: a hand slowing to a stop is followed into it, and a lid is
///   never thrown on ahead or turned around by an estimate.
/// - The speed carried is never more than half again the speed between the
///   last two readings, and nothing is carried when the two disagree on the
///   direction: the monotone limiter that keeps interpolation from running
///   past a corner.
/// - The carry runs one refresh past the last reading in full, then levels
///   off, so a reading that never comes does not carry the angle away.
/// - A speed lost in the readings' noise counts as a still lid, which is not
///   carried at all, and a still picture holds until the lid moves by more
///   than a reading flickers, so it neither drifts nor jitters.
/// - Each correction is blended in from where the picture is, how fast it
///   moves and how fast that is changing, critically damped, so the angle
///   never steps or jerks at a reading and settles without ringing.
///
/// A lid that stops dead is only seen to stop at the reading after, so a
/// picture that keeps up with a moving lid runs past a sudden stop by about
/// the distance the lid would have covered meanwhile. `trail` sets the
/// balance between the two.
struct LidAngleEstimator {

    struct Tuning {
        /// How long the filter remembers a reading: older readings weigh
        /// less by e⁻¹ every this many seconds.
        var memory: TimeInterval
        /// The scatter of one reading of a still lid, in degrees.
        var readingNoise: Double
        /// The step between two readings, in degrees.
        var resolution: Double
        /// How often the sensor takes a reading. Zero for readings that are
        /// new every time and exact when read.
        var refreshInterval: TimeInterval
        /// How far a reading can arrive from the sensor's steady clock.
        var refreshJitter: TimeInterval
        /// How far behind the readings' arrival the picture runs.
        var trail: TimeInterval
        /// How far past the last reading the angle is carried in full.
        var horizon: TimeInterval
        /// Past the horizon the carry fades out over about this long.
        var horizonFade: TimeInterval
        /// How fast a correction is blended in, radians per second.
        var blendFrequency: Double
        /// Speeds below this are the readings' noise: the lid is still.
        /// Degrees per second.
        var stillSpeed: Double
        /// How far a still lid's estimate may wander before the picture
        /// follows it, in degrees.
        var stillBand: Double
        /// The fastest speed carried, as a multiple of the speed between the
        /// last two readings.
        var speedLimit: Double
        /// How much harder than the readings show a slowing lid is assumed
        /// to slow, when they show it slowing by clearly more than their
        /// timing could fake. Readings can only show a stop once it is a
        /// refresh old, and a lid that has begun to slow is about to stop.
        var brake: Double

        /// The orientation sensor, measured on an M5 MacBook Pro: a reading
        /// every 104.2 to 104.5 ms, within a millisecond of its own clock, of
        /// a still lid scattered by 0.03 degrees.
        ///
        /// How long the sensor takes from hinge to report cannot be seen
        /// without moving the lid against a reference, so readings count
        /// from when they arrived. Against a simulation of this sensor and of
        /// hand closes, a 30 ms trail runs past a dead stop at 150 degrees a
        /// second about as far as the earlier spring did, lags a third to a
        /// half less, and runs past a hand slowing to a stop by a degree or
        /// two where the spring ran past by five or six.
        static func sensor(resolution: Double) -> Tuning {
            Tuning(
                memory: 0.03,
                readingNoise: 0.03,
                resolution: resolution,
                refreshInterval: 0.1043,
                refreshJitter: 0.001,
                trail: 0.03,
                horizon: 0.1043 + 0.05,
                horizonFade: 0.05,
                blendFrequency: 30,
                // A degree's step within one refresh reads as 10 degrees a
                // second, so whole degree readings need more to move.
                stillSpeed: 1.5 + 6.5 * resolution,
                stillBand: 0.1 + resolution,
                speedLimit: 1.5,
                brake: 1.5
            )
        }

        /// The preview's scripted sweep: exact and new at every poll. The
        /// picture runs a little over one poll behind it, between two
        /// readings it already has, so the sweep's corners are rounded off
        /// rather than run past, even after a late poll.
        static func script(pollInterval: TimeInterval) -> Tuning {
            Tuning(
                memory: 0.03,
                readingNoise: 0.01,
                resolution: 0,
                refreshInterval: 0,
                refreshJitter: 0,
                trail: 1.25 * pollInterval,
                horizon: pollInterval,
                horizonFade: 0.01,
                blendFrequency: 30,
                stillSpeed: 1.5,
                stillBand: 0.1,
                speedLimit: 1.5,
                brake: 1
            )
        }
    }

    /// Where the picture is: angle, speed, and how fast the speed changes.
    struct Motion {
        var angle: Double
        var speed: Double
        var acceleration: Double
    }

    private(set) var tuning: Tuning

    /// The filter (angle, speed, acceleration) and its covariance, as of
    /// `stateTime`, when the last reading arrived.
    private var state = SIMD3<Double>(0, 0, 0)
    private var covariance = Covariance()
    private var stateTime: TimeInterval = 0
    private(set) var hasReading = false

    /// What the picture is carried along: the filter's speed, limited, and
    /// its deceleration. Both zero for a still lid.
    private var carriedSpeed = 0.0
    private var carriedDeceleration = 0.0

    private var lastReading: Double?
    /// The reading before `lastReading`, to tell a lid sitting between two
    /// whole degrees from one moving through them.
    private var readingBefore: Double?
    private var lastReadTime: TimeInterval = -.greatestFiniteMagnitude
    /// When the last new reading was found.
    private var lastFoundTime: TimeInterval = -.greatestFiniteMagnitude
    /// The last new reading and when it arrived, for the limiter.
    private var lastSample: (angle: Double, time: TimeInterval)?
    private var secantSpeed: Double?
    private var clock = RefreshClock()
    /// How closely the last reading's arrival is known, in seconds.
    private var timingSpread: TimeInterval = .infinity
    /// A speed to start from, for the first reading after a reset.
    private var seed: (speed: Double, variance: Double)?

    /// The picture is the projection plus a correction decaying from
    /// `blendStart`, or a held angle while the lid is still.
    private var blendStart: TimeInterval = 0
    private var offset = 0.0
    private var offsetSpeed = 0.0
    private var offsetAcceleration = 0.0
    private var held: Double?
    /// The latest time a frame was drawn for. Frames draw a little ahead
    /// of now, so a reading can land after a frame that already showed a
    /// moment later than the reading.
    private var lastShownTime: TimeInterval = -.greatestFiniteMagnitude
    /// Readings in a row the filter's newest angle has stayed far from.
    private var strays = 0

    /// A lid of unknown motion could be moving this fast, degrees per second,
    /// and changing speed this fast, degrees per second squared.
    private static let unknownSpeed: Double = 150
    private static let unknownAcceleration: Double = 3000

    init(tuning: Tuning) {
        self.tuning = tuning
    }

    // MARK: - Readings

    /// Forgets everything. The next reading starts afresh, and the angle
    /// goes straight to it.
    mutating func reset(tuning: Tuning? = nil) {
        self = LidAngleEstimator(tuning: tuning ?? self.tuning)
    }

    /// Readings start again after a pause. The motion before the pause is
    /// forgotten and the lid starts at `speed`, give or take the square root
    /// of `variance` (any speed, if `nil`), but the angle carries on from
    /// where the picture is, so a picture left on screen does not jump.
    mutating func resume(speed resumed: Double = 0, variance: Double? = nil, at time: TimeInterval) {
        let variance = variance ?? Self.unknownSpeed * Self.unknownSpeed
        guard hasReading else {
            seed = (resumed, variance)
            return
        }
        let anchor = max(time, lastShownTime)
        let shown = motion(at: anchor)
        held = nil
        state = SIMD3(shown.angle, resumed, 0)
        covariance = Covariance(diagonal: SIMD3(100, variance, Self.unknownAcceleration * Self.unknownAcceleration))
        // About when the reading that woke this arrived.
        stateTime = time - tuning.refreshInterval / 2
        lastReading = nil
        readingBefore = nil
        lastSample = nil
        secantSpeed = nil
        carry()
        blend(from: shown, at: anchor)
    }

    /// One reading, read at `time`. A poll that finds the reading it found
    /// last time adds nothing, so this can be called on every poll.
    mutating func observe(_ reading: Double, at time: TimeInterval) {
        guard reading.isFinite, time.isFinite else { return }
        let previousRead = lastReadTime
        lastReadTime = time
        let refresh = tuning.refreshInterval

        // A new reading arrived after the read that still showed the last
        // one, and no more than a refresh ago; the refresh clock narrows
        // that down. The same reading again tells nothing of when.
        var arrived = time - refresh / 2
        var spread = refresh
        if let previous = lastReading, reading == previous {
            // Read again, or a still lid that read the same twice running.
            guard time - lastFoundTime >= 1.5 * refresh else { return }
        } else if refresh > 0 {
            let earliest = lastReading == nil ? time - refresh : max(time - refresh, previousRead)
            let placed = clock.place(earliest...time, period: refresh, jitter: tuning.refreshJitter)
            arrived = placed.time
            spread = placed.spread
        }
        timingSpread = spread
        let timingVariance = spread * spread / 12
        // A whole degree reading that flips back to the one before marks the
        // lid on the boundary between the two rather than moving back and
        // forth, and a reading within half a step of that boundary agrees
        // with it.
        var value = reading
        let step = tuning.resolution
        if step >= 0.5, let last = lastReading {
            if reading == readingBefore, abs(reading - last) <= step * 1.001 {
                value = (reading + last) / 2
            } else if let sample = lastSample, abs(reading - sample.angle) <= step / 2 + 1e-9 {
                value = sample.angle
            }
        }
        if lastReading != reading { readingBefore = lastReading }
        lastReading = reading
        lastFoundTime = time
        if let sample = lastSample, arrived - sample.time > 0.01,
           arrived - sample.time < 2.5 * max(refresh, 0.04) {
            secantSpeed = (value - sample.angle) / (arrived - sample.time)
        } else {
            secantSpeed = nil
        }
        lastSample = (value, arrived)

        guard hasReading else {
            begin(value, arrived: arrived, timingVariance: timingVariance, at: time)
            return
        }
        update(value, arrived: arrived, timingVariance: timingVariance, at: time)

        // A filter takes each reading in, so its newest angle is never far
        // from it for long; one that stays far has stopped taking them in.
        // It starts again from the reading, and says what it was holding.
        guard abs(state.x - value) > Self.strayLimit || !state.x.isFinite else {
            strays = 0
            return
        }
        strays += 1
        guard strays >= Self.straysBeforeRestart else { return }
        let held = summary(reading: value, arrived: arrived, at: time)
        Diagnostics.lid.error("estimator restarted: \(held, privacy: .public)")
        let speed = secantSpeed ?? 0
        hasReading = false
        seed = (speed.isFinite ? speed : 0, Self.unknownSpeed * Self.unknownSpeed)
        strays = 0
        begin(value, arrived: arrived, timingVariance: timingVariance, at: time)
    }

    /// Further than a lid moves between two readings, and further than any
    /// correction leaves the filter behind.
    private static let strayLimit = 20.0
    private static let straysBeforeRestart = 3

    /// What the filter holds, for the log.
    private func summary(reading: Double, arrived: TimeInterval, at time: TimeInterval) -> String {
        func f(_ x: Double) -> String { String(format: "%.4g", x) }
        return "reading \(f(reading)) at \(f(time)) arrived \(f(arrived)); state \(f(state.x)) \(f(state.y)) \(f(state.z)) "
            + "at \(f(stateTime)); covariance aa \(f(covariance.aa)) av \(f(covariance.av)) vv \(f(covariance.vv)) "
            + "cc \(f(covariance.cc)); spread \(f(timingSpread)) secant \(secantSpeed.map(f) ?? "-") "
            + "carried \(f(carriedSpeed)) held \(held.map(f) ?? "-") shown \(f(lastShownTime))"
    }

    private mutating func begin(_ reading: Double, arrived: TimeInterval, timingVariance: Double, at time: TimeInterval) {
        let start = seed ?? (0, Self.unknownSpeed * Self.unknownSpeed)
        seed = nil
        hasReading = true
        state = SIMD3(reading, start.speed, 0)
        covariance = Covariance(diagonal: SIMD3(
            measurementVariance(timingVariance: timingVariance, speed: start.speed),
            start.variance,
            Self.unknownAcceleration * Self.unknownAcceleration
        ))
        stateTime = arrived
        carry()
        held = nil
        offset = 0
        offsetSpeed = 0
        offsetAcceleration = 0
        blendStart = time
    }

    private mutating func update(_ reading: Double, arrived: TimeInterval, timingVariance: Double, at time: TimeInterval) {
        // The picture carries on from the last frame it drew, even one drawn
        // for a moment after this reading.
        let anchor = max(time, lastShownTime)
        let shown = motion(at: anchor)

        // Two readings found close together can be placed out of order; the
        // filter only runs forward.
        let dt = max(arrived - stateTime, 0)
        state = SIMD3(
            state.x + dt * (state.y + dt * state.z / 2),
            state.y + dt * state.z,
            state.z
        )
        covariance.predict(dt: dt, memory: tuning.memory)
        stateTime += dt

        let r = measurementVariance(timingVariance: timingVariance, speed: state.y)
        let gain = covariance.update(measurementVariance: r)
        state += gain * (reading - state.x)

        carry()
        settle(from: shown, at: anchor)
    }

    /// A reading's scatter, its rounding, and how far the lid moves in the
    /// uncertainty of when it arrived.
    private func measurementVariance(timingVariance: Double, speed: Double) -> Double {
        tuning.readingNoise * tuning.readingNoise
            + tuning.resolution * tuning.resolution / 12
            + timingVariance * speed * speed
    }

    /// What the picture is carried along until the next reading.
    private mutating func carry() {
        let speed = state.y
        var limited = speed
        if let secant = secantSpeed {
            if secant * speed <= 0 {
                limited = 0
            } else {
                limited = speed > 0 ? min(speed, tuning.speedLimit * secant) : max(speed, tuning.speedLimit * secant)
            }
        }
        let weight = Self.motionWeight(speed, still: tuning.stillSpeed)
        carriedSpeed = limited * weight
        let acceleration = state.z
        guard carriedSpeed != 0, acceleration * carriedSpeed < 0 else {
            carriedDeceleration = 0
            return
        }
        // A reading placed a few milliseconds early or late looks like a
        // lid speeding up or slowing down, so only a slowing well beyond
        // what that could explain brakes harder.
        let refresh = max(tuning.refreshInterval, 1e-3)
        let slowing = abs(acceleration) * refresh / abs(speed)
        let misreading = max(2 * min(timingSpread, refresh) / refresh, 0.05)
        let significance = min(max((slowing - misreading) / misreading, 0), 1)
        carriedDeceleration = acceleration * weight * (1 + (tuning.brake - 1) * significance)
    }

    /// Zero for a speed lost in the noise, one for a clear motion, smooth in
    /// between so the carry does not switch on with a jolt.
    private static func motionWeight(_ speed: Double, still: Double) -> Double {
        let x = min(max((abs(speed) - still) / still, 0), 1)
        return x * x * (3 - 2 * x)
    }

    // MARK: - Display

    /// What a frame that shows at `time` draws. Readings that come in
    /// after it carry on from it, so the picture never jumps back.
    mutating func frame(at time: TimeInterval) -> Motion {
        lastShownTime = max(lastShownTime, time)
        return motion(at: time)
    }

    /// Where the picture puts the lid at `time`, or `nil` before any reading.
    func angle(at time: TimeInterval) -> Double? {
        hasReading ? motion(at: time).angle : nil
    }

    /// How fast that angle moves at `time`, degrees per second.
    func speed(at time: TimeInterval) -> Double {
        hasReading ? motion(at: time).speed : 0
    }

    /// The newest reading, filtered, and the speed the lid is carried on at
    /// from it, or `nil` before any reading. Unlike the picture's, the speed
    /// is not blended in: it turns round at the reading that shows the lid
    /// turning, where the picture runs on past and comes back.
    var latest: Motion? {
        hasReading ? Motion(angle: state.x, speed: carriedSpeed, acceleration: carriedDeceleration) : nil
    }

    /// Puts the picture where the readings put the lid, for a picture that
    /// was not on screen and so has nothing to carry on from.
    mutating func rejoin(at time: TimeInterval) {
        held = nil
        offset = 0
        offsetSpeed = 0
        offsetAcceleration = 0
        blendStart = time
    }

    /// True while the lid is carried along, as opposed to held still.
    var isMoving: Bool { carriedSpeed != 0 }

    /// True once the picture holds still on a still lid, so nothing needs
    /// drawing until the lid moves.
    func isSettled(at time: TimeInterval) -> Bool {
        guard hasReading else { return true }
        if held != nil { return true }
        let correction = correction(at: time)
        return carriedSpeed == 0 && abs(correction.angle) < 0.1 && abs(correction.speed) < 1
    }

    func motion(at time: TimeInterval) -> Motion {
        if let held { return Motion(angle: held, speed: 0, acceleration: 0) }
        let projected = projection(at: time)
        let correction = correction(at: time)
        return Motion(
            angle: projected.angle + correction.angle,
            speed: projected.speed + correction.speed,
            acceleration: projected.acceleration + correction.acceleration
        )
    }

    /// The filtered angle carried to `time`: slowing down if the lid is
    /// slowing, in full up to the horizon, fading after it.
    private func projection(at time: TimeInterval) -> Motion {
        let ahead = time - tuning.trail - stateTime
        let speed = carriedSpeed
        guard ahead > 0 else {
            // Before the last reading: back along the line through it.
            return Motion(angle: state.x + speed * ahead, speed: speed, acceleration: 0)
        }
        let deceleration = carriedDeceleration
        func travel(_ t: TimeInterval) -> Motion {
            guard deceleration != 0 else { return Motion(angle: speed * t, speed: speed, acceleration: 0) }
            // A standstill is where the slowing ends.
            let stop = -speed / deceleration
            guard t < stop else { return Motion(angle: -speed * speed / (2 * deceleration), speed: 0, acceleration: 0) }
            return Motion(angle: t * (speed + deceleration * t / 2), speed: speed + deceleration * t, acceleration: deceleration)
        }
        let horizon = tuning.horizon
        guard ahead > horizon else {
            let moved = travel(ahead)
            return Motion(angle: state.x + moved.angle, speed: moved.speed, acceleration: moved.acceleration)
        }
        let fade = max(tuning.horizonFade, 1e-3)
        let remaining = exp(-(ahead - horizon) / fade)
        let moved = travel(horizon + fade * (1 - remaining))
        return Motion(
            angle: state.x + moved.angle,
            speed: moved.speed * remaining,
            acceleration: (moved.acceleration * remaining - moved.speed / fade) * remaining
        )
    }

    /// A critically damped decay from `offset`, `offsetSpeed` and
    /// `offsetAcceleration`, matching all three where it starts.
    private func correction(at time: TimeInterval) -> Motion {
        let t = max(time - blendStart, 0)
        let k = tuning.blendFrequency
        let decay = exp(-k * t)
        let c0 = offset
        let c1 = offsetSpeed + k * offset
        let c2 = offsetAcceleration / 2 + k * offsetSpeed + k * k * offset / 2
        let p = c0 + t * (c1 + t * c2)
        let dp = c1 + 2 * c2 * t
        let ddp = 2 * c2
        return Motion(
            angle: p * decay,
            speed: (dp - k * p) * decay,
            acceleration: (ddp - 2 * k * dp + k * k * p) * decay
        )
    }

    /// After a reading: holds a still picture on a still lid, and otherwise
    /// blends from what was shown into the new estimate.
    private mutating func settle(from shown: Motion, at time: TimeInterval) {
        let estimate = projection(at: time)
        if carriedSpeed == 0, abs(shown.speed) < tuning.stillSpeed,
           abs(estimate.angle - shown.angle) < tuning.stillBand {
            held = shown.angle
            return
        }
        held = nil
        blend(from: shown, at: time)
    }

    private mutating func blend(from shown: Motion, at time: TimeInterval) {
        let estimate = projection(at: time)
        let k = tuning.blendFrequency
        offset = shown.angle - estimate.angle
        offsetSpeed = shown.speed - estimate.speed
        offsetAcceleration = shown.acceleration - estimate.acceleration
        // A picture already past the estimate, in the way the lid is going,
        // keeps none of the speed that took it there: it stops and comes
        // back, rather than running on. One behind keeps its speed and
        // catches up smoothly.
        let heading = estimate.speed != 0 ? estimate.speed : shown.speed
        if offset * heading > 0, offset * offsetSpeed > 0 { offsetSpeed = 0 }
        // Nor does a correction ever carry it through the estimate and out
        // the other side: (c0 + c1 t + c2 t²) e⁻ᵏᵗ keeps one sign while c1
        // and c2 share the sign of the first of them that is not zero.
        if offset * (offsetSpeed + k * offset) < 0 { offsetSpeed = -k * offset }
        let side = offset != 0 ? offset : offsetSpeed
        if side * (offsetAcceleration / 2 + k * offsetSpeed + k * k * offset / 2) < 0 {
            offsetAcceleration = -2 * k * offsetSpeed - k * k * offset
        }
        blendStart = time
    }
}

/// The filter's covariance, symmetric, as the six numbers that matter.
private struct Covariance {
    var aa = 0.0, av = 0.0, ac = 0.0
    var vv = 0.0, vc = 0.0
    var cc = 0.0

    init() {}

    init(diagonal: SIMD3<Double>) {
        aa = diagonal.x
        vv = diagonal.y
        cc = diagonal.z
    }

    /// Carries the covariance `dt` ahead at constant acceleration, and fades
    /// it so that older readings count for less.
    mutating func predict(dt: TimeInterval, memory: TimeInterval) {
        let h = dt * dt / 2
        // F P Fᵀ, with F = [[1, dt, h], [0, 1, dt], [0, 0, 1]].
        let naa = aa + 2 * dt * av + 2 * h * ac + dt * dt * vv + 2 * dt * h * vc + h * h * cc
        let nav = av + dt * vv + h * vc + dt * (ac + dt * vc + h * cc)
        let nac = ac + dt * vc + h * cc
        let nvv = vv + 2 * dt * vc + dt * dt * cc
        let nvc = vc + dt * cc
        // Half a second forgets everything; past that the numbers only grow.
        let fade = exp(2 * min(dt, 0.5) / max(memory, 1e-3))
        aa = naa * fade
        av = nav * fade
        ac = nac * fade
        vv = nvv * fade
        vc = nvc * fade
        cc *= fade
    }

    /// Takes in a reading of the angle and returns the gain. Joseph form,
    /// P' = (I - K H) P (I - K H)ᵀ + K r Kᵀ with H = [1, 0, 0], so it stays
    /// symmetric and positive.
    mutating func update(measurementVariance r: Double) -> SIMD3<Double> {
        let s = aa + r
        guard s > 0, s.isFinite else { return .zero }
        let k = SIMD3(aa, av, ac) / s
        let rest = 1 - k.x
        let naa = rest * rest * aa + r * k.x * k.x
        let nav = rest * (av - k.y * aa) + r * k.x * k.y
        let nac = rest * (ac - k.z * aa) + r * k.x * k.z
        let nvv = vv - 2 * k.y * av + k.y * k.y * aa + r * k.y * k.y
        let nvc = vc - k.z * av - k.y * ac + k.y * k.z * aa + r * k.y * k.z
        let ncc = cc - 2 * k.z * ac + k.z * k.z * aa + r * k.z * k.z
        aa = naa
        av = nav
        ac = nac
        vv = max(nvv, 0)
        vc = nvc
        cc = max(ncc, 0)
        return k
    }
}

/// The sensor's refresh clock, recovered from when polls found new readings.
///
/// The sensor takes a reading on a steady clock of its own, about every
/// 104 ms. Each new reading turned up somewhere between the poll before and
/// the poll that found it. A clock of the right period passes through every
/// one of those windows, and as the polls drift against the sensor the
/// windows cut it down from both sides, until when each reading arrived is
/// known to a millisecond or two. Periods within half a percent of the
/// nominal one, which covers the 104.2 to 104.5 ms measured, are tried at
/// once and dropped as the windows rule them out.
struct RefreshClock {
    private struct Candidate {
        var period: TimeInterval
        /// When reading zero could have arrived, after `origin`.
        var phase: ClosedRange<TimeInterval>
    }

    private var candidates: [Candidate] = []
    private var origin: TimeInterval = 0
    private var lastWindowEnd: TimeInterval = -.greatestFiniteMagnitude

    /// Longer without a reading and the clock starts over: the periods left
    /// could have drifted out of step meanwhile.
    private static let memory: TimeInterval = 2
    private static let periodRange = 0.005
    private static let periodStep: TimeInterval = 0.00002

    /// When a reading found in `window` most likely arrived, and how wide
    /// the range it could have arrived in is.
    mutating func place(
        _ window: ClosedRange<TimeInterval>,
        period nominal: TimeInterval,
        jitter: TimeInterval
    ) -> (time: TimeInterval, spread: TimeInterval) {
        defer { lastWindowEnd = window.upperBound }
        let middle = (window.lowerBound + window.upperBound) / 2
        let whole = (middle, window.upperBound - window.lowerBound)
        guard nominal > 0 else { return whole }
        guard !candidates.isEmpty, window.upperBound - lastWindowEnd < Self.memory else {
            start(window, nominal: nominal, jitter: jitter)
            return whole
        }
        // Which reading this is, counted by the best placed clock.
        guard let best = candidates.min(by: { width($0.phase) < width($1.phase) }) else { return whole }
        let index = ((middle - origin - centre(best.phase)) / best.period).rounded()
        var survivors: [Candidate] = []
        var lower = TimeInterval.infinity
        var upper = -TimeInterval.infinity
        for candidate in candidates {
            let shift = index * candidate.period
            let low = max(candidate.phase.lowerBound, window.lowerBound - origin - shift - jitter)
            let high = min(candidate.phase.upperBound, window.upperBound - origin - shift + jitter)
            guard low <= high else { continue }
            survivors.append(Candidate(period: candidate.period, phase: low...high))
            lower = min(lower, origin + shift + low - jitter)
            upper = max(upper, origin + shift + high + jitter)
        }
        // Every clock missed the window: the sensor skipped or changed
        // pace. The window alone is the honest answer, and a fresh start.
        guard !survivors.isEmpty else {
            start(window, nominal: nominal, jitter: jitter)
            return whole
        }
        candidates = survivors
        let placedLower = max(lower, window.lowerBound)
        let placedUpper = min(upper, window.upperBound)
        guard placedLower <= placedUpper else { return whole }
        return ((placedLower + placedUpper) / 2, placedUpper - placedLower)
    }

    private mutating func start(_ window: ClosedRange<TimeInterval>, nominal: TimeInterval, jitter: TimeInterval) {
        origin = window.lowerBound
        let phase = -jitter...(window.upperBound - window.lowerBound + jitter)
        let count = Int((nominal * Self.periodRange / Self.periodStep).rounded())
        candidates = (-count...count).map { step in
            Candidate(period: nominal + Double(step) * Self.periodStep, phase: phase)
        }
    }

    private func width(_ range: ClosedRange<TimeInterval>) -> TimeInterval {
        range.upperBound - range.lowerBound
    }

    private func centre(_ range: ClosedRange<TimeInterval>) -> TimeInterval {
        (range.lowerBound + range.upperBound) / 2
    }
}
