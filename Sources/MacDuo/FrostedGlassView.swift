import AppKit
import QuartzCore

/// The effect drawn entirely by the window server, on whatever is behind the
/// overlay. Nothing is captured, so it needs no Screen Recording permission,
/// runs no capture stream and draws nothing on the GPU from this process.
///
/// It blurs and dims by the same rules as the captured picture
/// (`BlurGradient`), with the same settings, and only leaves out the lean:
/// each height is blurred by a stack of uniform blur bands
/// (`FrostBandLayout`), and darkened by one black layer whose opacity rises
/// from the hinge.
///
/// Built only when `WindowServerBlur.isAvailable`.
@MainActor
final class FrostedGlassView: NSView {

    /// Shared by every band, so they draw from one capture of the screen.
    private static let groupName = "MacDuo.frostedGlass"
    /// Darkening stops across the dimming's rise. The layer runs straight
    /// between them, which keeps within a step of 8 bits of the smoothstep.
    nonisolated private static let shadeIntervals = 24

    private let bandLayout = FrostBandLayout()
    private let samplesOtherWindows: Bool
    private var bands: [CALayer] = []
    private let shade = CAGradientLayer()
    private var lastState: State?

    private struct State: Equatable {
        var progress: Double
        var tuning: DepthTuning
        var gradient: BlurGradient
        var size: CGSize
    }

    /// - Parameter samplesOtherWindows: false blurs only layers behind the
    ///   bands in this view's own tree, for offscreen checks.
    init(frame: NSRect, scale: CGFloat, samplesOtherWindows: Bool = true) {
        self.samplesOtherWindows = samplesOtherWindows
        super.init(frame: frame)
        let root = CALayer()
        root.contentsScale = scale
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        shade.anchorPoint = .zero
        shade.startPoint = CGPoint(x: 0.5, y: 0)
        shade.endPoint = CGPoint(x: 0.5, y: 1)
        shade.isHidden = true
        root.addSublayer(shade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        CATransaction.commit()
        if let lastState {
            apply(progress: lastState.progress, tuning: lastState.tuning, gradient: lastState.gradient)
        }
    }

    /// - Parameter progress: how far the lid has closed past the start
    ///   angle, as a share of the travel to full effect, as the captured
    ///   picture gets it.
    func apply(progress: Double, tuning: DepthTuning, gradient: BlurGradient) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let state = State(progress: min(max(progress, 0), 1), tuning: tuning, gradient: gradient, size: size)
        guard state != lastState else { return }
        lastState = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let height = Double(size.height)
        let planned = bandLayout.bands(
            for: Self.blurProfile(progress: state.progress, tuning: tuning, gradient: gradient, height: height),
            // Past half the glass's height a blur is a wash of colour
            // whatever its radius, and a wider one only captures more of the
            // screen. The settings stay well short of it.
            maximumRadius: height / 2
        )
        while bands.count < planned.count, let band = makeBand() {
            layer?.insertSublayer(band, below: shade)
            bands.append(band)
        }
        for (index, band) in bands.enumerated() {
            guard index < planned.count else {
                band.isHidden = true
                continue
            }
            place(band, as: planned[index], width: Double(size.width))
        }

        let stops = Self.shadeStops(progress: state.progress, tuning: tuning, gradient: gradient, height: height)
        shade.isHidden = !stops.contains { $0.opacity > 0 }
        if !shade.isHidden {
            shade.frame = bounds
            shade.locations = stops.map { NSNumber(value: $0.position / height) }
            shade.colors = stops.map { CGColor(gray: 0, alpha: $0.opacity) }
        }
    }

    /// The blur up the glass in band radii: the captured picture's sigma at
    /// each height, through the window server's radius to sigma.
    nonisolated static func blurProfile(
        progress: Double,
        tuning: DepthTuning,
        gradient: BlurGradient,
        height: Double
    ) -> FrostBandLayout.Profile {
        let span = gradient.sigmaSpan(
            progress: progress,
            maxBlurRadius: tuning.maxBlurRadius,
            evenness: min(max(tuning.blurEvenness, 0), 1)
        )
        return FrostBandLayout.Profile(
            floor: span.hinge / WindowServerBlur.sigmaPerRadius,
            rise: span.range / WindowServerBlur.sigmaPerRadius,
            exponent: gradient.blurHeightCurve,
            height: height
        )
    }

    /// The black layer's opacity up the glass: the share of brightness the
    /// captured picture loses at each height.
    ///
    /// The window server blends the black over encoded values, taking that
    /// share of them away, which is what the picture's shader does through
    /// its 2.2 power on linear light.
    nonisolated static func shadeStops(
        progress: Double,
        tuning: DepthTuning,
        gradient: BlurGradient,
        height: Double
    ) -> [FrostBandLayout.Stop] {
        // Past the reach the dimming holds, so one more stop at the top.
        let reach = min(max(tuning.dimReach, 0.02), 1)
        var shares = (0...shadeIntervals).map { reach * Double($0) / Double(shadeIntervals) }
        if reach < 1 { shares.append(1) }
        return shares.map { share in
            FrostBandLayout.Stop(
                position: share * height,
                opacity: gradient.dimming(progress: progress, height: share, maxDim: tuning.maxDim, reach: reach)
            )
        }
    }

    private func makeBand() -> CALayer? {
        guard let band = WindowServerBlur.makeBand(
            groupName: Self.groupName,
            samplesOtherWindows: samplesOtherWindows
        ) else { return nil }
        band.anchorPoint = .zero
        band.contentsScale = layer?.contentsScale ?? 2
        band.isHidden = true
        let fade = CAGradientLayer()
        fade.anchorPoint = .zero
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        band.mask = fade
        return band
    }

    private func place(_ band: CALayer, as plan: FrostBandLayout.Band, width: Double) {
        let extent = plan.top - plan.bottom
        guard extent > 0 else {
            band.isHidden = true
            return
        }
        band.isHidden = false
        band.frame = CGRect(x: 0, y: plan.bottom, width: width, height: extent)
        WindowServerBlur.setRadius(plan.radius, of: band)
        guard let fade = band.mask as? CAGradientLayer else { return }
        fade.frame = band.bounds
        // Clear from the band's bottom to the first stop, opaque from the
        // last stop to its top. A band opaque from the hinge, over a blurred
        // hinge, has no clear part.
        var locations: [NSNumber] = []
        var colours: [CGColor] = []
        if let first = plan.fade.first, first.position > plan.bottom {
            locations.append(0)
            colours.append(CGColor(gray: 0, alpha: 0))
        }
        for stop in plan.fade {
            let location = min(max((stop.position - plan.bottom) / extent, 0), 1)
            locations.append(NSNumber(value: location))
            colours.append(CGColor(gray: 0, alpha: stop.opacity))
        }
        locations.append(1)
        colours.append(CGColor(gray: 0, alpha: 1))
        fade.locations = locations
        fade.colors = colours
    }
}
