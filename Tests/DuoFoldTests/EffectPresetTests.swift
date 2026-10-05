import AppKit
import Testing
@testable import DuoFold

struct EffectPresetTests {

    @Test
    func testEveryPresetFitsTheSlidersAndTheirSteps() {
        for preset in EffectPreset.allCases {
            for field in EffectField.allCases {
                let value = preset.settings[keyPath: field.keyPath]
                #expect(field.range.contains(value), "\(preset) sets \(field) to \(value), off its slider")
                let steps = value / field.step
                #expect(abs(steps - steps.rounded()) < 1e-6, "\(preset) sets \(field) to \(value), between steps")
            }
        }
    }

    @Test
    func testNoTwoPresetsReadAlike() {
        for (index, preset) in EffectPreset.allCases.enumerated() {
            for other in EffectPreset.allCases.dropFirst(index + 1) {
                #expect(!preset.settings.reads(like: other.settings), "\(preset) and \(other) look the same")
            }
        }
    }

    /// Values saved by a slider that did not step read as the preset they
    /// round to, and a change of one step does not.
    @Test
    func testSettingsReadAlikeAsThePanelRoundsThem() {
        let saved = EffectSettings(
            thresholdAngle: 84.58984375, blurSpan: 64.5883058562992, maxBlurRadius: 54.94417445866141,
            blurEvenness: 0.05230376476377953, maxDim: 0.5450756643700787, dimReach: 0.552177657480315,
            recession: 0.9731176181102363, maxLean: 70.33487635334646, viewingDistance: 6
        )
        #expect(saved.reads(like: EffectPreset.balanced.settings))
        for field in EffectField.allCases {
            var moved = EffectPreset.balanced.settings
            moved[keyPath: field.keyPath] += field.step
            #expect(!moved.reads(like: EffectPreset.balanced.settings), "a step of \(field) went unnoticed")
        }
    }

    @Test
    func testEveryPresetSymbolExists() {
        for preset in EffectPreset.allCases {
            #expect(NSImage(systemSymbolName: preset.symbolName, accessibilityDescription: nil) != nil, "\(preset.symbolName)")
        }
    }

    @MainActor
    @Test
    func testApplyingAPresetSetsEveryValueAndLeavesItUnedited() {
        let preferences = Preferences.shared
        let saved = (preferences.effectPresetName, preferences.effect)
        defer {
            preferences.effectPresetName = saved.0
            preferences.effect = saved.1
        }
        for preset in EffectPreset.allCases {
            preferences.apply(preset)
            #expect(preferences.effectPreset == preset)
            #expect(preferences.effect == preset.settings)
            #expect(!preferences.isEffectEdited)
            preferences.maxBlurRadius += 1
            #expect(preferences.isEffectEdited)
        }
    }
}
