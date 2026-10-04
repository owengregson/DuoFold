import Testing
@testable import MacDuo

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

    @Test
    func testSettlesOnAStillTarget() {
        var spring = CriticallyDampedSpring(value: 90, frequency: 24)
        for _ in 0..<120 { spring.advance(to: 60, dt: 1.0 / 120) }
        #expect(abs(spring.value - 60) < 0.01)
        #expect(spring.frequency == 24)
    }
}
