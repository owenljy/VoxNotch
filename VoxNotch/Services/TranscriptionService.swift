//
//  TranscriptionService.swift
//  VoxNotch
//
//  Transcription service with protocol-abstracted providers
//

import Foundation
import os.log

// MARK: - Transcription Provider Protocol

/// Protocol for speech-to-text transcription providers
protocol TranscriptionProvider: AnyObject, Sendable {
  /// Provider name for display
  var name: String { get }

  /// Whether the provider is ready to transcribe
  var isReady: Bool { get async }

  func unloadModel()

  /// Transcribe audio file to text
  /// - Parameters:
  ///   - audioURL: URL to the audio file (WAV format)
  ///   - language: Optional language code (e.g., "en", "zh")
  /// - Returns: Transcription result
  func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult
}

extension TranscriptionProvider {
  func unloadModel() {}
}

// MARK: - Transcription Result

/// Result of a transcription operation
struct TranscriptionResult: Sendable {
  /// The transcribed text
  let text: String

  /// Confidence score (0.0 - 1.0), if available
  let confidence: Float?

  /// Duration of the audio in seconds
  let audioDuration: TimeInterval

  /// Time taken for transcription in seconds
  let processingTime: TimeInterval

  /// Provider that produced this result
  let provider: String

  /// Detected or specified language
  let language: String?

  /// Transcript segments with timing (if available)
  let segments: [TranscriptSegment]?
}

/// A segment of transcribed text with timing information
struct TranscriptSegment: Sendable, Identifiable {
  let id: Int
  let start: TimeInterval
  let end: TimeInterval
  let text: String
}

// MARK: - Transcription Error

enum TranscriptionError: LocalizedError {
    case providerNotReady
    case fileNotFound
    case invalidFormat
    case fileTooSmall
    case fileCorrupted
    case audioTooShort
    case noSpeechDetected
    case transcriptionFailed(String)
    case modelNotLoaded
    case timeout

    var errorDescription: String? {
        switch self {
        case .providerNotReady:
            return "Speech model not ready"
        case .fileNotFound:
            return "Recording not found"
        case .invalidFormat:
            return "Recording format not supported"
        case .fileTooSmall:
            return "Recording too short"
        case .fileCorrupted:
            return "Recording is corrupted"
        case .audioTooShort:
            return "Recording too short"
        case .noSpeechDetected:
            return "No speech detected"
        case .transcriptionFailed:
            return "Transcription failed"
        case .modelNotLoaded:
            return "Speech model not downloaded"
        case .timeout:
            return "Timed out"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .audioTooShort, .noSpeechDetected:
            return "Try speaking longer or louder"
        case .modelNotLoaded, .providerNotReady:
            return "Open Settings → Speech Model to download"
        case .fileCorrupted, .invalidFormat, .fileTooSmall, .fileNotFound:
            return "Try recording again"
        case .timeout:
            return "Check your connection and try again"
        case .transcriptionFailed:
            return "Try again — or switch models in Settings"
        }
    }
}

// MARK: - Transcription Service

/// Main service for managing transcription using configurable ASR providers
///
/// Thread Safety: `providerLock` (NSLock) protects all access to `primaryProvider`.
final class TranscriptionService: @unchecked Sendable {

  // MARK: - Properties

  static let shared = TranscriptionService()

  private let logger = Logger(subsystem: "com.voxnotch", category: "TranscriptionService")
  private let settings = SettingsManager.shared
  private let fluidModelManager = FluidAudioModelManager.shared
  private let mlxModelManager = MLXAudioModelManager.shared

  /// Primary transcription provider (FluidAudio or MLXAudio)
  private var recordingSession: (any RecordingAudioSession)?
  private var recordingLease: UUID?
  private var activeOperations = 0
  private var lastUsed = Date()

  private var primaryProvider: TranscriptionProvider?

  /// Lock protecting primaryProvider during reconfigure/transcribe
  private let providerLock = NSLock()

  /// Whether the service is ready
  var isReady: Bool {
    get async {
      providerLock.lock()
      let primary = primaryProvider
      providerLock.unlock()
      if let primary {
        let ready = await primary.isReady
        // Re-check: if provider was swapped during await, report not ready
        providerLock.lock()
        let stillCurrent = (primaryProvider as AnyObject) === (primary as AnyObject)
        providerLock.unlock()
        return stillCurrent && ready
      }
      let engine = ASREngine(rawValue: settings.asrEngine) ?? .fluidAudio
      switch engine {
      case .fluidAudio: return fluidModelManager.isReady
      case .mlxAudio: return mlxModelManager.isReady
      }
    }
  }

  /// Current provider name for display
  var currentProviderName: String {
    providerLock.lock()
    let name = primaryProvider?.name
    providerLock.unlock()
    return name ?? "FluidAudio"
  }

  /// Whether models are currently downloading
  var isDownloadingModel: Bool {
    let engine = ASREngine(rawValue: settings.asrEngine) ?? .fluidAudio
    switch engine {
    case .fluidAudio:
      for (_, state) in fluidModelManager.modelStates {
        if case .downloading = state { return true }
      }
    case .mlxAudio:
      for (_, state) in mlxModelManager.modelStates {
        if case .downloading = state { return true }
      }
      // Also check custom model download states
      for (_, state) in mlxModelManager.customModelStates {
        if case .downloading = state { return true }
      }
    }
    return false
  }

  // MARK: - Initialization

  private init() {
    configureProviders()
    ModelMemoryManager.shared.start { [weak self] seconds in self?.unloadIfIdle(idleFor: seconds) }
  }

  // MARK: - Configuration

  /// Configure transcription providers based on selected ASR engine
  func configureProviders() {
    let engine = ASREngine(rawValue: settings.asrEngine) ?? .fluidAudio

    providerLock.lock()
    switch engine {
    case .fluidAudio:
      primaryProvider = FluidAudioProvider()
      logger.info("Primary provider: FluidAudio")

    case .mlxAudio:
      primaryProvider = MLXAudioProvider()
      logger.info("Primary provider: MLX Audio")
    }
    providerLock.unlock()
  }

  /// Reconfigure providers (call after settings change)
  ///
  /// Atomically replaces the provider in a single lock scope to avoid
  /// a window where `primaryProvider` is nil between the old nil-set
  /// and the new assignment.
  func reconfigure() {
    let engine = ASREngine(rawValue: settings.asrEngine) ?? .fluidAudio
    providerLock.lock()
    switch engine {
    case .fluidAudio:
      primaryProvider = FluidAudioProvider()
      logger.info("Reconfigured: FluidAudio")
    case .mlxAudio:
      primaryProvider = MLXAudioProvider()
      logger.info("Reconfigured: MLX Audio")
    }
    providerLock.unlock()
  }

  // MARK: - Public Methods

  /// Keep models alive during recording/loading/inference; release both owners when idle.
  private func beginOperation() {
    providerLock.withLock { activeOperations += 1; lastUsed = Date() }
  }
  private func endOperation() {
    providerLock.withLock { activeOperations -= 1; lastUsed = Date() }
  }

  func unloadIfIdle(idleFor seconds: TimeInterval = 300) {
    providerLock.lock()
    guard recordingLease == nil, activeOperations == 0, !isDownloadingModel, Date().timeIntervalSince(lastUsed) >= seconds else {
      providerLock.unlock()
      return
    }
    primaryProvider?.unloadModel()
    mlxModelManager.unloadModel()
    fluidModelManager.unloadModels()
    providerLock.unlock()
  }

  func beginStreaming() -> (@Sendable ([Float]) -> Void)? {
    cancelStreaming()
    providerLock.withLock { recordingLease = UUID(); lastUsed = Date() }
    if SpeechModel.resolve(settings.speechModel).builtin == .parakeetEOU {
      let session = EOURecordingSession { [self] in
        try await ensureModelReady()
        guard case .eou(let decoder) = fluidModelManager.getLoadedModel(for: .eou120m) else {
          throw TranscriptionError.modelNotLoaded
        }
        return decoder
      }
      providerLock.withLock { recordingSession = session }
      return { samples in session.append(samples) }
    }
    #if canImport(MLXAudioSTT)
    guard SpeechModel.resolve(settings.speechModel).builtin == .voxtralMini else { return nil }
    let language = settings.transcriptionLanguage == "auto" ? nil : settings.transcriptionLanguage
    let session = RecordingTranscriptionSession(language: language) { [self] in
      try await ensureModelReady()
      return try await MainActor.run {
        guard let model = mlxModelManager.getLoadedModel() else { throw TranscriptionError.modelNotLoaded }
        return ASRModelHandle(model: model)
      }
    }
    providerLock.withLock { recordingSession = session }
    return { samples in session.append(samples) }
    #else
    return nil
    #endif
  }

  func cancelStreaming() {
    providerLock.withLock {
      recordingLease = nil
      lastUsed = Date()
      recordingSession?.cancel()
      recordingSession = nil
    }
  }

  func finishStreaming(audioURL: URL, language: String?) async throws -> TranscriptionResult {
    beginOperation()
    let lease = providerLock.withLock { recordingLease }
    defer {
      endOperation()
      providerLock.withLock { if recordingLease == lease { recordingLease = nil } }
    }
    let session = providerLock.withLock { () -> (any RecordingAudioSession)? in
      defer { recordingSession = nil }
      return recordingSession
    }
    if let session {
      do {
        if settings.useVADSpeechGate, try await !VadGate.shared.containsSpeech(audioURL: audioURL) {
          session.cancel()
          throw TranscriptionError.noSpeechDetected
        }
        let result = try await session.finish()
        guard !result.text.isEmpty else { throw TranscriptionError.noSpeechDetected }
        return result
      } catch is CancellationError {
        session.cancel()
        throw CancellationError()
      } catch {
        session.cancel()
        try Task.checkCancellation()
        // The WAV is retained throughout recording, so failed streaming is recoverable.
        if case TranscriptionError.noSpeechDetected = error { throw error }
        logger.warning("Recording-time inference failed; retrying complete audio: \(error)")
      }
    }
    return try await transcribe(audioURL: audioURL, language: language)
  }

  /// Set the primary transcription provider
  func setPrimaryProvider(_ provider: TranscriptionProvider) {
    providerLock.lock()
    self.primaryProvider = provider
    providerLock.unlock()
    logger.info("Primary provider set: \(provider.name)")
  }

  /// Preload the model in the background to reduce cold start time.
  /// This is a non-throwing, best-effort operation.
  func preloadModel() {
    Task {
      do {
        try await ensureModelReady()
      } catch {
        logger.error("Failed to preload model: \(error.localizedDescription)")
      }
    }
  }

  /// Check if the model is downloaded and load it if so.
  /// Does NOT auto-download - throws if model not available.
  func ensureModelReady() async throws {
    beginOperation()
    defer { endOperation() }
    try Task.checkCancellation()
    let speechModelID = settings.speechModel
    let (builtinModel, customModel) = SpeechModel.resolve(speechModelID)

    // Handle custom user-defined models
    if let custom = customModel {
      if !mlxModelManager.isCustomModelReady(id: custom.id) {
        // fromPretrained uses HF Hub cache; fast if already downloaded
        try await mlxModelManager.downloadAndLoadCustom(model: custom)
        logger.info("Custom MLX Audio model ready: \(custom.hfRepoID)")
      }
      return
    }

    let engine = ASREngine(rawValue: settings.asrEngine) ?? .fluidAudio

    switch engine {
    case .fluidAudio:
      // Prefer explicitly selected model version; fall back to language-based recommendation
      let language = settings.transcriptionLanguage
      let version = builtinModel?.fluidAudioVersion
        ?? FluidAudioModelVersion(rawValue: settings.fluidAudioModel)
        ?? fluidModelManager.recommendedVersion(for: language == "auto" ? "en" : language)

      guard fluidModelManager.isVersionDownloaded(version) else {
        throw TranscriptionError.modelNotLoaded
      }

      if !fluidModelManager.isVersionReady(version) {
        _ = try await fluidModelManager.downloadAndLoad(version: version)
        logger.info("FluidAudio model loaded from cache")
      }

    case .mlxAudio:
      guard let version = builtinModel?.mlxAudioVersion
              ?? MLXAudioModelVersion(rawValue: settings.mlxAudioModel)
      else {
        throw TranscriptionError.modelNotLoaded
      }

      guard mlxModelManager.isVersionDownloaded(version) else {
        throw TranscriptionError.modelNotLoaded
      }

      if !mlxModelManager.isVersionReady(version) {
        _ = try await mlxModelManager.downloadAndLoad(version: version)
        logger.info("MLX Audio model loaded from cache")
      }
    }
  }

  /// Load a specific FluidAudio model version
  func loadFluidAudioModel(version: FluidAudioModelVersion) async throws {
    _ = try await fluidModelManager.downloadAndLoad(version: version)

    // Reinitialize provider with new model
    providerLock.lock()
    let provider = primaryProvider as? FluidAudioProvider
    providerLock.unlock()
    if let provider {
      try await provider.reinitialize()
      // Verify provider wasn't swapped during reinitialize
      providerLock.lock()
      let stillCurrent = primaryProvider as? FluidAudioProvider === provider
      providerLock.unlock()
      if !stillCurrent {
        logger.warning("Provider swapped during FluidAudio model load — reinitialize result orphaned")
      }
    }
  }

  /// Load a specific MLX Audio model version
  func loadMLXAudioModel(version: MLXAudioModelVersion) async throws {
    _ = try await mlxModelManager.downloadAndLoad(version: version)

    // Reinitialize provider with new model
    providerLock.lock()
    let provider = primaryProvider as? MLXAudioProvider
    providerLock.unlock()
    if let provider {
      try await provider.reinitialize()
      // Verify provider wasn't swapped during reinitialize
      providerLock.lock()
      let stillCurrent = primaryProvider as? MLXAudioProvider === provider
      providerLock.unlock()
      if !stillCurrent {
        logger.warning("Provider swapped during MLX Audio model load — reinitialize result orphaned")
      }
    }
  }

  /// Transcribe an audio file
  /// - Parameters:
  ///   - audioURL: URL to the audio file
  ///   - language: Optional language code (e.g., "en", "zh")
  /// - Returns: Transcription result
  func transcribe(audioURL: URL, language: String? = nil) async throws -> TranscriptionResult {
    beginOperation()
    defer { endOperation() }
    try Task.checkCancellation()
    // Validate audio file before transcription
    try validateAudioFile(at: audioURL)

    let effectiveLanguage = language ?? (settings.transcriptionLanguage == "auto" ? nil : settings.transcriptionLanguage)

    // Snapshot provider under lock to avoid race with reconfigure()
    providerLock.lock()
    let provider = primaryProvider
    providerLock.unlock()

    guard let provider else {
      throw TranscriptionError.providerNotReady
    }

    // Transcribe using FluidAudio
    do {
      let result = try await provider.transcribe(audioURL: audioURL, language: effectiveLanguage)

      // Warn if provider was swapped during transcription (result is still valid
      // because the local strong ref kept the old provider alive)
      providerLock.lock()
      let stillCurrent = primaryProvider === provider
      providerLock.unlock()
      if !stillCurrent {
        logger.warning("Provider swapped during transcription — result from previous provider")
      }

      return processResult(result)
    } catch {
      logger.error("Transcription failed: \(error.localizedDescription)")
      throw error
    }
  }

  // MARK: - Private Methods

  private func processResult(_ result: TranscriptionResult) -> TranscriptionResult {
    /// Handle empty/noise-only transcriptions gracefully
    if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return TranscriptionResult(
        text: "",
        confidence: result.confidence,
        audioDuration: result.audioDuration,
        processingTime: result.processingTime,
        provider: result.provider,
        language: result.language,
        segments: result.segments
      )
    }
    return result
  }

  /// Minimum file size for valid audio (header + some samples)
  private let minimumFileSize: Int = 1000

  /// Validate audio file before transcription
  private func validateAudioFile(at url: URL) throws {
    /// Check file exists
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TranscriptionError.fileNotFound
    }

    /// Check file size
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let fileSize = attributes[.size] as? Int
    else {
      throw TranscriptionError.fileCorrupted
    }

    if fileSize < minimumFileSize {
      throw TranscriptionError.fileTooSmall
    }

    /// Validate WAV header (first 4 bytes should be "RIFF")
    if url.pathExtension.lowercased() == "wav" {
      guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
        throw TranscriptionError.fileCorrupted
      }

      defer { try? fileHandle.close() }

      guard let headerData = try? fileHandle.read(upToCount: 4),
            headerData.count == 4
      else {
        throw TranscriptionError.fileCorrupted
      }

      let headerString = String(data: headerData, encoding: .ascii)
      if headerString != "RIFF" {
        throw TranscriptionError.invalidFormat
      }
    }
  }
}

// MARK: - Mock Provider (for development/testing)

/// Mock transcription provider for testing without ML dependencies
final class MockTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {

  let name = "Mock"

  var isReady: Bool {
    get async { true }
  }

  /// Simulated transcription delay
  private let simulatedDelay: TimeInterval = 0.5

  /// Predefined mock responses
  private let mockResponses: [String] = [
    "This is a test transcription.",
    "Hello world, testing voice dictation.",
    "The quick brown fox jumps over the lazy dog."
  ]

  private var responseIndex = 0

  func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
    let startTime = Date()

    /// Simulate processing time
    try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))

    /// Get mock response
    let text = mockResponses[responseIndex % mockResponses.count]

    let processingTime = Date().timeIntervalSince(startTime)

    return TranscriptionResult(
      text: text,
      confidence: 0.95,
      audioDuration: 2.0,
      processingTime: processingTime,
      provider: name,
      language: language,
      segments: nil
    )
  }
}
