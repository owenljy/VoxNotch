//
//  UtteranceSegmenterTests.swift
//  VoxNotchTests
//

import XCTest
@testable import VoxNotch

final class UtteranceSegmenterTests: XCTestCase {

  private let chunkSize = 4096
  private func chunk(_ value: Float) -> [Float] { [Float](repeating: value, count: chunkSize) }

  private func run(_ segmenter: inout UtteranceSegmenter, _ probabilities: [Float]) -> [UtteranceSegmenter.Event?] {
    probabilities.enumerated().map { index, p in
      segmenter.process(chunk: chunk(Float(index)), speechProbability: p)
    }
  }

  func testSilenceProducesNoEvents() {
    var segmenter = UtteranceSegmenter()
    XCTAssertTrue(run(&segmenter, [0.1, 0.2, 0.0]).allSatisfy { $0 == nil })
    XCTAssertFalse(segmenter.isSpeaking)
  }

  func testSpeechEmitsPartialsThenFinalAfterTwoSilentChunks() throws {
    var segmenter = UtteranceSegmenter()
    let events = run(&segmenter, [0.1, 0.9, 0.9, 0.1, 0.1, 0.1])

    XCTAssertNil(events[0])
    guard case .partial(let first) = events[1], case .partial(let second) = events[2], case .partial = events[3] else {
      return XCTFail("expected partials while speaking: \(events)")
    }
    XCTAssertEqual(first.id, second.id)
    XCTAssertEqual(first.startSample, 0, "includes one pre-roll chunk")
    XCTAssertEqual(first.samples.count, chunkSize * 2)

    guard case .final(let final) = events[4] else { return XCTFail("expected final: \(events)") }
    XCTAssertEqual(final.id, first.id)
    // pre-roll + 2 speech + first silent chunk kept, second silent chunk trimmed
    XCTAssertEqual(final.samples.count, chunkSize * 4)
    XCTAssertEqual(final.trailingSilenceSamples, chunkSize * 2)
    XCTAssertNil(events[5])
    XCTAssertFalse(segmenter.isSpeaking)
  }

  func testHysteresisBandDoesNotEndUtterance() {
    var segmenter = UtteranceSegmenter()
    let events = run(&segmenter, [0.9, 0.4, 0.4, 0.4, 0.1])
    XCTAssertFalse(events.contains { if case .final = $0 { true } else { false } })
    XCTAssertTrue(segmenter.isSpeaking)
  }

  func testSilenceRunResetsOnSpeech() {
    var segmenter = UtteranceSegmenter()
    let events = run(&segmenter, [0.9, 0.1, 0.9, 0.1, 0.9])
    XCTAssertFalse(events.contains { if case .final = $0 { true } else { false } })
  }

  func testNextUtteranceGetsNewIDAndCorrectStart() throws {
    var segmenter = UtteranceSegmenter()
    let events = run(&segmenter, [0.9, 0.1, 0.1, 0.1, 0.9])
    guard case .final(let first) = events[2], case .partial(let second) = events[4] else {
      return XCTFail("unexpected events: \(events)")
    }
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(second.startSample, chunkSize * 3, "starts at the pre-roll chunk")
  }

  func testHardMaxSplitsAndContinues() throws {
    var config = UtteranceSegmenter.Config()
    config.softMaxSamples = 4096 * 3
    config.hardMaxSamples = 4096 * 3
    var segmenter = UtteranceSegmenter(config: config)
    let events = run(&segmenter, [0.9, 0.9, 0.9, 0.9])

    guard case .final(let first) = events[2], case .partial(let next) = events[3] else {
      return XCTFail("unexpected events: \(events)")
    }
    XCTAssertEqual(first.samples.count, 4096 * 3)
    XCTAssertNotEqual(first.id, next.id)
    XCTAssertEqual(next.startSample, 4096 * 3)
    XCTAssertTrue(segmenter.isSpeaking)
  }

  func testSoftMaxSplitsOnlyOnNonSpeechChunk() {
    var config = UtteranceSegmenter.Config()
    config.softMaxSamples = 4096 * 2
    var segmenter = UtteranceSegmenter(config: config)
    let events = run(&segmenter, [0.9, 0.9, 0.9, 0.4])
    guard case .partial = events[2], case .final = events[3] else {
      return XCTFail("unexpected events: \(events)")
    }
  }

  func testFlushFinalizesWithTail() throws {
    var segmenter = UtteranceSegmenter()
    _ = run(&segmenter, [0.9])
    let event = segmenter.flush(appending: [Float](repeating: 1, count: 100))
    guard case .final(let utterance) = event else { return XCTFail("expected final") }
    XCTAssertEqual(utterance.samples.count, chunkSize + 100)
    XCTAssertEqual(utterance.trailingSilenceSamples, 0)
    XCTAssertFalse(segmenter.isSpeaking)
    XCTAssertNil(segmenter.flush())
  }

  func testShortSpeechDoesNotCountTrimmedSilenceTwice() {
    var segmenter = UtteranceSegmenter()
    let events = run(&segmenter, [0.9, 0.1, 0.1])
    guard case .final(let final) = events.last! else { return XCTFail("expected final") }
    XCTAssertEqual(final.samples.count - final.retainedSilenceSamples, chunkSize)
    XCTAssertGreaterThanOrEqual(final.samples.count - final.retainedSilenceSamples, LiveTranscriber.Config().minFinalSamples)
    XCTAssertEqual(final.trailingSilenceSamples, 2 * chunkSize, "latency still includes the full silence run")
  }

  func testFlushWithoutTailPreservesKnownSilenceForNoiseGate() {
    var segmenter = UtteranceSegmenter()
    _ = run(&segmenter, [0.9, 0.1])
    guard case .final(let final) = segmenter.flush() else { return XCTFail("expected final") }
    XCTAssertEqual(final.retainedSilenceSamples, chunkSize)
  }

  func testIdleFlushAccountsForDiscardedTailInNextTimestamp() {
    var segmenter = UtteranceSegmenter()
    XCTAssertNil(segmenter.flush(appending: [Float](repeating: 0, count: 123)))
    guard case .partial(let next) = segmenter.process(chunk: chunk(1), speechProbability: 0.9) else {
      return XCTFail("expected partial")
    }
    XCTAssertEqual(next.startSample, 123)
  }
}
