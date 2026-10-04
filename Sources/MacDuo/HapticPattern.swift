import Foundation

/// Where the trackpad taps fall along the lid's travel through the effect,
/// and how hard each one is.
///
/// Travel runs from 0, where the effect starts, to 1, where it reaches full
/// strength: the same progress that drives the blur.
struct HapticPattern: Equatable {

    enum Style: String, CaseIterable, Identifiable {
        /// Evenly spaced taps of one strength, like detents.
        case linear
        /// Faint taps that come faster and faster, so the end of the travel
        /// is a run of tiny taps.
        case exponential
        /// Evenly spaced taps that grow stronger.
        case swell
        /// One tap as the effect starts and a firm one at full strength.
        case bookends

        var id: String { rawValue }

        /// Whether the tap count setting applies.
        var usesTapCount: Bool { self != .bookends }
    }

    struct Stop: Equatable {
        /// Travel, 0...1.
        var position: Double
        /// 0...1, where 1 is the strongest tap the trackpad gives.
        var strength: Double
    }

    var style: Style
    /// Taps over the full travel.
    var taps: Int
    /// The strongest tap of the pattern, 0...1.
    var strength: Double

    /// How much faster the exponential taps come at the end than at the start.
    static let exponentialRise = 3.0

    /// In travel order.
    var stops: [Stop] {
        let count = max(taps, 1)
        let peak = min(max(strength, 0), 1)
        switch style {
        case .linear:
            return (1...count).map { Stop(position: Double($0) / Double(count), strength: peak) }
        case .exponential:
            // The taps up to travel p grow as e^(kp), so tap i of n sits
            // where that count reaches i.
            let k = Self.exponentialRise
            return (1...count).map { index in
                let position = log(1 + (exp(k) - 1) * Double(index) / Double(count)) / k
                return Stop(position: position, strength: peak * (0.35 + 0.65 * position))
            }
        case .swell:
            return (1...count).map { index in
                let position = Double(index) / Double(count)
                return Stop(position: position, strength: peak * (0.2 + 0.8 * position))
            }
        case .bookends:
            return [Stop(position: 0, strength: peak * 0.6), Stop(position: 1, strength: peak)]
        }
    }
}

/// Follows the travel and says when a tap is due.
///
/// Each stop fires once as the travel passes it. Going back over a stop only
/// counts once the travel is a little below it, so a lid resting on a stop,
/// with the sensor reading a hair either side, does not tap again and again.
struct HapticTrack {

    /// Travel to go back past a stop before it counts as left behind.
    static let releaseMargin = 0.01

    let stops: [HapticPattern.Stop]
    /// Taps on the way back up too.
    let followsOpening: Bool
    /// Stops at or below the travel so far.
    private var passed: Int

    /// Starts at `progress` with the stops already behind it passed, except
    /// a stop at 0 itself: that one marks the effect starting and is due now.
    init(pattern: HapticPattern, progress: Double, followsOpening: Bool) {
        stops = pattern.stops
        self.followsOpening = followsOpening
        passed = stops.first?.position == 0 ? 0 : stops.firstIndex { $0.position > progress } ?? stops.count
    }

    /// The tap due on moving to `progress`, if any. Passing several stops at
    /// once gives one tap, as strong as the strongest of them.
    mutating func advance(to progress: Double) -> Double? {
        var due: Double?
        while passed < stops.count, progress >= stops[passed].position {
            due = max(due ?? 0, stops[passed].strength)
            passed += 1
        }
        guard due == nil else { return due }
        while passed > 0, progress < stops[passed - 1].position - Self.releaseMargin {
            passed -= 1
            if followsOpening { due = max(due ?? 0, stops[passed].strength) }
        }
        return due
    }
}
