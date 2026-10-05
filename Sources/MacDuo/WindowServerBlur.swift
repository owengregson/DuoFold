import Foundation
import QuartzCore

/// Everything Mac Duo asks of private Core Animation, kept in one place.
///
/// `CABackdropLayer` shows a copy of whatever the window server has drawn
/// behind it, run through its filters, live and on the GPU, without this
/// process ever seeing the pixels. That is how the frosted glass blurs the
/// screen with no capture and no Screen Recording permission. `CAFilter`
/// supplies the `gaussianBlur` the bands run.
///
/// Neither class is public, so both are looked up by name and checked once
/// before anything is built: the classes must exist, the filter type must be
/// one `+[CAFilter filterTypes]` lists, every input key set must be one the
/// filter's `inputKeys` lists, and every layer property set must have a
/// setter. Key-value coding on a missing key raises an Objective-C
/// exception, which Swift cannot catch, so nothing is set unchecked. When a
/// check fails, `isAvailable` is false and the app captures the screen
/// instead.
///
/// Used on the main thread only, like any layer.
enum WindowServerBlur {

    /// Gaussian sigma, in points, per point of `inputRadius`.
    ///
    /// Measured offscreen through `CARenderer`, which runs the same Core
    /// Animation renderer as the window server: a sinusoidal grating behind a
    /// band loses half its contrast at `k · radius` between 1.14 and 1.23
    /// for radii of 2 to 24 points, against 1.18 for a Gaussian of sigma
    /// `radius`, and keeps 0.11, 0.58 and 0.77 of it at periods of 3, 6 and 9
    /// radii, against 0.11, 0.58 and 0.78. The radius is in layer points: a
    /// tree drawn at twice the scale blurs twice as many pixels. Drawn at
    /// twice the scale, as on a Retina screen, an edge behind a band spreads
    /// by a sigma of 0.90 to 0.99 radii for radii of 2 to 107 points, the
    /// widest blur the settings reach.
    static let sigmaPerRadius = 1.0

    /// Whether the window server can draw the frosted glass on this system.
    static var isAvailable: Bool { runtime != nil }

    private struct Runtime {
        let backdropClass: CALayer.Type
        let filterClass: NSObject.Type
        /// The optional blur inputs this system's filter accepts.
        let optionalInputs: Set<String>
        /// Whether this system has the reach filter (`makeReach`).
        let hasReach: Bool
    }

    private static let filterType = "gaussianBlur"
    private static let radiusKey = "inputRadius"

    /// How far the window server redraws around a change under a band, in
    /// points, through the reach filter (`makeReach`). Wider than any
    /// screen, so a change anywhere under a band has all of it redrawn.
    static let damageReach = 8192.0
    private static let reachType = "displacementMap"
    private static let reachAmountKey = "inputAmount"
    private static let reachOffsetKey = "inputOffset"
    private static let reachMapKey = "inputMaskImage"
    /// Clamps the blur at the band's edges instead of fading it to nothing.
    private static let normalizeEdgesKey = "inputNormalizeEdges"
    /// A wide blur of a dark screen is a smooth near-black gradient, which 8
    /// bits draw as contour bands. Dithered, it reads as one gradient.
    private static let ditherKey = "inputDither"

    private static let runtime: Runtime? = lookUp()

    private static func lookUp() -> Runtime? {
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else {
            Diagnostics.geometry.notice("window server blur: private classes missing")
            return nil
        }
        let probe = backdropClass.init()
        for setter in ["setGroupName:", "setWindowServerAware:"]
        where !probe.responds(to: NSSelectorFromString(setter)) {
            Diagnostics.geometry.notice("window server blur: backdrop has no \(setter, privacy: .public)")
            return nil
        }
        let typesSelector = NSSelectorFromString("filterTypes")
        guard filterClass.responds(to: typesSelector),
              filterClass.responds(to: NSSelectorFromString("filterWithType:")),
              let types = filterClass.perform(typesSelector)?.takeUnretainedValue() as? [String],
              types.contains(filterType),
              let filter = makeFilter(filterClass) else {
            Diagnostics.geometry.notice("window server blur: no \(filterType, privacy: .public) filter")
            return nil
        }
        let keysSelector = NSSelectorFromString("inputKeys")
        guard filter.responds(to: keysSelector),
              let keys = filter.perform(keysSelector)?.takeUnretainedValue() as? [String],
              keys.contains(radiusKey) else {
            Diagnostics.geometry.notice("window server blur: filter takes no radius")
            return nil
        }
        var hasReach = false
        if types.contains(reachType),
           let reach = filterClass.perform(NSSelectorFromString("filterWithType:"), with: reachType)?.takeUnretainedValue() as? NSObject,
           let reachKeys = reach.perform(keysSelector)?.takeUnretainedValue() as? [String],
           Set(reachKeys).isSuperset(of: [reachAmountKey, reachOffsetKey, reachMapKey]) {
            hasReach = true
        } else {
            Diagnostics.geometry.notice("window server blur: no \(reachType, privacy: .public) filter, bands redraw only around a change")
        }
        return Runtime(
            backdropClass: backdropClass,
            filterClass: filterClass,
            optionalInputs: Set(keys).intersection([normalizeEdgesKey, ditherKey]),
            hasReach: hasReach
        )
    }

    /// A filter that draws nothing but makes the window server redraw all
    /// of a band whenever anything under it changes.
    ///
    /// The window server redraws only what changed, and under a backdrop it
    /// widens that by the radius the backdrop's first blur-like filter
    /// reports (QuartzCore `Update::all_backdrop_info`, SkyLight
    /// `adjust_update_shapes_for_backdrops`). A leaning band shows each
    /// spot of the screen somewhere else, so a redraw of just the change
    /// and its blur reads black beyond what it captured and leaves the
    /// moved picture stale. A `displacementMap` ahead of the blur reports
    /// `|inputAmount|` as its radius whatever it draws; with a white map
    /// and an offset of one it moves nothing, so the band's picture is the
    /// blur's alone (`GlassDisplacementFilterTests`), while the window
    /// server redraws the whole band, and every band overlapping it, for
    /// any change under them.
    private static func makeReach(_ runtime: Runtime) -> NSObject? {
        guard runtime.hasReach,
              let reach = runtime.filterClass.perform(NSSelectorFromString("filterWithType:"), with: reachType)?
                  .takeUnretainedValue() as? NSObject,
              let map = whiteMap else { return nil }
        reach.setValue(damageReach, forKey: reachAmountKey)
        reach.setValue(CGPoint(x: 1, y: 1), forKey: reachOffsetKey)
        reach.setValue(map, forKey: reachMapKey)
        return reach
    }

    private static let whiteMap: CGImage? = {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()
    }()

    private static func makeFilter(_ filterClass: NSObject.Type) -> NSObject? {
        filterClass.perform(NSSelectorFromString("filterWithType:"), with: filterType)?
            .takeUnretainedValue() as? NSObject
    }

    /// A layer that shows the window server's drawing behind it, blurred
    /// uniformly. Every band given the same `groupName` shares one capture
    /// of the screen, taken before any of them draws, so none blurs
    /// another's output.
    ///
    /// - Parameter samplesOtherWindows: false limits the backdrop to layers
    ///   behind it in its own tree, which an offscreen check can render.
    static func makeBand(groupName: String, samplesOtherWindows: Bool = true) -> CALayer? {
        guard let runtime else { return nil }
        let band = runtime.backdropClass.init()
        band.setValue(samplesOtherWindows, forKey: "windowServerAware")
        band.setValue(groupName, forKey: "groupName")
        setRadius(0, of: band)
        return band
    }

    /// Sets the band's blur radius, in points. The blur is the last filter;
    /// the reach filter (`makeReach`), if this system has it, runs first.
    ///
    /// A fresh filter rather than a key path into the attached one: every
    /// step of it is checked above, and assigning `filters` always reaches
    /// the window server.
    static func setRadius(_ radius: Double, of band: CALayer) {
        guard let runtime, let filter = makeFilter(runtime.filterClass) else { return }
        filter.setValue(max(radius, 0), forKey: radiusKey)
        for key in runtime.optionalInputs {
            filter.setValue(true, forKey: key)
        }
        band.filters = [makeReach(runtime), filter].compactMap { $0 }
    }

    /// The blur filter of a band `setRadius` set up.
    static func blurFilter(of band: CALayer) -> NSObject? {
        band.filters?.last as? NSObject
    }
}
