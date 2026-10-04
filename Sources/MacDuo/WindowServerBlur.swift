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
    /// tree drawn at twice the scale blurs twice as many pixels.
    static let sigmaPerRadius = 1.0

    /// Whether the window server can draw the frosted glass on this system.
    static var isAvailable: Bool { runtime != nil }

    private struct Runtime {
        let backdropClass: CALayer.Type
        let filterClass: NSObject.Type
        /// The optional blur inputs this system's filter accepts.
        let optionalInputs: Set<String>
    }

    private static let filterType = "gaussianBlur"
    private static let radiusKey = "inputRadius"
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
        return Runtime(
            backdropClass: backdropClass,
            filterClass: filterClass,
            optionalInputs: Set(keys).intersection([normalizeEdgesKey, ditherKey])
        )
    }

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

    /// Sets the band's blur radius, in points.
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
        band.filters = [filter]
    }
}
