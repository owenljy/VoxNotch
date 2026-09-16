//
//  CustomSpeechModel.swift
//  VoxNotch
//
//  User-defined Hugging Face ASR models and unified model type
//

import Foundation
import os.log

// MARK: - Custom Speech Model

/// A user-defined MLX Audio ASR model from Hugging Face Hub
struct CustomSpeechModel: Codable, Identifiable, Hashable, Sendable {
  /// Stable UUID string
  let id: String
  /// User-provided display name (auto-derived from repo ID last segment if not given)
  var displayName: String
  /// HuggingFace repo ID, e.g. "mlx-community/my-finetuned-asr"
  let hfRepoID: String
  /// When the model was added
  var addedAt: Date
  /// True after a successful `GLMASRModel.fromPretrained` call; persisted across restarts
  var isDownloaded: Bool

  init(displayName: String, hfRepoID: String) {
    self.id = UUID().uuidString
    self.displayName = displayName
    self.hfRepoID = hfRepoID
    self.addedAt = Date()
    self.isDownloaded = false
  }

  func hash(into hasher: inout Hasher) { hasher.combine(id) }
  static func == (lhs: CustomSpeechModel, rhs: CustomSpeechModel) -> Bool { lhs.id == rhs.id }
}

// MARK: - Custom Model Registry

/// Observable registry of user-added custom HF ASR models persisted in UserDefaults
///
/// Thread Safety: `lock` (NSLock) protects all reads/writes to the `models` array.
@Observable
final class CustomModelRegistry: @unchecked Sendable {

  static let shared = CustomModelRegistry()

  private let logger = Logger(subsystem: "com.voxnotch", category: "CustomModelRegistry")
  private let defaultsKey = "customSpeechModels"
  private let lock = NSLock()

  private(set) var models: [CustomSpeechModel] = []

  private init() {
    load()
  }

  // MARK: - Public Methods

  /// Add a new custom model to the registry
  @discardableResult
  func add(repoID: String, displayName: String) -> CustomSpeechModel {
    let model = CustomSpeechModel(displayName: displayName, hfRepoID: repoID)
    lock.withLock { models.append(model) }
    save()
    return model
  }

  /// Remove a model by ID
  func remove(id: String) {
    lock.withLock { models.removeAll { $0.id == id } }
    save()
  }

  /// Look up a model by ID
  func model(withID id: String) -> CustomSpeechModel? {
    lock.withLock { models.first { $0.id == id } }
  }

  /// Mark a model as successfully downloaded (persists across restarts)
  func markDownloaded(id: String) {
    lock.withLock {
      guard let index = models.firstIndex(where: { $0.id == id }) else { return }
      models[index].isDownloaded = true
    }
    save()
  }

  /// Whether a model with the given repo ID already exists
  func contains(repoID: String) -> Bool {
    lock.withLock { models.contains { $0.hfRepoID == repoID } }
  }

  // MARK: - Persistence

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
    do {
      let decoded = try JSONDecoder().decode([CustomSpeechModel].self, from: data)
      // Drop Parakeet repos — they were added via the old HF browser path but
      // aren't MLX-compatible. Parakeet is handled by the built-in FluidAudio engine.
      let filtered = decoded.filter { !$0.hfRepoID.lowercased().contains("parakeet") }
      lock.withLock { models = filtered }
      if filtered.count != decoded.count {
        save()
      }
    } catch {
      logger.error("Failed to decode custom speech models from UserDefaults: \(error)")
    }
  }

  /// Persist current models to UserDefaults.
  /// Called outside the mutation lock — safe because we re-acquire the lock
  /// here to snapshot. Encoding + I/O must stay outside the lock to avoid
  /// blocking readers and to prevent NSLock deadlock (non-reentrant).
  private func save() {
    let snapshot = lock.withLock { models }
    do {
      let data = try JSONEncoder().encode(snapshot)
      UserDefaults.standard.set(data, forKey: defaultsKey)
    } catch {
      logger.error("Failed to encode custom speech models: \(error)")
    }
  }
}

// MARK: - AnyModel

/// Unified model wrapper covering both built-in and user-defined speech models.
/// Used in the quick-switch cycling UI and pinned model slots.
enum AnyModel: Identifiable, Hashable, Sendable {
  case builtin(SpeechModel)
  case custom(CustomSpeechModel)

  var id: String {
    switch self {
    case .builtin(let m): m.rawValue
    case .custom(let m): m.id
    }
  }

  var displayName: String {
    switch self {
    case .builtin(let m): m.displayName
    case .custom(let m): m.displayName
    }
  }

  /// True if model weights are present on disk and ready to use
  var isDownloaded: Bool {
    switch self {
    case .builtin(let m): m.isDownloaded
    case .custom(let m): MLXAudioModelManager.shared.isCustomModelOnDisk(m)
    }
  }

  var languageDescription: String {
    switch self {
    case .builtin(let m): m.languageDescription
    case .custom: "Custom"
    }
  }

  /// The raw string used to identify this model in settings storage
  var settingsID: String {
    switch self {
    case .builtin(let m): m.rawValue
    case .custom(let m): m.id
    }
  }
}
