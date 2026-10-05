import AppKit
import Combine
import LidAngleKit
import QuartzCore

/// Watches the lid angle and drives the depth effect overlay.
///
/// A timer polls the sensor, and a display link asks `LidAngleEstimator`
/// where the lid is at every screen refresh, so the ramp stays smooth between
/// readings.

/// Identity of the built-in display. `NSApplication` posts a screen change for
/// a backlight change too, and this tells the two apart.
struct Layout: Equatable {
    var displayID: CGDirectDisplayID?
    var frame: CGRect?
}

@MainActor
final class LidController: ObservableObject {

    @Published private(set) var currentAngle: Double = 0
    @Published private(set) var isSensorAvailable = false
    @Published private(set) var isActive = false
    /// `hinge.angle`, published for the settings panel. `hinge` itself
    /// changes on every reading.
    @Published private(set) var hingeLimit: Double?

    let snapshotter = ScreenSnapshotter()

    private let preferences: Preferences
    private let sensor = LidAngleSensor()
    private let overlay = DepthOverlay()
    private let streamer = ScreenStreamer()
    private let escapeKey = EscapeKey()
    private let haptics = TrackpadHaptics()
    /// The taps of the current run, if haptics are on.
    private var hapticTrack: HapticTrack?
    private var hinge: LidHingeLimit

    /// Keeps the sensor read on every poll while the settings panel shows
    /// the live angle.
    var isPanelOpen = false {
        didSet { if isPanelOpen { wake() } }
    }

    /// Pushed readings land on a utility queue and only wake the main
    /// thread when the lid moves.
    private lazy var pushWatch = LidPushWatch { [weak self] wake in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.wake(from: wake) }
        }
    }
    private let wakePolicy = LidWakePolicy()
    private let picturePolicy = LidPicturePolicy()
    private var pushInterval: TimeInterval = 0
    private var lastMovementAngle: Double = 0
    private var lastMovementTime: CFTimeInterval = 0

    private var enabledSubscription: AnyCancellable?
    private var captureSubscription: AnyCancellable?
    private var pictureTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var lastPublishTime: CFTimeInterval = 0

    private var rawAngle: Double = 0
    private var motion = LidMotion()
    /// The angle the picture shows. While it follows the lid the estimator
    /// sets it every frame; the ease back to flat springs it on from there.
    private var visualAngle = CriticallyDampedSpring(frequency: 24)
    /// Fills in the readings, one angle for every frame.
    private var estimator = LidAngleEstimator(tuning: .sensor(resolution: 0.01))
    /// Whether the estimator follows the preview's script rather than the
    /// sensor, so a switch either way starts it afresh.
    private var estimatorFollowsScript = false
    private var consecutiveFailedReads = 0
    private var startedAt: CFTimeInterval = 0
    private var preview: PreviewRun?
    private var isSuspended = false
    private var isCapturePending = false
    private var openDwell = LidOpenDwell()
    private var shutHold = LidShutHold()
    /// Set when a lid held shut ended the run: the lid opening brings it
    /// back at full strength.
    private var opensFromShut = false
    private lazy var clamshellWatch = LidClamshellWatch { [weak self] isShut in
        MainActor.assumeIsolated {
            guard !isShut else { return }
            self?.reopenFromShut(cause: "macOS reported the lid open")
        }
    }
    /// Where the lid last moved to by more than `timeoutMovementThreshold`,
    /// and when. The timeout counts from there.
    private var timeoutReferenceAngle: Double?
    private var timeoutReferenceTime: CFTimeInterval = 0
    /// Engaged when the timeout or Escape ends the effect, released once the
    /// lid rises back above the threshold.
    private var reopenLatch = LidReopenLatch()
    /// The setting as last seen, so flipping it drops stale tracking.
    private var wasTimeoutEnabled = false
    /// True while `beginClosingOut()` is easing the picture back to flat.
    private var isClosingOut = false
    private var closingOutStartedAt: CFTimeInterval = 0
    private var builtInLayout = Layout()
    private var peakAngle: Double = 0
    /// The lowest reading since the effect started. Opening releases only
    /// once the lid has risen `LidEffectPolicy.minimumReleaseRise` above it.
    private var lowestRunAngle: Double = 0
    /// Until the run's first frame with any effect, which is logged.
    private var awaitsFirstEffect = false

    private static let idlePollInterval: TimeInterval = 1.0 / 8
    private static let activePollInterval: TimeInterval = 1.0 / 30
    /// The sensor takes a reading every 104 ms however often it is read, but
    /// the sooner a poll finds one, the less the picture has to guess. At 60
    /// a second a moving lid's readings turn up 8 ms sooner on average, which
    /// in a simulation of the sensor takes about a fifth off how far the
    /// picture runs past a sudden stop. A read is a round trip of about a
    /// millisecond to the sensor, so only while a picture follows a moving
    /// lid.
    private static let movingPollInterval: TimeInterval = 1.0 / 60
    /// How far a speed measured from two whole degree pushes can be off,
    /// squared: a degree's rounding over a tenth of a second.
    private static let pushedSpeedVariance: Double = 100
    /// Degrees above the pre-warm zone at which polling speeds up.
    private static let fastPollMargin: Double = 20

    /// A change this large counts as the lid moving, for how long polling
    /// carries on before waiting for pushed readings.
    private static let movementThreshold: Double = 0.3

    /// How long after the lid last moved down the effect may still start.
    private static let closingMemory: TimeInterval = 1.5

    /// The ordinary hysteresis release waits this long, but deliberate
    /// opening is allowed to release immediately.
    private static let minimumEffectDuration: TimeInterval = 0.35

    /// How long a lid held above the start angle waits before it counts as
    /// opened again, for openings slower than `LidMotion.triggerOpeningSpeed`.
    private static let openDwellDuration: TimeInterval = 1

    /// Movement within this many degrees counts as holding still.
    private static let timeoutMovementThreshold: Double = 2

    /// How long the lid has to hold still before the timeout ends the effect.
    private static let timeoutStillDuration: TimeInterval = 2

    /// How close the eased angle must get to flat before the last frame
    /// snaps there. Half a degree short, the dim curve still darkens the top
    /// of the picture by several percent, and the fade would then reveal a
    /// brighter screen underneath.
    private static let closingOutSettleEpsilon: Double = 0.05

    /// Safety cap, in case the spring never quite settles.
    private static let closingOutMaxDuration: TimeInterval = 1.2

    /// A scripted angle sweep, so the settings panel can show the effect
    /// without the lid moving. It feeds the same path the sensor feeds.
    private struct PreviewRun {
        let startedAt: CFTimeInterval
        let open: Double
        let shut: Double
        var closing: CFTimeInterval = 1.4
        var hold: CFTimeInterval = 0.8
        var opening: CFTimeInterval = 0.6

        /// `nil` once the run is over.
        func angle(at now: CFTimeInterval) -> Double? {
            let elapsed = now - startedAt
            if elapsed < closing { return open + (shut - open) * (elapsed / closing) }
            if elapsed < closing + hold { return shut }
            if elapsed < closing + hold + opening {
                return shut + (open - shut) * ((elapsed - closing - hold) / opening)
            }
            return nil
        }
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        hinge = LidHingeLimit(angle: preferences.hingeLimit)
        hingeLimit = hinge.angle
        enabledSubscription = preferences.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard !enabled else { return }
                self?.disableEffect()
            }
        escapeKey.onPress = { [weak self] in self?.escape() }
        captureSubscription = preferences.$capturesScreen
            .removeDuplicates()
            .dropFirst()
            // After the change lands: the publisher fires before it does.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.switchRendering() }
            }
    }

    /// True when the effect is drawn from a screen capture: when the setting
    /// asks for it, or when the window server cannot draw the glass.
    var capturesScreen: Bool {
        preferences.capturesScreen || !WindowServerBlur.isAvailable
    }

    // MARK: - Lifecycle

    func start() {
        isSensorAvailable = sensor.isAvailable
        guard isSensorAvailable else { return }

        estimator.reset(tuning: sensorTuning)
        if let angle = sensor.angle() {
            rawAngle = angle
            currentAngle = max(angle, 0)
            visualAngle.reset(to: angle)
            estimator.observe(angle, at: CACurrentMediaTime())
        }
        // Before the first poll, which reads it.
        builtInLayout = Layout(displayID: NSScreen.builtIn?.displayID, frame: NSScreen.builtIn?.frame)
        pushInterval = LidWakePolicy.enabledPushInterval
        let pushes = pushWatch.start(sensor, interval: pushInterval)
        Diagnostics.lid.notice("sensor pushes readings: \(pushes)")
        setPollInterval(Self.idlePollInterval)
        observeSystemEvents()
        Diagnostics.lid.notice("listening for the lid opening: \(self.clamshellWatch.start())")
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("to.maki.MacDuo.preview"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPreview() }
        }
        // The same sweep held at a strength, its object, for a while: long
        // enough to look at, or to take a screenshot of.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("to.maki.MacDuo.preview.hold"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let progress = (note.object as? String).flatMap(Double.init) ?? 1
            MainActor.assumeIsolated { self?.runPreview(holdingAt: progress) }
        }
        // The glass captures nothing, so it never touches ScreenCaptureKit
        // and never asks for Screen Recording.
        prepareGlass()
        if capturesScreen { warmCapture() }
    }

    private func warmCapture() {
        overlay.warmUp()
        Task {
            await snapshotter.warmFilter()
            // After the overlay has put its presence window up, so the filter
            // can name this app and leave the overlay out of the picture.
            try? await Task.sleep(nanoseconds: 500_000_000)
            await streamer.warmFilter()
        }
    }

    /// Has the glass built and waiting, hidden, for the next close. In
    /// capture mode too: it covers the start until the capture arrives.
    private func prepareGlass() {
        guard let screen = NSScreen.builtIn else { return }
        overlay.prepareGlass(on: screen)
    }

    private func switchRendering() {
        Diagnostics.lid.notice("rendering switched, captures screen: \(self.capturesScreen)")
        stopEffectAndCapture()
        guard isSensorAvailable else { return }
        prepareGlass()
        if capturesScreen { warmCapture() }
    }

    /// Has the capture under way for a close that looks about to reach the
    /// start angle: the stream takes 25 to 45 ms to start, and a screenshot
    /// 50 to 75 ms to land. For the first reading that shows the lid
    /// closing, ahead of the start decision. The pre-warm's own rules end
    /// the capture if the close never comes, so only call it with a measured
    /// closing speed, which sets the time they count from. The glass needs
    /// no arming: it is built and waiting.
    func armPicture() {
        guard preferences.isEnabled, !isSuspended, !isActive, capturesScreen else { return }
        warmPicture()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = 0
        stopEffectAndCapture()
        // The report interval outlives this process.
        pushWatch.stop(sensor)
    }

    private func stopEffectAndCapture() {
        pictureTask?.cancel()
        pictureTask = nil
        isCapturePending = false
        isClosingOut = false
        stopDisplayLink()
        overlay.dismiss(animated: false)
        snapshotter.stop()
        streamer.stop()
        overlay.discardLive()
        preview = nil
        isActive = false
        opensFromShut = false
        endHaptics()
        updateEscapeKey()
    }

    private func disableEffect() {
        stopEffectAndCapture()
        motion.reset()
        openDwell.reset()
        shutHold.reset()
        peakAngle = 0
        if pollTimer != nil { setPollInterval(Self.idlePollInterval) }
    }

    /// Plays the effect once on the current screen contents.
    /// - Parameter progress: a strength to stop at and hold for
    ///   `previewHold`, rather than sweeping past full strength and back.
    func runPreview(holdingAt progress: Double? = nil) {
        guard preferences.isEnabled, !isSuspended, preview == nil, !isActive else { return }
        // Well above the trigger angle, so the sweep runs the pre-warm the way
        // a real close does.
        let threshold = effectiveThreshold
        var run = PreviewRun(
            startedAt: CACurrentMediaTime(),
            open: max(
                threshold + preferences.hysteresis + 5,
                min(threshold + 35, 130)
            ),
            shut: max(threshold - preferences.blurSpan * 1.15, 5)
        )
        if let progress {
            run = PreviewRun(
                startedAt: run.startedAt,
                open: run.open,
                shut: threshold - min(max(progress, 0), 1) * preferences.blurSpan,
                hold: Self.previewHold
            )
        }
        preview = run
        wake()
    }

    private static let previewHold: CFTimeInterval = 12

    /// Ends the run at once. The settings panel is under the picture, and a
    /// lid or sensor that will not read back past the start angle would
    /// otherwise leave only the timeout, which can be off.
    private func escape() {
        guard isActive else { return }
        Diagnostics.lid.notice("end: escape pressed, raw \(self.rawAngle, format: .fixed(precision: 2))")
        // A preview cut short ends the way a finished one does.
        if preview != nil {
            preview = nil
            peakAngle = 0
        }
        reopenLatch.engage()
        setActive(false)
        // Escape asks for the screen back now, not after the ease to flat.
        if isClosingOut { finishClosingOut() }
    }

    // MARK: - Polling

    private func setPollInterval(_ interval: TimeInterval) {
        guard pollInterval != interval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard !isSuspended else { return }

        let angle: Double
        let readAt: CFTimeInterval
        if let run = preview {
            readAt = CACurrentMediaTime()
            guard let scripted = run.angle(at: readAt) else {
                preview = nil
                peakAngle = 0
                // The next reading is the real lid, and the jump to it from
                // the sweep's last angle would read as a fast close.
                motion.reset()
                if isActive { setActive(false) }
                return
            }
            angle = scripted
        } else {
            let asked = CACurrentMediaTime()
            guard let read = sensor.angle() else {
                consecutiveFailedReads += 1
                if consecutiveFailedReads > 30, isActive {
                    Diagnostics.lid.notice(
                        """
                        release: sensor read failed \(self.consecutiveFailedReads) times in a row, \
                        last angle \(self.rawAngle, format: .fixed(precision: 2))
                        """
                    )
                    setActive(false)
                }
                return
            }
            if consecutiveFailedReads > 0 {
                Diagnostics.lid.notice(
                    "sensor recovered after \(self.consecutiveFailedReads) failed reads, angle \(read, format: .fixed(precision: 2))"
                )
            }
            consecutiveFailedReads = 0
            angle = read
            // Halfway through the round trip, about when the sensor answered.
            readAt = (asked + CACurrentMediaTime()) / 2
            learnHinge(from: read)
        }

        rawAngle = angle
        feedEstimator(angle, at: readAt)
        peakAngle = max(peakAngle, angle)
        if isActive { lowestRunAngle = min(lowestRunAngle, angle) }
        publish(angle: angle)

        // With no picture up there is no frame to follow, so the readings
        // drive the taps.
        if displayLink == nil { followHaptics(angle: angle) }

        if preferences.isEnabled {
            motion.update(with: angle, at: CACurrentMediaTime(), prewarmSpeed: preferences.closingSpeed)
            openDwell.update(angle: angle, at: CACurrentMediaTime(), dwellAngle: effectPolicy.dwellAngle)
            shutHold.update(angle: angle, at: CACurrentMediaTime())
            reconcile(angle: angle)
        }
        updateEscapeKey()

        schedulePolling(angle: angle)
    }

    /// Polls while anything needs fresh angles, and otherwise sleeps until a
    /// pushed reading shows the lid moving. A sensor that cannot push, or
    /// whose readings stopped, is polled as before.
    private func schedulePolling(angle: Double) {
        let now = CACurrentMediaTime()
        if abs(angle - lastMovementAngle) >= Self.movementThreshold {
            lastMovementAngle = angle
            lastMovementTime = now
        }
        // Only the display link finishes the ease back to flat, and a link
        // whose window lost its screen stops firing.
        if isClosingOut, now - closingOutStartedAt > 2 * Self.closingOutMaxDuration {
            Diagnostics.lid.notice("closing out never settled, finishing it")
            finishClosingOut()
        }
        let needsAngles = wakePolicy.needsFreshAngles(
            isPreviewing: preview != nil,
            isClosingOut: isClosingOut,
            isPanelOpen: isPanelOpen,
            isCapturePending: isCapturePending,
            isPrewarming: snapshotter.isPrewarming || streamer.isStarted,
            isActive: isActive,
            capturesScreen: capturesScreen,
            isTimeoutEnabled: preferences.isTimeoutEnabled,
            isShut: shutHold.isShut,
            isPictureSettled: estimator.isSettled(at: now),
            sinceMovement: now - lastMovementTime
        )
        if !needsAngles, pushWatch.isLive {
            sleep(at: angle)
            return
        }
        // The preview's script is exact whenever it is read.
        if isActive, !isClosingOut, displayLink != nil, preview == nil, estimator.isMoving {
            setPollInterval(Self.movingPollInterval)
            return
        }
        let prewarmZone = effectiveThreshold + preferences.prewarmCeiling
        let wantsFastPolling = preferences.isEnabled
            && (preview != nil || isActive || angle <= prewarmZone + Self.fastPollMargin)
        setPollInterval(wantsFastPolling ? Self.activePollInterval : Self.idlePollInterval)
    }

    /// Only sensor readings count. The preview sweeps past where any hinge
    /// stops.
    private func learnHinge(from reading: Double) {
        guard hinge.observe(reading, at: CACurrentMediaTime()), let limit = hinge.angle else { return }
        hingeLimit = limit
        preferences.hingeLimit = limit
        Diagnostics.lid.notice("hinge limit now \(limit, format: .fixed(precision: 2))")
    }

    /// The estimator's tuning for this Mac's sensor.
    private var sensorTuning: LidAngleEstimator.Tuning {
        .sensor(resolution: sensor.resolution == .wholeDegrees ? 1 : 0.01)
    }

    /// Hands a reading to the estimator, starting it afresh whenever the
    /// readings switch between the sensor and the preview's script.
    private func feedEstimator(_ angle: Double, at time: CFTimeInterval) {
        if (preview != nil) != estimatorFollowsScript {
            estimatorFollowsScript = preview != nil
            estimator.reset(tuning: estimatorFollowsScript
                ? .script(pollInterval: Self.activePollInterval)
                : sensorTuning)
        }
        estimator.observe(angle, at: time)
    }

    /// Stops polling until a pushed reading shows the lid moving.
    private func sleep(at angle: Double) {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = 0
        // A still picture needs no frames: the window server keeps the glass
        // live. A wake restarts the link through `reconcile`.
        stopDisplayLink()
        pushWatch.sleep(at: angle)
        let interval = wakePolicy.pushInterval(isEnabled: preferences.isEnabled)
        if interval != pushInterval {
            pushInterval = interval
            pushWatch.setInterval(interval, on: sensor)
        }
    }

    /// Starts polling again, from sleep or not.
    private func wake() {
        guard isSensorAvailable, !isSuspended else { return }
        pushWatch.wake()
        lastMovementTime = CACurrentMediaTime()
        setPollInterval(Self.activePollInterval)
    }

    private func wake(from push: LidPushWatch.Wake) {
        guard !isSuspended else { return }
        switch push {
        case .moved(let speed):
            // Act on this reading rather than a poll later, starting from the
            // speed the pushes measured: one reading cannot measure one.
            let now = CACurrentMediaTime()
            motion.wake(speed: speed, at: now, prewarmSpeed: preferences.closingSpeed)
            // The picture, if one is up, carries on from where it rests. A
            // speed of zero is one the pushes could not measure.
            if preview == nil {
                estimator.resume(speed: speed, variance: speed == 0 ? nil : Self.pushedSpeedVariance, at: now)
            }
            wake()
            poll()
        case .silent:
            Diagnostics.lid.notice("pushed readings stopped, polling until they return")
            pushWatch.setInterval(pushInterval, on: sensor)
            if preview == nil { estimator.resume(at: CACurrentMediaTime()) }
            wake()
        }
    }

    private var effectPolicy: LidEffectPolicy {
        LidEffectPolicy(
            threshold: preferences.thresholdAngle,
            hysteresis: preferences.hysteresis,
            hingeLimit: hingeLimit
        )
    }

    /// The start angle in force: the setting, unless the lid does not open far
    /// enough past it for the effect to be released.
    var effectiveThreshold: Double {
        effectPolicy.threshold
    }

    /// Escape belongs to other apps except while a run's picture covers the
    /// screen. The ease back to flat ends by itself and leaves the key alone.
    private func updateEscapeKey() {
        escapeKey.isArmed = isActive && overlay.isRevealed
    }

    /// Whether the picture belongs on screen for this angle. It widens the
    /// angle for release and keeps a lid held below the angle showing, unless
    /// the timeout ends it first.
    private func wantsEffect(angle: Double) -> Bool {
        // `builtInLayout` is kept current by the screen change observer, so
        // this does not enumerate the screens on every sample.
        guard preferences.isEnabled, builtInLayout.displayID != nil else { return false }
        if preferences.isTimeoutEnabled != wasTimeoutEnabled {
            timeoutReferenceAngle = nil
            wasTimeoutEnabled = preferences.isTimeoutEnabled
        }

        let now = CACurrentMediaTime()
        let policy = effectPolicy
        let threshold = policy.threshold
        let minimumDurationElapsed = now - startedAt > Self.minimumEffectDuration

        if !isActive, !reopenLatch.allowsStart(angle: angle, threshold: threshold) {
            return false
        }

        // A start goes on the estimator, which turns round with the lid. The
        // release keeps to the averaged speed its one-step rule is set for.
        let approach = self.approach
        let wanted = policy.wantsEffect(
            isEnabled: preferences.isEnabled,
            isActive: isActive,
            angle: angle,
            estimatedAngle: approach.angle,
            riseSinceLowest: angle - lowestRunAngle,
            hasBeenAboveThreshold: peakAngle >= threshold,
            wasClosingRecently: approach.isClosing || motion.intent.wasClosingRecently(
                at: now,
                memoryDuration: Self.closingMemory
            ),
            isClearlyOpening: isActive ? motion.isClearlyOpening : approach.isOpening,
            hasDwelledOpen: openDwell.hasDwelled(at: now, duration: Self.openDwellDuration),
            minimumDurationElapsed: minimumDurationElapsed
        )

        // The timeout only cuts short a run the policy would keep showing. A
        // shut lid is not held still on the picture: it parks the run, so the
        // opening still plays, and the count starts afresh once it opens.
        if shutHold.isShut { timeoutReferenceAngle = nil }
        if isActive, wanted, minimumDurationElapsed, !shutHold.isShut,
           preferences.isTimeoutEnabled, isPastTimeout(angle: angle) {
            reopenLatch.engage()
            return false
        }
        return wanted
    }

    /// What a start goes on.
    private var approach: LidApproach {
        LidApproach(estimator) ?? LidApproach(angle: rawAngle, speed: motion.velocity)
    }

    /// True once the angle has held within `timeoutMovementThreshold` of its
    /// last significant position for `timeoutStillDuration`.
    private func isPastTimeout(angle: Double) -> Bool {
        let now = CACurrentMediaTime()
        if let reference = timeoutReferenceAngle,
           abs(angle - reference) <= Self.timeoutMovementThreshold {
            return now - timeoutReferenceTime >= Self.timeoutStillDuration
        }
        timeoutReferenceAngle = angle
        timeoutReferenceTime = now
        return false
    }

    /// Brings the screen in line with `wantsEffect` on every sample. A run
    /// whose screenshot failed is retried here.
    private func reconcile(angle: Double) {
        guard preferences.isEnabled, !isSuspended else { return }
        // Should the lid open with no word from macOS, the reading brings the
        // run back instead.
        if !isActive, opensFromShut, !shutHold.isShut {
            reopenFromShut(cause: "a reading showed the lid open")
            return
        }
        let wanted = wantsEffect(angle: angle)
        if wanted != isActive {
            let approach = self.approach
            Diagnostics.lid.notice(
                """
                \(wanted ? "start" : "end", privacy: .public) raw \(angle, format: .fixed(precision: 2)) \
                estimate \(approach.angle, format: .fixed(precision: 2)) \
                at \(approach.speed, format: .fixed(precision: 1)) deg/s, \
                velocity \(self.motion.velocity, format: .fixed(precision: 1)) deg/s \
                snapshot \(self.snapshotter.latestImage != nil)
                """
            )
            setActive(wanted)
            return
        }
        if isActive {
            if shutHold.hasHeld(at: CACurrentMediaTime()) {
                endShut()
                return
            }
            if capturesScreen, preferences.isLivePicture { streamer.start() }
            if !overlay.isVisible, !isCapturePending { presentPicture() }
            // A visible overlay with no link would sit at its first frame.
            if overlay.isVisible, displayLink == nil { startDisplayLink() }
        } else if !isClosingOut {
            // The ease back to flat still draws the live picture, and this
            // would free it.
            updatePrewarm(angle: angle, ceiling: effectiveThreshold + preferences.prewarmCeiling)
        }
    }

    /// Ends a run on a lid held shut: the screen is dark, so nothing of it
    /// need go on, not the picture, the capture, the frames or the polling,
    /// and nothing of it is left over the screen, which a remote session can
    /// still be using. The lid opening brings it back (`reopenFromShut`).
    private func endShut() {
        Diagnostics.lid.notice("end: lid held shut, raw \(self.rawAngle, format: .fixed(precision: 2))")
        setActive(false)
        snapshotter.endPrewarm()
        streamer.stop()
        overlay.discardLive()
        opensFromShut = true
    }

    /// Brings back, at full strength, a run that a shut lid ended. macOS
    /// lights the screen as it reports the lid open, before a reading of
    /// ours can show the lid moving, so the run goes up then, as the lid was
    /// when it shut. The glass goes up at once: it shows the screen as it is
    /// now, where anything captured before the lid shut may be out of date,
    /// a remote session having used the screen meanwhile. The captured
    /// picture takes over on the capture's first new frame, and follows the
    /// lid out from the readings that come.
    private func reopenFromShut(cause: StaticString) {
        guard opensFromShut, !isActive, preferences.isEnabled, !isSuspended else { return }
        opensFromShut = false
        // A lid found already past the start angle has nothing to unwind.
        guard rawAngle < effectiveThreshold else { return }
        Diagnostics.lid.notice("reopen: \(cause, privacy: .public), raw \(self.rawAngle, format: .fixed(precision: 2))")
        // The shut lid's count starts over, or the next poll would end the
        // run again before a reading shows the lid open.
        shutHold.reset()
        if preview == nil { estimator.resume(at: CACurrentMediaTime()) }
        setActive(true)
        // Drawn now, not at the next refresh, which may not come before the
        // screen lights.
        applyVisual(angle: rawAngle)
        wake()
    }

    /// Runs only while the lid is closing, so holding it still does not leave
    /// a capture loop running.
    private func updatePrewarm(angle: Double, ceiling: Double) {
        let closingRecently = CACurrentMediaTime() - motion.lastClosingTime < preferences.prewarmLinger
        // The glass has nothing to warm up.
        // A shut lid warms nothing: its screen is dark until it opens.
        guard capturesScreen, angle <= ceiling, closingRecently, !shutHold.isShut else {
            snapshotter.endPrewarm()
            streamer.stop()
            overlay.discardLive()
            return
        }
        warmPicture()
    }

    /// Starts the capture the picture will be drawn from, or keeps it going.
    private func warmPicture() {
        guard preferences.isLivePicture else {
            streamer.stop()
            overlay.discardLive()
            snapshotter.beginPrewarm(interval: preferences.prewarmInterval)
            return
        }
        // Only the stream. Asking ScreenCaptureKit for a screenshot at the
        // same time makes it serve neither quickly.
        snapshotter.endPrewarm()
        streamer.start()
    }

    private func publish(angle: Double) {
        let now = CACurrentMediaTime()
        guard now - lastPublishTime > 0.08 else { return }
        lastPublishTime = now
        // A lid pressed shut reads a little under zero, which would show as -1°.
        let shown = max(angle, 0)
        if abs(currentAngle - shown) > 0.001 { currentAngle = shown }
    }

    // MARK: - Depth effect

    private func setActive(_ active: Bool) {
        isActive = active
        if active {
            peakAngle = rawAngle
            lowestRunAngle = rawAngle
            openDwell.reset()
            isClosingOut = false
            startedAt = CACurrentMediaTime()
            if preferences.isTimeoutEnabled {
                timeoutReferenceAngle = rawAngle
                timeoutReferenceTime = startedAt
            }
            visualAngle.reset(to: rawAngle)
            // What is on screen as a run starts is nothing, or the ease back
            // to flat, never the estimator's picture. The run starts where the
            // lid is, rather than easing in from where that picture rested or
            // ran on past a reversal.
            estimator.rejoin(at: startedAt)
            awaitsFirstEffect = true
            snapshotter.endPrewarm()
            setPollInterval(Self.activePollInterval)
            beginHaptics()
            presentPicture()
        } else {
            snapshotter.discard()
            timeoutReferenceAngle = nil
            endHaptics()
            beginClosingOut()
        }
        updateEscapeKey()
    }

    /// Eases the picture back to flat before the overlay fades away. Ending
    /// the effect with the lid still shut would otherwise fade out a warped
    /// picture. `step(_:)` drives the ease and calls `finishClosingOut()`.
    private func beginClosingOut() {
        // Nothing to ease before the picture is up, or with no link to draw
        // it, and no one to ease it for on a shut lid, whose screen is dark.
        guard overlay.isVisible, displayLink != nil, !shutHold.isShut else {
            stopDisplayLink()
            overlay.dismiss(animated: !shutHold.isShut)
            return
        }
        isClosingOut = true
        closingOutStartedAt = CACurrentMediaTime()
    }

    private func finishClosingOut() {
        isClosingOut = false
        stopDisplayLink()
        overlay.dismiss(animated: true)
    }

    private func endEffect() {
        setActive(false)
    }

    /// Puts the effect up as `LidPicturePolicy` plans it: the glass at once
    /// where it can be, and the captured picture over it once there is one.
    /// The next sample tries again if nothing could go up yet.
    private func presentPicture() {
        guard preferences.isEnabled, !isSuspended, isActive, let screen = NSScreen.builtIn else { return }
        let plan = picturePlan
        if plan.first != .pictureAlone {
            guard overlay.showGlass(on: screen, startAngle: effectiveThreshold, tuning: tuning) else { return }
            // Its first frame on screen shows the lid as it is, rather than
            // no effect until the link draws: a run unparked as the lid opens
            // is at full strength.
            applyVisual(angle: estimator.hasReading ? estimator.motion(at: CACurrentMediaTime()).angle : rawAngle)
            if plan.first == .glass {
                startDisplayLink()
                return
            }
        }
        if preferences.isLivePicture {
            // Now rather than at the next sample, which would be 30 ms on.
            streamer.start()
            guard overlay.showLive(on: screen, startAngle: effectiveThreshold, tuning: tuning, fadeIn: plan.fadeIn) else {
                // The glass, if it went up, is the run.
                if overlay.isVisible { startDisplayLink() }
                return
            }
            startDisplayLink()
            if let frame = streamer.newFrame() {
                Diagnostics.lid.notice("present: live, a stream frame was ready")
                overlay.absorb(frame)
            } else if !plan.seedsFromScreenshot {
                Diagnostics.lid.notice("present: live over the glass, waiting for the stream")
            } else if let image = snapshotter.latestImage {
                // A fast close can reach the trigger angle before the stream
                // has a frame. One screenshot starts the picture off.
                Diagnostics.lid.notice("present: live, seeding from the pre-warm screenshot")
                overlay.seed(image: image)
            } else {
                Diagnostics.lid.notice("present: live, no picture yet, asking for a screenshot")
                requestSeed()
            }
            return
        }

        if let image = snapshotter.latestImage, let screen = snapshotter.latestScreen {
            show(image: image, on: screen)
            return
        }
        // The glass, if it went up, follows the lid while the screenshot
        // is taken.
        if overlay.isVisible { startDisplayLink() }
        isCapturePending = true
        pictureTask?.cancel()
        pictureTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.snapshotter.captureOnce()
            guard !Task.isCancelled else { return }
            self.pictureTask = nil
            self.isCapturePending = false
            Diagnostics.lid.notice(
                """
                capture landed: image \(self.snapshotter.latestImage != nil) \
                on \(self.isActive) overlay \(self.overlay.isVisible)
                """
            )
            guard self.isActive, !self.overlay.showsCapturedPicture,
                  let image = self.snapshotter.latestImage,
                  let screen = self.snapshotter.latestScreen else { return }
            self.show(image: image, on: screen)
        }
    }

    private var picturePlan: LidPicturePolicy.Plan {
        picturePolicy.plan(
            capturesScreen: capturesScreen,
            isGlassAvailable: WindowServerBlur.isAvailable,
            isLivePicture: preferences.isLivePicture,
            hasStreamFrame: streamer.hasFrame
        )
    }

    /// Takes one screenshot to start a live overlay that has nothing to show
    /// yet. A stream frame that lands first makes it unnecessary.
    private func requestSeed() {
        isCapturePending = true
        let started = CACurrentMediaTime()
        pictureTask?.cancel()
        pictureTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.snapshotter.captureOnce()
            guard !Task.isCancelled else { return }
            self.pictureTask = nil
            self.isCapturePending = false
            Diagnostics.lid.notice(
                """
                seed capture landed after \((CACurrentMediaTime() - started) * 1000, format: .fixed(precision: 0)) ms: \
                image \(self.snapshotter.latestImage != nil) on \(self.isActive) \
                ready \(self.overlay.isPictureReady)
                """
            )
            guard self.isActive, !self.overlay.isPictureReady,
                  let image = self.snapshotter.latestImage else { return }
            self.overlay.seed(image: image)
        }
    }

    private func show(image: CGImage, on screen: NSScreen) {
        overlay.show(
            image: image,
            on: screen,
            startAngle: effectiveThreshold,
            tuning: tuning,
            fadeIn: picturePlan.fadeIn
        )
        // The link belongs to the overlay window.
        startDisplayLink()
    }

    private var ramp: LidEffectRamp {
        LidEffectRamp(
            startAngle: effectiveThreshold,
            span: preferences.blurSpan,
            maxLean: preferences.maxLean,
            recession: preferences.recession
        )
    }

    private func blurProgress(for angle: Double) -> Double {
        ramp.progress(at: angle)
    }

    // MARK: - Haptics

    private var hapticPattern: HapticPattern {
        HapticPattern(
            style: HapticPattern.Style(rawValue: preferences.hapticStyle) ?? .exponential,
            taps: Int(preferences.hapticTaps.rounded()),
            strength: preferences.hapticStrength
        )
    }

    private func beginHaptics() {
        guard preferences.isHapticsEnabled else {
            hapticTrack = nil
            return
        }
        hapticTrack = HapticTrack(
            pattern: hapticPattern,
            progress: blurProgress(for: rawAngle),
            followsOpening: preferences.isHapticsOnOpening
        )
        followHaptics(angle: rawAngle)
    }

    private func followHaptics(angle: Double) {
        guard isActive, let strength = hapticTrack?.advance(to: blurProgress(for: angle)) else { return }
        haptics.tap(strength: strength)
    }

    private func endHaptics() {
        guard hapticTrack != nil else { return }
        hapticTrack = nil
        haptics.rest()
    }

    /// Plays the chosen pattern over one quick close, for the settings panel.
    func tryHaptics() {
        haptics.play(hapticPattern, over: 1.2)
    }

    // MARK: - Animation

    private func startDisplayLink() {
        stopDisplayLink()
        guard let window = overlay.hostWindow else {
            Diagnostics.lid.notice("display link skipped, no overlay window")
            return
        }
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        // Every refresh the screen has, 120 a second on ProMotion: the
        // estimate is new at every frame while the lid moves, and a frame
        // that would look the same as the last is not drawn.
        let fastest = Float(window.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, fastest), maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        Diagnostics.lid.notice("display link started, up to \(Int(fastest)) fps")
        lastFrameTime = CACurrentMediaTime()
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// One line a second while the glass is up: how many frames were drawn,
    /// how many laid the glass out afresh, the angles drawn, and whether the
    /// sensor was being polled, to tell a still effect from a restless one.
    private struct GlassFrameLog {
        var started: CFTimeInterval = 0
        var frames = 0
        var firstChanges = 0
        var low = Double.infinity, high = -Double.infinity
    }
    private var glassFrameLog = GlassFrameLog()

    private func logGlassFrame(angle: Double, at now: CFTimeInterval) {
        guard !capturesScreen, overlay.isVisible else {
            glassFrameLog = GlassFrameLog()
            return
        }
        if glassFrameLog.frames == 0 {
            glassFrameLog.started = now
            glassFrameLog.firstChanges = overlay.glassChanges
        }
        glassFrameLog.frames += 1
        glassFrameLog.low = min(glassFrameLog.low, angle)
        glassFrameLog.high = max(glassFrameLog.high, angle)
        guard now - glassFrameLog.started >= 1 else { return }
        let log = glassFrameLog
        let changes = overlay.glassChanges - log.firstChanges
        let progress = blurProgress(for: log.high)
        Diagnostics.geometry.notice(
            "glass second: \(log.frames) frames, \(changes) laid out afresh, angle \(log.low, format: .fixed(precision: 3))...\(log.high, format: .fixed(precision: 3)), progress \(progress, format: .fixed(precision: 3)), polling \(self.pollTimer != nil), preview \(self.preview != nil)"
        )
        glassFrameLog = GlassFrameLog()
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let rawInterval = now - lastFrameTime
        let dt = min(max(rawInterval, 1.0 / 240), 1.0 / 20)
        lastFrameTime = now
        if let frame = streamer.newFrame() {
            overlay.absorb(frame)
        }

        guard isClosingOut else {
            // Where the lid will be as this frame reaches the screen.
            if estimator.hasReading {
                let motion = estimator.frame(at: link.targetTimestamp)
                visualAngle.value = motion.angle
                visualAngle.velocity = motion.speed
            } else {
                visualAngle.reset(to: rawAngle)
            }
            applyVisual(angle: visualAngle.value)
            logGlassFrame(angle: visualAngle.value, at: now)
            followHaptics(angle: visualAngle.value)
            if awaitsFirstEffect, isActive, blurProgress(for: visualAngle.value) > 0 {
                awaitsFirstEffect = false
                Diagnostics.lid.notice(
                    """
                    first effect frame shows \((link.targetTimestamp - self.startedAt) * 1000, format: .fixed(precision: 0)) ms \
                    after the start, at \(self.visualAngle.value, format: .fixed(precision: 2)), \
                    picture ready \(self.overlay.isPictureReady)
                    """
                )
            }
            return
        }
        let target = effectiveThreshold
        if estimator.hasReading {
            // A lid opened past the start angle takes the picture flat at
            // least as fast as it goes, as it did up to the release. The ease
            // only takes over where the lid stops short or falls behind it.
            let lid = estimator.motion(at: link.targetTimestamp)
            visualAngle.advance(to: target, dt: dt, floor: lid.angle, floorSpeed: lid.speed)
        } else {
            visualAngle.advance(to: target, dt: dt)
        }
        // At or above the threshold the picture is already flat, so a lid
        // that opened past it finishes at once.
        let settled = visualAngle.value >= target - Self.closingOutSettleEpsilon
        let timedOut = now - closingOutStartedAt > Self.closingOutMaxDuration
        guard settled || timedOut else {
            applyVisual(angle: visualAngle.value)
            return
        }
        // The frame that fades out must match the screen behind it exactly,
        // so land on the threshold itself rather than just short of it.
        visualAngle.reset(to: target)
        applyVisual(angle: target)
        finishClosingOut()
    }

    /// The picture holds its lean once it reaches the most it may lean, and
    /// past the full-effect angle along with its blur and dimming. The glass
    /// leans the same.
    private func applyVisual(angle: Double) {
        let progress = blurProgress(for: angle)
        overlay.update(progress: progress, currentAngle: ramp.pictureAngle(for: angle), tuning: tuning)
    }

    private var tuning: DepthTuning {
        DepthTuning(
            viewingDistance: preferences.viewingDistance,
            recession: preferences.recession,
            blurEvenness: preferences.blurEvenness,
            dimReach: preferences.dimReach,
            maxBlurRadius: preferences.maxBlurRadius,
            maxDim: preferences.maxDim
        )
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // macOS posts this for backlight and colour changes too.
                let screen = NSScreen.builtIn
                let layout = Layout(displayID: screen?.displayID, frame: screen?.frame)
                guard layout != self.builtInLayout else {
                    Diagnostics.lid.notice("screen parameters changed, layout unchanged")
                    return
                }
                Diagnostics.lid.notice(
                    "screen parameters changed, layout now \(String(describing: layout), privacy: .public)"
                )
                self.builtInLayout = layout
                if self.isActive { self.setActive(false) }
                self.streamer.stop()
                self.streamer.invalidateFilter()
                self.overlay.discardLive()
                self.snapshotter.discard()
                // Building a capture filter lists the shareable content,
                // which would ask the glass for Screen Recording.
                if self.capturesScreen {
                    Task { await self.streamer.warmFilter() }
                    Task { await self.snapshotter.warmFilter() }
                }
                self.prepareGlass()
            }
        }
    }

    private func suspend() {
        Diagnostics.lid.notice("suspend")
        isSuspended = true
        stopEffectAndCapture()
        pushWatch.pause(sensor)
        estimator.reset(tuning: sensorTuning)
        estimatorFollowsScript = false
    }

    private func resume() {
        Diagnostics.lid.notice("resume")
        isSuspended = false
        // A fresh baseline, so waking with a nearly shut lid does not read as
        // closing movement.
        motion.reset()
        openDwell.reset()
        shutHold.reset()
        peakAngle = 0
        timeoutReferenceAngle = nil
        reopenLatch.reset()
        wasTimeoutEnabled = false
        isClosingOut = false
        // A reading from before sleep and one after must not make a hold.
        hinge.interrupt()
        estimator.reset(tuning: sensorTuning)
        estimatorFollowsScript = false
        if let angle = sensor.angle() {
            rawAngle = angle
            visualAngle.reset(to: angle)
            estimator.observe(angle, at: CACurrentMediaTime())
        }
        if sensor.isPushing {
            pushInterval = LidWakePolicy.enabledPushInterval
            pushWatch.setInterval(pushInterval, on: sensor)
        }
        wake()
    }
}
