import Foundation

struct LidMotionIntent {
    private(set) var lastMovedDownTime: TimeInterval = -Double.greatestFiniteMagnitude

    mutating func update(
        angularVelocity: Double,
        at now: TimeInterval,
        closingSpeed: Double,
        openingSpeed: Double
    ) {
        if angularVelocity >= openingSpeed {
            // Opening is an intentional reversal, so an earlier close must not
            // be reused to start the effect again near the threshold.
            lastMovedDownTime = -Double.greatestFiniteMagnitude
        } else if angularVelocity <= -closingSpeed {
            lastMovedDownTime = now
        }
    }

    func wasClosingRecently(at now: TimeInterval, memoryDuration: TimeInterval) -> Bool {
        now - lastMovedDownTime < memoryDuration
    }

    mutating func reset() {
        lastMovedDownTime = -Double.greatestFiniteMagnitude
    }
}

/// How fast the lid moves, measured between the readings that changed, and
/// what that says about where it is heading.
struct LidMotion {

    /// Closing speed that counts as a deliberate close, in degrees per second.
    /// A still lid reads under 0.5.
    static let triggerClosingSpeed: Double = 2

    /// Opening speed that counts as a deliberate reversal, in degrees per second.
    static let triggerOpeningSpeed: Double = 2

    static let predictionSpeedFloor: Double = 40

    /// Sensor latency the prediction adds on top of the reading's own age.
    static let predictionLatency: TimeInterval = 0.04

    /// Degrees per second, negative while the lid closes.
    private(set) var velocity: Double = 0
    private(set) var intent = LidMotionIntent()
    /// When the lid last closed as fast as the pre-warm asks for.
    private(set) var lastClosingTime: TimeInterval = -.greatestFiniteMagnitude
    private var lastChangedAngle: Double?
    private var lastChangeTime: TimeInterval = 0

    var isClearlyOpening: Bool { velocity >= Self.triggerOpeningSpeed }

    /// Takes one reading. The first after a reset only sets the baseline.
    mutating func update(with angle: Double, at now: TimeInterval, prewarmSpeed: Double) {
        guard let last = lastChangedAngle else {
            lastChangedAngle = angle
            lastChangeTime = now
            return
        }
        if angle != last {
            let dt = now - lastChangeTime
            if dt > 0.001 {
                let instant = (angle - last) / dt
                velocity = 0.5 * instant + 0.5 * velocity
            }
            lastChangedAngle = angle
            lastChangeTime = now
        } else if now - lastChangeTime > 0.4 {
            velocity = 0
        }
        intent.update(
            angularVelocity: velocity,
            at: now,
            closingSpeed: Self.triggerClosingSpeed,
            openingSpeed: Self.triggerOpeningSpeed
        )
        if velocity >= Self.triggerOpeningSpeed {
            lastClosingTime = -.greatestFiniteMagnitude
        } else if velocity <= -prewarmSpeed {
            lastClosingTime = now
        }
    }

    /// Readings start again after a sleep, at the speed the pushed readings
    /// measured. The reading before the sleep is too old to measure against.
    mutating func wake(speed: Double, at now: TimeInterval, prewarmSpeed: Double) {
        if abs(speed) > abs(velocity) {
            velocity = speed
            intent.update(
                angularVelocity: speed,
                at: now,
                closingSpeed: Self.triggerClosingSpeed,
                openingSpeed: Self.triggerOpeningSpeed
            )
            if speed <= -prewarmSpeed { lastClosingTime = now }
        }
        lastChangedAngle = nil
    }

    /// A reading can be a full sensor refresh old, so a fast close works from
    /// where the lid is heading rather than the last reading.
    func predictedAngle(from angle: Double, at now: TimeInterval) -> Double {
        guard velocity < -Self.predictionSpeedFloor else { return angle }
        let staleness = min(now - lastChangeTime, 0.12)
        return angle + velocity * (staleness + Self.predictionLatency)
    }

    /// Forgets the motion, so the next reading starts a fresh baseline.
    mutating func reset() {
        self = LidMotion()
    }
}

/// How long the lid has stayed opened back above the start angle.
struct LidOpenDwell {
    private(set) var since: TimeInterval?

    mutating func update(angle: Double, at now: TimeInterval, dwellAngle: Double) {
        if angle >= dwellAngle {
            if since == nil { since = now }
        } else {
            since = nil
        }
    }

    func hasDwelled(at now: TimeInterval, duration: TimeInterval) -> Bool {
        guard let since else { return false }
        return now - since >= duration
    }

    mutating func reset() {
        since = nil
    }
}

/// How long the lid has stayed pressed shut. Nobody looks at a shut screen,
/// so a run held shut long enough ends, and opening the lid shows the
/// screen as it is.
struct LidShutHold {
    /// A lid at or below this is shut. Pressed shut it reads about a degree
    /// below zero, and resting there it creeps up to half a degree above.
    static let shutAngle: Double = 1

    /// How long the lid stays shut before the run ends.
    static let duration: TimeInterval = 2

    private(set) var since: TimeInterval?

    var isShut: Bool { since != nil }

    mutating func update(angle: Double, at now: TimeInterval) {
        if angle <= Self.shutAngle {
            if since == nil { since = now }
        } else {
            since = nil
        }
    }

    func hasHeld(at now: TimeInterval) -> Bool {
        guard let since else { return false }
        return now - since >= Self.duration
    }

    mutating func reset() {
        since = nil
    }
}

/// Holds off a new run after one was ended early, by the timeout or by
/// Escape, until the lid has opened back to the start angle. Closing further
/// from the same resting spot is not a new close.
struct LidReopenLatch {
    private(set) var isEngaged = false

    mutating func engage() {
        isEngaged = true
    }

    /// Whether a run may start at this angle. Reaching the threshold lets go.
    mutating func allowsStart(angle: Double, threshold: Double) -> Bool {
        guard isEngaged else { return true }
        guard angle >= threshold else { return false }
        isEngaged = false
        return true
    }

    mutating func reset() {
        isEngaged = false
    }
}

/// How far this lid opens, learned from the widest angle it has been held
/// at. Hinges stop a few degrees either side of 130°, so a start angle near
/// the top of the slider can leave the release angle out of reach.
struct LidHingeLimit {
    /// Readings within this many degrees of the first count as one hold. A
    /// whole-degree sensor resting on a half-degree boundary alternates
    /// between two readings a degree apart.
    static let holdTolerance: Double = 1

    /// How long a hold must last before it counts, so one stray reading
    /// cannot raise the limit.
    static let holdDuration: TimeInterval = 1

    /// No hinge opens past flat. A reading outside this is a sensor fault, or
    /// a lid pressed shut, which reads a little under zero and is no stop.
    static let plausibleAngles: ClosedRange<Double> = 0...180

    /// The widest angle held so far, `nil` before the first hold. It only
    /// rises: a lid resting lower has not found a new hinge stop.
    private(set) var angle: Double?

    private var holdAnchor: Double?
    private var holdFloor: Double = 0
    private var holdStart: TimeInterval = 0

    init(angle: Double? = nil) {
        if let angle, Self.plausibleAngles.contains(angle) {
            self.angle = angle
        }
    }

    /// Returns true when the reading raised the limit.
    @discardableResult
    mutating func observe(_ reading: Double, at now: TimeInterval) -> Bool {
        guard Self.plausibleAngles.contains(reading) else {
            holdAnchor = nil
            return false
        }
        guard let anchor = holdAnchor, abs(reading - anchor) <= Self.holdTolerance else {
            holdAnchor = reading
            holdFloor = reading
            holdStart = now
            return false
        }
        // The lowest reading of the hold, so a lid resting between two
        // readings counts as the lower one.
        holdFloor = min(holdFloor, reading)
        guard now - holdStart >= Self.holdDuration, holdFloor > (angle ?? -.infinity) else {
            return false
        }
        angle = holdFloor
        return true
    }

    /// Drops the hold in progress, for a gap in the readings such as sleep.
    mutating func interrupt() {
        holdAnchor = nil
    }
}

struct LidEffectPolicy {
    let threshold: Double
    let hysteresis: Double

    init(threshold: Double, hysteresis: Double) {
        self.threshold = threshold
        self.hysteresis = hysteresis
    }

    /// The configured start angle, lowered where needed so that the lid at
    /// `hingeLimit` reaches `threshold + hysteresis`. Every release rule then
    /// has a lid position that satisfies it, and the opening and dwell rules,
    /// which need only the threshold, keep `hysteresis` of margin should the
    /// limit sit a little high. Before the limit is known the setting stands.
    init(threshold: Double, hysteresis: Double, hingeLimit: Double?) {
        let reachable = hingeLimit.map { $0 - hysteresis } ?? .infinity
        self.init(threshold: min(threshold, reachable), hysteresis: hysteresis)
    }

    /// A lid held at or above this angle has been opened again, even when
    /// threshold + hysteresis is past what the hinge can reach. The threshold
    /// itself, so a hinge whose limit rounds to the threshold still releases.
    var dwellAngle: Double { threshold }

    /// How far the lid must have risen above its lowest reading of the run
    /// before opening speed alone releases the effect. A sensor that reports
    /// whole degrees moves in 1° steps, and one step over a sensor refresh
    /// already reads as fast opening. A lid resting on a half-degree boundary
    /// alternates between two readings, and this keeps that from flapping the
    /// effect on and off.
    static let minimumReleaseRise: Double = 1.5

    func wantsEffect(
        isEnabled: Bool,
        isActive: Bool,
        angle: Double,
        predictedAngle: Double,
        riseSinceLowest: Double,
        hasBeenAboveThreshold: Bool,
        wasClosingRecently: Bool,
        isClearlyOpening: Bool,
        hasDwelledOpen: Bool,
        minimumDurationElapsed: Bool,
        hasHeldShut: Bool = false
    ) -> Bool {
        guard isEnabled else { return false }

        if isActive {
            // A lid held shut ends the run, whatever the timeout is set to.
            if hasHeldShut { return false }

            // Deliberately opening back across the configured start angle is
            // sufficient to recover even when threshold + hysteresis cannot
            // be reached by the hardware. The rise rules out a single
            // whole-degree step; a smaller opening releases through the dwell.
            if isClearlyOpening, angle >= threshold, riseSinceLowest >= Self.minimumReleaseRise {
                return false
            }

            // An opening slower than that still ends with the lid held above
            // the start angle, which releases it too.
            if hasDwelledOpen { return false }

            // Keep the ordinary release hysteresis for stationary readings and
            // sensor jitter around the start angle.
            guard minimumDurationElapsed else { return true }
            return angle < threshold + hysteresis
        }

        // A resting or opening lid below the threshold must not start the
        // effect, including while an older closing observation is remembered.
        return hasBeenAboveThreshold
            && wasClosingRecently
            && !isClearlyOpening
            && predictedAngle <= threshold
    }
}

/// How far into the effect the lid is: from the start angle down to
/// `span` degrees further closed, where it reaches full strength.
struct LidEffectRamp {
    let startAngle: Double
    let span: Double
    /// Lid travel past the start angle at which the picture's lean tops out.
    let leanTravel: Double

    /// - Parameters:
    ///   - maxLean: the most the picture leans back, in degrees.
    ///   - recession: degrees of lean per degree of closing.
    init(startAngle: Double, span: Double, maxLean: Double = .infinity, recession: Double = 1) {
        self.startAngle = startAngle
        // No span at all would leave nothing to ramp over.
        self.span = max(span, 1)
        // A picture that does not lean has no lean to cap.
        leanTravel = recession > 0 ? max(maxLean, 1) / recession : .infinity
    }

    var fullEffectAngle: Double { startAngle - span }

    /// 0 at the start angle and above, 1 at the full-effect angle and below.
    func progress(at angle: Double) -> Double {
        min(max((startAngle - angle) / span, 0), 1)
    }

    /// The angle the picture is drawn at. It holds once the lean reaches its
    /// most, and at full strength, so the picture stops leaning back when the
    /// blur and dimming stop growing, rather than stretching on until the lid
    /// shuts.
    ///
    /// Perspective squeezes the far edge faster the further the picture
    /// leans, so equal steps of closing look like ever bigger ones. The lean
    /// eases into its cap rather than stopping dead.
    func pictureAngle(for angle: Double) -> Double {
        let travel = startAngle - angle
        guard travel > 0 else { return angle }
        let held = min(Self.softLimit(travel, limit: leanTravel, knee: leanTravel / 4), span)
        // Untouched until something holds it, to the last bit.
        return held == travel ? angle : startAngle - held
    }

    /// `value` up to `limit - knee`, then easing into `limit`, which it
    /// reaches at `limit + knee` and keeps. The slope runs smoothly from 1
    /// down to 0, so whatever follows it slows to a stop.
    static func softLimit(_ value: Double, limit: Double, knee: Double) -> Double {
        guard limit.isFinite else { return value }
        guard knee > 0 else { return min(value, limit) }
        if value <= limit - knee { return value }
        if value >= limit + knee { return limit }
        let over = value - (limit - knee)
        return value - over * over / (4 * knee)
    }
}
