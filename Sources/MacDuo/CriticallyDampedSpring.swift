import Foundation

/// Eases the picture back to flat at the display refresh rate, from wherever
/// it was following the lid.
///
/// Semi-implicit Euler stays stable while `frequency * dt` is below 2. The
/// caller clamps `dt`.
struct CriticallyDampedSpring {
    var value: Double
    var velocity: Double = 0

    /// Radians per second. Higher follows the target faster and smooths less.
    var frequency: Double = 16

    init(value: Double = 0, frequency: Double = 16) {
        self.value = value
        self.frequency = frequency
    }

    mutating func advance(to target: Double, dt: Double) {
        let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }
}
