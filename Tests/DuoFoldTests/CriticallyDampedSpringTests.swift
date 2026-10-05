import Testing
@testable import DuoFold

struct CriticallyDampedSpringTests {

    @Test(arguments: [16.0, 24])
    func testASteadyCloseTrailsByTwoOverFrequencySeconds(frequency: Double) {
        var spring = CriticallyDampedSpring(value: 90, frequency: frequency)
        let speed = -150.0, dt = 1.0 / 120
        var target = 90.0
        for _ in 0..<240 {
            target += speed * dt
            spring.advance(to: target, dt: dt)
        }
        let lag = (spring.value - target) / -speed
        #expect(abs(lag - 2 / frequency) < 0.01)
    }

    /// Frames until the value comes within the controller's settle distance
    /// of 90, with `floor` at each frame.
    private func framesToSettle(_ spring: CriticallyDampedSpring, floor: (Int) -> (angle: Double, speed: Double)?) -> Int? {
        var spring = spring
        var previous = spring.value
        for frame in 1...240 {
            if let floor = floor(frame) {
                spring.advance(to: 90, dt: 1.0 / 120, floor: floor.angle, floorSpeed: floor.speed)
                if floor.speed > 0 { #expect(spring.value >= floor.angle - 1e-9) }
            } else {
                spring.advance(to: 90, dt: 1.0 / 120)
            }
            #expect(spring.value >= previous - 1e-9)
            previous = spring.value
            if spring.value >= 90 - 0.05 { return frame }
        }
        return nil
    }

    @Test
    func testARisingFloorTakesTheSpringToTheTargetAsFastAsItRises() throws {
        // Let go at 60 while following a lid opening at 400 degrees a
        // second, past the target of 90. Moving that fast that close, the
        // ease alone brakes and creeps the rest of the way.
        var spring = CriticallyDampedSpring(value: 60, frequency: 24)
        spring.velocity = 400
        let carried = try #require(framesToSettle(spring) { (60 + 400 * Double($0) / 120, 400) })
        let eased = try #require(framesToSettle(spring) { _ in nil })
        #expect(carried <= 10)
        #expect(eased > 3 * carried)
    }

    @Test
    func testTheSpringCarriesOnWhereTheFloorStopsShort() throws {
        // The lid brakes from 300 degrees a second to a stop at 80, short of
        // the target, and the spring takes the picture the rest of the way
        // without stepping back.
        var spring = CriticallyDampedSpring(value: 60, frequency: 24)
        spring.velocity = 300
        let braking = 300.0 * 300 / (2 * 20)
        let frames = try #require(framesToSettle(spring) { frame in
            let time = min(Double(frame) / 120, 300 / braking)
            return (60 + 300 * time - braking * time * time / 2, 300 - braking * time)
        })
        #expect(frames < 60)
    }

    @Test
    func testAStillFloorBelowLeavesTheSpringAlone() {
        var spring = CriticallyDampedSpring(value: 40, frequency: 24)
        var plain = spring
        for _ in 0..<60 {
            spring.advance(to: 90, dt: 1.0 / 120, floor: 40, floorSpeed: 0)
            plain.advance(to: 90, dt: 1.0 / 120)
        }
        #expect(spring.value == plain.value)
        #expect(spring.velocity == plain.velocity)
    }

    @Test
    func testSettlesOnAStillTarget() {
        var spring = CriticallyDampedSpring(value: 90, frequency: 24)
        for _ in 0..<120 { spring.advance(to: 60, dt: 1.0 / 120) }
        #expect(abs(spring.value - 60) < 0.01)
        #expect(spring.frequency == 24)
    }
}
