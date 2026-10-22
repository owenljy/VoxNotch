//
//  AssistantPromptBuilder.swift
//  VoxNotch
//
//  Builds chat messages for the Always-On assistant. The prompt prefix stays
//  stable between requests (system prompt, then an append-only, chronological
//  transcript whose optional window start moves in whole minutes) so providers
//  with prefix caching can reuse it.
//

import Foundation

nonisolated enum AssistantPromptBuilder {

  static var defaultSystemPrompt: String { AssistantPromptTemplate.general.prompt }

  /// - Parameters:
  ///   - previousAnswers: earlier AI answers, interleaved by time so the model can build on them.
  ///   - window: seconds of history to include; nil or <= 0 sends the entire session.
  static func messages(
    systemPrompt: String,
    transcript: [LiveTranscriptSegment],
    previousAnswers: [AssistantAnswer] = [],
    trigger: AssistantAnswer.Trigger,
    now: Date,
    window: TimeInterval?
  ) -> [ChatMessage] {
    let cutoff: Date? = window.flatMap { window in
      guard window > 0 else { return nil }
      return Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - window) / 60).rounded(.down) * 60)
    }

    var entries: [(time: Date, text: String)] = transcript
      .filter { segment in !segment.text.isEmpty && (cutoff.map { segment.endedAt >= $0 } ?? true) }
      .map { ($0.startedAt, "\(speaker(for: $0.source)): \($0.text)") }

    entries += previousAnswers
      .filter { answer in
        !answer.markdown.isEmpty
          && (answer.status == .done || answer.status == .stopped)
          && (cutoff.map { answer.createdAt >= $0 } ?? true)
      }
      .map { ($0.createdAt, "[Copilot — private suggestion shown only to Me]\n\($0.markdown)\n[/Copilot]") }

    // Stable sort keeps same-time entries in insertion order (speech before answers).
    let lines = entries.enumerated()
      .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
      .map(\.element.text)

    let body = """
      Live conversation transcript (Me = me, Them = other participants):
      <transcript>
      \(lines.isEmpty ? "(nothing has been said yet)" : lines.joined(separator: "\n"))
      </transcript>

      \(instruction(for: trigger))
      """

    let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return [
      ChatMessage(role: .system, content: system.isEmpty ? defaultSystemPrompt : system),
      ChatMessage(role: .user, content: body),
    ]
  }

  static func speaker(for source: AudioSource) -> String {
    source == .microphone ? "Me" : "Them"
  }

  private static func instruction(for trigger: AssistantAnswer.Trigger) -> String {
    switch trigger {
    case .manual:
      "Help me right now, focusing on the most recent part of the conversation."
    case .auto:
      "The other person just finished speaking. Help me respond to what they said last."
    }
  }
}
