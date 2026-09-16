//
//  TranscriptionEngine.swift
//  VoxNotch
//
//  Protocol abstracting TranscriptionService for testability.
//

import Foundation

/// Abstraction over speech-to-text so QuickDictationController can be tested with mocks.
protocol TranscriptionEngine: AnyObject, Sendable {
    var isReady: Bool { get async }
    func preloadModel()
    func ensureModelReady() async throws
    func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult
    func beginStreaming() -> (@Sendable ([Float]) -> Void)?
    func finishStreaming(audioURL: URL, language: String?) async throws -> TranscriptionResult
    func cancelStreaming()
    func reconfigure()
}

extension TranscriptionService: TranscriptionEngine {}


extension TranscriptionEngine {
    func beginStreaming() -> (@Sendable ([Float]) -> Void)? { nil }
    func finishStreaming(audioURL: URL, language: String?) async throws -> TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language)
    }
    func cancelStreaming() {}
}
