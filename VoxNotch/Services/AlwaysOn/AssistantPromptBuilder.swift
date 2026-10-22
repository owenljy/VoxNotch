//
//  AssistantPromptBuilder.swift
//  VoxNotch
//
//  Builds chat messages for the Always-On assistant. The prompt prefix is kept
//  stable between requests (system prompt, then an append-only transcript whose
//  start moves in whole minutes) so providers with prefix caching can reuse it.
//

import Foundation

nonisolated enum AssistantPromptBuilder {

  static let defaultSystemPrompt = """
    You are a real-time conversation copilot. You see a live transcript between the user ("Me") and \
    other participants ("Them"). The transcript comes from speech recognition and may contain errors.

    - Lead with one or two sentences the user can say out loud right away.
    - Add a short bulleted list of supporting points only when it genuinely helps.
    - Be concise, specific and natural. No preamble, and don't restate the question.
    - If nothing needs a response, give one useful insight in a single line.
    - Use Markdown formatting.
    """

  static func messages(
    systemPrompt: String,
    transcript: [LiveTranscriptSegment],
    trigger: AssistantAnswer.Trigger,
    now: Date,
    window: TimeInterval
  ) -> [ChatMessage] {
    let cutoff = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - window) / 60).rounded(.down) * 60)
    let lines = transcript
      .filter { $0.endedAt >= cutoff && !$0.text.isEmpty }
      .map { "\(speaker(for: $0.source)): \($0.text)" }

    let body = """
      Live conversation transcript (Me = the user, Them = other participants):
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
      "Help me with what to say or know right now, focusing on the most recent part of the conversation."
    case .auto:
      "The other person just finished speaking. Help me respond to what they said last."
    }
  }
}
