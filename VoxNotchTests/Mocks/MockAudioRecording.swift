//
//  MockAudioRecording.swift
//  VoxNotchTests
//

import Foundation
@testable import VoxNotch

final class MockAudioRecording: AudioRecording {
    // Explicit init to resolve actor isolation ambiguity
    nonisolated init() {}

    var onResampledAudioSamples: (@Sendable ([Float]) -> Void)?
    var isRecording: Bool = false
    var accumulateBuffers: Bool = false
    var onSilenceWarning: (() -> Void)?
    var onSilenceThresholdReached: (() -> Void)?

    var startRecordingCallCount = 0
    var stopRecordingCallCount = 0
    var cancelRecordingCallCount = 0
    var cleanupCallCount = 0
    var lastCleanupURL: URL?

    var stubbedCaptureResult: AudioCaptureManager.CaptureResult?
    var stubbedStartError: Error?
    var stubbedStopError: Error?

    func startRecording() async throws {
        if let error = stubbedStartError { throw error }
        startRecordingCallCount += 1
        isRecording = true
    }

    func stopRecording() throws -> AudioCaptureManager.CaptureResult {
        if let error = stubbedStopError { throw error }
        stopRecordingCallCount += 1
        isRecording = false
        return stubbedCaptureResult ?? AudioCaptureManager.CaptureResult(
            fileURL: URL(fileURLWithPath: "/tmp/mock.wav"),
            duration: 2.0,
            sampleRate: 16000
        )
    }

    func cancelRecording() {
        cancelRecordingCallCount += 1
        isRecording = false
    }

    func cleanupFile(at url: URL) {
        cleanupCallCount += 1
        lastCleanupURL = url
    }
}
