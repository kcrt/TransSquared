//
//  UtilityTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - TimeInterval Formatting Tests

struct TimeIntervalFormattingTests {

    @Test func formattedMMSSZero() {
        #expect(TimeInterval(0).formattedMMSS == "00:00")
    }

    @Test func formattedMMSSUnderOneMinute() {
        #expect(TimeInterval(45).formattedMMSS == "00:45")
    }

    @Test func formattedMMSSExactMinute() {
        #expect(TimeInterval(60).formattedMMSS == "01:00")
    }

    @Test func formattedMMSSMultipleMinutes() {
        #expect(TimeInterval(225).formattedMMSS == "03:45")
    }

    @Test func formattedMMSSOverAnHour() {
        #expect(TimeInterval(3900).formattedMMSS == "65:00")
    }

    @Test func formattedMMSSNegativeClampedToZero() {
        #expect(TimeInterval(-10).formattedMMSS == "00:00")
    }

    @Test func formattedMMSSFractionalTruncated() {
        #expect(TimeInterval(45.9).formattedMMSS == "00:45")
    }

    @Test func formattedMSSZero() {
        #expect(TimeInterval(0).formattedMSS == "0:00")
    }

    @Test func formattedMSSUnderOneMinute() {
        #expect(TimeInterval(9).formattedMSS == "0:09")
    }

    @Test func formattedMSSMultipleMinutes() {
        #expect(TimeInterval(225).formattedMSS == "3:45")
    }

    @Test func formattedMSSNegativeClampedToZero() {
        #expect(TimeInterval(-5).formattedMSS == "0:00")
    }
}

// MARK: - TransSquaredError Tests

struct TransSquaredErrorTests {

    @Test func allCasesHaveDescriptions() {
        let cases: [TransSquaredError] = [
            .alreadyCapturing, .microphoneUnavailable,
            .alreadyRunning, .audioFormatUnavailable, .recordingFailed
        ]
        for error in cases {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test func conformsToLocalizedError() {
        let error: any LocalizedError = TransSquaredError.microphoneUnavailable
        #expect(error.errorDescription != nil)
    }
}

// MARK: - PermissionIssue Tests

struct PermissionIssueTests {

    @Test func identifiable() {
        let mic = PermissionIssue.microphone
        let speech = PermissionIssue.speechRecognition
        #expect(mic.id != speech.id)
    }

    @Test func titleAndMessageAreNonEmpty() {
        for issue in [PermissionIssue.microphone, .speechRecognition] {
            #expect(!issue.title.isEmpty)
            #expect(!issue.message.isEmpty)
        }
    }
}

// MARK: - AudioLevelMonitor Tests

@MainActor
struct AudioLevelMonitorTests {

    @Test func initialLevelsAreAllZero() {
        let monitor = AudioLevelMonitor()
        #expect(monitor.levels.count == AudioLevelMonitor.sampleCount)
        #expect(monitor.levels.allSatisfy { $0 == 0 })
    }

    @Test func appendAddsLevel() {
        let monitor = AudioLevelMonitor()
        monitor.append(0.5)
        #expect(monitor.levels.last == 0.5)
        #expect(monitor.levels.count == AudioLevelMonitor.sampleCount)
    }

    @Test func appendMaintainsFixedSize() {
        let monitor = AudioLevelMonitor()
        for i in 0..<(AudioLevelMonitor.sampleCount + 10) {
            monitor.append(Float(i) / 100.0)
        }
        #expect(monitor.levels.count == AudioLevelMonitor.sampleCount)
        let expected = Float(AudioLevelMonitor.sampleCount + 10 - 1) / 100.0
        #expect(monitor.levels.last == expected)
    }

    @Test func appendShiftsOutOldestValue() {
        let monitor = AudioLevelMonitor()
        for i in 0..<AudioLevelMonitor.sampleCount {
            monitor.append(Float(i + 1))
        }
        #expect(monitor.levels.first == 1.0)
        #expect(monitor.levels.last == Float(AudioLevelMonitor.sampleCount))

        monitor.append(99.0)
        #expect(monitor.levels.first == 2.0)
        #expect(monitor.levels.last == 99.0)
    }

    @Test func resetSetsAllToZero() {
        let monitor = AudioLevelMonitor()
        monitor.append(0.8)
        monitor.append(0.6)
        monitor.reset()
        #expect(monitor.levels.count == AudioLevelMonitor.sampleCount)
        #expect(monitor.levels.allSatisfy { $0 == 0 })
    }

    @Test func sampleCountIsReasonable() {
        #expect(AudioLevelMonitor.sampleCount > 0)
        #expect(AudioLevelMonitor.sampleCount <= 100)
    }
}
