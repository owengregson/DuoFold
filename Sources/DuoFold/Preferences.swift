import Combine
import Foundation

/// User settings, backed by `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let isEnabled = "isEnabled"
        static let isTimeoutEnabled = "isTimeoutEnabled"
        static let effectPreset = "effectPreset"
        static let thresholdAngle = "thresholdAngle"
        static let blurSpan = "blurSpan"
        static let maxBlurRadius = "maxBlurRadius"
        static let maxDim = "maxDim"
        static let viewingDistance = "viewingDistance"
        static let recession = "recession"
        static let maxLean = "maxLean"
        static let blurEvenness = "blurEvenness"
        static let dimReach = "dimReach"
        static let showsAngleInMenuBar = "showsAngleInMenuBar"
        static let showsMenuBarIcon = "showsMenuBarIcon"
        static let isLivePicture = "isLivePicture"
        static let isHapticsEnabled = "isHapticsEnabled"
        static let hapticStyle = "hapticStyle"
        static let hapticStrength = "hapticStrength"
        static let hapticTaps = "hapticTaps"
        static let isHapticsOnOpening = "isHapticsOnOpening"

        static let all = [
            isEnabled, isTimeoutEnabled, effectPreset, thresholdAngle, blurSpan, maxBlurRadius,
            maxDim, viewingDistance, recession, maxLean, blurEvenness, dimReach,
            showsAngleInMenuBar, showsMenuBarIcon, isLivePicture,
            isHapticsEnabled, hapticStyle, hapticStrength, hapticTaps, isHapticsOnOpening,
        ]
    }

    static let factoryHapticStyle = HapticPattern.Style.swell
    static let factoryHapticStrength = 1.0
    static let factoryHapticTaps = 48.0

    private static let factory: [String: Any] = {
        let effect = EffectPreset.standard.settings
        return [
            Key.isEnabled: true,
            Key.isTimeoutEnabled: false,
            Key.effectPreset: EffectPreset.standard.rawValue,
            Key.thresholdAngle: effect.thresholdAngle,
            Key.blurSpan: effect.blurSpan,
            Key.maxBlurRadius: effect.maxBlurRadius,
            Key.maxDim: effect.maxDim,
            Key.viewingDistance: effect.viewingDistance,
            Key.recession: effect.recession,
            Key.maxLean: effect.maxLean,
            Key.blurEvenness: effect.blurEvenness,
            Key.dimReach: effect.dimReach,
            Key.showsAngleInMenuBar: true,
            Key.showsMenuBarIcon: true,
            Key.isLivePicture: true,
            Key.isHapticsEnabled: true,
            Key.hapticStyle: factoryHapticStyle.rawValue,
            Key.hapticStrength: factoryHapticStrength,
            Key.hapticTaps: factoryHapticTaps,
            Key.isHapticsOnOpening: true,
        ]
    }()

    /// Master switch for the depth effect.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    /// Ends the effect early if the angle holds still while below the
    /// threshold, instead of waiting for the lid to open back past it. A
    /// saved value outranks the registered default, so an existing choice
    /// stands.
    @Published var isTimeoutEnabled: Bool {
        didSet { defaults.set(isTimeoutEnabled, forKey: Key.isTimeoutEnabled) }
    }

    /// The preset the effect settings were last set from, an
    /// `EffectPreset` raw value. The settings may have been edited since.
    @Published var effectPresetName: String {
        didSet { defaults.set(effectPresetName, forKey: Key.effectPreset) }
    }

    /// Closing past this angle starts the depth effect. Degrees.
    @Published var thresholdAngle: Double {
        didSet { defaults.set(thresholdAngle, forKey: Key.thresholdAngle) }
    }

    /// How many degrees below the threshold the blur takes to reach maximum.
    @Published var blurSpan: Double {
        didSet { defaults.set(blurSpan, forKey: Key.blurSpan) }
    }

    /// Gaussian blur radius at full effect, in points.
    @Published var maxBlurRadius: Double {
        didSet { defaults.set(maxBlurRadius, forKey: Key.maxBlurRadius) }
    }

    /// Black overlay opacity where the blur is at full strength, 0...1.
    @Published var maxDim: Double {
        didSet { defaults.set(maxDim, forKey: Key.maxDim) }
    }

    /// Distance from the eye to the middle of the screen, as a multiple of
    /// the screen height.
    @Published var viewingDistance: Double {
        didSet { defaults.set(viewingDistance, forKey: Key.viewingDistance) }
    }

    /// Degrees the picture turns away from the glass for each degree the lid
    /// closes. One holds the picture still in the room.
    @Published var recession: Double {
        didSet { defaults.set(recession, forKey: Key.recession) }
    }

    /// The most the picture leans back, in degrees. Past it the picture holds.
    @Published var maxLean: Double {
        didSet { defaults.set(maxLean, forKey: Key.maxLean) }
    }

    /// Blur at the hinge edge as a fraction of the blur at the far edge. One
    /// blurs the whole picture by the same amount.
    @Published var blurEvenness: Double {
        didSet { defaults.set(blurEvenness, forKey: Key.blurEvenness) }
    }

    /// Height at which the dimming reaches full strength, as a fraction of
    /// the screen height.
    @Published var dimReach: Double {
        didSet { defaults.set(dimReach, forKey: Key.dimReach) }
    }

    /// Draw the live angle next to the menu bar icon.
    @Published var showsAngleInMenuBar: Bool {
        didSet { defaults.set(showsAngleInMenuBar, forKey: Key.showsAngleInMenuBar) }
    }

    /// Keep the icon in the menu bar. Without it, opening the app again is
    /// the way into the settings.
    @Published var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: Key.showsMenuBarIcon) }
    }

    /// Keep the picture under the effect updating, instead of holding the one
    /// frame that was on screen at the trigger angle. Only the screen capture
    /// can hold a frame.
    @Published var isLivePicture: Bool {
        didSet { defaults.set(isLivePicture, forKey: Key.isLivePicture) }
    }

    /// Tap the trackpad as the lid closes through the effect.
    @Published var isHapticsEnabled: Bool {
        didSet { defaults.set(isHapticsEnabled, forKey: Key.isHapticsEnabled) }
    }

    /// A `HapticPattern.Style` raw value.
    @Published var hapticStyle: String {
        didSet { defaults.set(hapticStyle, forKey: Key.hapticStyle) }
    }

    /// The strongest tap of the pattern, 0...1.
    @Published var hapticStrength: Double {
        didSet { defaults.set(hapticStrength, forKey: Key.hapticStrength) }
    }

    /// Taps over the full travel, for the patterns that space them out.
    @Published var hapticTaps: Double {
        didSet { defaults.set(hapticTaps, forKey: Key.hapticTaps) }
    }

    /// Tap on the way back up too.
    @Published var isHapticsOnOpening: Bool {
        didSet { defaults.set(isHapticsOnOpening, forKey: Key.isHapticsOnOpening) }
    }

    /// Eye distance in screen heights, at the two ends of the perspective
    /// slider. The panel offers the strength, which runs the other way.
    nonisolated static let farthestEye: Double = 6
    nonisolated static let nearestEye: Double = 1
    nonisolated static let eyeRange: Double = farthestEye - nearestEye

    /// The preset the effect settings started from.
    var effectPreset: EffectPreset {
        EffectPreset(rawValue: effectPresetName) ?? .standard
    }

    /// The settings a preset sets, as they stand.
    var effect: EffectSettings {
        get {
            EffectSettings(
                thresholdAngle: thresholdAngle, blurSpan: blurSpan, maxBlurRadius: maxBlurRadius,
                blurEvenness: blurEvenness, maxDim: maxDim, dimReach: dimReach,
                recession: recession, maxLean: maxLean, viewingDistance: viewingDistance
            )
        }
        set {
            for field in EffectField.allCases {
                self[keyPath: Self.keyPath(field)] = newValue[keyPath: field.keyPath]
            }
        }
    }

    /// Whether the effect settings have moved off the preset they started from.
    var isEffectEdited: Bool {
        !effect.reads(like: effectPreset.settings)
    }

    func apply(_ preset: EffectPreset) {
        effectPresetName = preset.rawValue
        effect = preset.settings
    }

    static func keyPath(_ field: EffectField) -> ReferenceWritableKeyPath<Preferences, Double> {
        switch field {
        case .thresholdAngle: return \.thresholdAngle
        case .blurSpan: return \.blurSpan
        case .maxBlurRadius: return \.maxBlurRadius
        case .blurEvenness: return \.blurEvenness
        case .maxDim: return \.maxDim
        case .dimReach: return \.dimReach
        case .recession: return \.recession
        case .maxLean: return \.maxLean
        case .viewingDistance: return \.viewingDistance
        }
    }

    /// Highest angle above the threshold at which the pre-warm may run.
    let prewarmCeiling: Double = 70

    /// Closing speed in degrees per second that starts the pre-warm.
    let closingSpeed: Double = 8

    /// How long the pre-warm runs after the lid stops moving.
    let prewarmLinger: TimeInterval = 2

    /// Seconds between pre-warm screenshots.
    let prewarmInterval: TimeInterval = 0.25

    /// Degrees above the threshold before the overlay is released.
    let hysteresis: Double = 4

    /// The widest angle this Mac's lid has been held at, which keeps the start
    /// angle low enough to release. A measurement rather than a setting, so
    /// Reset keeps it. Stored for this Mac only, so that a home folder moved
    /// to another MacBook does not bring the old hinge along. Forget it with
    /// `defaults -currentHost delete com.owengregson.duofold hingeLimit`.
    var hingeLimit: Double? {
        get {
            let value = CFPreferencesCopyValue(
                Self.hingeLimitKey,
                kCFPreferencesCurrentApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
            return (value as? NSNumber)?.doubleValue
        }
        set {
            CFPreferencesSetValue(
                Self.hingeLimitKey,
                newValue.map { $0 as NSNumber },
                kCFPreferencesCurrentApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
            CFPreferencesSynchronize(
                kCFPreferencesCurrentApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        }
    }

    private static let hingeLimitKey = "hingeLimit" as CFString

    /// Settings from earlier versions, removed at launch.
    private static let retired = [
        "blurFrontWidth", "maxTilt", "tiltDegrees", "tiltRatio", "dimEvenness",
        // The screen capture is now only the fallback for a system whose
        // window server cannot draw the glass.
        "capturesScreen",
    ]

    private let defaults = UserDefaults.standard

    // No inline values on purpose. Swift skips property observers for the
    // assignment that initialises a property.
    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: Self.factory)
        for key in Self.retired { defaults.removeObject(forKey: key) }
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        isTimeoutEnabled = defaults.bool(forKey: Key.isTimeoutEnabled)
        effectPresetName = defaults.string(forKey: Key.effectPreset) ?? EffectPreset.standard.rawValue
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        blurSpan = defaults.double(forKey: Key.blurSpan)
        maxBlurRadius = defaults.double(forKey: Key.maxBlurRadius)
        maxDim = defaults.double(forKey: Key.maxDim)
        viewingDistance = defaults.double(forKey: Key.viewingDistance)
        recession = defaults.double(forKey: Key.recession)
        maxLean = defaults.double(forKey: Key.maxLean)
        blurEvenness = defaults.double(forKey: Key.blurEvenness)
        dimReach = defaults.double(forKey: Key.dimReach)
        showsAngleInMenuBar = defaults.bool(forKey: Key.showsAngleInMenuBar)
        showsMenuBarIcon = defaults.bool(forKey: Key.showsMenuBarIcon)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
        isHapticsEnabled = defaults.bool(forKey: Key.isHapticsEnabled)
        hapticStyle = defaults.string(forKey: Key.hapticStyle) ?? Self.factoryHapticStyle.rawValue
        hapticStrength = defaults.double(forKey: Key.hapticStrength)
        hapticTaps = defaults.double(forKey: Key.hapticTaps)
        isHapticsOnOpening = defaults.bool(forKey: Key.isHapticsOnOpening)
    }

    func resetToDefaults() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        isTimeoutEnabled = defaults.bool(forKey: Key.isTimeoutEnabled)
        effectPresetName = defaults.string(forKey: Key.effectPreset) ?? EffectPreset.standard.rawValue
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        blurSpan = defaults.double(forKey: Key.blurSpan)
        maxBlurRadius = defaults.double(forKey: Key.maxBlurRadius)
        maxDim = defaults.double(forKey: Key.maxDim)
        viewingDistance = defaults.double(forKey: Key.viewingDistance)
        recession = defaults.double(forKey: Key.recession)
        maxLean = defaults.double(forKey: Key.maxLean)
        blurEvenness = defaults.double(forKey: Key.blurEvenness)
        dimReach = defaults.double(forKey: Key.dimReach)
        showsAngleInMenuBar = defaults.bool(forKey: Key.showsAngleInMenuBar)
        showsMenuBarIcon = defaults.bool(forKey: Key.showsMenuBarIcon)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
        isHapticsEnabled = defaults.bool(forKey: Key.isHapticsEnabled)
        hapticStyle = defaults.string(forKey: Key.hapticStyle) ?? Self.factoryHapticStyle.rawValue
        hapticStrength = defaults.double(forKey: Key.hapticStrength)
        hapticTaps = defaults.double(forKey: Key.hapticTaps)
        isHapticsOnOpening = defaults.bool(forKey: Key.isHapticsOnOpening)
    }
}
