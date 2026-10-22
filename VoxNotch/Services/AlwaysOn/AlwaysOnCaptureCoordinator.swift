import Foundation

/// Serializes starts for each device. A cancelled start may still be inside a
/// system permission prompt; its cleanup must finish before a replacement starts.
@MainActor
final class AlwaysOnCaptureCoordinator {
  private var tasks: [AudioSource: Task<Void, Error>] = [:]
  private(set) var generations: [AudioSource: Int] = [:]
  private let stopCapture: (AudioSource) -> Void

  init(stopCapture: @escaping (AudioSource) -> Void) {
    self.stopCapture = stopCapture
  }

  func start(_ source: AudioSource, operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
    let previous = tasks[source]
    stop(source)
    let task = Task {
      _ = await previous?.result
      try Task.checkCancellation()
      do {
        try await operation()
        try Task.checkCancellation()
      } catch {
        stopCapture(source)
        if Task.isCancelled { throw CancellationError() }
        throw error
      }
    }
    tasks[source] = task
    return task
  }

  func stop(_ source: AudioSource) {
    generations[source, default: 0] += 1
    tasks[source]?.cancel()
    stopCapture(source)
  }

  func stopAll() {
    AudioSource.allCases.forEach(stop)
  }
}
