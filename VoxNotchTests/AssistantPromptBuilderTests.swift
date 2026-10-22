//
//  AssistantPromptBuilderTests.swift
//  VoxNotchTests
//

import XCTest
@testable import VoxNotch

final class AssistantPromptBuilderTests: XCTestCase {

  private let now = Date(timeIntervalSince1970: 10_000)

  private func segment(_ source: AudioSource, _ text: String, endedAgo: TimeInterval) -> LiveTranscriptSegment {
    LiveTranscriptSegment(
      id: UUID(), source: source, text: text,
      startedAt: now.addingTimeInterval(-endedAgo - 1), endedAt: now.addingTimeInterval(-endedAgo), isFinal: true)
  }

  func testBuildsSystemAndTranscriptMessages() {
    let messages = AssistantPromptBuilder.messages(
      systemPrompt: "Be helpful.",
      transcript: [segment(.systemAudio, "How would you test it?", endedAgo: 5), segment(.microphone, "Good question.", endedAgo: 2)],
      trigger: .auto, now: now, window: 600)

    XCTAssertEqual(messages.map(\.role), [.system, .user])
    XCTAssertEqual(messages[0].content, "Be helpful.")
    XCTAssertTrue(messages[1].content.contains("Them: How would you test it?\nMe: Good question."))
    XCTAssertTrue(messages[1].content.hasSuffix("Help me respond to what they said last."))
  }

  func testEmptySystemPromptFallsBackToDefault() {
    let messages = AssistantPromptBuilder.messages(systemPrompt: "  \n", transcript: [], trigger: .manual, now: now, window: 600)
    XCTAssertEqual(messages[0].content, AssistantPromptBuilder.defaultSystemPrompt)
    XCTAssertTrue(messages[1].content.contains("(nothing has been said yet)"))
  }

  func testWindowDropsOldSegmentsAtWholeMinuteBoundary() {
    // now = 10_000s; window 120s → raw cutoff 9_880 → floored to 9_840.
    let transcript = [
      segment(.systemAudio, "too old", endedAgo: 170),
      segment(.systemAudio, "kept by minute rounding", endedAgo: 150),
      segment(.microphone, "recent", endedAgo: 10),
    ]
    let content = AssistantPromptBuilder.messages(systemPrompt: "x", transcript: transcript, trigger: .manual, now: now, window: 120)[1].content
    XCTAssertFalse(content.contains("too old"))
    XCTAssertTrue(content.contains("kept by minute rounding"))
    XCTAssertTrue(content.contains("recent"))
  }

  func testPrefixIsStableAsTranscriptGrows() {
    let first = [segment(.systemAudio, "Hello.", endedAgo: 20)]
    let a = AssistantPromptBuilder.messages(systemPrompt: "x", transcript: first, trigger: .auto, now: now, window: 600)[1].content
    let b = AssistantPromptBuilder.messages(
      systemPrompt: "x", transcript: first + [segment(.microphone, "Hi!", endedAgo: 5)], trigger: .auto,
      now: now.addingTimeInterval(5), window: 600)[1].content
    let sharedPrefix = a.commonPrefix(with: b)
    XCTAssertTrue(sharedPrefix.hasSuffix("Them: Hello.\n"), sharedPrefix)
  }
}
