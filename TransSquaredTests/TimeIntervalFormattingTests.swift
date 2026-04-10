//
//  TimeIntervalFormattingTests.swift
//  TransSquaredTests
//

import Testing
@testable import TransSquared

// MARK: - TimeInterval Formatting Tests

struct TimeIntervalFormattingTests {

    // MARK: formattedMMSS

    @Test func formattedMMSS_zero() {
        #expect(0.0.formattedMMSS == "00:00")
    }

    @Test func formattedMMSS_oneSecond() {
        #expect(1.0.formattedMMSS == "00:01")
    }

    @Test func formattedMMSS_fiftyNineSeconds() {
        #expect(59.0.formattedMMSS == "00:59")
    }

    @Test func formattedMMSS_oneMinute() {
        #expect(60.0.formattedMMSS == "01:00")
    }

    @Test func formattedMMSS_twoMinutesAndFiveSeconds() {
        #expect(125.0.formattedMMSS == "02:05")
    }

    @Test func formattedMMSS_tenMinutes() {
        #expect(600.0.formattedMMSS == "10:00")
    }

    @Test func formattedMMSS_beyondOneHour_noHoursColumn() {
        // formattedMMSS has no hours field — minutes keep accumulating beyond 59
        #expect(3661.0.formattedMMSS == "61:01")
    }

    @Test func formattedMMSS_negative_clampsToZero() {
        // Negative values are clamped to 0 via max(0, ...)
        #expect((-5.0).formattedMMSS == "00:00")
    }

    @Test func formattedMMSS_fractionalSecondsAreTruncated() {
        // 90.9 seconds → truncated to 90 → "01:30"
        #expect(90.9.formattedMMSS == "01:30")
    }

    // MARK: formattedMSS

    @Test func formattedMSS_zero() {
        #expect(0.0.formattedMSS == "0:00")
    }

    @Test func formattedMSS_oneSecond() {
        #expect(1.0.formattedMSS == "0:01")
    }

    @Test func formattedMSS_fiftyNineSeconds() {
        #expect(59.0.formattedMSS == "0:59")
    }

    @Test func formattedMSS_oneMinute() {
        #expect(60.0.formattedMSS == "1:00")
    }

    @Test func formattedMSS_twoMinutesAndFiveSeconds() {
        #expect(125.0.formattedMSS == "2:05")
    }

    @Test func formattedMSS_tenMinutesPlus() {
        // No leading zero on minutes — "10:05"
        #expect(605.0.formattedMSS == "10:05")
    }

    @Test func formattedMSS_negative_clampsToZero() {
        #expect((-3.0).formattedMSS == "0:00")
    }

    @Test func formattedMSS_fractionalSecondsAreTruncated() {
        // 61.7 seconds → truncated to 61 → "1:01"
        #expect(61.7.formattedMSS == "1:01")
    }

    // MARK: Consistency between formats

    @Test func formattedMMSS_andFormattedMSS_agreeOnMinutesAndSeconds() {
        // For 0–9 minutes, formattedMSS has no leading zero on minutes,
        // while formattedMMSS always has two digits.
        let interval: TimeInterval = 305.0  // 5:05
        #expect(interval.formattedMMSS == "05:05")
        #expect(interval.formattedMSS == "5:05")
    }
}
