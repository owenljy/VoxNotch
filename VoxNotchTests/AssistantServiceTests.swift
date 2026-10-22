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

  override func setUp() async throws {
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
    let service = AssistantService(makeStream: { _, _ in
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
    let service = AssistantService(makeStream: { _, _ in
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

  func testNewAskStopsPreviousAnswer() async throws {
    let service = AssistantService(makeStream: { _, _ in
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
    let service = AssistantService(historyStore: history, makeStream: { _, _ in
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
    let service = AssistantService(historyStore: history, makeStream: { _, _ in stream })
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
    let service = AssistantService(makeStream: { _, _ in stream })
    service.ask(trigger: .manual)
    state.begin(sources: [.microphone])
    continuation.yield("old session")
    continuation.finish()
    try await waitUntil { !service.isAnswering }
    XCTAssertTrue(state.answers.isEmpty)
    XCTAssertNil(service.currentAnswerID)
  }
}
