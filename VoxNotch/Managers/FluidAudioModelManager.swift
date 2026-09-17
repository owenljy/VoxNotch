//
//  FluidAudioModelManager.swift
//  VoxNotch
//
//  Manages FluidAudio ASR model downloads and lifecycle
//

import CryptoKit
import FluidAudio
import Foundation
import os.log

// MARK: - FluidAudio Model Version

/// Available FluidAudio ASR model versions
enum FluidAudioModelVersion: String, CaseIterable, Identifiable, Sendable {
  case v2English = "v2"
  case v3Multilingual = "v3"
  case unifiedEnglish = "unified-en-0.6b"
  case eou120m = "eou-120m-320ms"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .v2English: return "Parakeet v2 (English)"
    case .unifiedEnglish: return "Parakeet Unified English 0.6B"
    case .eou120m: return "Parakeet EOU 120M"
    case .v3Multilingual: return "Parakeet v3 (Multilingual)"
    }
  }

  var supportedLanguages: [String] {
    switch self {
    case .v2English, .unifiedEnglish, .eou120m: return ["en"]
    case .v3Multilingual: return [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk",
      ]
    }
  }

  var estimatedSizeMB: Int {
    switch self {
    case .v2English: return 500
    case .unifiedEnglish: return 615
    case .eou120m: return 225
    case .v3Multilingual: return 800
    }
  }

  /// Convert to FluidAudio's AsrModelVersion
  var asrModelVersion: AsrModelVersion? {
    switch self {
    case .unifiedEnglish, .eou120m: return nil
    case .v2English: return .v2
    case .v3Multilingual: return .v3
    }
  }
}

/// Each family retains its own decoder API; Unified is not a TDT AsrModels variant.
enum LoadedFluidAudioModel: Sendable {
  case tdt(AsrManager)
  case unified(UnifiedAsrManager)
  case eou(EOUDecoder)
}

// MARK: - FluidAudio Model Manager

/// Manages FluidAudio model downloads and lifecycle
///
/// Thread Safety: uses dual protection —
/// • `lock` (NSLock) guards internal model references (`loadedModels`, `loadedVersion`)
///   that are read/written from async download tasks and background transcription providers.
/// • UI-observable state (`modelStates`, `downloadProgress`) is written via `MainActor.run`
///   from async methods; `refreshAllModelStates()` and `delete*()` must be called from MainActor.
@Observable
final class FluidAudioModelManager: @unchecked Sendable {

  // MARK: - Singleton

  static let shared = FluidAudioModelManager()

  // MARK: - Properties

  private let logger = Logger(subsystem: "com.voxnotch", category: "FluidAudioModelManager")

  /// Current state of each batch ASR model version
  private(set) var modelStates: [FluidAudioModelVersion: ModelDownloadState] = [:]

  /// Currently loaded ASR models
  private var loadedModels: LoadedFluidAudioModel?
  @ObservationIgnored private var loadTasks: [FluidAudioModelVersion: Task<Void, Error>] = [:]

  /// Currently loaded model version
  private(set) var loadedVersion: FluidAudioModelVersion?

  /// Download progress (0.0 to 1.0)
  private(set) var downloadProgress: Double = 0

  /// Whether any model is ready (lock-protected — safe to call from any thread)
  var isReady: Bool {
    lock.withLock { loadedModels != nil }
  }

  /// Lock for thread safety
  private let lock = NSLock()

  // MARK: - Initialization

  private init() {
    for version in FluidAudioModelVersion.allCases {
      modelStates[version] = .notDownloaded
    }
    refreshAllModelStates()
  }

  // MARK: - Public Methods

  /// Concurrent callers for one version share a single download/load operation.
  func downloadAndLoad(version: FluidAudioModelVersion) async throws {
    let task = lock.withLock { () -> Task<Void, Error> in
      if let task = loadTasks[version] { return task }
      let task = Task { [self] in
        defer { lock.withLock { loadTasks[version] = nil } }
        try await performDownloadAndLoad(version: version)
      }
      loadTasks[version] = task
      return task
    }
    try await task.value
    try Task.checkCancellation()
  }

  private func performDownloadAndLoad(version: FluidAudioModelVersion) async throws {
    if isVersionReady(version) { return }
    await MainActor.run {
      modelStates[version] = .downloading(progress: 0, downloadedBytes: 0,
        totalBytes: Int64(version.estimatedSizeMB) * 1_000_000, speedBytesPerSecond: 0)
    }
    let pollingTask = DownloadProgressTracker.poll(
      directory: modelDirectory(for: version),
      expectedBytes: Int64(version.estimatedSizeMB) * 1_000_000
    ) { [weak self] progress, bytes, total, speed in
      guard let self, self.modelStates[version]?.isDownloading == true else { return }
      self.modelStates[version] = .downloading(progress: progress, downloadedBytes: bytes,
        totalBytes: total, speedBytesPerSecond: speed)
      self.downloadProgress = progress
    }
    defer { pollingTask.cancel() }

    do {
      let loaded: LoadedFluidAudioModel
      if version == .eou120m {
        let manager = StreamingEouAsrManager(chunkSize: .ms320)
        try await manager.loadModels(to: modelsRoot)
        loaded = .eou(EOUDecoder(engine: CoreMLEOUEngine(manager: manager)))
      } else if version == .unifiedEnglish {
        let manager = UnifiedAsrManager(encoderPrecision: .int8)
        try await manager.loadModels(to: modelsRoot)
        loaded = .unified(manager)
      } else {
        guard let tdtVersion = version.asrModelVersion else { throw FluidAudioError.modelNotLoaded }
        let models = try await AsrModels.downloadAndLoad(version: tdtVersion)
        let manager = AsrManager()
        try await manager.loadModels(models)
        loaded = .tdt(manager)
      }
      try Task.checkCancellation()
      guard verifyChecksumManifest(for: version) else {
        throw FluidAudioError.modelDownloadFailed("Model files corrupted (checksum mismatch). Delete the model and download it again.")
      }
      saveChecksumManifest(for: version)
      let previous = lock.withLock {
        let previous = loadedVersion
        loadedModels = loaded
        loadedVersion = version
        return previous
      }
      await MainActor.run {
        if let previous, previous != version { modelStates[previous] = .downloaded }
        modelStates[version] = .ready
        downloadProgress = 1
      }
    } catch {
      await MainActor.run { modelStates[version] = .failed(message: error.localizedDescription) }
      throw error
    }
  }

  func getLoadedModel(for version: FluidAudioModelVersion) -> LoadedFluidAudioModel? {
    lock.withLock { loadedVersion == version ? loadedModels : nil }
  }

  func isVersionReady(_ version: FluidAudioModelVersion) -> Bool {
    lock.withLock { loadedVersion == version && loadedModels != nil }
  }

  private var modelsRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("FluidAudio/Models")
  }

  func modelDirectory(for version: FluidAudioModelVersion) -> URL {
    if let tdtVersion = version.asrModelVersion {
      return AsrModels.defaultCacheDirectory(for: tdtVersion)
    }
    return modelsRoot.appendingPathComponent(
      version == .eou120m ? Repo.parakeetEou320.folderName : Repo.parakeetUnified.folderName)
  }

  /// Unload current models to free memory
  func unloadModels() {
    let previousVersion: FluidAudioModelVersion? = lock.withLock {
      loadedModels = nil
      let v = loadedVersion
      loadedVersion = nil
      return v
    }
    if let version = previousVersion {
      Task { @MainActor in
        modelStates[version] = .downloaded
      }
    }
    logger.info("Unloaded FluidAudio models")
  }

  /// Get recommended model version for a language
  func recommendedVersion(for language: String) -> FluidAudioModelVersion {
    let normalizedLang = language.lowercased().prefix(2)
    if normalizedLang == "en" {
      return .v2English
    }
    return .v3Multilingual
  }

  // MARK: - Model State Refresh

  /// Check filesystem for all model types and update states without downloading.
  /// Must be called from MainActor (writes UI-observable `modelStates`).
  func refreshAllModelStates() {
    let (currentLoadedVersion, hasLoadedModels) = lock.withLock {
      (loadedVersion, loadedModels != nil)
    }
    for version in FluidAudioModelVersion.allCases {
      if lock.withLock({ loadTasks[version] != nil }) { continue }
      let isDownloaded = isVersionDownloaded(version)
      if isDownloaded {
        // If loaded in memory, mark ready; otherwise just downloaded
        if currentLoadedVersion == version && hasLoadedModels {
          modelStates[version] = .ready
        } else {
          modelStates[version] = .downloaded
        }
      } else if !(modelStates[version]?.isDownloading ?? false) {
        modelStates[version] = .notDownloaded
      }
    }
  }

  // MARK: - Readiness Queries

  /// Check if a specific batch ASR version is downloaded on disk
  func isVersionDownloaded(_ version: FluidAudioModelVersion) -> Bool {
    let cacheDir = modelDirectory(for: version)
    if let tdtVersion = version.asrModelVersion {
      return AsrModels.modelsExist(at: cacheDir, version: tdtVersion)
    }
    let required = version == .eou120m
      ? ModelNames.ParakeetEOU.requiredModels
      : ModelNames.ParakeetUnified.requiredModels(variant: "offline")
    return FluidModelCache.isComplete(cacheDir, required: required)
  }

  /// Whether Quick Dictation models are ready (batch ASR model is downloaded)
  func quickDictationModelsReady() -> Bool {
    let settings = SettingsManager.shared
    let language = settings.transcriptionLanguage
    let version = recommendedVersion(for: language == "auto" ? "en" : language)
    return isVersionDownloaded(version)
  }

  /// Human-readable description of missing models
  func missingModelsDescription() -> String {
    var missing: [String] = []

    let settings = SettingsManager.shared
    let language = settings.transcriptionLanguage
    let version = recommendedVersion(for: language == "auto" ? "en" : language)
    if !isVersionDownloaded(version) {
      missing.append("Speech Model (\(version.displayName))")
    }

    if missing.isEmpty {
      return "All models downloaded"
    }
    return "Missing: \(missing.joined(separator: ", "))"
  }

  // MARK: - Download Methods (for Settings UI)

  /// Download batch ASR model only (called from Settings)
  func downloadBatchModel(version: FluidAudioModelVersion) async throws {
    try await downloadAndLoad(version: version)
  }

  // MARK: - Delete Methods

  /// Delete batch ASR model files.
  /// Must be called from MainActor (writes UI-observable `modelStates`).
  func deleteBatchModel(version: FluidAudioModelVersion) throws {
    guard !lock.withLock({ loadTasks[version] != nil }) else {
      throw FluidAudioError.modelDownloadFailed("Wait for the download to finish before deleting this model.")
    }
    // Atomically check and unload if currently loaded
    lock.withLock {
      if loadedVersion == version {
        loadedModels = nil
        loadedVersion = nil
      }
    }

    let cacheDir = modelDirectory(for: version)
    if FileManager.default.fileExists(atPath: cacheDir.path) {
      try FileManager.default.removeItem(at: cacheDir)
    }

    modelStates[version] = .notDownloaded
    logger.info("Deleted batch ASR model: \(version.rawValue)")
  }

  /// Delete all downloaded models
  func deleteAllModels() throws {
    var errors: [String] = []
    for version in FluidAudioModelVersion.allCases {
      do {
        try deleteBatchModel(version: version)
      } catch {
        errors.append("\(version.rawValue): \(error.localizedDescription)")
      }
    }
    if !errors.isEmpty {
      logger.error("Some models failed to delete: \(errors.joined(separator: "; "))")
    }
    logger.info("Deleted all models")
  }

  /// Calculate total storage used by all downloaded models
  func totalStorageUsedBytes() -> Int64 {
    var total: Int64 = 0
    for version in FluidAudioModelVersion.allCases {
      let dir = modelDirectory(for: version)
      total += DownloadProgressTracker.directorySize(at: dir)
    }
    return total
  }

  // MARK: - Integrity Verification

  /// Compute SHA256 of a single file using chunked reads (safe for large model files)
  private func sha256(of url: URL) -> String? {
    guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fileHandle.close() }

    var hasher = SHA256()
    let chunkSize = 4 * 1024 * 1024 // 4 MB

    while autoreleasepool(invoking: {
      guard let chunk = try? fileHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
        return false
      }
      hasher.update(data: chunk)
      return true
    }) {}

    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Build a checksum manifest for all files in a model directory.
  /// Returns a dictionary of relative-path → SHA256.
  private func buildManifest(for directory: URL) -> [String: String] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [:] }

    var manifest: [String: String] = [:]
    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true,
            fileURL.lastPathComponent != ".voxnotch_checksums.json"
      else { continue }

      if let hash = sha256(of: fileURL) {
        let relativePath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
        manifest[relativePath] = hash
      }
    }
    return manifest
  }

  /// Save a checksum manifest alongside the model directory for future verification.
  func saveChecksumManifest(for version: FluidAudioModelVersion) {
    let cacheDir = modelDirectory(for: version)
    let manifest = buildManifest(for: cacheDir)
    guard !manifest.isEmpty else { return }

    let manifestURL = cacheDir.appendingPathComponent(".voxnotch_checksums.json")
    do {
      let data = try JSONEncoder().encode(manifest)
      try data.write(to: manifestURL, options: .atomic)
      logger.info("Saved checksum manifest for \(version.rawValue) (\(manifest.count) files)")
    } catch {
      logger.error("Failed to save checksum manifest for \(version.rawValue): \(error)")
    }
  }

  /// Verify a downloaded model's files against its saved checksum manifest.
  /// Returns true if no manifest exists (first download) or all checksums match.
  func verifyChecksumManifest(for version: FluidAudioModelVersion) -> Bool {
    let cacheDir = modelDirectory(for: version)
    let manifestURL = cacheDir.appendingPathComponent(".voxnotch_checksums.json")

    let data: Data
    do {
      data = try Data(contentsOf: manifestURL)
    } catch {
      return true // No manifest yet — trust first download
    }
    let savedManifest: [String: String]
    do {
      savedManifest = try JSONDecoder().decode([String: String].self, from: data)
    } catch {
      logger.error("Failed to decode checksum manifest for \(version.rawValue): \(error)")
      return false // Corrupted manifest — treat as verification failure
    }

    let currentManifest = buildManifest(for: cacheDir)

    for (path, expectedHash) in savedManifest {
      guard let actualHash = currentManifest[path] else {
        logger.error("Checksum verification failed: missing file \(path)")
        return false
      }
      if actualHash != expectedHash {
        logger.error("Checksum verification failed: \(path) hash mismatch")
        return false
      }
    }

    return true
  }

}

// MARK: - FluidAudio Errors

enum FluidAudioError: LocalizedError {
  case modelNotLoaded
  case modelDownloadFailed(String)
  case transcriptionFailed(String)
  case invalidAudioFormat

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded:
      return "Speech model not loaded"
    case .modelDownloadFailed(let message):
      return "Model download failed: \(message)"
    case .transcriptionFailed:
      return "Transcription failed"
    case .invalidAudioFormat:
      return "Audio format not supported"
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .modelNotLoaded:
      return "Open Settings → Speech Model to download"
    case .modelDownloadFailed:
      return "Check your connection and try again"
    case .transcriptionFailed:
      return "Try again — or switch models in Settings"
    case .invalidAudioFormat:
      return "Try recording again"
    }
  }
}
