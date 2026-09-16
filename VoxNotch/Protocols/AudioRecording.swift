//
//  AudioRecording.swift
//  VoxNotch
//
//  Protocol abstracting audio capture for testability and source-swap
//  (microphone vs. system audio).
//

import Foundation

/// Abstraction over audio capture so QuickDictationController can be tested with mocks
/// and so the pipeline can swap between microphone and system-audio sources transparently.
/// The `AudioSource` enum is defined in Models/AudioSource.swift.
///
/// `startRecording()` is async because some sources (ScreenCaptureKit) need to negotiate
/// permissions and start an IPC stream; faking it sync would lie about when capture began.
/// Permission management is intentionally NOT on this protocol — it differs by source
/// (Microphone vs. Screen Recording) and is the caller's concern.
protocol AudioRecording: AnyObject {
    var onResampledAudioSamples: (@Sendable ([Float]) -> Void)? { get set }
    var isRecording: Bool { get }
    var accumulateBuffers: Bool { get set }
    var onSilenceWarning: (() -> Void)? { get set }
    var onSilenceThresholdReached: (() -> Void)? { get set }
    func startRecording() async throws
    func stopRecording() throws -> AudioCaptureManager.CaptureResult
    func cancelRecording()
    func cleanupFile(at url: URL)
}

extension AudioCaptureManager: AudioRecording {}
