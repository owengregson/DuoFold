import SwiftUI

/// The lid angle on a track from shut, at the left, to fully open. The
/// stretch where the effect builds is shaded, darkest where it reaches full
/// strength, so the start settings read against the lid as it moves.
struct LidGauge: View {
    var angle: Double
    /// The start angle in force.
    var start: Double
    /// Degrees of further closing to full strength.
    var span: Double
    /// The widest the lid opens, the right end of the track.
    var limit: Double
    var isOn: Bool

    private static let trackHeight: CGFloat = 4
    private static let needleSize: CGFloat = 10

    private var full: Double { max(start - span, 0) }
    private var isInEffect: Bool { isOn && angle < start }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = { (angle: Double) -> CGFloat in
                CGFloat(min(max(angle / limit, 0), 1)) * width
            }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(LinearGradient(
                        colors: [.accentColor, .accentColor.opacity(0.15)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(x(start) - x(full), Self.trackHeight), height: Self.trackHeight)
                    .offset(x: x(full))
                    .opacity(isOn ? 1 : 0.35)
                Capsule()
                    .fill(.secondary)
                    .frame(width: 1.5, height: 10)
                    .offset(x: x(start) - 0.75)
                Circle()
                    .fill(isInEffect ? Color.accentColor : Color.secondary)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                    .frame(width: Self.needleSize, height: Self.needleSize)
                    .offset(x: x(angle) - Self.needleSize / 2)
                    .animation(.easeOut(duration: 0.12), value: angle)
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: Self.needleSize)
        .accessibilityHidden(true)
    }
}
