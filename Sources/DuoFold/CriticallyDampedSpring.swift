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

    /// Advances toward `target` as above, but never trails `floor` while it
    /// rises toward the target on its own at `floorSpeed`. Wherever the floor
    /// stops, the spring carries on from there at the floor's own speed.
    mutating func advance(to target: Double, dt: Double, floor: Double, floorSpeed: Double) {
        advance(to: target, dt: dt)
        guard floorSpeed > 0, floor > value else { return }
        value = floor
        velocity = max(velocity, floorSpeed)
    }

    mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }
}
