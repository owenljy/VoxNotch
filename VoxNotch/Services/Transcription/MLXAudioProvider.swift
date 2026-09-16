//
//  MLXAudioProvider.swift
//  VoxNotch
//
//  Speech-to-text provider using mlx-audio-swift for ASR
//

import AVFoundation
import Foundation
import os.log

#if canImport(MLXAudioSTT)
import MLX
import MLXAudioSTT
#endif

/// Speech-to-text provider using MLX Audio (GLM-ASR models)
/// Implements TranscriptionProvider protocol for seamless integration
///
/// Thread Safety: `lock` (NSLock) protects `isModelLoaded` and `model`.
final class MLXAudioProvider: TranscriptionProvider, @unchecked Sendable {

  // MARK: - Properties

  let name = "MLX Audio"

  private let logger = Logger(subsystem: "com.voxnotch", category: "MLXAudioProvider")
  private let modelManager = MLXAudioModelManager.shared

  /// Lock for thread safety
  private let lock = NSLock()

  /// Whether the model is currently loaded
  private var isModelLoaded = false

  #if canImport(MLXAudioSTT)
  /// The loaded ASR model (GLMASRModel or Qwen3ASRModel, stored as the common protocol)
  private var model: (any STTGenerationModel)?
  #endif

  // MARK: - TranscriptionProvider

  var isReady: Bool {
    get async {
      modelManager.isReady
    }
  }

  func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
    let startTime = Date()

    #if canImport(MLXAudioSTT)
    /// Ensure model is loaded
    try await ensureModelLoaded()

    guard model != nil else {
      throw TranscriptionError.modelNotLoaded
    }

    /// Run audio loading and model inference on a dedicated GCD queue so the
    /// synchronous `model.generate()` call doesn't block Swift's cooperative
    /// thread pool, which would starve MainActor tasks and freeze the UI.
    if SettingsManager.shared.useVADSpeechGate {
      guard try await VadGate.shared.containsSpeech(audioURL: audioURL) else {
        throw TranscriptionError.noSpeechDetected
      }
    }
    let cancellation = ASRCancellation()
    let (outputText, detectedLanguage, audioDuration) = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, String?, Double), Error>) in
        ASRInference.queue.async { [self] in
          do {
            try cancellation.check()
            guard let model = self.lock.withLock({ self.model }) else { throw TranscriptionError.modelNotLoaded }
            let samples = try self.loadAudioSamples(from: audioURL)
            let output = try ASRInference.generate(model: model, samples: samples, language: language, cancellation: cancellation)
            continuation.resume(returning: (output.text, output.language, Double(samples.count) / 16000))
          } catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: { cancellation.cancel() }
    try Task.checkCancellation()

    let processingTime = Date().timeIntervalSince(startTime)

    guard !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TranscriptionError.noSpeechDetected
    }

    let cleanedText = outputText.trimmingCharacters(in: .whitespacesAndNewlines)

    return TranscriptionResult(
      text: cleanedText,
      confidence: nil,
      audioDuration: audioDuration,
      processingTime: processingTime,
      provider: name,
      language: detectedLanguage,
      segments: nil
    )
    #else
    /// MLX Audio SDK not available
    throw TranscriptionError.providerNotReady
    #endif
  }

  // MARK: - Model Management

  #if canImport(MLXAudioSTT)
  /// Ensure the ASR model is loaded.
  /// Priority: (1) model already in manager memory, (2) custom model by loaderClass,
  /// (3) built-in model by loaderClass. All paths store the result in `self.model`.
  private func ensureModelLoaded() async throws {
    /// 1. Use a model already loaded by the manager (fastest path).
    if let existing = modelManager.getLoadedModel() {
      lock.withLock {
        model = existing
        isModelLoaded = true
      }
      logger.info("Using existing MLX Audio model from manager")
      return
    }

    /// 2. Custom model — detect loader class from cached config.json.
    let speechModelID = SettingsManager.shared.speechModel
    let (_, customModel) = SpeechModel.resolve(speechModelID)

    if let custom = customModel {
      logger.info("Loading custom MLX Audio model from HF cache: \(custom.hfRepoID)")
      let loaderClass = try await modelManager.inferLoaderClass(hfRepoID: custom.hfRepoID)
      let loaded: any STTGenerationModel
      switch loaderClass {
      case .glmASR:
        loaded = try await GLMASRModel.fromPretrained(custom.hfRepoID)
      case .qwen3ASR:
        loaded = try await Qwen3ASRModel.fromPretrained(custom.hfRepoID)
      case .voxtralRealtime:
        loaded = try await VoxtralRealtimeModel.fromPretrained(custom.hfRepoID)
      case .parakeet:
        loaded = try await ParakeetModel.fromPretrained(custom.hfRepoID)
      }
      lock.withLock {
        model = loaded
        isModelLoaded = true
      }
      logger.info("Custom MLX Audio model loaded successfully")
      return
    }

    /// 3. Built-in model — dispatch by version.loaderClass.
    let settings = SettingsManager.shared
    guard let version = MLXAudioModelVersion(rawValue: settings.mlxAudioModel) else {
      throw MLXAudioError.modelNotLoaded
    }
    guard modelManager.isVersionDownloaded(version) else {
      throw TranscriptionError.modelNotLoaded
    }

    logger.info("Loading MLX Audio model: \(version.displayName)")
    // downloadAndLoad sets loadedModel in the manager and returns; then we pull it out.
    _ = try await modelManager.downloadAndLoad(version: version)
    if let loaded = modelManager.getLoadedModel() {
      lock.withLock {
        model = loaded
        isModelLoaded = true
      }
    }

    logger.info("MLX Audio model loaded successfully")
  }
  #endif

  /// Unload the model to free memory
  func unloadModel() {
    lock.withLock {
      #if canImport(MLXAudioSTT)
      model = nil
      #endif
      isModelLoaded = false
    }

    logger.info("MLX Audio model unloaded")
  }

  /// Reinitialize after model change
  func reinitialize() async throws {
    unloadModel()
    #if canImport(MLXAudioSTT)
    try await ensureModelLoaded()
    #endif
  }

  // MARK: - Audio Loading

  #if canImport(MLXAudioSTT)
  /// Load audio file and convert to MLXArray at 16kHz mono
  private func loadAudioSamples(from url: URL) throws -> [Float] {
    let audioFile = try AVAudioFile(forReading: url)
    let sourceFormat = audioFile.processingFormat
    let frameCount = AVAudioFrameCount(audioFile.length)

    /// Target format: 16kHz mono Float32
    guard let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16000,
      channels: 1,
      interleaved: false
    ) else {
      throw MLXAudioError.invalidAudioFormat
    }

    /// Read source audio
    guard let sourceBuffer = AVAudioPCMBuffer(
      pcmFormat: sourceFormat,
      frameCapacity: frameCount
    ) else {
      throw MLXAudioError.audioLoadFailed("Failed to create source buffer")
    }
    try audioFile.read(into: sourceBuffer)

    /// Convert if needed
    let outputBuffer: AVAudioPCMBuffer
    if sourceFormat.sampleRate != 16000 || sourceFormat.channelCount != 1 {
      guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw MLXAudioError.audioLoadFailed("Failed to create audio converter")
      }

      let ratio = 16000.0 / sourceFormat.sampleRate
      let outputCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 100

      guard let buffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: outputCapacity
      ) else {
        throw MLXAudioError.audioLoadFailed("Failed to create output buffer")
      }

      var error: NSError?
      var inputConsumed = false
      converter.convert(to: buffer, error: &error) { _, outStatus in
        if inputConsumed {
          outStatus.pointee = .noDataNow
          return nil
        }
        inputConsumed = true
        outStatus.pointee = .haveData
        return sourceBuffer
      }

      if let error {
        throw MLXAudioError.audioLoadFailed(error.localizedDescription)
      }

      outputBuffer = buffer
    } else {
      outputBuffer = sourceBuffer
    }

    /// Convert to MLXArray
    guard let floatData = outputBuffer.floatChannelData else {
      throw MLXAudioError.audioLoadFailed("Failed to get float channel data")
    }

    let samples = Int(outputBuffer.frameLength)
    let floatArray = Array(UnsafeBufferPointer(start: floatData[0], count: samples))

    return floatArray
  }
  #endif
}
