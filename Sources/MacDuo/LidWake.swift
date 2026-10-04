import Foundation
import LidAngleKit
import QuartzCore

/// Whether a pushed lid reading is worth waking the main thread for.
///
/// Pushed readings are whole degrees, and a lid resting between two of them
/// flickers by one, so only a reading `margin` away from where the lid
/// rested wakes it, once per sleep. The wake carries the speed the last two
/// pushes measured, so the controller can act on its very first poll
/// instead of waiting for a second reading to measure one.
struct PushWakeFilter {
    var margin: Double = 1.5
    /// The precise angle the controller went to sleep at; `nil` while awake.
    private(set) var restingAngle: Double?
    private var lastPush: (degrees: Double, time: TimeInterval)?

    mutating func sleep(at angle: Double) {
        restingAngle = angle
    }

    mutating func wake() {
        restingAngle = nil
    }

    /// The speed to wake with, in degrees per second, or `nil` to stay asleep.
    mutating func receive(_ degrees: Double, at time: TimeInterval) -> Double? {
        let previous = lastPush
        lastPush = (degrees, time)
        guard let restingAngle, abs(degrees - restingAngle) >= margin else { return nil }
        self.restingAngle = nil
        // Two pushes in one burst, or a gap that spans a pause, measure
        // nothing.
        guard let previous, time - previous.time > 0.02, time - previous.time < 0.6 else { return 0 }
        return (degrees - previous.degrees) / (time - previous.time)
    }
}

/// When the controller can stop reading the sensor and wait for a pushed
/// reading to wake it.
struct LidWakePolicy {

    /// How long polling carries on after the lid last moved. Longer than
    /// the open dwell, so a slow opening still gets to release the effect.
    static let settleDuration: TimeInterval = 1.5

    /// With the effect on, a still lid pushes at the sensor's own refresh,
    /// wherever it rests: a fast close from fully open reaches the start
    /// angle in a quarter of a second, and a capture needs its head start.
    /// Measured, a process taking these readings shows no CPU time and no
    /// idle wakeups.
    static let enabledPushInterval: TimeInterval = 0.1

    /// With the effect off, readings only keep the shown angle roughly
    /// current.
    static let disabledPushInterval: TimeInterval = 0.5

    /// Whether anything still needs a fresh angle on every poll.
    func needsFreshAngles(
        isPreviewing: Bool,
        isClosingOut: Bool,
        isPanelOpen: Bool,
        isCapturePending: Bool,
        isPrewarming: Bool,
        isActive: Bool,
        capturesScreen: Bool,
        isTimeoutEnabled: Bool,
        isPictureSettled: Bool,
        sinceMovement: TimeInterval
    ) -> Bool {
        if isPreviewing || isClosingOut || isPanelOpen || isCapturePending { return true }
        // Only a poll ends a capture warmed up for a close that never came,
        // once its linger runs out.
        if isPrewarming { return true }
        if sinceMovement < Self.settleDuration { return true }
        guard isActive else { return false }
        // A capture keeps delivering frames, the timeout counts time, and a
        // picture still easing toward the lid has frames left to draw.
        return capturesScreen || isTimeoutEnabled || !isPictureSettled
    }

    func pushInterval(isEnabled: Bool) -> TimeInterval {
        isEnabled ? Self.enabledPushInterval : Self.disabledPushInterval
    }
}

/// Lets the controller stop polling while the lid is still.
///
/// The sensor pushes readings to a utility queue, where each is compared
/// with where the lid rested and dropped unless it moved, so the main thread
/// sleeps. Every reading also pushes back a deadline; if readings stop coming
/// (another process changed the interval, or the sensor came back from sleep
/// without it), the deadline wakes the controller to poll instead.
final class LidPushWatch: @unchecked Sendable {

    enum Wake {
        /// A reading away from where the lid rested, with the pushed speed.
        case moved(speed: Double)
        /// No reading arrived in time.
        case silent
    }

    private let queue = DispatchQueue(label: "MacDuo.lidPush", qos: .utility)
    private let lock = NSLock()
    private var filter = PushWakeFilter()
    private var lastPushTime: CFTimeInterval = -.greatestFiniteMagnitude
    private var silenceLimit: TimeInterval = 1
    private var silence: DispatchSourceTimer?
    /// Called on the push queue.
    private let onWake: (Wake) -> Void

    init(onWake: @escaping (Wake) -> Void) {
        self.onWake = onWake
    }

    /// Starts the pushed readings. False when the sensor cannot push, and
    /// the controller has to poll.
    func start(_ sensor: LidAngleSensor, interval: TimeInterval) -> Bool {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.fallSilent() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        lock.lock()
        silence = timer
        silenceLimit = Self.silenceLimit(for: interval)
        lock.unlock()
        let started = sensor.startPushing(interval: interval, queue: queue) { [weak self] degrees in
            self?.receive(degrees)
        }
        if !started {
            lock.lock()
            silence = nil
            lock.unlock()
            timer.cancel()
        }
        return started
    }

    /// True while readings keep arriving, so a still lid can be left to
    /// them.
    var isLive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return silence != nil && CACurrentMediaTime() - lastPushTime < silenceLimit
    }

    func sleep(at angle: Double) {
        lock.lock()
        filter.sleep(at: angle)
        lock.unlock()
    }

    func wake() {
        lock.lock()
        filter.wake()
        lock.unlock()
    }

    func setInterval(_ interval: TimeInterval, on sensor: LidAngleSensor) {
        lock.lock()
        silenceLimit = Self.silenceLimit(for: interval)
        lock.unlock()
        sensor.setPushInterval(interval)
    }

    /// While the Mac sleeps nothing listens, so the sensor goes back to its
    /// own once a second.
    func pause(_ sensor: LidAngleSensor) {
        wake()
        sensor.restorePushInterval()
    }

    /// Puts the interval back, and stops the readings for good.
    func stop(_ sensor: LidAngleSensor) {
        sensor.stopPushing()
        lock.lock()
        let timer = silence
        silence = nil
        lock.unlock()
        timer?.cancel()
    }

    /// Three intervals and some slack: one late reading is not silence.
    private static func silenceLimit(for interval: TimeInterval) -> TimeInterval {
        3 * interval + 0.5
    }

    private func receive(_ degrees: Double) {
        let now = CACurrentMediaTime()
        lock.lock()
        lastPushTime = now
        let speed = filter.receive(degrees, at: now)
        let limit = silenceLimit
        let timer = silence
        lock.unlock()
        timer?.schedule(deadline: .now() + limit, leeway: .milliseconds(250))
        if let speed { onWake(.moved(speed: speed)) }
    }

    private func fallSilent() {
        lock.lock()
        let wasAsleep = filter.restingAngle != nil
        filter.wake()
        lock.unlock()
        if wasAsleep { onWake(.silent) }
    }
}
