//
//  AssistantServiceTests.swift
//  VoxNotchTests
//

import XCTest
@testable import VoxNotch

@MainActor
final class AssistantServiceTests: XCTestCase {

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
}
