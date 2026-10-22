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
    recognitionHints: [String] = [],
    customTerms: [String] = [],
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

    let windowed = transcript.filter { segment in
      !segment.text.isEmpty && (cutoff.map { segment.endedAt >= $0 } ?? true)
    }
    var entries: [(time: Date, text: String)] = windowed
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

    let latest = latestLines(transcript: windowed, previousAnswers: previousAnswers)
    let latestBlock = latest.isEmpty ? "" : """


      Latest — respond to this:
      <latest>
      \(latest.joined(separator: "\n"))
      </latest>
      """

    let body = """
      Live conversation transcript (Me = me, Them = other participants):
      <transcript>
      \(lines.isEmpty ? "(nothing has been said yet)" : lines.joined(separator: "\n"))
      </transcript>\(latestBlock)

      \(instruction(for: trigger, hasLatest: !latest.isEmpty))
      """

    let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let system = (trimmed.isEmpty ? defaultSystemPrompt : trimmed)
      + recognitionNotes(hints: recognitionHints, terms: customTerms)
    return [
      ChatMessage(role: .system, content: system),
      ChatMessage(role: .user, content: body),
    ]
  }

  /// Homophones (trie/try) can't be fixed by the recognizer, only by reading context,
  /// so the model is told what to expect. Lives in the system message, which stays
  /// identical across requests and keeps prefix caching effective.
  static func recognitionNotes(hints: [String], terms: [String]) -> String {
    guard !hints.isEmpty || !terms.isEmpty else { return "" }
    var notes = """


      Speech-recognition notes: the transcript comes from an automatic recognizer that often \
      mishears technical terms, especially words that sound alike. When the context supports it, \
      silently read them as the intended term and always use the correct term in your answer. \
      Never point out or correct the transcript itself.
      """
    if !hints.isEmpty {
      notes += "\nCommon mishearings (heard → meant):\n" + hints.map { "- \($0)" }.joined(separator: "\n")
    }
    if !terms.isEmpty {
      notes += "\nTerms likely to come up (match similar-sounding words to these): " + terms.joined(separator: ", ")
    }
    return notes
  }

  static func speaker(for source: AudioSource) -> String {
    source == .microphone ? "Me" : "Them"
  }

  /// The other side's most recent 1–2 lines, preferring those since the last AI answer
  /// (i.e. not yet answered). Falls back to the last lines from anyone when only Me spoke.
  static func latestLines(transcript: [LiveTranscriptSegment], previousAnswers: [AssistantAnswer]) -> [String] {
    let spoken = transcript.filter { !$0.text.isEmpty }
    let them = spoken.filter { $0.source == .systemAudio }
    let lastAnswerAt = previousAnswers
      .filter { !$0.markdown.isEmpty && ($0.status == .done || $0.status == .stopped) }
      .map(\.createdAt)
      .max()
    let unanswered = lastAnswerAt.map { cutoff in them.filter { $0.endedAt > cutoff } } ?? them
    let focus = !unanswered.isEmpty ? unanswered : (!them.isEmpty ? them : spoken)
    return focus.suffix(2).map { "\(speaker(for: $0.source)): \($0.text)" }
  }

  private static func instruction(for trigger: AssistantAnswer.Trigger, hasLatest: Bool) -> String {
    let lead = switch trigger {
    case .manual: "Help me right now."
    case .auto: "The other person just finished speaking."
    }
    guard hasLatest else { return "\(lead) Focus on the most recent part of the conversation." }
    return """
      \(lead) Answer what is in <latest> — above all its most recent question. Use the rest of the \
      transcript and earlier Copilot suggestions only as background, and don't re-answer earlier \
      questions unless the latest one refers back to them.
      """
  }
}
