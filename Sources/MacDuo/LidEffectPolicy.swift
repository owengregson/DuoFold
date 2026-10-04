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

    /// No hinge opens past flat. A reading outside this is a sensor fault.
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
        minimumDurationElapsed: Bool
    ) -> Bool {
        guard isEnabled else { return false }

        if isActive {
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
