import os
import XCTest
@testable import VoxNotch

@MainActor
final class AutoTriggerCoordinatorTests: XCTestCase {
  private final class DisabledHistory: AlwaysOnHistorySettingsProviding {
    let saveHistory = false
    let historyRetentionDays = 0
  }

  func testDisablingAutoAnswerCancelsPreviouslyScheduledSilenceAnswer() async throws {
    let state = AlwaysOnState.shared
    let settings = AssistantSettings.shared
    let previous = (settings.autoAnswer, settings.autoAnswerSilence)
    state.begin(sources: [.systemAudio])
    state.status = .running
    settings.autoAnswer = true
    settings.autoAnswerSilence = 0.05
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let assistant = AssistantService(historyStore: AlwaysOnHistoryStore(settings: DisabledHistory()), makeStream: { _, _ in
      calls.withLock { $0 += 1 }
      return AsyncThrowingStream { $0.finish() }
    })
    let coordinator = AutoTriggerCoordinator(assistant: assistant, settings: settings)
    defer {
      coordinator.reset()
      assistant.stop()
      state.end()
      settings.autoAnswer = previous.0
      settings.autoAnswerSilence = previous.1
    }

    // First prove that this configuration does fire when left enabled.
    coordinator.handle(statement(), accepted: true)
    let deadline = ContinuousClock.now + .seconds(2)
    while calls.withLock({ $0 }) == 0 {
      guard ContinuousClock.now < deadline else { return XCTFail("silence answer never fired") }
      try await Task.sleep(for: .milliseconds(5))
    }
    coordinator.reset()
    coordinator.handle(statement(), accepted: true)
    settings.autoAnswer = false
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(calls.withLock { $0 }, 1, "the pending timer must reread the disabled setting")
  }

  private func statement() -> TranscriptUpdate {
    TranscriptUpdate(
      utteranceID: UUID(), source: .systemAudio, text: "Let us discuss this.", isFinal: true,
      startedAt: Date(), endedAt: Date(), processingLatency: .zero, trailingSilence: .zero
    )
  }
}
