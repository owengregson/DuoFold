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

    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @State private var settingsOpenFailed = false

    var onQuit: () -> Void

    private static let width: CGFloat = 300
    private static let inset: CGFloat = 14
    private static let bodyHeight: CGFloat = 400
    private static let authorURL = URL(string: "https://github.com/sumimakito")!
    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.inset)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            if controller.isSensorAvailable {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        switches
                        if !hasScreenPermission, controller.capturesScreen {
                            permissionNotice
                        }
                        startGroup
                        lookGroup
                        perspectiveGroup
                        hapticsGroup
                    }
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 10)
                }
                .frame(height: Self.bodyHeight)
            } else {
                unavailableNotice
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 12)
            }
            Divider()
            appGroup
                .padding(.horizontal, Self.inset)
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .frame(width: Self.width)
        .onAppear { hasScreenPermission = CGPreflightScreenCaptureAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenPermission = CGPreflightScreenCaptureAccess()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Mac Duo").font(.title2.weight(.semibold))
            Spacer()
            Text(String(format: "%.1f°", controller.currentAngle))
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(localized("Lid angle"))
        }
    }

    private var unavailableNotice: some View {
        Text(localized("This Mac has no lid angle sensor. Only some MacBook models have one."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Escape only helps someone who knew about it before the picture
            // covered this panel.
            toggleRow(
                localized("Depth effect"),
                isOn: $preferences.isEnabled,
                help: localized("Leans the screen away as the lid closes.")
                    + "\n" + localized("Press Esc to end it at once.")
            )
            toggleRow(
                localized("Screen capture"),
                isOn: capturesScreen,
                help: WindowServerBlur.isAvailable
                    ? localized("Draws the effect from a capture of the screen, with lean and perspective. Needs Screen Recording permission and more power. Off, macOS blurs and dims the live screen itself.")
                    : localized("macOS on this Mac cannot blur the screen itself, so the effect captures it.")
            )
            .disabled(!preferences.isEnabled || !WindowServerBlur.isAvailable)
            toggleRow(
                localized("Live rendering"),
                isOn: $preferences.isLivePicture,
                help: localized("Off holds the frame from when the effect started.")
            )
            // The glass always shows the live screen.
            .disabled(!preferences.isEnabled || !controller.capturesScreen)
        }
    }

    /// On, and fixed, when the window server cannot draw the glass.
    private var capturesScreen: Binding<Bool> {
        Binding(
            get: { controller.capturesScreen },
            set: { preferences.capturesScreen = $0 }
        )
    }

    private var startGroup: some View {
        group(localized("Start")) {
            toggleRow(
                localized("Timeout"),
                isOn: $preferences.isTimeoutEnabled,
                help: localized("Ends the effect once the angle stops changing.")
            )
            slider(
                localized("Start angle"), value: $preferences.thresholdAngle, in: 5...130, format: "%.0f°",
                help: startAngleHelp
            )
            slider(
                localized("Full effect after"), value: $preferences.blurSpan, in: 5...100, format: "%.0f°",
                help: localized("Degrees of further closing to reach full strength.")
            )
        }
    }

    /// Names the angle in force when the hinge holds the setting down. The
    /// slider keeps the setting, which applies again on a lid that opens wider.
    private var startAngleHelp: String {
        let help = localized("The effect starts at this angle.")
        let effective = controller.effectiveThreshold
        guard effective.rounded() < preferences.thresholdAngle.rounded() else { return help }
        let lowered = String(format: localized("Lowered to %.0f° so opening the lid fully still ends the effect."), effective)
        return help + "\n" + lowered
    }

    private var lookGroup: some View {
        group(localized("Look")) {
            // The glass blurs and dims by the same rules as the captured
            // picture; only the lean is left out.
            slider(
                localized("Blur"), value: $preferences.maxBlurRadius, in: 10...160, format: "%.0f pt",
                help: localized("Blur radius at the far edge.")
            )
            slider(
                localized("Blur spread"), value: $preferences.blurEvenness, in: 0...1, format: "%.0f%%", scale: 100,
                help: localized("0 blurs the far edge only, 100 the whole picture.")
            )
            slider(
                localized("Dimming"), value: $preferences.maxDim, in: 0...1, format: "%.0f%%", scale: 100,
                help: localized("How dark the far edge goes.")
            )
            slider(
                localized("Dimming spread"), value: $preferences.dimReach, in: 0.2...1, format: "%.0f%%", scale: 100,
                help: localized("Everything above this height goes fully dark.")
            )
        }
    }

    private var perspectiveGroup: some View {
        group(localized("Perspective")) {
            slider(
                localized("Lean back"), value: $preferences.recession, in: 0...3, format: "%.1f×",
                help: localized("Degrees of lean per degree of closing. 1 holds it still.")
            )
            slider(
                localized("Max lean"), value: $preferences.maxLean, in: 10...85, format: "%.0f°",
                help: localized("The picture stops leaning back past this angle.")
            )
            slider(
                localized("Perspective"), value: perspective, in: 0...1, format: "%.0f%%", scale: 100,
                help: localized("0 keeps the sides parallel, 100 converges sharply.")
            )
        }
        // The glass leans as the captured picture does, where the window
        // server can mesh a layer.
        .disabled(!controller.capturesScreen && !GlassMesh.isAvailable)
    }

    private var hapticStyle: HapticPattern.Style {
        HapticPattern.Style(rawValue: preferences.hapticStyle) ?? .exponential
    }

    private var hapticsGroup: some View {
        group(localized("Haptics")) {
            toggleRow(
                localized("Trackpad taps"),
                isOn: $preferences.isHapticsEnabled,
                help: localized("Taps the trackpad as the lid closes. Felt with a finger resting on it.")
            )
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(localized("Pattern"))
                        Spacer()
                        Picker("", selection: $preferences.hapticStyle) {
                            ForEach(HapticPattern.Style.allCases) { style in
                                Text(localized(style.titleKey)).tag(style.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel(localized("Pattern"))
                        Button(localized("Try")) { controller.tryHaptics() }
                            .controlSize(.small)
                    }
                    description(localized(hapticStyle.summaryKey))
                }
                slider(
                    localized("Strength"), value: $preferences.hapticStrength, in: 0.1...1, format: "%.0f%%", scale: 100
                )
                slider(
                    localized("Taps"), value: $preferences.hapticTaps, in: 4...48, format: "%.0f",
                    help: localized("Over the whole closing travel.")
                )
                .disabled(!hapticStyle.usesTapCount)
                toggleRow(localized("While opening"), isOn: $preferences.isHapticsOnOpening, help: nil)
            }
            .disabled(!preferences.isHapticsEnabled)
        }
    }

    private var appGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localized("Language"))
                Spacer()
                Picker("", selection: $language) {
                    Text(localized("System")).tag("")
                    Text(verbatim: "English").tag(SettingsLanguage.english.rawValue)
                    Text(localized("Chinese (Simplified)")).tag(SettingsLanguage.chinese.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(localized("Language"))
            }
            toggleRow(
                localized("Show icon in menu bar"),
                isOn: $preferences.showsMenuBarIcon,
                help: localized("When off, open Mac Duo again to show these settings.")
            )
            toggleRow(localized("Show angle in menu bar"), isOn: $preferences.showsAngleInMenuBar, help: nil)
                .disabled(!preferences.showsMenuBarIcon)
            toggleRow(localized("Launch at login"), isOn: $launchesAtLogin, help: nil)
                .onChange(of: launchesAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }
            HStack {
                Button(localized("Reset")) { preferences.resetToDefaults() }
                Spacer()
                Button(localized("Quit"), action: onQuit)
            }
            .controlSize(.small)
            .padding(.top, 2)
            HStack(spacing: 0) {
                Text(localized("Made by ")).foregroundStyle(.secondary)
                Link("Makito", destination: Self.authorURL)
                    .pointingHand()
                Spacer()
                Text("© 2026 Makito").foregroundStyle(.secondary)
            }
            .font(.caption2)
            .padding(.top, 2)
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(title)
            }
            description(help)
        }
    }

    @ViewBuilder
    private func description(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var perspective: Binding<Double> {
        Binding(
            get: { (Preferences.farthestEye - preferences.viewingDistance) / Preferences.eyeRange },
            set: { preferences.viewingDistance = Preferences.farthestEye - $0 * Preferences.eyeRange }
        )
    }

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
                Text(localized("Could not open System Settings. Open it manually and enable screen recording for Mac Duo under Privacy & Security."))
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

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .disabled(!preferences.isEnabled)
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String,
        scale: Double = 1,
        help: String? = nil
    ) -> some View {
        let reading = String(format: format, value.wrappedValue * scale)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(reading)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(reading)
            description(help)
        }
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
