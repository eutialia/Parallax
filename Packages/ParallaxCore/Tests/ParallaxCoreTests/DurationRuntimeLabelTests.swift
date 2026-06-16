import Testing
import Foundation
@testable import ParallaxCore

@Suite("Duration.compactRuntimeLabel")
struct DurationRuntimeLabelTests {

    @Test("hours and minutes render as \"1h 23m\"")
    func hoursAndMinutes() {
        #expect(Duration.seconds(83 * 60).compactRuntimeLabel == "1h 23m")
    }

    @Test("a whole-hour runtime drops the minutes")
    func wholeHours() {
        #expect(Duration.seconds(2 * 3600).compactRuntimeLabel == "2h")
    }

    @Test("sub-hour renders minutes only")
    func minutesOnly() {
        #expect(Duration.seconds(45 * 60).compactRuntimeLabel == "45m")
    }

    @Test("sub-minute collapses to \"<1m\"")
    func subMinute() {
        #expect(Duration.seconds(30).compactRuntimeLabel == "<1m")
    }

    @Test("seconds within a minute are truncated, not rounded up")
    func truncatesSeconds() {
        // 1h 23m 59s → still 1h 23m (whole-minute floor, no spill into 24m).
        #expect(Duration.seconds(83 * 60 + 59).compactRuntimeLabel == "1h 23m")
    }

    @Test("zero and negative durations render empty")
    func emptyForNonPositive() {
        #expect(Duration.zero.compactRuntimeLabel == "")
        #expect(Duration.seconds(-120).compactRuntimeLabel == "")
    }
}
