import AppKit
import QuartzCore

/// The effect drawn entirely by the window server, on whatever is behind the
/// overlay. Nothing is captured, so it needs no Screen Recording permission,
/// runs no capture stream and draws nothing on the GPU from this process.
///
/// It draws `FrostedGlass`: each height up the glass is blurred as much as a
/// frosted sheet lifted that far off the screen would blur it, by a stack of
/// uniform blur bands (`FrostBandLayout`), and darkened by the share of its
/// light that would miss the screen, by one black layer whose opacity comes
/// from a small grid.
///
/// Built only when `WindowServerBlur.isAvailable`.
@MainActor
final class FrostedGlassView: NSView {

    /// Shared by every band, so they draw from one capture of the screen.
    private static let groupName = "MacDuo.frostedGlass"
    /// Darkening grid columns across the glass. It varies slowly, and the
    /// layer interpolates between its points.
    private static let shadeColumns = 64

    private let bandLayout = FrostBandLayout()
    private let samplesOtherWindows: Bool
    private var bands: [CALayer] = []
    private let shade = CALayer()
    private var lastState: State?
    /// Brightness grids by whole degree of lift, for `cachedSize`.
    private var brightnessCache: [Int: [Double]] = [:]
    private var cachedSize: CGSize = .zero

    private struct State: Equatable {
        var lift: Double
        var frost: Double
        var darkness: Double
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
        shade.contentsGravity = .resize
        shade.magnificationFilter = .linear
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
            apply(lift: lastState.lift, frost: lastState.frost, darkness: lastState.darkness)
        }
    }

    /// - Parameters:
    ///   - lift: the angle between the glass and the screen it left, radians.
    ///   - frost: how diffuse the glass is. One scatters like tracing paper,
    ///     zero is clear.
    ///   - darkness: how much of the light the lifted glass loses shows as
    ///     dark. One is all of it.
    func apply(lift: Double, frost: Double, darkness: Double) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let state = State(
            lift: min(max(lift, 0), .pi / 2),
            frost: max(frost, 0),
            darkness: min(max(darkness, 0), 1),
            size: size
        )
        guard state != lastState else { return }
        lastState = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let height = Double(size.height)
        let sigmaPerHeight = state.frost * FrostedGlass.gaussianSigmaPerHeight(lift: state.lift)
        // Points of blur radius per point up the glass.
        let radiusPerHeight = sigmaPerHeight * sin(state.lift) / WindowServerBlur.sigmaPerRadius
        let planned = bandLayout.bands(
            radiusPerHeight: radiusPerHeight,
            height: height,
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

        shade.isHidden = state.lift < 1e-4 || state.darkness <= 0
        if !shade.isHidden, let shaded = shadeImage(for: state) {
            shade.frame = shaded.frame
            shade.contents = shaded.image
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
        // last stop to its top.
        var locations: [NSNumber] = [0]
        var colours: [CGColor] = [CGColor(gray: 0, alpha: 0)]
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

    // MARK: - Darkening

    /// The black layer's opacity on a grid, and where the layer goes: half a
    /// grid cell past the glass on every side, so the cells' centres, where
    /// the layer is exact, fall on the grid points, edges included.
    private func shadeImage(for state: State) -> (image: CGImage, frame: CGRect)? {
        let size = state.size
        let columns = Self.shadeColumns
        let rows = max(Int((Double(columns) * Double(size.height) / Double(size.width)).rounded()), 2)
        if size != cachedSize {
            brightnessCache = [:]
            cachedSize = size
        }
        // Whole degree grids, mixed for the angle in between.
        let degrees = state.lift * 180 / .pi
        let lower = Int(degrees.rounded(.down))
        let mix = degrees - Double(lower)
        let below = brightness(degree: lower, columns: columns, rows: rows, size: size)
        let above = mix > 1e-6 ? brightness(degree: lower + 1, columns: columns, rows: rows, size: size) : below

        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        for row in 0..<rows {
            // Image rows run from the top; grid rows from the hinge.
            let imageRow = rows - 1 - row
            for column in 0..<columns {
                let index = row * columns + column
                let kept = below[index] + (above[index] - below[index]) * mix
                // The light lost is a share of linear light, but the window
                // server blends the black over encoded values, so the share
                // goes in through the display's transfer curve.
                let alpha = state.darkness * (1 - pow(max(kept, 0), 1 / 2.2))
                pixels[(imageRow * columns + column) * 4 + 3] = UInt8((min(max(alpha, 0), 1) * 255).rounded())
            }
        }
        let image = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            CGContext(
                data: bytes.baseAddress,
                width: columns,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: columns * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        guard let image else { return nil }
        let cellWidth = Double(size.width) / Double(columns - 1)
        let cellHeight = Double(size.height) / Double(rows - 1)
        let frame = CGRect(
            x: -cellWidth / 2,
            y: -cellHeight / 2,
            width: Double(size.width) + cellWidth,
            height: Double(size.height) + cellHeight
        )
        return (image, frame)
    }

    private func brightness(degree: Int, columns: Int, rows: Int, size: CGSize) -> [Double] {
        if let cached = brightnessCache[degree] { return cached }
        let grid = FrostedGlass.brightnessGrid(
            lift: Double(degree) * .pi / 180,
            width: Double(size.width),
            height: Double(size.height),
            columns: columns,
            rows: rows
        )
        brightnessCache[degree] = grid
        return grid
    }
}
