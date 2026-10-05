import AppKit
import QuartzCore

/// The effect drawn entirely by the window server, on whatever is behind the
/// overlay. Nothing is captured, so it needs no Screen Recording permission,
/// runs no capture stream and draws nothing on the GPU from this process.
///
/// It draws what the captured picture draws, by the same rules
/// (`BlurGradient`) and with the same settings:
/// - each height is blurred by a stack of uniform blur bands
///   (`FrostBandLayout`) over a sharp copy of the screen, and darkened by one
///   black layer whose opacity rises from the hinge;
/// - the picture leans back as the captured picture does: every layer is
///   laid out flat and carried by a mesh to where `GlassLean` puts it;
/// - the captured picture's blur takes in the black margin around it, which
///   darkens its edges and spreads a little of them into the margin. The
///   glass stretches each band's edge into the margin, and darkens edges and
///   margin by the share of the blur at each point that falls on the
///   picture rather than the margin;
/// - past the margin, black.
///
/// Built only when `WindowServerBlur.isAvailable`.
@MainActor
final class FrostedGlassView: NSView {

    /// Shared by every band, so they draw from one capture of the screen.
    private static let groupName = "MacDuo.frostedGlass"
    /// Darkening stops across the dimming's rise. The layer runs straight
    /// between them, which keeps within a step of 8 bits of the smoothstep.
    nonisolated private static let shadeIntervals = 24
    /// How far the edge darkening reaches each way, in blur sigmas. Past four
    /// the share of the blur on the other side is under a hundred thousandth.
    nonisolated private static let edgeReach = 4.0
    /// Stops across the edge darkening. Straight runs between them keep
    /// within a fifth of a step of 8 bits of the true curve.
    nonisolated private static let edgeStops = 33
    /// Rows of mesh over the screen's height. The lean squeezes the picture
    /// more toward the top, and between rows a mesh runs straight; at this
    /// many the rows stay within a hundredth of a point of the true lean.
    nonisolated private static let meshRows = 64

    private let bandLayout = FrostBandLayout()
    private let samplesOtherWindows: Bool
    /// A sharp copy of the screen under the bands, so the leaning picture
    /// shows the screen where no band blurs it.
    private var base: CALayer?
    private var bands: [CALayer] = []
    private let shade = CAGradientLayer()
    /// Left, right, top and hinge edges, darkened as the blur takes in the
    /// margin beyond each.
    private let edges = (0..<4).map { _ in CAGradientLayer() }
    /// Black past the margin.
    private let surround = CAShapeLayer()
    private var lastState: State?

    private struct State: Equatable {
        var progress: Double
        var tuning: DepthTuning
        var gradient: BlurGradient
        var size: CGSize
        var lean: GlassLean
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

        if GlassMesh.isAvailable, let base = WindowServerBlur.makeBand(
            groupName: Self.groupName,
            samplesOtherWindows: samplesOtherWindows
        ) {
            base.anchorPoint = .zero
            base.contentsScale = scale
            base.isHidden = true
            root.addSublayer(base)
            self.base = base
        }

        shade.anchorPoint = .zero
        shade.startPoint = CGPoint(x: 0.5, y: 0)
        shade.endPoint = CGPoint(x: 0.5, y: 1)
        shade.isHidden = true
        root.addSublayer(shade)

        let profile = Self.edgeProfile()
        for edge in edges {
            edge.anchorPoint = .zero
            edge.startPoint = CGPoint(x: 0, y: 0.5)
            edge.endPoint = CGPoint(x: 1, y: 0.5)
            edge.locations = profile.map { NSNumber(value: $0.position) }
            edge.colors = profile.map { CGColor(gray: 0, alpha: $0.opacity) }
            edge.isHidden = true
            root.addSublayer(edge)
        }

        surround.anchorPoint = .zero
        surround.fillColor = CGColor(gray: 0, alpha: 1)
        surround.fillRule = .evenOdd
        surround.isHidden = true
        root.addSublayer(surround)
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
            apply(progress: lastState.progress, tuning: lastState.tuning, gradient: lastState.gradient, lean: lastState.lean)
        }
    }

    /// - Parameters:
    ///   - progress: how far the lid has closed past the start angle, as a
    ///     share of the travel to full effect, as the captured picture gets
    ///     it.
    ///   - lean: where the picture lies on screen; flat when `nil`, or when
    ///     this system cannot mesh a layer.
    func apply(progress: Double, tuning: DepthTuning, gradient: BlurGradient, lean: GlassLean? = nil) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = layer?.contentsScale ?? 2
        let flat = GlassLean.flat(screenSize: size, pixelScale: scale)
        var lean = GlassMesh.isAvailable ? (lean ?? flat) : flat
        lean.screenSize = size
        let state = State(progress: min(max(progress, 0), 1), tuning: tuning, gradient: gradient, size: size, lean: lean)
        guard state != lastState else { return }
        lastState = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let height = Double(size.height)
        let leans = !lean.isFlat
        let rows = { (bottom: Double, top: Double) in max(Int((Double(Self.meshRows) * (top - bottom) / height).rounded(.up)), 2) }

        if let base {
            base.isHidden = !leans
            if leans {
                base.frame = CGRect(origin: .zero, size: size)
                GlassMesh.apply(lean.meshParts(for: lean.pictureGrid(bottom: 0, top: height, rows: Self.meshRows), layerFrame: base.frame), to: base)
            }
        }

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
            let plan = planned[index]
            guard let shown = place(band, as: plan, lean: lean, leans: leans) else { continue }
            GlassMesh.apply(
                leans
                    ? lean.meshParts(
                        for: lean.pictureGrid(bottom: plan.bottom, top: plan.top, rows: rows(plan.bottom, plan.top), layerRows: shown),
                        layerFrame: band.frame
                    )
                    : ([], []),
                to: band
            )
        }

        let stops = Self.shadeStops(progress: state.progress, tuning: tuning, gradient: gradient, height: height)
        shade.isHidden = !stops.contains { $0.opacity > 0 }
        if !shade.isHidden {
            shade.frame = bounds
            shade.locations = stops.map { NSNumber(value: $0.position / height) }
            shade.colors = stops.map { CGColor(gray: 0, alpha: $0.opacity) }
            GlassMesh.apply(leans ? lean.meshParts(for: lean.pictureGrid(bottom: 0, top: height, rows: Self.meshRows), layerFrame: bounds) : ([], []), to: shade)
        }

        let sigma = { (picture: Double) in
            gradient.sigma(progress: state.progress, height: picture / height,
                           maxBlurRadius: tuning.maxBlurRadius, evenness: min(max(tuning.blurEvenness, 0), 1))
        }
        for (edge, grid) in zip(edges, Self.edgeGrids(lean: lean, sigma: sigma)) {
            edge.isHidden = grid == nil || !GlassMesh.isAvailable
            guard let grid, !edge.isHidden else { continue }
            edge.frame = bounds
            GlassMesh.apply(lean.meshParts(for: grid, layerFrame: bounds), to: edge)
        }

        surround.isHidden = !leans
        if leans {
            surround.frame = bounds
            let path = CGMutablePath()
            path.addRect(bounds.insetBy(dx: -8, dy: -8))
            let padded = lean.padded
            path.addLines(between: [
                CGPoint(x: padded.minX, y: padded.minY), CGPoint(x: padded.maxX, y: padded.minY),
                CGPoint(x: padded.maxX, y: padded.maxY), CGPoint(x: padded.minX, y: padded.maxY),
            ].map(lean.screenPoint))
            path.closeSubpath()
            surround.path = path
        }
    }

    // MARK: - Blur and dimming

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

    // MARK: - Edges

    /// The darkening across an edge, along a layer's width: from well inside
    /// the picture at 0 to well out in the margin at 1. A Gaussian of sigma
    /// `s` centred `d` inside a straight edge has the share `Φ(d / s)` of
    /// itself on the picture, and the rest on the black margin. The captured
    /// picture blurs light, so it keeps that share of the light there, which
    /// keeps its 1 / 2.2 power of the encoded value the black is laid over,
    /// as the dimming has it (`shadeStops`).
    nonisolated static func edgeProfile() -> [FrostBandLayout.Stop] {
        (0..<edgeStops).map { index in
            let position = Double(index) / Double(edgeStops - 1)
            // Sigmas inside the edge: edgeReach at 0, -edgeReach at 1.
            let inside = edgeReach * (1 - 2 * position)
            let kept = 0.5 * erfc(-inside / 2.squareRoot())
            return FrostBandLayout.Stop(position: position, opacity: 1 - pow(kept, 1 / 2.2))
        }
    }

    /// Where each edge's darkening lies, as meshes of `edgeProfile` laid
    /// across the left, right, top and hinge edges, each `edgeReach` sigmas
    /// either side of the edge and stretched on out to the end of the
    /// margin. `nil` for an edge whose blur is too small to darken anything.
    nonisolated static func edgeGrids(lean: GlassLean, sigma: (Double) -> Double) -> [GlassLean.Grid?] {
        let width = Double(lean.screenSize.width), height = Double(lean.screenSize.height)
        let padded = lean.padded
        let overlap = 2.0
        let reach = edgeReach
        typealias Vertex = GlassLean.Vertex
        let visible = { (s: Double) in reach * s >= 0.1 }

        // Left and right: a row every so often up the height, the profile
        // running across the edge, its width following the blur there.
        let heights = (0...meshRows).map { Double(padded.maxY + overlap) * Double($0) / Double(meshRows) }
        func side(_ edge: Double, outward: Double) -> GlassLean.Grid? {
            guard heights.contains(where: { visible(sigma(min($0, height))) }) else { return nil }
            let far = outward < 0 ? Double(padded.minX) - overlap : Double(padded.maxX) + overlap
            return GlassLean.Grid(rows: heights.map { y in
                let s = sigma(min(y, height)), v = y / heights.last!
                let outer = edge + outward * reach * s
                return [
                    Vertex(from: CGPoint(x: 0, y: v), picture: CGPoint(x: edge - outward * reach * s, y: y)),
                    Vertex(from: CGPoint(x: 1, y: v), picture: CGPoint(x: outer, y: y)),
                    Vertex(from: CGPoint(x: 1, y: v), picture: CGPoint(x: outward < 0 ? min(outer, far) : max(outer, far), y: y)),
                ]
            })
        }

        // Top and hinge: one blur along each, the profile running up across
        // the edge, rows across it so the lean is followed.
        func across(_ edge: Double, outward: Double, s: Double) -> GlassLean.Grid? {
            guard visible(s) else { return nil }
            let far = outward > 0 ? Double(padded.maxY) + overlap : Double(padded.minY) - overlap
            let steps = 16
            var rows: [[Vertex]] = (0...steps).map { step in
                let u = Double(step) / Double(steps)
                let y = edge + outward * reach * s * (2 * u - 1)
                return [
                    Vertex(from: CGPoint(x: u, y: 0), picture: CGPoint(x: Double(padded.minX) - overlap, y: y)),
                    Vertex(from: CGPoint(x: u, y: 1), picture: CGPoint(x: Double(padded.maxX) + overlap, y: y)),
                ]
            }
            let outer = edge + outward * reach * s
            let last = outward > 0 ? max(outer, far) : min(outer, far)
            rows.append([
                Vertex(from: CGPoint(x: 1, y: 0), picture: CGPoint(x: Double(padded.minX) - overlap, y: last)),
                Vertex(from: CGPoint(x: 1, y: 1), picture: CGPoint(x: Double(padded.maxX) + overlap, y: last)),
            ])
            return GlassLean.Grid(rows: rows)
        }

        return [
            side(0, outward: -1),
            side(width, outward: 1),
            across(height, outward: 1, s: sigma(height)),
            across(0, outward: -1, s: sigma(0)),
        ]
    }

    // MARK: - Bands

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

    /// Lays a band out and fades it in, and returns its frame's bottom and
    /// top, or `nil` for a band with nothing to show.
    ///
    /// A mask is read where its layer shows rather than where the layer is
    /// laid out, and it clips the layer to the layer's frame. So a leaning
    /// band's frame reaches from the rows it captures to where they show, up
    /// to the top of the screen, and its fade sits where each of its rows
    /// shows. The lean keeps rows level, so a row's fade is exact across it.
    private func place(_ band: CALayer, as plan: FrostBandLayout.Band, lean: GlassLean, leans: Bool) -> ClosedRange<Double>? {
        let extent = plan.top - plan.bottom
        guard extent > 0 else {
            band.isHidden = true
            return nil
        }
        let width = Double(lean.screenSize.width), height = Double(lean.screenSize.height)
        let shows = { (y: Double) in leans ? Double(lean.screenPoint(CGPoint(x: width / 2, y: y)).y) : y }
        let reach = plan.top >= height ? Double(lean.padded.maxY) : plan.top
        let low = min(plan.bottom, shows(plan.bottom))
        let high = max(plan.top, min(shows(reach), height))
        band.isHidden = false
        band.frame = CGRect(x: 0, y: low, width: width, height: high - low)
        WindowServerBlur.setRadius(plan.radius, of: band)
        guard let fade = band.mask as? CAGradientLayer else { return low...high }
        fade.frame = band.bounds
        // Clear below the first stop, opaque from the last stop up. A band
        // opaque from the hinge, over a blurred hinge, has no clear part.
        let location = { (y: Double) in min(max((shows(y) - low) / (high - low), 0), 1) }
        var locations: [NSNumber] = []
        var colours: [CGColor] = []
        if let first = plan.fade.first, location(first.position) > 0 {
            locations.append(0)
            colours.append(CGColor(gray: 0, alpha: 0))
        }
        for stop in plan.fade {
            locations.append(NSNumber(value: location(stop.position)))
            colours.append(CGColor(gray: 0, alpha: stop.opacity))
        }
        locations.append(1)
        colours.append(CGColor(gray: 0, alpha: 1))
        fade.locations = locations
        fade.colors = colours
        return low...high
    }
}
