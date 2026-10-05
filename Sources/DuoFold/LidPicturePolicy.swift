import Foundation

/// What goes on screen the moment a run starts, and how the captured
/// picture then takes over.
///
/// The window server's glass is built ahead and shows on the next refresh.
/// A capture is not: the stream takes 25 to 45 ms to start and a screenshot
/// 50 to 75 ms to land, and until then the screen showed nothing. The glass
/// blurs and dims exactly as the picture will (`GlassMatchesCaptureTests`),
/// so in capture mode it goes up first and the picture, drawn flat to begin
/// with (`LidLeanCatchUp`), cuts in over it showing the same frame.
struct LidPicturePolicy {

    /// How long the picture fades in over the bare screen. It covers the
    /// pop of a picture that arrives late and already leaning, or of a
    /// screenshot older than what is on screen. Over the glass neither
    /// happens.
    static let fadeInDuration: TimeInterval = 0.07

    enum First: Equatable {
        /// The glass is the effect.
        case glass
        /// The glass now; the picture over it once it has a frame.
        case glassUnderPicture
        /// Nothing until the picture has a frame.
        case pictureAlone
    }

    struct Plan: Equatable {
        var first: First
        /// Whether the live picture starts from a screenshot, held or
        /// taken now, rather than waiting for the stream. A screenshot and
        /// a starting stream slow each other down, so only when nothing
        /// covers the wait.
        var seedsFromScreenshot: Bool
        var fadeIn: TimeInterval
    }

    func plan(
        capturesScreen: Bool,
        isGlassAvailable: Bool,
        isLivePicture: Bool,
        hasStreamFrame: Bool
    ) -> Plan {
        guard capturesScreen else {
            return Plan(first: .glass, seedsFromScreenshot: false, fadeIn: 0)
        }
        guard isGlassAvailable else {
            return Plan(
                first: .pictureAlone,
                seedsFromScreenshot: isLivePicture && !hasStreamFrame,
                fadeIn: Self.fadeInDuration
            )
        }
        return Plan(first: .glassUnderPicture, seedsFromScreenshot: false, fadeIn: 0)
    }
}

/// The lean of a picture that has just taken over. The glass cannot lean,
/// and a picture that pops in leaning as far as the lid has gone shows a
/// jump, so the picture starts flat and eases into the lid's lean. Blur and
/// dimming follow the lid throughout; only the lean catches up.
struct LidLeanCatchUp {

    /// A quarter of a second: by then the lid is well into the ramp and the
    /// blur and dimming carry the effect, and at a fast close the lean
    /// never has to catch up faster than about twice the lid's own speed.
    static let duration: TimeInterval = 0.25

    private(set) var startedAt: TimeInterval?

    /// The picture is on screen from `now`.
    mutating func begin(at now: TimeInterval) {
        startedAt = now
    }

    mutating func reset() {
        startedAt = nil
    }

    /// How much of the lid's lean to draw: none at the handover, all of it
    /// from `duration` on, and all of it when no handover is in progress.
    /// Smooth at both ends, so neither join shows as a change of pace.
    func share(at now: TimeInterval) -> Double {
        guard let startedAt else { return 1 }
        let t = min(max((now - startedAt) / Self.duration, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The angle to draw the picture at: `share` of the way from flat, at
    /// the start angle, to the lid's.
    func pictureAngle(_ angle: Double, startAngle: Double, at now: TimeInterval) -> Double {
        let share = share(at: now)
        guard share < 1 else { return angle }
        return startAngle + (angle - startAngle) * share
    }
}

/// When the glass under a picture that has taken over may come down. The
/// picture's window is shown with its first frame still on its way to the
/// screen, so the glass stays until a second frame has been drawn: the
/// screen never shows the bare desktop between the two.
struct GlassHandover {
    private(set) var framesDrawn = 0

    var isComplete: Bool { framesDrawn >= 2 }

    mutating func drewFrame() {
        framesDrawn += 1
    }
}
