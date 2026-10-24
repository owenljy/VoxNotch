import Foundation
import os

/// A deadline for visible answer text, including connection setup and hidden
/// reasoning. Each attempt owns its stream; cancelling it cancels transport too.
nonisolated enum FirstTokenRetryStream {
  typealias Factory = @Sendable ([ChatMessage], OpenAICompatibleConfig) -> AsyncThrowingStream<String, Error>
  typealias Sleep = @Sendable (Duration) async throws -> Void

  struct TimedOut: LocalizedError {
    let timeout: Duration
    var errorDescription: String? {
      "No answer text before the first-token deadline on either attempt. Try another model or increase First token timeout in AI Provider settings."
    }
  }

  private enum FirstTextState { case waiting, started, expired }

  static func stream(
    messages: [ChatMessage], primary: OpenAICompatibleConfig, retry: OpenAICompatibleConfig,
    timeout: Duration, makeStream: @escaping Factory,
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
    onRetry: @escaping @Sendable (OpenAICompatibleConfig) async -> Void = { _ in }
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for attempt in 0...1 {
            try Task.checkCancellation()
            let config = attempt == 0 ? primary : retry
            if attempt == 1 {
              await onRetry(config)
              try Task.checkCancellation()
            }
            do {
              try await consume(
                messages: messages, config: config, timeout: timeout,
                makeStream: makeStream, sleep: sleep, yield: { continuation.yield($0) })
              continuation.finish()
              return
            } catch is TimedOut where attempt == 0 {
              // Only a missing first visible token triggers the one retry.
              continue
            }
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func consume(
    messages: [ChatMessage], config: OpenAICompatibleConfig, timeout: Duration,
    makeStream: @escaping Factory, sleep: @escaping Sleep,
    yield: @escaping @Sendable (String) -> Void
  ) async throws {
    let state = OSAllocatedUnfairLock(initialState: FirstTextState.waiting)
    try await withThrowingTaskGroup(of: Bool.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        var leadingWhitespace = ""
        var started = false
        for try await delta in makeStream(messages, config) {
          try Task.checkCancellation()
          guard !delta.isEmpty else { continue }
          if !started {
            if delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              leadingWhitespace += delta
              continue
            }
            let accepted = state.withLock { value in
              guard value != .expired else { return false }
              value = .started
              return true
            }
            guard accepted else { throw TimedOut(timeout: timeout) }
            started = true
            yield(leadingWhitespace + delta)
            leadingWhitespace = ""
          } else {
            yield(delta)
          }
        }
        try Task.checkCancellation()
        return true
      }
      group.addTask {
        try await sleep(timeout)
        try Task.checkCancellation()
        let expired = state.withLock { value in
          guard value == .waiting else { return false }
          value = .expired
          return true
        }
        if expired { throw TimedOut(timeout: timeout) }
        return false
      }
      // The timer finishing after a first token must not truncate the answer.
      while let streamFinished = try await group.next() {
        if streamFinished { return }
      }
    }
  }
}
