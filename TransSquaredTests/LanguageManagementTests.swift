//
//  LanguageManagementTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - Locale Resolution Helper Tests

struct LocaleResolutionTests {

    // MARK: likelyRegion(for:)

    @Test func likelyRegion_english_isUS() {
        // "en" expands to "en-Latn-US" → region US
        let region = SessionViewModel.likelyRegion(for: "en")
        #expect(region == Locale.Region("US"))
    }

    @Test func likelyRegion_japanese_isJP() {
        let region = SessionViewModel.likelyRegion(for: "ja")
        #expect(region == Locale.Region("JP"))
    }

    @Test func likelyRegion_korean_isKR() {
        let region = SessionViewModel.likelyRegion(for: "ko")
        #expect(region == Locale.Region("KR"))
    }

    @Test func likelyRegion_chineseSimplified_isChina() {
        // "zh-Hans" expands to "zh-Hans-CN"
        let region = SessionViewModel.likelyRegion(for: "zh-Hans")
        #expect(region == Locale.Region("CN"))
    }

    @Test func likelyRegion_returnsNonNilForKnownLanguage() {
        // Any well-known BCP 47 language tag must resolve to some region
        #expect(SessionViewModel.likelyRegion(for: "fr") != nil)
        #expect(SessionViewModel.likelyRegion(for: "de") != nil)
        #expect(SessionViewModel.likelyRegion(for: "es") != nil)
    }

    // MARK: bestLanguageMatch(from:for:)

    @Test func bestLanguageMatch_emptyCandidates_returnsNil() {
        let result = SessionViewModel.bestLanguageMatch(from: [], for: "en")
        #expect(result == nil)
    }

    @Test func bestLanguageMatch_singleCandidate_returnsThatCandidate() {
        let candidates = [Locale.Language(identifier: "en-US")]
        let result = SessionViewModel.bestLanguageMatch(from: candidates, for: "en")
        #expect(result != nil)
    }

    @Test func bestLanguageMatch_noRegionVariant_preferredOverRegionVariant() {
        // Candidates without a region are preferred when neither matches the user's region
        let noRegion = Locale.Language(identifier: "zh-Hans")
        let withRegion = Locale.Language(identifier: "zh-Hans-TW")
        // Assuming the test device does not have TW as its region, zh-Hans (no region)
        // should be preferred via the "no region" fallback rule.
        let candidates = [withRegion, noRegion]
        let result = SessionViewModel.bestLanguageMatch(from: candidates, for: "zh")
        // "zh-Hans" has region==nil, "zh-Hans-TW" has region TW.
        // The second fallback rule: first(where: { $0.region == nil }) picks noRegion.
        #expect(result?.region == nil)
    }

    @Test func bestLanguageMatch_multipleMatchingCandidates_returnsFirstFallback() {
        let a = Locale.Language(identifier: "fr-FR")
        let b = Locale.Language(identifier: "fr-BE")
        // Neither FR nor BE is likely the user's device region in this test host
        let result = SessionViewModel.bestLanguageMatch(from: [a, b], for: "fr")
        // Falls through to likelyRegion → likely FR for "fr"
        #expect(result != nil)
    }
}

// MARK: - Target Language Count Tests

@MainActor
struct TargetLanguageCountTests {

    @Test func addTargetLanguage_incrementsCount() {
        let vm = makeTestViewModel()
        let initialCount = vm.targetCount   // 1 by default
        vm.supportedTargetLanguages = [
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "zh-Hans"),
            Locale.Language(identifier: "ko"),
        ]
        vm.addTargetLanguage()
        #expect(vm.targetCount == initialCount + 1)
    }

    @Test func addTargetLanguage_doesNotExceedMax() {
        let vm = makeTestViewModel()
        vm.targetCount = SessionViewModel.maxTargetCount
        vm.supportedTargetLanguages = []
        vm.addTargetLanguage()
        #expect(vm.targetCount == SessionViewModel.maxTargetCount)
    }

    @Test func addTargetLanguage_maxCountIsPositive() {
        #expect(SessionViewModel.maxTargetCount > 0)
    }

    @Test func removeTargetLanguage_decrementsCount() {
        let vm = makeTestViewModel()
        vm.targetCount = 3
        vm.removeTargetLanguage()
        #expect(vm.targetCount == 2)
    }

    @Test func removeTargetLanguage_doesNotGoBelowOne() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.removeTargetLanguage()
        #expect(vm.targetCount == 1)
    }

    @Test func addAndRemove_roundTrip() {
        let vm = makeTestViewModel()
        vm.supportedTargetLanguages = [
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "zh-Hans"),
        ]
        let initial = vm.targetCount
        vm.addTargetLanguage()
        #expect(vm.targetCount == initial + 1)
        vm.removeTargetLanguage()
        #expect(vm.targetCount == initial)
    }
}
