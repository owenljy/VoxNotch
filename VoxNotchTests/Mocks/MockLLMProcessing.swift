//
//  MockLLMProcessing.swift
//  VoxNotchTests
//

import Foundation
@testable import VoxNotch

final class MockLLMProcessing: LLMProcessing {
    var isEnabled: Bool = false

    var onProcess: (() async -> Void)?
    var processCallCount = 0
    var lastProcessedText: String?
    var lastLanguage: String?
    var stubbedResult: LLMProcessingResult?

    func processWithResult(text: String, language: String?) async -> LLMProcessingResult {
        processCallCount += 1
        lastProcessedText = text
        lastLanguage = language
        await onProcess?()
        return stubbedResult ?? .skipped(originalText: text)
    }
}
