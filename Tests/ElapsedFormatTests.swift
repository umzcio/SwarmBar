import Testing
@testable import SwarmBar

@MainActor
struct ElapsedFormatTests {
    @Test func secondsOnly() {
        #expect(ElapsedTimeText.format(0) == "0s")
        #expect(ElapsedTimeText.format(42) == "42s")
        #expect(ElapsedTimeText.format(59) == "59s")
    }

    @Test func minutesAndSeconds() {
        #expect(ElapsedTimeText.format(60) == "1m 0s")
        #expect(ElapsedTimeText.format(65) == "1m 5s")
        #expect(ElapsedTimeText.format(59 * 60 + 59) == "59m 59s")
    }

    @Test func hoursAndMinutes() {
        #expect(ElapsedTimeText.format(3600) == "1h 0m")
        #expect(ElapsedTimeText.format(3725) == "1h 2m")
        #expect(ElapsedTimeText.format(2 * 3600 + 30 * 60) == "2h 30m")
    }

    @Test func negativeClampsToZero() {
        #expect(ElapsedTimeText.format(-5) == "0s")
    }

    /// Int(_:) traps on a Double past Int's range, and a session date read
    /// from a file can be anything, so neither format may convert first and
    /// clamp afterwards.
    @Test func outOfRangeIntervalsNeverTrap() {
        for elapsed in [1e300, -1e300, .infinity, -.infinity, .nan, 9.3e18] {
            _ = ElapsedTimeText.format(elapsed)
            _ = ElapsedTimeText.agoFormat(elapsed)
        }
        #expect(ElapsedTimeText.format(-1e300) == "0s")
        #expect(ElapsedTimeText.format(.nan) == "0s")
        #expect(ElapsedTimeText.agoFormat(-.infinity) == "just now")
        #expect(ElapsedTimeText.format(1e300) == ElapsedTimeText.format(ElapsedTimeText.longestShown))
    }
}
