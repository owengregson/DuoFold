import Testing
@testable import MacDuo

struct HapticPatternTests {

    @Test
    func testLinearSpacesEvenTapsOfOneStrength() {
        let stops = HapticPattern(style: .linear, taps: 4, strength: 0.5).stops
        #expect(stops.map(\.position) == [0.25, 0.5, 0.75, 1])
        #expect(stops.allSatisfy { $0.strength == 0.5 })
    }

    @Test
    func testExponentialTapsComeFasterAndGrowFromFaint() {
        let stops = HapticPattern(style: .exponential, taps: 20, strength: 1).stops
        #expect(stops.count == 20)
        #expect(abs(stops.last!.position - 1) < 1e-12)
        let gaps = zip(stops.dropFirst(), stops).map { $0.position - $1.position }
        // Each gap shorter than the one before, and the last far shorter than
        // the first.
        #expect(zip(gaps.dropFirst(), gaps).allSatisfy { $0 < $1 })
        #expect(gaps.last! < gaps.first! / 5)
        #expect(zip(stops.dropFirst(), stops).allSatisfy { $0.strength > $1.strength })
        #expect(stops.first!.strength < 0.5)
        #expect(abs(stops.last!.strength - 1) < 1e-12)
    }

    @Test
    func testSwellGrowsToFullStrength() {
        let stops = HapticPattern(style: .swell, taps: 5, strength: 0.8).stops
        #expect(stops.map(\.position) == [0.2, 0.4, 0.6, 0.8, 1])
        #expect(zip(stops.dropFirst(), stops).allSatisfy { $0.strength > $1.strength })
        #expect(abs(stops.last!.strength - 0.8) < 1e-12)
    }

    @Test
    func testBookendsTapAtStartAndFull() {
        let stops = HapticPattern(style: .bookends, taps: 30, strength: 1).stops
        #expect(stops.map(\.position) == [0, 1])
        #expect(stops[0].strength < stops[1].strength)
    }

    @Test(arguments: HapticPattern.Style.allCases)
    func testClosingThroughTheTravelTapsOncePerStop(style: HapticPattern.Style) {
        let pattern = HapticPattern(style: style, taps: 12, strength: 1)
        var track = HapticTrack(pattern: pattern, progress: 0, followsOpening: false)
        var taps = 0
        // Small enough steps that no two stops fall in one.
        for step in 0...20_000 {
            if track.advance(to: Double(step) / 20_000) != nil { taps += 1 }
        }
        #expect(taps == pattern.stops.count)
    }

    @Test
    func testJitterOnAStopTapsOnce() {
        var track = HapticTrack(
            pattern: HapticPattern(style: .linear, taps: 4, strength: 1),
            progress: 0.2,
            followsOpening: true
        )
        #expect(track.advance(to: 0.25) != nil)
        for reading in [0.249, 0.251, 0.246, 0.25, 0.248] {
            #expect(track.advance(to: reading) == nil)
        }
    }

    @Test
    func testOpeningTapsOnlyWhenAskedTo() {
        let pattern = HapticPattern(style: .linear, taps: 4, strength: 1)
        var quiet = HapticTrack(pattern: pattern, progress: 0, followsOpening: false)
        var both = HapticTrack(pattern: pattern, progress: 0, followsOpening: true)
        _ = quiet.advance(to: 0.6)
        _ = both.advance(to: 0.6)
        #expect(quiet.advance(to: 0.3) == nil)
        #expect(both.advance(to: 0.3) != nil)
        // Closing again passes the stop once more either way.
        #expect(quiet.advance(to: 0.55) != nil)
        #expect(both.advance(to: 0.55) != nil)
    }

    @Test
    func testSeveralStopsAtOnceGiveOneTapAtTheStrongest() {
        var track = HapticTrack(
            pattern: HapticPattern(style: .swell, taps: 10, strength: 1),
            progress: 0,
            followsOpening: false
        )
        let strength = track.advance(to: 0.55)
        #expect(strength == HapticPattern(style: .swell, taps: 10, strength: 1).stops[4].strength)
        #expect(track.advance(to: 0.55) == nil)
    }

    @Test
    func testStartingPartWaySkipsTheStopsBehind() {
        var track = HapticTrack(
            pattern: HapticPattern(style: .linear, taps: 10, strength: 1),
            progress: 0.42,
            followsOpening: false
        )
        #expect(track.advance(to: 0.45) == nil)
        #expect(track.advance(to: 0.5) != nil)
    }

    @Test
    func testBookendsTapAsTheEffectStarts() {
        var track = HapticTrack(
            pattern: HapticPattern(style: .bookends, taps: 0, strength: 1),
            progress: 0.1,
            followsOpening: false
        )
        #expect(track.advance(to: 0.1) != nil)
        #expect(track.advance(to: 0.9) == nil)
        #expect(track.advance(to: 1) != nil)
    }
}
