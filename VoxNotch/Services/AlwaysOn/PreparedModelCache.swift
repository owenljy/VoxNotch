import Foundation

nonisolated enum ModelPreparationStatus: Equatable {
  case idle, preparing, ready, failed(String)
}

nonisolated enum ModelPreparationError: LocalizedError {
  case released
  var errorDescription: String? {
    "Transcription preparation was released to free memory. Try starting Always-On again."
  }
}

/// Launch preloading and an immediate Start share one task and one set of
/// warmed models. Cancelling a waiter doesn't cancel preparation for others.
@MainActor @Observable
final class PreparedModelCache<Models: Sendable> {
  private(set) var status: ModelPreparationStatus = .idle
  @ObservationIgnored private var cached: Models?
  @ObservationIgnored private var pending: Task<Models, Error>?
  @ObservationIgnored private var generation = UUID()
  private let load: @Sendable () async throws -> Models

  init(load: @escaping @Sendable () async throws -> Models) {
    self.load = load
  }

  // Swift 6.3.3 crashes in EarlyPerfInliner while optimizing the synthesized
  // generic deallocator during Release archives. Keep only destruction unoptimized.
  @_optimize(none)
  deinit {}

  func preload() {
    guard cached == nil, pending == nil else { return }
    let request = startLoad()
    Task { _ = try? await resolve(request) }
  }

  func models() async throws -> Models {
    try Task.checkCancellation()
    if let cached { return cached }
    let request = startLoad()
    let value = try await resolve(request)
    try Task.checkCancellation()
    return value
  }

  /// Existing sessions retain their own model references. This releases only
  /// the idle cache and prevents a late load from repopulating it after pressure.
  func release() {
    generation = UUID()
    pending?.cancel()
    pending = nil
    cached = nil
    status = .idle
  }

  private func startLoad() -> (id: UUID, task: Task<Models, Error>) {
    if let pending { return (generation, pending) }
    generation = UUID()
    status = .preparing
    let task = Task<Models, Error>.detached(priority: .utility) { [load] in try await load() }
    pending = task
    return (generation, task)
  }

  private func resolve(_ request: (id: UUID, task: Task<Models, Error>)) async throws -> Models {
    let value: Models
    do {
      value = try await request.task.value
    } catch {
      guard generation == request.id else { throw ModelPreparationError.released }
      pending = nil
      status = error is CancellationError ? .idle : .failed(error.localizedDescription)
      throw error
    }
    guard generation == request.id else { throw ModelPreparationError.released }
    cached = value
    pending = nil
    status = .ready
    return value
  }
}
