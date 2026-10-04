import AppKit
import IOKit

/// Taps the trackpad.
///
/// The Force Touch trackpad's actuator gives a range of tap strengths through
/// MultitouchSupport, a private framework, so it is looked up at run time.
/// Where it is missing, the public haptic patterns stand in: three kinds of
/// tap, felt only while a finger rests on the trackpad.
final class TrackpadHaptics: @unchecked Sendable {

    /// Actuations run here, off the main thread, so a slow one cannot hold up
    /// a frame. The actuator is only touched from this queue.
    private let queue = DispatchQueue(label: "MacDuo.haptics", qos: .userInteractive)
    private var actuator: Actuator?
    private var hasLookedForActuator = false

    /// Taps closer together than this merge into one.
    private static let minimumSpacing: TimeInterval = 0.008

    /// Plays one tap. `strength` runs from 0, nothing, to 1, the firmest tap.
    func tap(strength: Double) {
        guard strength > 0.01 else { return }
        queue.async { self.perform(strength: strength) }
    }

    /// Lets go of the actuator once a run is over, so the trackpad's own
    /// clicks are not competing with an open handle.
    func rest() {
        queue.async { self.actuator?.close() }
    }

    /// Plays `pattern` as if the lid closed through the whole travel in
    /// `duration`, for the settings panel.
    func play(_ pattern: HapticPattern, over duration: TimeInterval) {
        let start = DispatchTime.now()
        var last = -Double.infinity
        for stop in pattern.stops {
            let time = max(stop.position * duration, last + Self.minimumSpacing)
            last = time
            queue.asyncAfter(deadline: start + time) { self.perform(strength: stop.strength) }
        }
        queue.asyncAfter(deadline: start + duration + 0.3) { self.actuator?.close() }
    }

    private func perform(strength: Double) {
        if !hasLookedForActuator {
            hasLookedForActuator = true
            actuator = Actuator()
            if actuator == nil {
                Diagnostics.lid.notice("trackpad actuator unavailable, using system haptics")
            }
        }
        if let actuator, actuator.tap(strength: strength) { return }
        // The public patterns, nearest in feel to the strength asked for.
        let pattern: NSHapticFeedbackManager.FeedbackPattern = strength < 0.4
            ? .alignment
            : strength < 0.75 ? .generic : .levelChange
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }
}

/// The built-in trackpad's actuator, through MultitouchSupport.
private final class Actuator {

    private typealias Create = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias Control = @convention(c) (CFTypeRef) -> Int32
    private typealias Actuate = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

    /// The actuator's tap waveforms, faintest first. These are the ones known
    /// to be single taps of rising strength; the others include the two
    /// halves of a force click.
    private static let waveforms: [Int32] = [1, 2, 3, 4, 6]

    private let reference: CFTypeRef
    private let openActuator: Control
    private let closeActuator: Control
    private let actuate: Actuate
    private var isOpen = false

    init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let library = dlopen(path, RTLD_LAZY),
              let create = dlsym(library, "MTActuatorCreateFromDeviceID"),
              let open = dlsym(library, "MTActuatorOpen"),
              let close = dlsym(library, "MTActuatorClose"),
              let actuate = dlsym(library, "MTActuatorActuate"),
              let deviceID = Self.builtInTrackpadID(),
              let reference = unsafeBitCast(create, to: Create.self)(deviceID)?.takeRetainedValue() else {
            return nil
        }
        self.reference = reference
        openActuator = unsafeBitCast(open, to: Control.self)
        closeActuator = unsafeBitCast(close, to: Control.self)
        self.actuate = unsafeBitCast(actuate, to: Actuate.self)
    }

    deinit {
        close()
    }

    /// False when the actuator would not open or take the tap.
    func tap(strength: Double) -> Bool {
        if !isOpen { isOpen = openActuator(reference) == 0 }
        guard isOpen else { return false }
        let steps = Self.waveforms.count
        let index = min(max(Int((strength * Double(steps)).rounded(.up)) - 1, 0), steps - 1)
        return actuate(reference, Self.waveforms[index], 0, 0, 0) == 0
    }

    func close() {
        guard isOpen else { return }
        _ = closeActuator(reference)
        isOpen = false
    }

    /// The multitouch ID of the built-in trackpad, if it has an actuator.
    private static func builtInTrackpadID() -> UInt64? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleMultitouchDevice"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        func property(_ service: io_object_t, _ key: String) -> NSNumber? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
        }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard property(service, "MT Built-In")?.boolValue ?? true,
                  property(service, "ActuationSupported")?.boolValue ?? false,
                  let id = property(service, "Multitouch ID") else { continue }
            return id.uint64Value
        }
        return nil
    }
}
