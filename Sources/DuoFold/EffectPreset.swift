import Foundation

/// Where the effect starts and how it looks: everything a preset sets.
struct EffectSettings: Equatable {
    var thresholdAngle: Double
    var blurSpan: Double
    var maxBlurRadius: Double
    var blurEvenness: Double
    var maxDim: Double
    var dimReach: Double
    var recession: Double
    var maxLean: Double
    var viewingDistance: Double

    /// Whether the two read the same in the settings panel, which shows
    /// every value rounded to the step its slider moves by.
    func reads(like other: EffectSettings) -> Bool {
        EffectField.allCases.allSatisfy { field in
            field.rounded(self[keyPath: field.keyPath]) == field.rounded(other[keyPath: field.keyPath])
        }
    }
}

/// One value of `EffectSettings`, with the step its slider moves by.
enum EffectField: CaseIterable {
    case thresholdAngle, blurSpan, maxBlurRadius, blurEvenness, maxDim, dimReach
    case recession, maxLean, viewingDistance

    var keyPath: WritableKeyPath<EffectSettings, Double> {
        switch self {
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

    /// The smallest change the panel shows: a degree, a point, a percent, a
    /// tenth of the lean ratio, or a percent of the perspective slider.
    var step: Double {
        switch self {
        case .thresholdAngle, .blurSpan, .maxBlurRadius, .maxLean: return 1
        case .blurEvenness, .maxDim, .dimReach: return 0.01
        case .recession: return 0.1
        case .viewingDistance: return Preferences.eyeRange / 100
        }
    }

    /// Where the panel's slider runs.
    var range: ClosedRange<Double> {
        switch self {
        case .thresholdAngle: return 5...130
        case .blurSpan: return 5...100
        case .maxBlurRadius: return 10...160
        case .blurEvenness, .maxDim: return 0...1
        case .dimReach: return 0.2...1
        case .recession: return 0...3
        case .maxLean: return 10...85
        case .viewingDistance: return Preferences.nearestEye...Preferences.farthestEye
        }
    }

    /// In whole steps, so two values compare as the panel shows them.
    func rounded(_ value: Double) -> Int {
        Int((value / step).rounded())
    }
}

/// Named starting points for the effect. Picking one sets every value of
/// `EffectSettings`; the sliders then fine-tune from there.
enum EffectPreset: String, CaseIterable, Identifiable {
    case balanced, subtle, deep, flat, classic

    /// The factory settings.
    static let standard = EffectPreset.balanced

    var id: String { rawValue }

    var settings: EffectSettings {
        switch self {
        case .balanced:
            return EffectSettings(
                thresholdAngle: 85, blurSpan: 65, maxBlurRadius: 55, blurEvenness: 0.05,
                maxDim: 0.55, dimReach: 0.55, recession: 1, maxLean: 70, viewingDistance: 6
            )
        case .subtle:
            return EffectSettings(
                thresholdAngle: 75, blurSpan: 55, maxBlurRadius: 25, blurEvenness: 0,
                maxDim: 0.3, dimReach: 0.8, recession: 0.6, maxLean: 35, viewingDistance: 6
            )
        case .deep:
            return EffectSettings(
                thresholdAngle: 95, blurSpan: 60, maxBlurRadius: 100, blurEvenness: 0.15,
                maxDim: 0.85, dimReach: 0.45, recession: 1.3, maxLean: 80, viewingDistance: 3.5
            )
        case .flat:
            return EffectSettings(
                thresholdAngle: 85, blurSpan: 60, maxBlurRadius: 70, blurEvenness: 0.5,
                maxDim: 0.5, dimReach: 0.8, recession: 0, maxLean: 45, viewingDistance: 6
            )
        case .classic:
            // The look the app first shipped with.
            return EffectSettings(
                thresholdAngle: 90, blurSpan: 60, maxBlurRadius: 135, blurEvenness: 0,
                maxDim: 1, dimReach: 0.5, recession: 1, maxLean: 45, viewingDistance: 6
            )
        }
    }

    var titleKey: String {
        switch self {
        case .balanced: return "Balanced"
        case .subtle: return "Subtle"
        case .deep: return "Deep"
        case .flat: return "Flat"
        case .classic: return "Classic"
        }
    }

    var summaryKey: String {
        switch self {
        case .balanced: return "The default: a steady lean and a soft blur."
        case .subtle: return "A light blur and a slight lean."
        case .deep: return "A strong lean, perspective and dimming."
        case .flat: return "Blurs and dims without leaning."
        case .classic: return "A heavy blur that fades into black."
        }
    }

    var symbolName: String {
        switch self {
        case .balanced: return "circle.lefthalf.filled"
        case .subtle: return "circle.dotted"
        case .deep: return "skew"
        case .flat: return "rectangle"
        case .classic: return "moon"
        }
    }
}
