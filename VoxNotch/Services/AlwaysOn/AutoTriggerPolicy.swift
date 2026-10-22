//
//  AutoTriggerPolicy.swift
//  VoxNotch
//
//  Decides when the assistant answers on its own.
//
//  - Speculative: the other person pauses (first silent VAD chunk) after a line
//    ending in "?" → answer immediately; if they keep talking, cancel it.
//  - Question final: a finalized line ending in "?" → answer.
//  - Silence: unanswered speech from the other person followed by `silenceDelay`
//    of quiet → answer.
//

import Foundation

nonisolated struct AutoTriggerPolicy {

  struct Config: Equatable, Sendable {
    var isEnabled = true
    var answerQuestionsImmediately = true
    var silenceDelay: TimeInterval = 1.5
    var minimumInterval: TimeInterval = 4
  }

  enum Action: Equatable {
    case fire(speculative: Bool)
    case cancelSpeculative
    case scheduleSilenceCheck(after: TimeInterval)
  }

  enum SilenceDecision: Equatable {
    case fire
    case wait(TimeInterval)
    case none
  }

  var config: Config

  private(set) var speculativeUtterance: UUID?
  private(set) var hasUnansweredSpeech = false
  private var answeredUtterances: [UUID] = []
  private var lastFireAt: Date?
  private var lastActivityAt = Date.distantPast
  private var latestSystemUtterance: UUID?

  init(config: Config = Config()) {
    self.config = config
  }

  /// `accepted` is false for finals the transcript dropped (empty or echo).
  mutating func handle(_ update: TranscriptUpdate, accepted: Bool, now: Date) -> [Action] {
    guard config.isEnabled else { return [] }
    let isSpeaking = !update.isFinal && update.trailingSilence == .zero && !update.text.isEmpty

    switch update.source {
    case .microphone:
      if isSpeaking { lastActivityAt = now }
      if update.isFinal, accepted {
        // The user answered themselves.
        hasUnansweredSpeech = false
        lastActivityAt = now
      }
      return []

    case .systemAudio:
      let id = update.utteranceID
      latestSystemUtterance = id

      if !update.isFinal {
        guard !update.text.isEmpty else { return [] }
        if isSpeaking {
          lastActivityAt = now
          hasUnansweredSpeech = true
          if speculativeUtterance == id {
            speculativeUtterance = nil
            answeredUtterances.removeAll { $0 == id }
            return [.cancelSpeculative]
          }
          return []
        }
        // Paused: the partial already covers the whole utterance.
        if config.answerQuestionsImmediately, Self.isQuestion(update.text), canFire(id, now: now) {
          markFired(id, now: now)
          speculativeUtterance = id
          return [.fire(speculative: true)]
        }
        hasUnansweredSpeech = true
        return []
      }

      if speculativeUtterance == id {
        speculativeUtterance = nil
        return []
      }
      guard accepted, !update.text.isEmpty, !answeredUtterances.contains(id) else { return [] }
      lastActivityAt = now
      if config.answerQuestionsImmediately, Self.isQuestion(update.text), canFire(id, now: now) {
        markFired(id, now: now)
        return [.fire(speculative: false)]
      }
      hasUnansweredSpeech = true
      return [.scheduleSilenceCheck(after: config.silenceDelay)]
    }
  }

  mutating func silenceCheck(now: Date) -> SilenceDecision {
    guard config.isEnabled, hasUnansweredSpeech, speculativeUtterance == nil else { return .none }
    let quietFor = now.timeIntervalSince(lastActivityAt)
    if quietFor < config.silenceDelay - 0.05 {
      return .wait(config.silenceDelay - quietFor)
    }
    if let lastFireAt, now.timeIntervalSince(lastFireAt) < config.minimumInterval {
      return .wait(config.minimumInterval - now.timeIntervalSince(lastFireAt))
    }
    hasUnansweredSpeech = false
    lastFireAt = now
    return .fire
  }

  mutating func noteManualAnswer() {
    // The same utterance may still be partial when the user presses Ask.
    // Its later final must not launch a second answer to the same question.
    if let id = latestSystemUtterance, !answeredUtterances.contains(id) {
      answeredUtterances.append(id)
      if answeredUtterances.count > 32 { answeredUtterances.removeFirst() }
    }
    hasUnansweredSpeech = false
    speculativeUtterance = nil
  }

  static func isQuestion(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
  }

  private func canFire(_ id: UUID, now: Date) -> Bool {
    guard !answeredUtterances.contains(id) else { return false }
    guard let lastFireAt else { return true }
    return now.timeIntervalSince(lastFireAt) >= config.minimumInterval
  }

  private mutating func markFired(_ id: UUID, now: Date) {
    answeredUtterances.append(id)
    if answeredUtterances.count > 32 { answeredUtterances.removeFirst() }
    lastFireAt = now
    hasUnansweredSpeech = false
  }
}
