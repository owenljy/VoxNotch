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

  /// Sources skipped because their permission isn't granted. VoxNotch never asks
  /// mid-session (the macOS dialog would show on a shared screen).
  var permissionIssues: Set<AudioSource> = []

  /// Recent RMS input level per source, for meters.
  var levels: [AudioSource: Float] = [:]

  /// Bumped on every transcript change; views use it to trigger auto-scroll.
  private(set) var revision = 0

  /// AI answers, oldest first.
  private(set) var answers: [AssistantAnswer] = []

  /// Committed keyboard selection; nil follows the latest answer.
  private(set) var selectedAnswerID: UUID?

  private enum AnswerBrowsing {
    case idle
    case preview(answer: UUID, origin: UUID)
    case locked(answer: UUID, origin: UUID)

    var answerID: UUID? {
      switch self {
      case .idle: nil
      case .preview(let answer, _), .locked(let answer, _): answer
      }
    }

    var originID: UUID? {
      switch self {
      case .idle: nil
      case .preview(_, let origin), .locked(_, let origin): origin
      }
    }
  }

  private var answerBrowsing: AnswerBrowsing = .idle

  var isAnswerLocked: Bool {
    if case .locked = answerBrowsing { return true }
    return false
  }

  var isPreviewingAnswer: Bool {
    if case .preview = answerBrowsing { return true }
    return false
  }

  private static let maxAnswers = 50

  var displayedAnswer: AssistantAnswer? {
    if let id = answerBrowsing.answerID ?? selectedAnswerID,
       let answer = answers.first(where: { $0.id == id }) {
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
  /// The row changed by the most recent accepted final (which may arrive out of order).
  private(set) var lastFinalSegment: LiveTranscriptSegment?

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

  /// Finals and in-progress partials in chronological display order.
  var displayRows: [LiveTranscriptSegment] {
    var rows = segments
    // Finals are already sorted; insert at most two partials rather than sorting
    // the whole session again on every streaming update.
    for partial in partials.values.sorted(by: { $0.startedAt < $1.startedAt }) {
      let index = rows.firstIndex { $0.startedAt > partial.startedAt } ?? rows.endIndex
      rows.insert(partial, at: index)
    }
    return rows
  }

  func begin(sources: Set<AudioSource>) {
    permissionIssues = []
    sessionID = UUID().uuidString
    segments = []
    lastFinalSegment = nil
    partials = [:]
    answers = []
    selectedAnswerID = nil
    answerBrowsing = .idle
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
    lastFinalSegment = nil
    partials = [:]
    answers = []
    selectedAnswerID = nil
    answerBrowsing = .idle
    revision += 1
  }

  // MARK: - Answers

  func appendAnswer(_ answer: AssistantAnswer) {
    answers.append(answer)
    if answers.count > Self.maxAnswers { answers.removeFirst(answers.count - Self.maxAnswers) }
    selectedAnswerID = nil
    reconcileAnswerBrowsing()
  }

  func removeAnswer(_ id: UUID) {
    answers.removeAll { $0.id == id }
    reconcileAnswerBrowsing()
  }

  func updateAnswer(_ id: UUID, _ change: (inout AssistantAnswer) -> Void) {
    guard let index = answers.firstIndex(where: { $0.id == id }) else { return }
    change(&answers[index])
  }

  func showAnswer(offset: Int) {
    guard let index = displayedAnswerIndex else { return }
    let target = min(max(index + offset, 0), answers.count - 1)
    answerBrowsing = .idle
    selectedAnswerID = target == answers.count - 1 ? nil : answers[target].id
  }

  /// Hovering never changes the committed page. The origin uses an ID so a new
  /// answer arriving during a preview cannot change the page we return to.
  func previewAnswer(_ id: UUID) {
    guard !isAnswerLocked, answers.contains(where: { $0.id == id }),
          let origin = answerBrowsing.originID ?? displayedAnswer?.id else { return }
    if answerBrowsing.answerID != id {
      answerBrowsing = .preview(answer: id, origin: origin)
    }
  }

  func endAnswerPreview() {
    guard isPreviewingAnswer else { return }
    restoreAnswerOrigin()
  }

  func lockAnswer(_ id: UUID) {
    guard answers.contains(where: { $0.id == id }),
          let origin = answerBrowsing.originID ?? displayedAnswer?.id else { return }
    answerBrowsing = .locked(answer: id, origin: origin)
  }

  func unlockAnswer() {
    restoreAnswerOrigin()
  }

  private func restoreAnswerOrigin() {
    guard let origin = answerBrowsing.originID else { return }
    selectedAnswerID = answers.contains(where: { $0.id == origin }) && origin != answers.last?.id ? origin : nil
    answerBrowsing = .idle
  }

  private func reconcileAnswerBrowsing() {
    if let selectedAnswerID, !answers.contains(where: { $0.id == selectedAnswerID }) {
      self.selectedAnswerID = nil
    }
    guard let id = answerBrowsing.answerID else { return }
    guard answers.contains(where: { $0.id == id }) else {
      restoreAnswerOrigin()
      return
    }
    // The bounded history may evict the origin while its preview is still open.
    guard let origin = answerBrowsing.originID,
          !answers.contains(where: { $0.id == origin }), let fallback = answers.last?.id else { return }
    answerBrowsing = isAnswerLocked
      ? .locked(answer: id, origin: fallback)
      : .preview(answer: id, origin: fallback)
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
    lastFinalSegment = nil
    guard !update.text.isEmpty, !isEcho(update) else { return false }

    let insertionIndex = segments.firstIndex { $0.startedAt > update.startedAt } ?? segments.endIndex
    let previousIndex = insertionIndex - 1
    if previousIndex >= 0,
       segments[previousIndex].source == update.source,
       (0...mergeGap).contains(update.startedAt.timeIntervalSince(segments[previousIndex].endedAt))
    {
      segments[previousIndex].text += " " + update.text
      segments[previousIndex].endedAt = update.endedAt
      lastFinalSegment = segments[previousIndex]
    } else {
      let segment = LiveTranscriptSegment(
        id: update.utteranceID,
        source: update.source,
        text: update.text,
        startedAt: update.startedAt,
        endedAt: update.endedAt,
        isFinal: true
      )
      segments.insert(segment, at: insertionIndex)
      lastFinalSegment = segment
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
