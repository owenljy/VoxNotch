//
//  AlwaysOnState.swift
//  VoxNotch
//
//  Observable state for Always-On mode: lifecycle status and the live,
//  source-tagged transcript.
//

import Foundation

@MainActor @Observable
final class AlwaysOnState {

  static let shared = AlwaysOnState()

  enum Status: Equatable {
    case idle
    case preparing
    case running
    case failed(String)
  }

  var status: Status = .idle

  /// Stable identifier for the current run, shared with the persisted
  /// `AlwaysOnSessionRecord` row. Regenerated on every `begin()`.
  private(set) var sessionID: String = UUID().uuidString
  private(set) var activeSources: Set<AudioSource> = []
  var startedAt: Date?
  var isPaused = false
  var preparingMessage = "Starting live transcription…"

  /// Recent RMS input level per source, for meters.
  var levels: [AudioSource: Float] = [:]

  /// Bumped on every transcript change; views use it to trigger auto-scroll.
  private(set) var revision = 0

  /// AI answers, oldest first.
  private(set) var answers: [AssistantAnswer] = []

  /// Answer pinned by the pager; nil follows the latest answer.
  var selectedAnswerID: UUID?

  private static let maxAnswers = 50

  var displayedAnswer: AssistantAnswer? {
    if let selectedAnswerID, let answer = answers.first(where: { $0.id == selectedAnswerID }) {
      return answer
    }
    return answers.last
  }

  var displayedAnswerIndex: Int? {
    guard let answer = displayedAnswer else { return nil }
    return answers.firstIndex { $0.id == answer.id }
  }

  /// Finalized transcript lines in chronological order.
  private(set) var segments: [LiveTranscriptSegment] = []

  /// In-progress (volatile) utterance per source.
  private(set) var partials: [AudioSource: LiveTranscriptSegment] = [:]

  /// Consecutive finals from the same source closer than this are merged into one line.
  var mergeGap: TimeInterval = 1.5
  var suppressEcho = true

  private static let echoWindow: TimeInterval = 2

  var isActive: Bool {
    switch status {
    case .preparing, .running: true
    case .idle, .failed: false
    }
  }

  /// Transcript lines followed by in-progress partials, in display order.
  var displayRows: [LiveTranscriptSegment] {
    segments + partials.values.sorted { $0.startedAt < $1.startedAt }
  }

  func begin(sources: Set<AudioSource>) {
    sessionID = UUID().uuidString
    segments = []
    partials = [:]
    answers = []
    selectedAnswerID = nil
    levels = [:]
    activeSources = sources
    startedAt = nil
    isPaused = false
    status = .preparing
    revision += 1
  }

  func end() {
    partials = [:]
    levels = [:]
    activeSources = []
    isPaused = false
    startedAt = nil
    status = .idle
    revision += 1
  }

  func setSource(_ source: AudioSource, active: Bool) {
    if active { activeSources.insert(source) } else { activeSources.remove(source) }
    if !active { partials[source] = nil; levels[source] = nil }
  }

  func clearTranscript() {
    segments = []
    partials = [:]
    answers = []
    selectedAnswerID = nil
    revision += 1
  }

  // MARK: - Answers

  func appendAnswer(_ answer: AssistantAnswer) {
    answers.append(answer)
    if answers.count > Self.maxAnswers { answers.removeFirst(answers.count - Self.maxAnswers) }
    selectedAnswerID = nil
  }

  func removeAnswer(_ id: UUID) {
    answers.removeAll { $0.id == id }
    if selectedAnswerID == id { selectedAnswerID = nil }
  }

  func updateAnswer(_ id: UUID, _ change: (inout AssistantAnswer) -> Void) {
    guard let index = answers.firstIndex(where: { $0.id == id }) else { return }
    change(&answers[index])
  }

  func showAnswer(offset: Int) {
    guard let index = displayedAnswerIndex else { return }
    let target = min(max(index + offset, 0), answers.count - 1)
    selectedAnswerID = target == answers.count - 1 ? nil : answers[target].id
  }

  func clearPartials() {
    partials = [:]
    revision += 1
  }

  /// Returns false when a final is dropped (empty or echo).
  @discardableResult
  func apply(_ update: TranscriptUpdate) -> Bool {
    revision += 1
    guard update.isFinal else {
      partials[update.source] = LiveTranscriptSegment(
        id: update.utteranceID,
        source: update.source,
        text: update.text,
        startedAt: update.startedAt,
        endedAt: update.endedAt,
        isFinal: false
      )
      return true
    }

    if partials[update.source]?.id == update.utteranceID {
      partials[update.source] = nil
    }
    guard !update.text.isEmpty, !isEcho(update) else { return false }

    if let lastIndex = segments.indices.last,
       segments[lastIndex].source == update.source,
       update.startedAt.timeIntervalSince(segments[lastIndex].endedAt) <= mergeGap
    {
      segments[lastIndex].text += " " + update.text
      segments[lastIndex].endedAt = update.endedAt
    } else {
      segments.append(LiveTranscriptSegment(
        id: update.utteranceID,
        source: update.source,
        text: update.text,
        startedAt: update.startedAt,
        endedAt: update.endedAt,
        isFinal: true
      ))
    }
    return true
  }

  private func isEcho(_ update: TranscriptUpdate) -> Bool {
    guard suppressEcho, update.source == .microphone, activeSources.contains(.systemAudio) else { return false }
    let windowStart = update.startedAt.addingTimeInterval(-Self.echoWindow)
    let windowEnd = update.endedAt.addingTimeInterval(Self.echoWindow)
    var candidates = segments.filter { $0.source == .systemAudio }
    if let partial = partials[.systemAudio] { candidates.append(partial) }
    let systemText = candidates
      .filter { $0.endedAt >= windowStart && $0.startedAt <= windowEnd }
      .map(\.text)
      .joined(separator: " ")
    return EchoFilter.isLikelyEcho(micText: update.text, systemText: systemText)
  }
}
