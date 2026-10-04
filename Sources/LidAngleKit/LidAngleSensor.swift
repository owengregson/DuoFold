import Foundation
import IOKit
import IOKit.hid

/// Reads the lid hinge angle from the MacBook orientation sensor.
///
/// The sensor is an Apple HID device on usage page `0x20`, usage `0x8A`, that
/// macOS marks as built-in. No product ID is required, and an external display
/// with the same usage is left out. Two reports carry the angle, both through
/// `kIOHIDReportTypeFeature`:
///
/// - Report 1: 3 bytes `[0x01, lo, hi]`, whole degrees, 0...360.
/// - Report 7: 5 bytes `[0x07, b0, b1, b2, b3]`, little-endian hundredths of a
///   degree. Not every model declares it, so report 1 is the fallback.
///
/// The value refreshes about every 100 ms and needs no permission.
///
/// Reading a report is a round trip to the sensor coprocessor, so a watcher
/// that polls to notice the lid starting to move keeps waking the CPU. The
/// sensor can also push report 1 on its own, which `startPushing` uses.
public final class LidAngleSensor {

    /// Which report the sensor answers with, decided once at open time.
    public enum Resolution {
        /// Report 7, 0.01 degree steps.
        case hundredthsOfADegree
        /// Report 1, 1 degree steps.
        case wholeDegrees

        public var reportID: Int {
            switch self {
            case .hundredthsOfADegree: return 7
            case .wholeDegrees: return 1
            }
        }

        public var describedName: String {
            switch self {
            case .hundredthsOfADegree: return "report 7 (0.01°)"
            case .wholeDegrees: return "report 1 (1°)"
            }
        }
    }

    /// What the last call to `angle()` saw. A failed read returns `nil` and
    /// leaves the reason here.
    public struct ReadTrace {
        /// The result of `IOHIDDeviceGetReport`.
        public var status: IOReturn = kIOReturnSuccess
        /// Bytes the device wrote.
        public var length: Int = 0
        public var bytes: [UInt8] = []
        /// The decoded value when it fell outside 0...360.
        public var rejectedDegrees: Double?
    }

    public private(set) var lastRead = ReadTrace()
    public private(set) var resolution: Resolution?
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer = [UInt8](repeating: 0, count: 32)
    private var receiver: PushReceiver?
    /// Set once pushing has stopped. A cancelled device cannot be activated
    /// again.
    private var hasStoppedPushing = false
    private var driver: io_registry_entry_t = 0

    public var isAvailable: Bool { device != nil && resolution != nil }

    /// True between `startPushing` and `stopPushing`.
    public var isPushing: Bool { receiver != nil }

    public init() {
        open()
    }

    deinit {
        if let receiver, let device {
            restorePushInterval()
            // Closing the manager closes the device, so it waits for the
            // cancel handler, after which no pushed report can still run.
            receiver.afterCancel = { [manager] in
                if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
            }
            IOHIDDeviceCancel(device)
        } else if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if driver != 0 { IOObjectRelease(driver) }
    }

    /// The current lid angle in degrees, or `nil` if the read failed.
    ///
    /// 0 means closed. A MacBook opens to roughly 130 degrees.
    public func angle() -> Double? {
        guard let resolution else { return nil }
        guard let bytes = read(reportID: resolution.reportID) else { return nil }
        guard bytes.first == UInt8(resolution.reportID) else { return nil }

        let degrees: Double
        switch resolution {
        case .hundredthsOfADegree:
            guard bytes.count >= 5 else { return nil }
            let raw = UInt32(bytes[1])
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3]) << 16
                | UInt32(bytes[4]) << 24
            degrees = Double(raw) / 100
        case .wholeDegrees:
            guard bytes.count >= 3 else { return nil }
            degrees = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        }

        guard degrees >= 0, degrees <= 360 else {
            lastRead.rejectedDegrees = degrees
            return nil
        }
        return degrees
    }

    // MARK: - Pushed readings

    /// The sensor pushes report 1, whole degrees, once a second on its own,
    /// or every `ReportInterval` microseconds once its `AppleSPUHIDDriver` is
    /// given one. Measured on an M5 MacBook Pro: 500 ms pushes at 2 Hz, and
    /// 100 ms and anything shorter at 10 Hz, the sensor's own refresh.
    ///
    /// The interval belongs to the driver, not to this process: every client
    /// shares it and it stays set after this process exits. The registry reads
    /// it back as 0 whatever it is set to, so the previous value cannot be
    /// read and restored. `restorePushInterval` puts back 0, the driver's own
    /// once a second, which is what it reads at boot.
    private static let intervalKey = "ReportInterval" as CFString
    private static let pushBufferSize = 64

    /// What a pushed report needs, kept apart from the sensor and retained by
    /// the device until it is cancelled, so a report in flight while the
    /// sensor goes away touches nothing freed.
    private final class PushReceiver: @unchecked Sendable {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: LidAngleSensor.pushBufferSize)
        private let lock = NSLock()
        private var handler: ((Double) -> Void)?
        /// Runs on the push queue once the device has been cancelled.
        var afterCancel: (() -> Void)?

        init(handler: @escaping (Double) -> Void) {
            self.handler = handler
        }

        deinit {
            buffer.deallocate()
        }

        func setHandler(_ handler: ((Double) -> Void)?) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        func deliver(_ degrees: Double) {
            lock.lock()
            let handler = self.handler
            lock.unlock()
            handler?(degrees)
        }
    }

    private static let pushCallback: IOHIDReportCallback = { context, result, _, _, reportID, report, length in
        guard let context, result == kIOReturnSuccess, reportID == 1, length >= 3 else { return }
        let degrees = Double(UInt16(report[1]) | UInt16(report[2]) << 8)
        guard degrees <= 360 else { return }
        Unmanaged<PushReceiver>.fromOpaque(context).takeUnretainedValue().deliver(degrees)
    }

    /// Starts the sensor pushing whole degree readings to `handler` on
    /// `queue`, about `interval` apart. Returns false when the sensor cannot
    /// be told how often to push, and the caller has to poll: once a second
    /// is too slow to notice the lid starting to close.
    ///
    /// Pushing can start once per sensor. The interval outlives the process,
    /// so `stopPushing`, or `restorePushInterval` while the Mac sleeps, must
    /// run before it exits.
    @discardableResult
    public func startPushing(
        interval: TimeInterval,
        queue: DispatchQueue,
        handler: @escaping (Double) -> Void
    ) -> Bool {
        guard let device, receiver == nil, !hasStoppedPushing else { return false }
        guard setPushInterval(interval) else { return false }

        let receiver = PushReceiver(handler: handler)
        // Released by the cancel handler, after the last report has run.
        let context = Unmanaged.passRetained(receiver).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, receiver.buffer, Self.pushBufferSize, Self.pushCallback, context
        )
        IOHIDDeviceSetCancelHandler(device) {
            let receiver = Unmanaged<PushReceiver>.fromOpaque(context).takeRetainedValue()
            receiver.afterCancel?()
            receiver.afterCancel = nil
        }
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceActivate(device)
        self.receiver = receiver
        return true
    }

    /// Changes how often pushed readings arrive. False when the driver could
    /// not be found or refused the value.
    @discardableResult
    public func setPushInterval(_ interval: TimeInterval) -> Bool {
        guard let driver = pushDriver() else { return false }
        let microseconds = max(Int((interval * 1_000_000).rounded()), 0)
        return IORegistryEntrySetCFProperty(driver, Self.intervalKey, NSNumber(value: microseconds)) == KERN_SUCCESS
    }

    /// Puts the driver back to its own once a second. Pushed readings keep
    /// arriving at that rate until `setPushInterval` speeds them up again.
    public func restorePushInterval() {
        setPushInterval(0)
    }

    /// Restores the interval and stops the readings for good.
    public func stopPushing() {
        guard let device, let receiver else { return }
        restorePushInterval()
        receiver.setHandler(nil)
        IOHIDDeviceCancel(device)
        self.receiver = nil
        hasStoppedPushing = true
    }

    /// The `AppleSPUHIDDriver` under this device, which holds the interval.
    /// Found below the device itself, so no other sensor's driver is touched.
    private func pushDriver() -> io_registry_entry_t? {
        if driver != 0 { return driver }
        guard let device else { return nil }
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            if IOObjectConformsTo(entry, "AppleSPUHIDDriver") != 0 {
                driver = entry
                return entry
            }
            IOObjectRelease(entry)
        }
        return nil
    }

    // MARK: - Device

    private func open() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDDeviceUsagePageKey: 0x20,
            kIOHIDDeviceUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return
        }
        self.manager = manager

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for candidate in devices {
            // An external display can carry the same usage and reads 0.
            guard (IOHIDDeviceGetProperty(candidate, kIOHIDBuiltInKey as CFString) as? NSNumber)?.boolValue == true else {
                continue
            }
            device = candidate
            for format in [Resolution.hundredthsOfADegree, .wholeDegrees] {
                resolution = format
                if angle() != nil { return }
            }
        }
        device = nil
        resolution = nil
    }

    private func read(reportID: Int) -> [UInt8]? {
        lastRead = ReadTrace()
        guard let device else {
            lastRead.status = kIOReturnNoDevice
            return nil
        }
        var length = CFIndex(buffer.count)
        let result = buffer.withUnsafeMutableBufferPointer { pointer -> IOReturn in
            guard let base = pointer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), base, &length)
        }
        lastRead.status = result
        lastRead.length = Int(length)
        guard result == kIOReturnSuccess, length > 0 else { return nil }
        let bytes = Array(buffer[0..<Int(length)])
        lastRead.bytes = bytes
        return bytes
    }
}
