//
//  AutoTriggerPolicyTests.swift
//  VoxNotchTests
//

import XCTest
@testable import VoxNotch

final class AutoTriggerPolicyTests: XCTestCase {

  private let t0 = Date(timeIntervalSince1970: 50_000)

  private func update(
    _ source: AudioSource, _ text: String, id: UUID, final: Bool = false, pausedMs: Int = 0
  ) -> TranscriptUpdate {
    TranscriptUpdate(
      utteranceID: id, source: source, text: text, isFinal: final,
      startedAt: t0, endedAt: t0, processingLatency: .zero, trailingSilence: .milliseconds(pausedMs))
  }

  private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

  func testQuestionPauseFiresSpeculativelyAndFinalConfirms() {
    var policy = AutoTriggerPolicy()
    let id = UUID()
    XCTAssertEqual(policy.handle(update(.systemAudio, "How would you", id: id), accepted: true, now: at(0)), [])
    XCTAssertEqual(
      policy.handle(update(.systemAudio, "How would you test it?", id: id, pausedMs: 256), accepted: true, now: at(1)),
      [.fire(speculative: true)])
    XCTAssertEqual(policy.speculativeUtterance, id)
    XCTAssertEqual(policy.handle(update(.systemAudio, "How would you test it?", id: id, final: true), accepted: true, now: at(1.3)), [])
    XCTAssertNil(policy.speculativeUtterance)
    XCTAssertEqual(policy.silenceCheck(now: at(5)), .none, "already answered")
  }

  func testResumedSpeechCancelsSpeculativeAnswer() {
    var policy = AutoTriggerPolicy()
    let id = UUID()
    _ = policy.handle(update(.systemAudio, "Any questions?", id: id, pausedMs: 256), accepted: true, now: at(0))
    XCTAssertEqual(
      policy.handle(update(.systemAudio, "Any questions? Because I also", id: id), accepted: true, now: at(0.3)),
      [.cancelSpeculative])
    XCTAssertNil(policy.speculativeUtterance)
    // The same utterance can fire again once it really ends with a question.
    XCTAssertEqual(
      policy.handle(update(.systemAudio, "Any questions? Because I also want to know what?", id: id, final: true), accepted: true, now: at(5)),
      [.fire(speculative: false)])
  }

  func testStatementSchedulesSilenceCheckThenFires() {
    var policy = AutoTriggerPolicy(config: .init(silenceDelay: 1.5))
    let actions = policy.handle(update(.systemAudio, "We grew thirty percent.", id: UUID(), final: true), accepted: true, now: at(0))
    XCTAssertEqual(actions, [.scheduleSilenceCheck(after: 1.5)])
    XCTAssertEqual(policy.silenceCheck(now: at(1.0)), .wait(0.5))
    XCTAssertEqual(policy.silenceCheck(now: at(1.5)), .fire)
    XCTAssertEqual(policy.silenceCheck(now: at(3)), .none)
  }

  func testUserSpeakingDelaysAndUserFinalCancelsSilenceAnswer() {
    var policy = AutoTriggerPolicy(config: .init(silenceDelay: 1.5))
    _ = policy.handle(update(.systemAudio, "That's our plan.", id: UUID(), final: true), accepted: true, now: at(0))
    _ = policy.handle(update(.microphone, "Sounds", id: UUID()), accepted: true, now: at(1))
    XCTAssertEqual(policy.silenceCheck(now: at(1.5)), .wait(1.0))
    _ = policy.handle(update(.microphone, "Sounds good to me.", id: UUID(), final: true), accepted: true, now: at(2))
    XCTAssertEqual(policy.silenceCheck(now: at(4)), .none)
  }

  func testEchoedMicFinalDoesNotCountAsUserAnswer() {
    var policy = AutoTriggerPolicy(config: .init(silenceDelay: 1.5))
    _ = policy.handle(update(.systemAudio, "That's our plan.", id: UUID(), final: true), accepted: true, now: at(0))
    _ = policy.handle(update(.microphone, "That's our plan.", id: UUID(), final: true), accepted: false, now: at(0.2))
    XCTAssertEqual(policy.silenceCheck(now: at(1.6)), .fire)
  }

  func testMinimumIntervalBetweenAutoAnswers() {
    var policy = AutoTriggerPolicy(config: .init(minimumInterval: 4))
    XCTAssertEqual(policy.handle(update(.systemAudio, "First?", id: UUID(), final: true), accepted: true, now: at(0)), [.fire(speculative: false)])
    XCTAssertEqual(
      policy.handle(update(.systemAudio, "Second?", id: UUID(), final: true), accepted: true, now: at(1)),
      [.scheduleSilenceCheck(after: 1.5)])
    XCTAssertEqual(policy.silenceCheck(now: at(2.5)), .wait(1.5))
    XCTAssertEqual(policy.silenceCheck(now: at(4)), .fire)
  }

  func testDisabledOrNonImmediateModes() {
    var disabled = AutoTriggerPolicy(config: .init(isEnabled: false))
    XCTAssertEqual(disabled.handle(update(.systemAudio, "Why?", id: UUID(), final: true), accepted: true, now: at(0)), [])

    var silenceOnly = AutoTriggerPolicy(config: .init(answerQuestionsImmediately: false))
    XCTAssertEqual(
      silenceOnly.handle(update(.systemAudio, "Why?", id: UUID(), pausedMs: 256), accepted: true, now: at(0)), [])
    XCTAssertEqual(
      silenceOnly.handle(update(.systemAudio, "Why?", id: UUID(), final: true), accepted: true, now: at(0.3)),
      [.scheduleSilenceCheck(after: 1.5)])
  }

  func testManualAnswerClearsPendingSpeech() {
    var policy = AutoTriggerPolicy()
    _ = policy.handle(update(.systemAudio, "Okay.", id: UUID(), final: true), accepted: true, now: at(0))
    policy.noteManualAnswer()
    XCTAssertEqual(policy.silenceCheck(now: at(5)), .none)
  }

  func testManualAskDuringPartialPreventsDuplicateAutoAnswerOnFinal() {
    var policy = AutoTriggerPolicy()
    let id = UUID()
    _ = policy.handle(update(.systemAudio, "What is a trie?", id: id), accepted: true, now: at(0))
    policy.noteManualAnswer()
    XCTAssertEqual(policy.handle(update(.systemAudio, "What is a trie?", id: id, final: true), accepted: true, now: at(2)), [])
    XCTAssertEqual(policy.silenceCheck(now: at(5)), .none)
    XCTAssertEqual(policy.handle(update(.systemAudio, "And a heap?", id: UUID(), final: true), accepted: true, now: at(6)), [.fire(speculative: false)])
  }
}
