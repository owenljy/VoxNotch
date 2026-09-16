//
//  MLXAudioModelManager.swift
//  VoxNotch
//
//  Manages MLX Audio ASR model downloads and lifecycle
//

import Foundation
import os.log

#if canImport(MLXAudioSTT)
import MLX
import MLXAudioSTT
#endif

// MARK: - MLX Model Loader Class

/// Which Swift class is responsible for loading a given MLX ASR model.
/// Add a new case here when a new model family is introduced.
enum MLXModelLoaderClass {
  case glmASR           // GLMASRModel.fromPretrained
  case qwen3ASR         // Qwen3ASRModel.fromPretrained
  case voxtralRealtime  // VoxtralRealtimeModel.fromPretrained
  case parakeet         // ParakeetModel.fromPretrained
}

// MARK: - MLX Audio Model Version

/// Available MLX Audio ASR model versions
enum MLXAudioModelVersion: String, CaseIterable, Identifiable, Sendable {
  case glmAsrNano = "mlx-community/GLM-ASR-Nano-2512-4bit"
  case qwen3Asr = "mlx-community/Qwen3-ASR-1.7B-bf16"
  case qwen3AsrSmall = "mlx-community/Qwen3-ASR-0.6B-4bit"
  case qwen3AsrQuantized = "mlx-community/Qwen3-ASR-1.7B-4bit"
  case voxtralMini = "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .glmAsrNano: "GLM-ASR-Nano (4-bit)"
    case .qwen3Asr: "Qwen3-ASR 1.7B (BF16)"
    case .qwen3AsrSmall: "Qwen3-ASR 0.6B (4-bit)"
    case .qwen3AsrQuantized: "Qwen3-ASR 1.7B (4-bit)"
    case .voxtralMini: "Voxtral Mini 4B (4-bit)"
    }
  }

  var estimatedSizeMB: Int {
    switch self {
    case .glmAsrNano: 400
    case .qwen3Asr: 3400
    case .qwen3AsrSmall: 713
    case .qwen3AsrQuantized: 1608
    case .voxtralMini: 3130
    }
  }

  var supportedLanguages: [String] {
    switch self {
    case .glmAsrNano, .qwen3Asr, .qwen3AsrSmall, .qwen3AsrQuantized:
      ["en", "zh", "ja", "ko", "es", "fr", "de", "it", "pt", "ru", "ar"]
    case .voxtralMini:
      ["en", "ar", "de", "es", "fr", "hi", "it", "ja", "ko", "nl", "pt", "ru", "zh"]
    }
  }

  /// Folder name used for local storage
  var folderName: String {
    switch self {
    case .glmAsrNano: "GLM-ASR-Nano-2512-4bit"
    case .qwen3Asr: "Qwen3-ASR-1.7B-bf16"
    case .qwen3AsrSmall: "Qwen3-ASR-0.6B-4bit"
    case .qwen3AsrQuantized: "Qwen3-ASR-1.7B-4bit"
    case .voxtralMini: "Voxtral-Mini-4B-Realtime-2602-4bit"
    }
  }

  /// Which Swift class should load this model version.
  /// Update this when adding new model variants.
  var loaderClass: MLXModelLoaderClass {
    switch self {
    case .glmAsrNano:   .glmASR
    case .qwen3Asr, .qwen3AsrSmall, .qwen3AsrQuantized: .qwen3ASR
    case .voxtralMini:  .voxtralRealtime
    }
  }
}



// MARK: - MLX Audio Model Manager

/// Manages MLX Audio model downloads and lifecycle
///
/// Thread Safety: uses dual protection —
/// • `lock` (NSLock) guards internal model references (`loadedModel`, `loadedVersion`,
///   `loadedCustomModelID`) read/written from async download tasks and background providers.
/// • UI-observable state (`modelStates`, `customModelStates`, `downloadProgress`,
///   `alignerModelState`) is written via `MainActor.run` from async methods;
///   `refreshAllModelStates()` and `delete*()` must be called from MainActor.
@Observable
final class MLXAudioModelManager: @unchecked Sendable {

  // MARK: - Singleton

  static let shared = MLXAudioModelManager()

  // MARK: - Properties

  private let logger = Logger(subsystem: "com.voxnotch", category: "MLXAudioModelManager")

  /// Current state of each built-in model version
  private(set) var modelStates: [MLXAudioModelVersion: ModelDownloadState] = [:]

  /// Current state of each custom model (keyed by CustomSpeechModel.id)
  private(set) var customModelStates: [String: ModelDownloadState] = [:]

  /// Currently loaded built-in model version (nil when a custom model is loaded)
  private(set) var loadedVersion: MLXAudioModelVersion?

  /// ID of the currently loaded custom model (nil when a built-in model is loaded)
  private(set) var loadedCustomModelID: String?

  /// Download progress (0.0 to 1.0)
  private(set) var downloadProgress: Double = 0

  /// Whether any model is ready (lock-protected — safe to call from any thread)
  var isReady: Bool {
    lock.withLock { loadedVersion != nil || loadedCustomModelID != nil }
  }

  @ObservationIgnored private var loadTasks: [MLXAudioModelVersion: Task<URL, Error>] = [:]
  @ObservationIgnored private var customLoadTasks: [String: Task<Void, Error>] = [:]

  /// Lock for thread safety
  private let lock = NSLock()

  #if canImport(MLXAudioSTT)
  /// The loaded ASR model (shared with MLXAudioProvider; holds both built-in and custom models).
  /// Typed as the protocol so GLMASRModel and Qwen3ASRModel can both be stored here.
  private var loadedModel: (any STTGenerationModel)?
  #endif

  /// Observable state for the Source Separation aligner model
  private(set) var alignerModelState: ModelDownloadState = .notDownloaded

  /// HuggingFace repo ID for the forced aligner model (not an ASR model)
  private static let alignerRepoID = "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"

  /// Base directory for MLX Audio models
  private var mlxModelsDirectory: URL {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!

    return appSupport
      .appendingPathComponent("VoxNotch", isDirectory: true)
      .appendingPathComponent("MLXModels", isDirectory: true)
  }

  // MARK: - Initialization

  private init() {
    for version in MLXAudioModelVersion.allCases {
      modelStates[version] = .notDownloaded
    }
    refreshAllModelStates()
  }

  // MARK: - Public Methods

  /// Download and load a model version
  /// - Parameter version: The model version to download and load
  @discardableResult
  func downloadAndLoad(version: MLXAudioModelVersion) async throws -> URL {
    let task = lock.withLock { () -> Task<URL, Error> in
      if let pending = loadTasks[version] { return pending }
      let pending = Task { [self] in
        defer { lock.withLock { loadTasks[version] = nil } }
        return try await performDownloadAndLoad(version: version)
      }
      loadTasks[version] = pending
      return pending
    }
    let result = try await task.value
    try Task.checkCancellation()
    return result
  }

  private func performDownloadAndLoad(version: MLXAudioModelVersion) async throws -> URL {
    let (currentState, currentVersion) = lock.withLock {
      (modelStates[version], loadedVersion)
    }

    /// Already ready, return cached path
    if currentState == .ready, currentVersion == version {
      return modelDirectory(for: version)
    }

    /// Already downloading, wait with timeout
    if case .downloading = currentState {
      logger.info("Model \(version.rawValue) already downloading, waiting...")
      let deadline = Date().addingTimeInterval(300) // 5-minute timeout
      while Date() < deadline {
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms
        let state = lock.withLock { modelStates[version] }
        if case .ready = state {
          return modelDirectory(for: version)
        }
        if case .failed(let message) = state {
          throw MLXAudioError.modelDownloadFailed(message)
        }
      }
      throw MLXAudioError.modelDownloadFailed("Download timed out after 5 minutes")
    }

    /// Start download
    await MainActor.run {
      modelStates[version] = .downloading(progress: 0, downloadedBytes: 0, totalBytes: Int64(version.estimatedSizeMB) * 1_000_000, speedBytesPerSecond: 0)
      downloadProgress = 0
    }

    logger.info("Starting download for MLX Audio model: \(version.rawValue)")

    do {
      #if canImport(MLXAudioSTT)
      let cacheURL = mlxAudioCacheURL(for: version)
      let expectedBytes = Int64(version.estimatedSizeMB) * 1_000_000
      let pollingTask = DownloadProgressTracker.poll(
        directory: cacheURL,
        expectedBytes: expectedBytes
      ) { [weak self] progress, downloadedBytes, totalBytes, speed in
        guard let self else { return }
        if case .downloading = self.modelStates[version] {
          self.modelStates[version] = .downloading(
            progress: progress, downloadedBytes: downloadedBytes,
            totalBytes: totalBytes, speedBytesPerSecond: speed
          )
          self.downloadProgress = progress
        }
      }
      defer { pollingTask.cancel() }

      /// Download and load the model using the correct class for each version.
      /// Dispatch is driven by `version.loaderClass` so adding a new model variant only
      /// requires updating the `loaderClass` property — no changes needed here.
      // NOTE: Upstream bug in mlx-audio-swift (GLMASR.swift line 661): GLMASRModel calls
      // model.update(verify: .all) even when config.useRope=true, causing a crash when
      // embed_positions.weight is absent in newer GLM-ASR checkpoints. Track the upstream
      // fix at https://github.com/Blaizzy/mlx-audio-swift.
      try await HFModelDownload.ensureCached(repoID: version.rawValue, directory: cacheURL)
      let loaded: any STTGenerationModel
      switch version.loaderClass {
      case .glmASR:
        loaded = try await GLMASRModel.fromPretrained(version.rawValue)
      case .qwen3ASR:
        // Qwen3ASRModel.fromPretrained calls generateTokenizerJSONIfMissing() internally.
        loaded = try await Qwen3ASRModel.fromPretrained(version.rawValue)
      case .voxtralRealtime:
        loaded = try await VoxtralRealtimeModel.fromPretrained(version.rawValue)
      case .parakeet:
        loaded = try await ParakeetModel.fromPretrained(version.rawValue)
      }
      guard ModelCacheValidation.isComplete(cacheURL) else {
        throw MLXAudioError.modelDownloadFailed("Model download is incomplete; delete it and retry")
      }
      try await warmupInference(loaded)
      lock.withLock {
        if let previous = loadedVersion, previous != version { modelStates[previous] = .downloaded }
        if let previous = loadedCustomModelID { customModelStates[previous] = .downloaded }
        loadedModel = loaded
        loadedVersion = version
        loadedCustomModelID = nil
      }
      await MainActor.run {
        modelStates[version] = .ready
        downloadProgress = 1.0
      }

      logger.info("MLX Audio model \(version.rawValue) downloaded and loaded successfully")
      return modelDirectory(for: version)
      #else
      throw MLXAudioError.modelDownloadFailed("MLXAudioSTT not available")
      #endif

    } catch {
      let errorMessage = error.localizedDescription
      await MainActor.run {
        modelStates[version] = .failed(message: errorMessage)
      }
      logger.error("Failed to download MLX Audio model: \(errorMessage)")
      throw MLXAudioError.modelDownloadFailed(errorMessage)
    }
  }

  /// Get the model directory for a version
  func modelDirectory(for version: MLXAudioModelVersion) -> URL {
    mlxAudioCacheURL(for: version)
  }

  /// Check if a specific version is downloaded/loaded (memory or disk)
  func isVersionDownloaded(_ version: MLXAudioModelVersion) -> Bool {
    lock.lock()
    let inMemory = loadedVersion == version
    lock.unlock()
    return inMemory || isVersionOnDisk(version)
  }

  /// Check if a specific version is ready
  func isVersionReady(_ version: MLXAudioModelVersion) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return loadedVersion == version && (modelStates[version]?.isReady ?? false)
  }

  #if canImport(MLXAudioSTT)
  /// Get the loaded ASR model (for use by MLXAudioProvider).
  /// Returns whichever model class is currently in memory (GLMASRModel or Qwen3ASRModel).
  func getLoadedModel() -> (any STTGenerationModel)? {
    lock.lock()
    defer { lock.unlock() }
    return loadedModel
  }
  #endif

  /// Unload current model to free memory
  func unloadModel() {
    lock.lock()
    #if canImport(MLXAudioSTT)
    loadedModel = nil
    #endif
    if let version = loadedVersion {
      loadedVersion = nil
      let customID = loadedCustomModelID
      loadedCustomModelID = nil
      lock.unlock()
      Task { @MainActor in
        modelStates[version] = .downloaded
        if let customID {
          customModelStates[customID] = .downloaded
        }
      }
    } else if let customID = loadedCustomModelID {
      loadedCustomModelID = nil
      lock.unlock()
      Task { @MainActor in
        customModelStates[customID] = .downloaded
      }
    } else {
      lock.unlock()
    }
    logger.info("Unloaded MLX Audio model")
  }

  // MARK: - Custom Model Support

  /// Download and load a user-defined HuggingFace ASR model.
  /// Uses HF Hub cache so repeated calls after first download are fast.
  func downloadAndLoadCustom(model: CustomSpeechModel) async throws {
    let task = lock.withLock { () -> Task<Void, Error> in
      if let pending = customLoadTasks[model.id] { return pending }
      let pending = Task { [self] in
        defer { lock.withLock { customLoadTasks[model.id] = nil } }
        try await performDownloadAndLoadCustom(model: model)
      }
      customLoadTasks[model.id] = pending
      return pending
    }
    try await task.value
    try Task.checkCancellation()
  }

  private func performDownloadAndLoadCustom(model: CustomSpeechModel) async throws {
    let id = model.id

    let alreadyLoaded = lock.withLock { loadedCustomModelID == id }

    guard !alreadyLoaded else { return }

    await MainActor.run {
      customModelStates[id] = .downloading(progress: 0, downloadedBytes: 0, totalBytes: 3_400_000_000, speedBytesPerSecond: 0)
    }

    logger.info("Loading custom MLX Audio model: \(model.hfRepoID)")

    do {
      #if canImport(MLXAudioSTT)
      let cacheURL = mlxAudioCacheURL(repoID: model.hfRepoID)
      let expectedBytes: Int64 = 3_400_000_000
      let pollingTask = DownloadProgressTracker.poll(
        directory: cacheURL,
        expectedBytes: expectedBytes
      ) { [weak self] progress, downloadedBytes, totalBytes, speed in
        guard let self else { return }
        if case .downloading = self.customModelStates[id] {
          self.customModelStates[id] = .downloading(
            progress: progress, downloadedBytes: downloadedBytes,
            totalBytes: totalBytes, speedBytesPerSecond: speed
          )
        }
      }
      defer { pollingTask.cancel() }

      let loaderClass = try await inferLoaderClass(hfRepoID: model.hfRepoID)
      try await HFModelDownload.ensureCached(repoID: model.hfRepoID, directory: cacheURL)
      let loaded: any STTGenerationModel
      switch loaderClass {
      case .glmASR:
        loaded = try await GLMASRModel.fromPretrained(model.hfRepoID)
      case .qwen3ASR:
        loaded = try await Qwen3ASRModel.fromPretrained(model.hfRepoID)
      case .voxtralRealtime:
        loaded = try await VoxtralRealtimeModel.fromPretrained(model.hfRepoID)
      case .parakeet:
        loaded = try await ParakeetModel.fromPretrained(model.hfRepoID)
      }
      guard ModelCacheValidation.isComplete(cacheURL) else {
        throw MLXAudioError.modelDownloadFailed("Model download is incomplete; delete it and retry")
      }
      try await warmupInference(loaded)

      lock.withLock {
        if let previous = loadedVersion { modelStates[previous] = .downloaded }
        if let previous = loadedCustomModelID, previous != id { customModelStates[previous] = .downloaded }
        loadedModel = loaded
        loadedVersion = nil
        loadedCustomModelID = id
      }

      await MainActor.run {
        customModelStates[id] = .ready
      }

      // Persist download status in registry so it survives restarts
      await MainActor.run {
        CustomModelRegistry.shared.markDownloaded(id: id)
      }

      logger.info("Custom model loaded successfully: \(model.hfRepoID)")
      #else
      throw MLXAudioError.modelDownloadFailed("MLXAudioSTT not available in this build")
      #endif

    } catch {
      let msg = error.localizedDescription
      await MainActor.run {
        customModelStates[id] = .failed(message: msg)
      }
      logger.error("Failed to load custom model \(model.hfRepoID): \(msg)")
      throw MLXAudioError.modelDownloadFailed(msg)
    }
  }

  /// Whether a custom model is loaded in memory and ready
  func isCustomModelReady(id: String) -> Bool {
    lock.withLock { loadedCustomModelID == id }
  }

  /// Unload a specific custom model from memory (keeps HF cache)
  func unloadCustomModel(id: String) {
    lock.withLock {
      if loadedCustomModelID == id {
        loadedCustomModelID = nil
        #if canImport(MLXAudioSTT)
        loadedModel = nil
        #endif
      }
    }

    Task { @MainActor in
      customModelStates[id] = .downloaded
    }
  }

  func isCustomModelOnDisk(_ model: CustomSpeechModel) -> Bool {
    ModelCacheValidation.isComplete(mlxAudioCacheURL(repoID: model.hfRepoID))
  }

  /// Preserve caches shared with built-in models or another saved import.
  func deleteCustomModel(_ model: CustomSpeechModel) throws {
    guard !lock.withLock({ customLoadTasks[model.id] != nil }) else {
      throw MLXAudioError.modelDownloadFailed("Wait for the model download to finish before removing it.")
    }
    let sharedCache = MLXAudioModelVersion.allCases.contains { $0.rawValue == model.hfRepoID }
      || CustomModelRegistry.shared.models.contains { $0.id != model.id && $0.hfRepoID == model.hfRepoID }
    let cacheURL = mlxAudioCacheURL(repoID: model.hfRepoID)
    if !sharedCache && FileManager.default.fileExists(atPath: cacheURL.path) {
      try FileManager.default.removeItem(at: cacheURL)
    }
    lock.withLock {
      if loadedCustomModelID == model.id {
        loadedCustomModelID = nil
        #if canImport(MLXAudioSTT)
        loadedModel = nil
        #endif
      }
    }
    customModelStates.removeValue(forKey: model.id)
    CustomModelRegistry.shared.remove(id: model.id)
    logger.info("Deleted custom model: \(model.hfRepoID)")
  }

  // MARK: - Metal Warmup

  #if canImport(MLXAudioSTT)
  /// Runs a silent inference to force Metal kernel compilation before the user
  /// starts dictating. Discards the output. Takes ~2–6 s on first run;
  /// subsequent calls return immediately because Metal caches pipelines.
  private func warmupInference(_ model: any STTGenerationModel) async throws {
    let handle = ASRModelHandle(model: model)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      ASRInference.queue.async {
        _ = handle.model.generate(audio: MLXArray(Array(repeating: Float.zero, count: 1600)))
        continuation.resume()
      }
    }
    logger.info("MLX Audio Metal warmup complete")
  }
  #endif

  // MARK: - Model State Refresh

  /// Refresh model states by checking both in-memory and on-disk presence.
  /// Must be called from MainActor (writes UI-observable `modelStates` and `alignerModelState`).
  func refreshAllModelStates() {
    let currentLoadedVersion = lock.withLock { loadedVersion }

    for version in MLXAudioModelVersion.allCases {
      /// Skip if currently downloading
      if modelStates[version]?.isDownloading == true {
        continue
      }

      if currentLoadedVersion == version {
        modelStates[version] = .ready
      } else if isVersionOnDisk(version) {
        modelStates[version] = .downloaded
      } else {
        modelStates[version] = .notDownloaded
      }
    }

    for model in CustomModelRegistry.shared.models {
      if lock.withLock({ customLoadTasks[model.id] != nil }) { continue }
      if isCustomModelReady(id: model.id) {
        customModelStates[model.id] = .ready
      } else {
        customModelStates[model.id] = isCustomModelOnDisk(model) ? .downloaded : .notDownloaded
      }
    }

    // Refresh aligner model state (skip if currently downloading)
    if !alignerModelState.isDownloading {
      alignerModelState = alignerModelExists() ? .downloaded : .notDownloaded
    }
  }

  // MARK: - Delete Methods

  /// Delete model files for a version from the actual MLX Audio cache.
  /// Must be called from MainActor (writes UI-observable `modelStates`).
  func deleteModel(version: MLXAudioModelVersion) throws {
    // Atomically check and unload if currently loaded
    lock.withLock {
      if loadedVersion == version {
        #if canImport(MLXAudioSTT)
        loadedModel = nil
        #endif
        loadedVersion = nil
      }
    }

    let cacheDir = mlxAudioCacheURL(for: version)
    if FileManager.default.fileExists(atPath: cacheDir.path) {
      try FileManager.default.removeItem(at: cacheDir)
    }

    modelStates[version] = .notDownloaded
    logger.info("Deleted MLX Audio model: \(version.rawValue)")
  }

  /// Delete all downloaded MLX Audio models
  func deleteAllModels() throws {
    var errors: [String] = []
    for version in MLXAudioModelVersion.allCases {
      do {
        try deleteModel(version: version)
      } catch {
        errors.append("\(version.rawValue): \(error.localizedDescription)")
      }
    }
    if !errors.isEmpty {
      logger.error("Some models failed to delete: \(errors.joined(separator: "; "))")
    }
    logger.info("Deleted all MLX Audio models")
  }

  /// Calculate total storage used by all downloaded models (uses actual MLX cache path)
  func totalStorageUsedBytes() -> Int64 {
    var total: Int64 = 0
    for version in MLXAudioModelVersion.allCases {
      total += DownloadProgressTracker.directorySize(at: mlxAudioCacheURL(for: version))
    }
    return total
  }

  /// Resolve architecture before downloading weights. Never guess a GLM loader.
  func inferLoaderClass(hfRepoID: String) async throws -> MLXModelLoaderClass {
    let configURL = mlxAudioCacheURL(repoID: hfRepoID).appendingPathComponent("config.json")
    let data: Data
    if let cached = try? Data(contentsOf: configURL) {
      data = cached
    } else {
      let parts = hfRepoID.split(separator: "/")
      guard parts.count == 2, parts.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }),
            let url = URL(string: "https://huggingface.co/\(hfRepoID)/resolve/main/config.json") else {
        throw MLXAudioError.modelDownloadFailed("Invalid Hugging Face model ID")
      }
      var request = URLRequest(url: url)
      request.timeoutInterval = 30
      HFModelDownload.authorize(&request)
      let (remote, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw MLXAudioError.modelDownloadFailed("Could not fetch model config.json")
      }
      data = remote
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw MLXAudioError.modelDownloadFailed("Invalid model config.json")
    }
    switch json["model_type"] as? String {
    case "qwen3_asr": return .qwen3ASR
    case "voxtral_realtime": return .voxtralRealtime
    case "glmasr", "glm_asr": return .glmASR
    default:
      if json["joint"] != nil && json["encoder"] != nil { return .parakeet }
      throw MLXAudioError.modelDownloadFailed("Unsupported ASR architecture: \(json["model_type"] as? String ?? "unknown")")
    }
  }

  /// Actual MLX Audio cache directory for a given model version.
  /// GLMASRModel stores downloads at ~/.cache/huggingface/hub/mlx-audio/{org}_{model}/
  private func mlxAudioCacheURL(for version: MLXAudioModelVersion) -> URL {
    mlxAudioCacheURL(repoID: version.rawValue)
  }

  private func mlxAudioCacheURL(repoID: String) -> URL {
    let repoFolder = repoID.replacingOccurrences(of: "/", with: "_")
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cache/huggingface/hub/mlx-audio")
      .appendingPathComponent(repoFolder)
  }

  /// Returns true if the model's cache directory exists and is non-empty on disk.
  private func isVersionOnDisk(_ version: MLXAudioModelVersion) -> Bool {
    ModelCacheValidation.isComplete(mlxAudioCacheURL(for: version))
  }

  // MARK: - Source Separation Aligner

  /// Returns true if the forced aligner model's HF cache directory exists and is non-empty.
  func alignerModelExists() -> Bool {
    ModelCacheValidation.isComplete(mlxAudioCacheURL(repoID: Self.alignerRepoID))
  }

  /// Delete the forced aligner model from disk and reset state.
  func deleteAlignerModel() {
    let url = mlxAudioCacheURL(repoID: Self.alignerRepoID)
    try? FileManager.default.removeItem(at: url)
    alignerModelState = .notDownloaded
  }

  /// Download the Source Separation aligner model from HuggingFace Hub.
  /// `Qwen3ForcedAlignerModel.fromPretrained` handles caching automatically;
  /// subsequent calls return immediately if the model is already cached.
  func downloadAlignerModel() async throws {
    await MainActor.run {
      alignerModelState = .downloading(
        progress: 0,
        downloadedBytes: 0,
        totalBytes: 350_000_000,
        speedBytesPerSecond: 0
      )
    }

    #if canImport(MLXAudioSTT)
    do {
      let cacheURL = mlxAudioCacheURL(repoID: Self.alignerRepoID)
      let expectedBytes: Int64 = 350_000_000
      let pollingTask = DownloadProgressTracker.poll(
        directory: cacheURL,
        expectedBytes: expectedBytes
      ) { [weak self] progress, downloadedBytes, totalBytes, speed in
        guard let self else { return }
        if case .downloading = self.alignerModelState {
          self.alignerModelState = .downloading(
            progress: progress, downloadedBytes: downloadedBytes,
            totalBytes: totalBytes, speedBytesPerSecond: speed
          )
        }
      }
      defer { pollingTask.cancel() }

      try await HFModelDownload.ensureCached(repoID: Self.alignerRepoID, directory: cacheURL)
      _ = try await Qwen3ForcedAlignerModel.fromPretrained(Self.alignerRepoID)

      await MainActor.run { alignerModelState = .downloaded }
      logger.info("Source Separation aligner model downloaded successfully")

    } catch {
      let msg = error.localizedDescription
      await MainActor.run { alignerModelState = .failed(message: msg) }
      logger.error("Failed to download aligner model: \(msg)")
      throw MLXAudioError.modelDownloadFailed(msg)
    }
    #else
    await MainActor.run { alignerModelState = .failed(message: "MLXAudioSTT not available") }
    throw MLXAudioError.modelDownloadFailed("MLXAudioSTT not available")
    #endif
  }

}

// MARK: - MLX Audio Errors

enum MLXAudioError: LocalizedError {
  case modelNotLoaded
  case modelDownloadFailed(String)
  case transcriptionFailed(String)
  case invalidAudioFormat
  case audioLoadFailed(String)

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
    case .audioLoadFailed:
      return "Could not read audio file"
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
    case .invalidAudioFormat, .audioLoadFailed:
      return "Try recording again"
    }
  }
}

