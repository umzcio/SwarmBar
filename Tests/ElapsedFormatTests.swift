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
}
