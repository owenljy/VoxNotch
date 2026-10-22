//
//  AutoTriggerCoordinator.swift
//  VoxNotch
//
//  Feeds transcript updates to AutoTriggerPolicy and carries out its actions:
//  asking the assistant, discarding speculative answers and running the
//  silence timer.
//

import Foundation

@MainActor
final class AutoTriggerCoordinator {

  private let assistant: AssistantService
  private let settings: AssistantSettings
  private var policy = AutoTriggerPolicy()
  private var speculativeAnswerID: UUID?
  private var silenceTask: Task<Void, Never>?

  init(assistant: AssistantService, settings: AssistantSettings) {
    self.assistant = assistant
    self.settings = settings
  }

  func reset() {
    silenceTask?.cancel()
    silenceTask = nil
    speculativeAnswerID = nil
    policy = AutoTriggerPolicy(config: currentConfig())
  }

  func handle(_ update: TranscriptUpdate, accepted: Bool) {
    policy.config = currentConfig()
    for action in policy.handle(update, accepted: accepted, now: Date()) {
      switch action {
      case .fire(let speculative):
        fire(speculative: speculative)
      case .cancelSpeculative:
        if let id = speculativeAnswerID { assistant.discard(id) }
        speculativeAnswerID = nil
      case .scheduleSilenceCheck(let delay):
        scheduleSilenceCheck(after: delay)
      }
    }
    if policy.speculativeUtterance == nil {
      speculativeAnswerID = nil
    }
  }

  func noteManualAsk() {
    policy.noteManualAnswer()
    silenceTask?.cancel()
    silenceTask = nil
    speculativeAnswerID = nil
  }

  // MARK: - Private

  private func currentConfig() -> AutoTriggerPolicy.Config {
    AutoTriggerPolicy.Config(
      isEnabled: settings.autoAnswer && settings.isProviderConfigured && !AlwaysOnState.shared.isPaused,
      answerQuestionsImmediately: settings.answerQuestionsImmediately,
      silenceDelay: settings.autoAnswerSilence
    )
  }

  private func fire(speculative: Bool) {
    guard currentConfig().isEnabled else { return }
    // Never interrupt an answer the user explicitly asked for.
    guard assistant.currentTrigger != .manual else { return }
    silenceTask?.cancel()
    silenceTask = nil
    let id = assistant.ask(trigger: .auto)
    speculativeAnswerID = speculative ? id : nil
  }

  private func scheduleSilenceCheck(after delay: TimeInterval) {
    silenceTask?.cancel()
    silenceTask = Task { [weak self] in
      var wait = delay
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(max(wait, 0.05)))
        guard !Task.isCancelled, let self else { return }
        self.policy.config = self.currentConfig()
        switch self.policy.silenceCheck(now: Date()) {
        case .fire:
          self.fire(speculative: false)
          return
        case .wait(let more):
          wait = more
        case .none:
          return
        }
      }
    }
  }
}
