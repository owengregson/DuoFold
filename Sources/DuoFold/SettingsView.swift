import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: LidController

    /// Empty means following the system language.
    @AppStorage("settingsLanguage") private var language = ""

    private var selectedLanguage: SettingsLanguage {
        SettingsLanguage(rawValue: language) ?? .preferred
    }

    private func localized(_ key: String) -> String {
        selectedLanguage.localized(key)
    }

    private enum Tab: Hashable {
        case effect, haptics, general
    }

    @State private var tab = Tab.effect
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @State private var settingsOpenFailed = false
    @State private var confirmsReset = false

    var onQuit: () -> Void

    private static let width: CGFloat = 340
    private static let inset: CGFloat = 14
    /// Fixed, so the panel keeps its size from tab to tab.
    private static let bodyHeight: CGFloat = 380
    private static let authorURL = URL(string: "https://github.com/owengregson")!
    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Self.inset)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if controller.isSensorAvailable, controller.capturesScreen, !hasScreenPermission {
                permissionNotice
                    .padding(.horizontal, Self.inset)
                    .padding(.bottom, 10)
            }
            if controller.isSensorAvailable {
                Picker("", selection: $tab) {
                    Text(localized("Effect")).tag(Tab.effect)
                    Text(localized("Haptics")).tag(Tab.haptics)
                    Text(localized("General")).tag(Tab.general)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Self.inset)
            }
            Group {
                if !controller.isSensorAvailable {
                    // Nothing to tune without a sensor; the header says why.
                    generalForm
                } else {
                    switch tab {
                    case .effect: effectForm
                    case .haptics: hapticsForm
                    case .general: generalForm
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: Self.bodyHeight)
            Divider()
            footer
                .padding(.horizontal, Self.inset)
                .padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .onAppear { hasScreenPermission = CGPreflightScreenCaptureAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenPermission = CGPreflightScreenCaptureAccess()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: "Duo Fold").font(.title3.weight(.semibold))
                Spacer()
                if controller.isSensorAvailable {
                    Toggle(localized("Depth effect"), isOn: $preferences.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(localized("Leans the screen away as the lid closes."))
                }
            }
            if controller.isSensorAvailable {
                HStack(spacing: 10) {
                    LidGauge(
                        angle: controller.currentAngle,
                        start: controller.effectiveThreshold,
                        span: preferences.blurSpan,
                        limit: gaugeLimit,
                        isOn: preferences.isEnabled
                    )
                    Text(String(format: "%.0f°", controller.currentAngle))
                        .font(.system(.body, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                        .accessibilityLabel(localized("Lid angle"))
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(localized("This Mac has no lid angle sensor. Only some MacBook models have one."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The right end of the gauge: as wide as this lid has been seen to open.
    private var gaugeLimit: Double {
        max(controller.hingeLimit ?? 135, controller.effectiveThreshold + 10, 120)
    }

    private var status: String {
        if !preferences.isEnabled { return localized("The effect is off.") }
        if controller.isActive { return localized("Running. Press Esc to end it.") }
        let start = controller.effectiveThreshold
        return String(
            format: localized("Starts at %.0f°, full effect by %.0f°."),
            start, max(start - preferences.blurSpan, 0)
        )
    }

    // MARK: - Effect

    private var effectForm: some View {
        Form {
            Section {
                presetPicker
            } header: {
                Text(localized("Preset"))
            } footer: {
                presetFooter
            }
            Section(localized("Start")) {
                effectSlider(
                    localized("Start angle"), .thresholdAngle, format: "%.0f°",
                    help: localized("The effect starts at this angle."),
                    note: loweredNote
                )
                effectSlider(
                    localized("Full effect after"), .blurSpan, format: "%.0f°",
                    help: localized("Degrees of further closing to reach full strength.")
                )
                Toggle(isOn: $preferences.isTimeoutEnabled) {
                    Text(localized("Timeout"))
                    Text(localized("Ends the effect once the angle stops changing."))
                }
            }
            Section(localized("Look")) {
                effectSlider(
                    localized("Blur"), .maxBlurRadius, format: "%.0f pt",
                    help: localized("Blur radius at the far edge.")
                )
                effectSlider(
                    localized("Blur spread"), .blurEvenness, format: "%.0f%%", scale: 100,
                    help: localized("0 blurs the far edge only, 100 the whole picture.")
                )
                effectSlider(
                    localized("Dimming"), .maxDim, format: "%.0f%%", scale: 100,
                    help: localized("How dark the far edge goes.")
                )
                effectSlider(
                    localized("Dimming spread"), .dimReach, format: "%.0f%%", scale: 100,
                    help: localized("Everything above this height goes fully dark.")
                )
            }
            Section(localized("Perspective")) {
                effectSlider(
                    localized("Lean back"), .recession, format: "%.1f×",
                    help: localized("Degrees of lean per degree of closing. 1 holds it still.")
                )
                effectSlider(
                    localized("Max lean"), .maxLean, format: "%.0f°",
                    help: localized("The picture stops leaning back past this angle.")
                )
                slider(
                    localized("Perspective"), value: perspective, in: 0...1, step: 0.01,
                    format: "%.0f%%", scale: 100,
                    reset: Self.perspective(of: preferences.effectPreset.settings.viewingDistance),
                    help: localized("0 keeps the sides parallel, 100 converges sharply.")
                )
            }
            if controller.capturesScreen {
                Section {
                    Toggle(isOn: $preferences.isLivePicture) {
                        Text(localized("Live rendering"))
                        Text(localized("Off holds the frame from when the effect started."))
                    }
                } header: {
                    Text(localized("Screen capture"))
                } footer: {
                    footnote(localized("macOS cannot draw the effect itself on this Mac, so Duo Fold captures the screen instead."))
                }
            }
        }
    }

    private var presetPicker: some View {
        HStack(spacing: 6) {
            ForEach(EffectPreset.allCases) { preset in
                presetButton(preset)
            }
        }
        .padding(.vertical, 2)
    }

    private func presetButton(_ preset: EffectPreset) -> some View {
        let isSelected = preferences.effectPreset == preset
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Button {
            preferences.apply(preset)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 15))
                    .frame(height: 18)
                Text(localized(preset.titleKey))
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(shape.fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
            .overlay(shape.strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(localized(preset.summaryKey))
        .accessibilityLabel(localized(preset.titleKey))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var presetFooter: some View {
        let preset = preferences.effectPreset
        if preferences.isEffectEdited {
            HStack(spacing: 4) {
                footnote(String(format: localized("%@, edited."), localized(preset.titleKey)))
                Button(localized("Revert")) { preferences.apply(preset) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(String(format: localized("Puts every value back to %@."), localized(preset.titleKey)))
            }
        } else {
            footnote(localized(preset.summaryKey))
        }
    }

    /// Names the angle in force when the hinge holds the setting down. The
    /// slider keeps the setting, which applies again on a lid that opens wider.
    private var loweredNote: String? {
        let effective = controller.effectiveThreshold
        guard effective.rounded() < preferences.thresholdAngle.rounded() else { return nil }
        return String(format: localized("Lowered to %.0f° so opening the lid fully still ends the effect."), effective)
    }

    private static func perspective(of viewingDistance: Double) -> Double {
        (Preferences.farthestEye - viewingDistance) / Preferences.eyeRange
    }

    private var perspective: Binding<Double> {
        Binding(
            get: { Self.perspective(of: preferences.viewingDistance) },
            set: { preferences.viewingDistance = Preferences.farthestEye - $0 * Preferences.eyeRange }
        )
    }

    /// A slider for one of the values a preset sets, which resets to the
    /// preset's value.
    private func effectSlider(
        _ title: String,
        _ field: EffectField,
        format: String,
        scale: Double = 1,
        help: String,
        note: String? = nil
    ) -> some View {
        slider(
            title,
            value: $preferences[dynamicMember: Preferences.keyPath(field)],
            in: field.range,
            step: field.step,
            format: format,
            scale: scale,
            reset: preferences.effectPreset.settings[keyPath: field.keyPath],
            help: help,
            note: note
        )
    }

    // MARK: - Haptics

    private var hapticStyle: HapticPattern.Style {
        HapticPattern.Style(rawValue: preferences.hapticStyle) ?? Preferences.factoryHapticStyle
    }

    private var hapticsForm: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.isHapticsEnabled) {
                    Text(localized("Trackpad taps"))
                    Text(localized("Taps the trackpad as the lid closes. Felt with a finger resting on it."))
                }
            }
            Section(localized("Pattern")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Picker(localized("Pattern"), selection: $preferences.hapticStyle) {
                            ForEach(HapticPattern.Style.allCases) { style in
                                Text(localized(style.titleKey)).tag(style.rawValue)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        Button {
                            controller.tryHaptics()
                        } label: {
                            Label(localized("Try"), systemImage: "hand.tap")
                        }
                        .help(localized("Plays the pattern on the trackpad now."))
                    }
                    footnote(localized(hapticStyle.summaryKey))
                }
                slider(
                    localized("Strength"), value: $preferences.hapticStrength, in: 0.1...1, step: 0.01,
                    format: "%.0f%%", scale: 100, reset: Preferences.factoryHapticStrength,
                    help: localized("The strongest tap of the pattern.")
                )
                slider(
                    localized("Taps"), value: $preferences.hapticTaps, in: 4...48, step: 1,
                    format: "%.0f", reset: Preferences.factoryHapticTaps,
                    help: localized("Over the whole closing travel.")
                )
                .disabled(!hapticStyle.usesTapCount)
                Toggle(localized("While opening"), isOn: $preferences.isHapticsOnOpening)
            }
            .disabled(!preferences.isHapticsEnabled)
        }
    }

    // MARK: - General

    private var generalForm: some View {
        Form {
            Section {
                Picker(localized("Language"), selection: $language) {
                    Text(localized("System")).tag("")
                    Text(verbatim: "English").tag(SettingsLanguage.english.rawValue)
                    Text(localized("Chinese (Simplified)")).tag(SettingsLanguage.chinese.rawValue)
                }
                Toggle(localized("Launch at login"), isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }
            Section(localized("Menu bar")) {
                Toggle(isOn: $preferences.showsMenuBarIcon) {
                    Text(localized("Show icon in menu bar"))
                    Text(localized("When off, open Duo Fold again to show these settings."))
                }
                Toggle(localized("Show angle in menu bar"), isOn: $preferences.showsAngleInMenuBar)
                    .disabled(!preferences.showsMenuBarIcon)
            }
            Section {
                if confirmsReset {
                    HStack {
                        Text(localized("Reset all settings?"))
                        Spacer()
                        Button(localized("Cancel")) { confirmsReset = false }
                            .keyboardShortcut(.cancelAction)
                        // Red, and never the default button, so Return cannot reset.
                        Button(localized("Reset"), role: .destructive) {
                            preferences.resetToDefaults()
                            confirmsReset = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                } else {
                    LabeledContent {
                        Button(localized("Reset")) { confirmsReset = true }
                    } label: {
                        Text(localized("Reset all settings"))
                        Text(localized("Every setting goes back to its default. The language stays."))
                    }
                }
            }
            Section {
                LabeledContent(localized("Version"), value: Self.version)
            }
        }
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    controller.runPreview()
                } label: {
                    Label(localized("Preview"), systemImage: "play.fill")
                }
                .disabled(!controller.isSensorAvailable || !preferences.isEnabled || controller.isActive)
                .help(localized("Plays the effect once. Press Esc to end it."))
                Spacer()
                Button(localized("Quit"), action: onQuit)
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
            HStack(spacing: 0) {
                Text(localized("Made by ")).foregroundStyle(.secondary)
                Link("owengregson", destination: Self.authorURL)
                    .pointingHand()
                Spacer()
                Text("© 2026 owengregson").foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
    }

    // MARK: - Screen Recording

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("Screen Recording permission is required to show the depth effect."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(localized("Open System Settings")) {
                    openScreenRecordingSettings()
                }
                .controlSize(.small)
            }
            if settingsOpenFailed {
                Text(localized("Could not open System Settings. Open it manually and enable screen recording for Duo Fold under Privacy & Security."))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openScreenRecordingSettings() {
        settingsOpenFailed = false
        Task { @MainActor in
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.open(Self.screenRecordingSettingsURL, configuration: configuration)
            } catch {
                settingsOpenFailed = true
            }
        }
    }

    // MARK: - Rows

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A titled slider that moves in `step`s, with its reading and, once it
    /// has moved off `reset`, a button that puts it back.
    private func slider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        format: String,
        scale: Double = 1,
        reset: Double?,
        help: String,
        note: String? = nil
    ) -> some View {
        let reading = String(format: format, value.wrappedValue * scale)
        let isChanged = reset.map { (value.wrappedValue / step).rounded() != ($0 / step).rounded() } ?? false
        let stepped = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = ($0 / step).rounded() * step }
        )
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                if let reset {
                    Button {
                        value.wrappedValue = reset
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(String(format: localized("Reset to %@"), String(format: format, reset * scale)))
                    .accessibilityLabel(String(format: localized("Reset to %@"), String(format: format, reset * scale)))
                    // Kept in the layout, so the reading does not jump.
                    .opacity(isChanged ? 1 : 0)
                    .disabled(!isChanged)
                }
                Text(reading)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: stepped, in: range)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(reading)
            if let note {
                footnote(note)
            }
        }
        .help(help)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private extension HapticPattern.Style {
    var titleKey: String {
        switch self {
        case .linear: return "Linear"
        case .exponential: return "Exponential"
        case .swell: return "Swell"
        case .bookends: return "Start and end"
        }
    }

    var summaryKey: String {
        switch self {
        case .linear: return "Even taps, like detents."
        case .exponential: return "Tiny taps that come faster and faster."
        case .swell: return "Even taps that grow stronger."
        case .bookends: return "One tap as the effect starts, a firm one at full effect."
        }
    }
}

private extension View {
    func pointingHand() -> some View {
        modifier(PointingHand())
    }
}

private struct PointingHand: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}
