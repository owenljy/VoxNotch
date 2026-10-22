//
//  AlwaysOnStateTests.swift
//  VoxNotchTests
//

import XCTest
@testable import VoxNotch

@MainActor
final class AlwaysOnStateTests: XCTestCase {

  private var state: AlwaysOnState!
  private let t0 = Date(timeIntervalSince1970: 1_000)

  override func setUp() async throws {
    state = AlwaysOnState.shared
    state.begin(sources: [.microphone, .systemAudio])
  }

  override func tearDown() async throws {
    state.end()
  }

  private func update(
    _ source: AudioSource, _ text: String, final: Bool, id: UUID = UUID(), start: TimeInterval, end: TimeInterval
  ) -> TranscriptUpdate {
    TranscriptUpdate(
      utteranceID: id, source: source, text: text, isFinal: final,
      startedAt: t0.addingTimeInterval(start), endedAt: t0.addingTimeInterval(end),
      processingLatency: .zero, trailingSilence: .zero
    )
  }

  func testPartialIsReplacedByFinal() {
    let id = UUID()
    state.apply(update(.systemAudio, "How do", final: false, id: id, start: 0, end: 1))
    XCTAssertEqual(state.partials[.systemAudio]?.text, "How do")
    state.apply(update(.systemAudio, "How do you test it?", final: true, id: id, start: 0, end: 2))
    XCTAssertNil(state.partials[.systemAudio])
    XCTAssertEqual(state.segments.map(\.text), ["How do you test it?"])
  }

  func testEmptyFinalOnlyClearsPartial() {
    let id = UUID()
    state.apply(update(.microphone, "uh", final: false, id: id, start: 0, end: 1))
    state.apply(update(.microphone, "", final: true, id: id, start: 0, end: 1))
    XCTAssertNil(state.partials[.microphone])
    XCTAssertTrue(state.segments.isEmpty)
  }

  func testCloseFinalsFromSameSourceMerge() {
    state.apply(update(.systemAudio, "First part.", final: true, start: 0, end: 2))
    state.apply(update(.systemAudio, "Second part.", final: true, start: 3, end: 4))
    state.apply(update(.systemAudio, "Much later.", final: true, start: 10, end: 11))
    XCTAssertEqual(state.segments.map(\.text), ["First part. Second part.", "Much later."])
  }

  func testDifferentSourcesDoNotMerge() {
    state.apply(update(.systemAudio, "Question?", final: true, start: 0, end: 2))
    state.apply(update(.microphone, "Answer.", final: true, start: 2.5, end: 3))
    XCTAssertEqual(state.segments.map(\.source), [.systemAudio, .microphone])
  }

  func testMicEchoOfSystemAudioIsDropped() {
    state.apply(update(.systemAudio, "We grew revenue thirty percent this quarter", final: true, start: 0, end: 3))
    state.apply(update(.microphone, "grew revenue thirty percent this quarter", final: true, start: 0.2, end: 3.1))
    XCTAssertEqual(state.segments.count, 1)

    state.apply(update(.microphone, "That sounds great to me", final: true, start: 4, end: 5))
    XCTAssertEqual(state.segments.last?.source, .microphone)
  }

  func testEchoSuppressionCanBeDisabled() {
    state.suppressEcho = false
    defer { state.suppressEcho = true }
    state.apply(update(.systemAudio, "hello there everyone", final: true, start: 0, end: 2))
    state.apply(update(.microphone, "hello there everyone", final: true, start: 0, end: 2))
    XCTAssertEqual(state.segments.count, 2)
  }
}
