//
//  SessionTimingTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - Session Timing Tests

@MainActor
struct SessionTimingTests {

    // MARK: adjustedElapsedTime

    @Test func adjustedElapsedTime_fileModeReturnsOffsetDirectly() {
        let vm = makeTestViewModel()
        vm.isTranscribingFile = true
        vm.accumulatedElapsedTime = 100.0
        // File mode: audioOffset is the absolute position in the file; accumulated time is ignored
        let result = vm.adjustedElapsedTime(audioOffset: 5.0)
        #expect(result == 5.0)
    }

    @Test func adjustedElapsedTime_liveModeAddsAccumulatedTime() {
        let vm = makeTestViewModel()
        vm.isTranscribingFile = false
        vm.accumulatedElapsedTime = 30.0
        let result = vm.adjustedElapsedTime(audioOffset: 5.0)
        #expect(result == 35.0)
    }

    @Test func adjustedElapsedTime_liveMode_zeroAccumulatedAndZeroOffset() {
        let vm = makeTestViewModel()
        vm.isTranscribingFile = false
        vm.accumulatedElapsedTime = 0.0
        #expect(vm.adjustedElapsedTime(audioOffset: 0.0) == 0.0)
    }

    @Test func adjustedElapsedTime_fileModeIgnoresAccumulatedTime() {
        let vm = makeTestViewModel()
        vm.isTranscribingFile = true
        vm.accumulatedElapsedTime = 9999.0   // large value — must be ignored in file mode
        let result = vm.adjustedElapsedTime(audioOffset: 12.5)
        #expect(result == 12.5)
    }

    // MARK: currentElapsedTime

    @Test func currentElapsedTime_noActiveSession_returnsAccumulatedOnly() {
        let vm = makeTestViewModel()
        vm.sessionStartDate = nil
        vm.accumulatedElapsedTime = 45.0
        #expect(vm.currentElapsedTime == 45.0)
    }

    @Test func currentElapsedTime_defaultIsZero() {
        let vm = makeTestViewModel()
        // Fresh VM: no session started, no accumulated time
        #expect(vm.currentElapsedTime == 0.0)
    }

    @Test func currentElapsedTime_includesCurrentSessionDuration() {
        let vm = makeTestViewModel()
        // Pretend the session started 10 seconds ago
        vm.sessionStartDate = Date(timeIntervalSinceNow: -10.0)
        vm.accumulatedElapsedTime = 5.0
        let elapsed = vm.currentElapsedTime
        // Should be ≈ 5 + 10 = 15 seconds (allow ±0.2 s for scheduling jitter)
        #expect(elapsed >= 14.8 && elapsed <= 15.2)
    }

    @Test func currentElapsedTime_accumulatesAcrossSessions() {
        let vm = makeTestViewModel()
        // Simulate time from two completed sessions already banked
        vm.accumulatedElapsedTime = 120.0
        vm.sessionStartDate = nil
        #expect(vm.currentElapsedTime == 120.0)
    }

    // MARK: accumulatedElapsedTime default

    @Test func accumulatedElapsedTime_defaultIsZero() {
        let vm = makeTestViewModel()
        #expect(vm.accumulatedElapsedTime == 0.0)
    }
}
