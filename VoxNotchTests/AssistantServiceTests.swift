//
//  AssistantServiceTests.swift
//  VoxNotchTests
//

import XCTest
import GRDB
@testable import VoxNotch

@MainActor
final class AssistantServiceTests: XCTestCase {

  private final class HistorySettings: AlwaysOnHistorySettingsProviding {
    let saveHistory = true
    let historyRetentionDays = 0
  }

  private var state: AlwaysOnState!
  private var settings: AssistantSettings!

  override func setUp() async throws {
    settings = AssistantSettings(readAPIKey: { _ in .value("test-key") })
    state = AlwaysOnState.shared
    state.begin(sources: [.microphone, .systemAudio])
  }

  override func tearDown() async throws {
    state.end()
  }

  private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: Duration = .seconds(2)) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
      guard clock.now < deadline else { return XCTFail("timed out") }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  func testStreamsDeltasIntoAnswer() async throws {
    let service = AssistantService(settings: settings, makeStream: { _, _ in
      AsyncThrowingStream { continuation in
        Task {
          for delta in ["**Short", " answer**", "\n\n- point"] {
            continuation.yield(delta)
            try? await Task.sleep(for: .milliseconds(10))
          }
          continuation.finish()
        }
      }
    })
    service.ask(trigger: .manual)
    XCTAssertEqual(state.answers.count, 1)
    XCTAssertEqual(state.answers[0].status, .waiting)

    try await waitUntil { self.state.answers.first?.status == .done }
    XCTAssertEqual(state.answers[0].markdown, "**Short answer**\n\n- point")
    XCTAssertNotNil(state.answers[0].firstTokenLatency)
    XCTAssertFalse(service.isAnswering)
  }

  func testFailureKeepsPartialTextAndMessage() async throws {
    let service = AssistantService(settings: settings, makeStream: { _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield("Partial")
        continuation.finish(throwing: LLMError.apiError("401: bad key"))
      }
    })
    service.ask(trigger: .auto)
    try await waitUntil { if case .failed = self.state.answers.first?.status { true } else { false } }
    XCTAssertEqual(state.answers[0].markdown, "Partial")
    XCTAssertEqual(state.answers[0].status, .failed("401: bad key"))
    XCTAssertEqual(state.answers[0].trigger, .auto)
  }

  func testKeychainApprovalFailureDoesNotStartProviderOrPrompt() {
    let denied = AssistantSettings(readAPIKey: { interactive in
      XCTAssertFalse(interactive, "Asking must only perform silent Keychain reads")
      return .needsApproval
    })
    let service = AssistantService(settings: denied, makeStream: { _, _ in
      XCTFail("A request must not start while the saved API key needs approval")
      return AsyncThrowingStream { $0.finish() }
    })
    XCTAssertNil(service.ask(trigger: .auto))
    XCTAssertFalse(service.isAnswering)
    guard case .failed(let message) = state.answers.last?.status else {
      return XCTFail("Expected an actionable permission failure")
    }
    XCTAssertTrue(message.contains("approval"))
  }

  func testNewAskStopsPreviousAnswer() async throws {
    let service = AssistantService(settings: settings, makeStream: { _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield("first")
        // never finishes on its own
        continuation.onTermination = { _ in }
      }
    })
    service.ask(trigger: .manual)
    try await waitUntil { self.state.answers.first?.status == .streaming }
    service.ask(trigger: .manual)

    XCTAssertEqual(state.answers.count, 2)
    XCTAssertEqual(state.answers[0].status, .stopped)
    XCTAssertTrue(state.answers[1].isInProgress)
    service.stop()
    XCTAssertEqual(state.answers[1].status, .stopped)
  }

  func testPagerFollowsLatestUntilPinned() {
    for _ in 0..<3 {
      state.appendAnswer(AssistantAnswer(id: UUID(), createdAt: Date(), trigger: .manual, model: "m"))
    }
    XCTAssertEqual(state.displayedAnswerIndex, 2)
    state.showAnswer(offset: -1)
    XCTAssertEqual(state.displayedAnswerIndex, 1)
    state.showAnswer(offset: -5)
    XCTAssertEqual(state.displayedAnswerIndex, 0)
    state.showAnswer(offset: 10)
    XCTAssertEqual(state.displayedAnswerIndex, 2)
    XCTAssertNil(state.selectedAnswerID, "returning to the last answer resumes following")
  }

  func testPagerShortcutsNavigateHistoryOnlyWhileActive() throws {
    for _ in 0..<2 {
      state.appendAnswer(AssistantAnswer(id: UUID(), createdAt: Date(), trigger: .manual, model: "m"))
    }
    AlwaysOnShortcuts.install()
    let previous = try XCTUnwrap(HotkeyManager.shared.shortcuts.first { $0.shortcut == .defaultPreviousAnswer })
    let next = try XCTUnwrap(HotkeyManager.shared.shortcuts.first { $0.shortcut == .defaultNextAnswer })

    XCTAssertTrue(previous.handler(), "consumes the shortcut while Always-On is running")
    XCTAssertEqual(state.displayedAnswerIndex, 0)
    XCTAssertTrue(next.handler())
    XCTAssertEqual(state.displayedAnswerIndex, 1)

    state.end()
    XCTAssertFalse(previous.handler(), "lets the key reach other apps once Always-On stops")
  }

  func testDiscardRemovesCompletedSpeculativeAnswerFromHistory() async throws {
    let queue = try DatabaseQueue()
    try DatabaseManager.makeMigrator().migrate(queue)
    let history = AlwaysOnHistoryStore(databaseManager: queue, settings: HistorySettings())
    let service = AssistantService(settings: settings, historyStore: history, makeStream: { _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield("speculative")
        continuation.finish()
      }
    })
    let id = try XCTUnwrap(service.ask(trigger: .auto))
    try await waitUntil { !service.isAnswering }
    let saved = try await history.answers(for: state.sessionID)
    XCTAssertEqual(saved.count, 1)
    service.discard(id)
    let remaining = try await history.answers(for: state.sessionID)
    XCTAssertTrue(remaining.isEmpty)
    XCTAssertTrue(state.answers.isEmpty)
  }

  func testStoppedAnswerCannotReappearInDeletedHistory() async throws {
    let queue = try DatabaseQueue()
    try DatabaseManager.makeMigrator().migrate(queue)
    let history = AlwaysOnHistoryStore(databaseManager: queue, settings: HistorySettings())
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let service = AssistantService(settings: settings, historyStore: history, makeStream: { _, _ in stream })
    service.ask(trigger: .manual)
    continuation.yield("partial")
    try await waitUntil { self.state.answers.first?.status == .streaming }
    let sessionID = state.sessionID
    service.stop()
    try await history.deleteSession(id: sessionID)
    continuation.finish()
    await Task.yield()
    let sessions = try await history.sessions()
    XCTAssertTrue(sessions.isEmpty)
    XCTAssertEqual(state.answers.first?.markdown, "partial", "stop flushes the buffered last token")
  }

  func testNewSessionDropsOldAnswerAndReleasesRequestOwnership() async throws {
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let service = AssistantService(settings: settings, makeStream: { _, _ in stream })
    service.ask(trigger: .manual)
    state.begin(sources: [.microphone])
    continuation.yield("old session")
    continuation.finish()
    try await waitUntil { !service.isAnswering }
    XCTAssertTrue(state.answers.isEmpty)
    XCTAssertNil(service.currentAnswerID)
  }

  func testTimeoutRetriesSameAnswerAndRecordsTheActualFallbackModel() async throws {
    let clock = ManualFirstTokenDeadline()
    let harness = FirstTokenStreamHarness()
    let settings = self.settings!
    let previous = settings.fallbackModel
    settings.fallbackModel = "fallback-test"
    defer { settings.fallbackModel = previous }
    let queue = try DatabaseQueue()
    try DatabaseManager.makeMigrator().migrate(queue)
    let history = AlwaysOnHistoryStore(databaseManager: queue, settings: HistorySettings())
    let service = AssistantService(settings: settings,
      historyStore: history, makeStream: { harness.stream($0, $1) },
      deadlineSleep: { try await clock.sleep($0) })
    defer { service.stop() }
    let id = try XCTUnwrap(service.ask(trigger: .manual))
    while await clock.pendingCount == 0 { await Task.yield() }
    await clock.fire()
    try await waitUntil { harness.count == 2 && self.state.answers[0].retryCount == 1 }
    XCTAssertEqual(state.answers.count, 1, "Retry must keep the same history page")
    XCTAssertEqual(state.answers[0].id, id)
    XCTAssertEqual(state.answers[0].model, "fallback-test")
    XCTAssertTrue(harness.isTerminated(0))
    harness.yield("Recovered", attempt: 1)
    harness.finish(attempt: 1)
    try await waitUntil { !service.isAnswering }
    XCTAssertEqual(state.answers[0].markdown, "Recovered")
    XCTAssertEqual(state.answers[0].status, .done)
    let saved = try await history.answers(for: state.sessionID)
    XCTAssertEqual(saved.first?.model, "fallback-test")
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(MobileCompanionSnapshot(state: state).answers.first?.retryCount, 1)
  }

  func testDiscardBeforeFirstTokenCancelsRequestWithoutRetryOrHistoryResurrection() async throws {
    let clock = ManualFirstTokenDeadline()
    let harness = FirstTokenStreamHarness()
    let service = AssistantService(settings: settings,
      makeStream: { harness.stream($0, $1) }, deadlineSleep: { try await clock.sleep($0) })
    defer { service.stop() }
    let id = try XCTUnwrap(service.ask(trigger: .auto))
    try await waitUntil { harness.count == 1 }
    service.discard(id)
    try await waitUntil { harness.isTerminated(0) }
    await clock.fire()
    harness.yield("Late result", attempt: 0)
    await Task.yield()
    XCTAssertTrue(state.answers.isEmpty)
    XCTAssertEqual(harness.count, 1)
    XCTAssertFalse(service.isAnswering)
  }

  func testImmediateStopDoesNotStartAnUnconsumedRequest() async throws {
    let harness = FirstTokenStreamHarness()
    let service = AssistantService(settings: settings, makeStream: { harness.stream($0, $1) })
    service.ask(trigger: .auto)
    service.stop()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(harness.count, 0)
    XCTAssertEqual(state.answers.first?.status, .stopped)
  }
}
