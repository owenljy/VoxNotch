//
//  FluidAudioProvider.swift
//  VoxNotch
//
//  Transcription provider for FluidAudio TDT, Unified, and EOU models
//

import Accelerate
import AVFoundation
import FluidAudio
import Foundation
import os.log

/// Speech-to-text provider using model handles owned by FluidAudioModelManager.
final class FluidAudioProvider: TranscriptionProvider, @unchecked Sendable {

  // MARK: - Properties

  let name = "FluidAudio"

  private let logger = Logger(subsystem: "com.jingyuanliang.VoxNotch", category: "FluidAudioProvider")
  private let modelManager = FluidAudioModelManager.shared

  private var selectedVersion: FluidAudioModelVersion {
    SpeechModel.resolve(SettingsManager.shared.speechModel).builtin?.fluidAudioVersion
      ?? FluidAudioModelVersion(rawValue: SettingsManager.shared.fluidAudioModel) ?? .v2English
  }

  // MARK: - TranscriptionProvider

  var isReady: Bool {
    get async {
      modelManager.isVersionReady(selectedVersion)
    }
  }

  func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
    let startTime = Date()

    try Task.checkCancellation()
    let version = selectedVersion
    guard let model = modelManager.getLoadedModel(for: version) else {
      throw TranscriptionError.modelNotLoaded
    }

    // Check if audio contains actual speech (VAD) or energy (RMS fallback)
    if SettingsManager.shared.useVADSpeechGate {
      guard try await VadGate.shared.containsSpeech(audioURL: audioURL) else {
        throw TranscriptionError.noSpeechDetected
      }
    } else {
      guard hasSignificantAudio(audioURL: audioURL) else {
        throw TranscriptionError.noSpeechDetected
      }
    }

    switch model {
    case .unified(let manager):
      let samples = try AudioConverter().resampleAudioFile(audioURL)
      try Task.checkCancellation()
      let result = try await manager.transcribeWithTimings(samples)
      try Task.checkCancellation()
      guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TranscriptionError.noSpeechDetected
      }
      return TranscriptionResult(text: result.text, confidence: nil,
        audioDuration: Double(samples.count) / 16000,
        processingTime: Date().timeIntervalSince(startTime), provider: name,
        language: "en", segments: buildSegments(from: result.tokenTimings))

    case .eou(let decoder):
      let samples = try AudioConverter().resampleAudioFile(audioURL)
      let session = EOURecordingSession { decoder }
      for start in stride(from: 0, to: samples.count, by: 5120) {
        session.append(Array(samples[start..<min(start + 5120, samples.count)]))
      }
      let result = try await session.finish()
      guard !result.text.isEmpty else { throw TranscriptionError.noSpeechDetected }
      return result

    case .tdt(let manager):
      let transcriptionURL = try ensureMinimumDuration(audioURL: audioURL)
      defer {
        if transcriptionURL != audioURL { try? FileManager.default.removeItem(at: transcriptionURL) }
      }
      var decoderState = try TdtDecoderState(decoderLayers: version.asrModelVersion?.decoderLayers ?? 2)
      let result = try await manager.transcribe(transcriptionURL, decoderState: &decoderState)
      try Task.checkCancellation()
      guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TranscriptionError.noSpeechDetected
      }
      return TranscriptionResult(text: result.text, confidence: result.confidence,
        audioDuration: result.duration, processingTime: Date().timeIntervalSince(startTime),
        provider: name, language: version == .v2English ? "en" : language,
        segments: result.tokenTimings.map { buildSegments(from: $0) })
    }
  }

  // MARK: - Model Management

  func loadModel(version: FluidAudioModelVersion) async throws {
    try await modelManager.downloadAndLoad(version: version)
  }

  // Model handles are owned only by the manager. Reconfiguration never retains a stale decoder.
  func unloadModel() {}
  func reinitialize() async throws {}

  // MARK: - Private Helpers

  /// Minimum audio duration required by FluidAudio (16kHz samples)
  private let minimumSampleCount = 16000 // 1 second at 16kHz

  /// Ensure audio file has at least 1 second of 16kHz audio.
  /// If too short, returns a new URL to a silence-padded copy; otherwise returns the original URL.
  private func ensureMinimumDuration(audioURL: URL) throws -> URL {
    let audioFile = try AVAudioFile(forReading: audioURL)
    let sampleRate = audioFile.processingFormat.sampleRate
    let frameCount = AVAudioFrameCount(audioFile.length)
    let durationSamples = Int(Double(frameCount) * (16000.0 / sampleRate))

    guard durationSamples < minimumSampleCount else {
      return audioURL // Already long enough
    }

    logger.info("Audio too short (\(frameCount) frames at \(sampleRate)Hz), padding with silence")

    // Read existing audio
    guard let readBuffer = AVAudioPCMBuffer(
      pcmFormat: audioFile.processingFormat,
      frameCapacity: frameCount
    ) else {
      throw TranscriptionError.audioTooShort
    }
    try audioFile.read(into: readBuffer)

    // Convert to 16kHz mono if needed
    let outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16000,
      channels: 1,
      interleaved: false
    )!

    let convertedBuffer: AVAudioPCMBuffer
    if audioFile.processingFormat.sampleRate != 16000 || audioFile.processingFormat.channelCount != 1 {
      guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: outputFormat) else {
        throw TranscriptionError.audioTooShort
      }
      let ratio = 16000.0 / sampleRate
      let outputCapacity = AVAudioFrameCount(Double(frameCount) * ratio)
      guard let buf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
        throw TranscriptionError.audioTooShort
      }
      var error: NSError?
      converter.convert(to: buf, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return readBuffer
      }
      if let error { throw error }
      convertedBuffer = buf
    } else {
      convertedBuffer = readBuffer
    }

    // Create padded buffer (at least 1 second)
    let existingFrames = Int(convertedBuffer.frameLength)
    let totalFrames = max(minimumSampleCount, existingFrames)
    guard let paddedBuffer = AVAudioPCMBuffer(
      pcmFormat: outputFormat,
      frameCapacity: AVAudioFrameCount(totalFrames)
    ) else {
      throw TranscriptionError.audioTooShort
    }

    // Copy existing samples
    if let src = convertedBuffer.floatChannelData, let dst = paddedBuffer.floatChannelData {
      dst[0].update(from: src[0], count: existingFrames)
      // Remaining frames are already zeroed (silence)
    }
    paddedBuffer.frameLength = AVAudioFrameCount(totalFrames)

    // Write to temp file
    let paddedURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("voxnotch_padded_\(UUID().uuidString).wav")
    let outputFile = try AVAudioFile(
      forWriting: paddedURL,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ]
    )
    try outputFile.write(from: paddedBuffer)

    return paddedURL
  }

  /// Build transcript segments from token timings
  private func buildSegments(from timings: [TokenTiming]) -> [TranscriptSegment] {
    var segments: [TranscriptSegment] = []
    var currentText = ""
    var segmentStart: TimeInterval = 0
    var segmentEnd: TimeInterval = 0
    var segmentId = 0

    for timing in timings {
      // Start new segment on sentence boundaries
      let isPunctuation = timing.token.last?.isPunctuation ?? false

      currentText += timing.token
      segmentEnd = timing.endTime

      if segmentStart == 0 {
        segmentStart = timing.startTime
      }

      // Split on sentence-ending punctuation
      if isPunctuation && (timing.token.contains(".") || timing.token.contains("?") || timing.token.contains("!")) {
        let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
          segments.append(TranscriptSegment(
            id: segmentId,
            start: segmentStart,
            end: segmentEnd,
            text: trimmedText
          ))
          segmentId += 1
        }
        currentText = ""
        segmentStart = 0
      }
    }

    // Add remaining text as final segment
    let remainingText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !remainingText.isEmpty {
      segments.append(TranscriptSegment(
        id: segmentId,
        start: segmentStart,
        end: segmentEnd,
        text: remainingText
      ))
    }

    return segments
  }

  /// Check if audio contains significant energy above noise floor.
  /// Returns false for near-silent recordings that would produce phantom words.
  private func hasSignificantAudio(audioURL: URL, thresholdDB: Float = -40.0) -> Bool {
    let audioFile: AVAudioFile
    do {
      audioFile = try AVAudioFile(forReading: audioURL)
    } catch {
      logger.error("Failed to open audio for energy check: \(error.localizedDescription)")
      return true // Allow transcription to proceed; it will fail with a clearer error
    }
    let frameCount = AVAudioFrameCount(audioFile.length)
    guard frameCount > 0 else { return false }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
      logger.error("Failed to allocate buffer for energy check")
      return true
    }
    do {
      try audioFile.read(into: buffer)
    } catch {
      logger.error("Failed to read audio for energy check: \(error.localizedDescription)")
      return true
    }
    guard let channelData = buffer.floatChannelData else { return true }

    var rms: Float = 0
    vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(buffer.frameLength))

    let db = 20.0 * log10(max(rms, 1e-10))
    logger.info("Pre-transcription audio energy: \(db, privacy: .public) dB (threshold: \(thresholdDB, privacy: .public) dB)")
    return db >= thresholdDB
  }
}
