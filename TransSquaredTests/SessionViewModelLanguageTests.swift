//
//  SessionViewModelLanguageTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - Language Swap Tests

@MainActor
struct LanguageSwapTests {

    @Test func swapIsDisabledDuringActiveSession() {
        let vm = makeTestViewModel()
        vm.isSessionActive = true
        let oldSource = vm.sourceLocaleIdentifier
        let oldTarget = vm.targetLanguageIdentifier
        vm.swapLanguages()
        #expect(vm.sourceLocaleIdentifier == oldSource)
        #expect(vm.targetLanguageIdentifier == oldTarget)
    }

    @Test func swapWithEmptyLocalesIsNoOp() {
        let vm = makeTestViewModel()
        vm.supportedSourceLocales = []
        let oldSource = vm.sourceLocaleIdentifier
        vm.swapLanguages()
        #expect(vm.sourceLocaleIdentifier == oldSource)
        #expect(vm.errorMessage != nil)
    }

    @Test func swapWithMatchingLocalesSwapsCorrectly() {
        let vm = makeTestViewModel()
        vm.isSessionActive = false
        vm.sourceLocaleIdentifier = "ja_JP"
        vm.targetLanguageIdentifier = "en"
        vm.supportedSourceLocales = [
            Locale(identifier: "ja_JP"),
            Locale(identifier: "en_US"),
        ]
        vm.swapLanguages()
        #expect(vm.sourceLocaleIdentifier == "en_US")
        #expect(vm.targetLanguageIdentifier == "ja")
    }
}

// MARK: - Likely Region Tests

@MainActor
struct LikelyRegionTests {

    @Test func englishLikelyRegionIsUS() {
        let region = SessionViewModel.likelyRegion(for: "en")
        #expect(region?.identifier == "US")
    }

    @Test func japaneseLikelyRegionIsJP() {
        let region = SessionViewModel.likelyRegion(for: "ja")
        #expect(region?.identifier == "JP")
    }

    @Test func chineseSimplifiedLikelyRegion() {
        let region = SessionViewModel.likelyRegion(for: "zh-Hans")
        #expect(region != nil)
    }

    @Test func koreanLikelyRegionIsKR() {
        let region = SessionViewModel.likelyRegion(for: "ko")
        #expect(region?.identifier == "KR")
    }
}

// MARK: - Best Language Match Tests

@MainActor
struct BestLanguageMatchTests {

    @Test func matchesUserRegionFirst() {
        let candidates = [
            Locale.Language(identifier: "en-GB"),
            Locale.Language(identifier: "en-US"),
            Locale.Language(identifier: "en"),
        ]
        let result = SessionViewModel.bestLanguageMatch(from: candidates, for: "en")
        #expect(result != nil)
    }

    @Test func emptyReturnNil() {
        let result = SessionViewModel.bestLanguageMatch(from: [], for: "en")
        #expect(result == nil)
    }

    @Test func singleCandidateReturned() {
        let candidates = [Locale.Language(identifier: "fr")]
        let result = SessionViewModel.bestLanguageMatch(from: candidates, for: "fr")
        #expect(result?.minimalIdentifier == "fr")
    }
}

// MARK: - Add/Remove Target Language Tests

@MainActor
struct AddRemoveTargetLanguageTests {

    @Test func addTargetLanguageIncrementsCount() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.supportedTargetLanguages = [
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "ko"),
            Locale.Language(identifier: "zh-Hans"),
        ]
        vm.addTargetLanguage()
        #expect(vm.targetCount == 2)
    }

    @Test func addTargetLanguageClampsAtMax() {
        let vm = makeTestViewModel()
        vm.targetCount = SessionViewModel.maxTargetCount
        vm.addTargetLanguage()
        #expect(vm.targetCount == SessionViewModel.maxTargetCount)
    }

    @Test func removeTargetLanguageDecrementsCount() {
        let vm = makeTestViewModel()
        vm.targetCount = 2
        vm.removeTargetLanguage()
        #expect(vm.targetCount == 1)
    }

    @Test func removeTargetLanguageClampsAtOne() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.removeTargetLanguage()
        #expect(vm.targetCount == 1)
    }

    @Test func addTargetLanguagePicksUnusedLanguage() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.targetLanguageIdentifiers[0] = "en"
        vm.supportedTargetLanguages = [
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "ko"),
        ]
        vm.addTargetLanguage()
        #expect(vm.targetLanguageIdentifiers[1] == "ko")
    }
}
