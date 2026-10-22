//
//  AssistantService.swift
//  VoxNotch
//
//  Sends the live transcript to the OpenAI-compatible provider and streams the
//  answer into AlwaysOnState. One request at a time: a new ask cancels the old.
//

import Foundation
import os

@MainActor
final class AssistantService {

  typealias StreamFactory = @Sendable ([ChatMessage], OpenAICompatibleConfig) -> AsyncThrowingStream<String, Error>

  static let shared = AssistantService()

  private let state: AlwaysOnState
  private let settings: AssistantSettings
  private let historyStore: AlwaysOnHistoryStore
  private let makeStream: StreamFactory
  private let logger = Logger(subsystem: "com.voxnotch", category: "AssistantService")

  private var currentTask: Task<Void, Never>?
  private var currentBuffer: StreamBuffer?
  private var currentSessionID: String?
  private(set) var currentAnswerID: UUID?
  private(set) var currentTrigger: AssistantAnswer.Trigger?

  /// UI refresh cadence for streamed text (~30fps).
  private static let flushInterval = Duration.milliseconds(33)

  init(
    state: AlwaysOnState? = nil,
    settings: AssistantSettings? = nil,
    historyStore: AlwaysOnHistoryStore? = nil,
    makeStream: @escaping StreamFactory = { OpenAICompatibleClient.shared.streamChat(messages: $0, config: $1) }
  ) {
    self.state = state ?? .shared
    self.settings = settings ?? .shared
    self.historyStore = historyStore ?? .shared
    self.makeStream = makeStream
  }

  var isAnswering: Bool { currentTask != nil }

  @discardableResult
  func ask(trigger: AssistantAnswer.Trigger) -> UUID? {
    stop()

    let config = settings.providerConfig
    var answer = AssistantAnswer(id: UUID(), createdAt: Date(), trigger: trigger, model: config.model)
    guard settings.isProviderConfigured else {
      answer.status = .failed("Set up an AI provider in Settings first.")
      state.appendAnswer(answer)
      return nil
    }

    // Partials are included directly, so the request doesn't wait for finalization;
    // flushing just makes the transcript pane settle sooner.
    if trigger == .manual {
      Task { await AlwaysOnController.shared.flushPendingSpeech() }
    }

    let messages = AssistantPromptBuilder.messages(
      systemPrompt: settings.systemPrompt,
      recognitionHints: settings.selectedTemplate.recognitionHints,
      customTerms: settings.customTermList,
      transcript: state.displayRows,
      previousAnswers: settings.includePreviousAnswers ? state.answers : [],
      trigger: trigger,
      now: Date(),
      window: settings.contextWindowMinutes * 60
    )
    answer.templateName = settings.selectedTemplate.name

    state.appendAnswer(answer)
    currentAnswerID = answer.id
    currentTrigger = trigger
    let sessionID = state.sessionID
    currentSessionID = sessionID
    let stream = makeStream(messages, config)
    currentTask = Task { await run(answerID: answer.id, sessionID: sessionID, stream: stream) }
    return answer.id
  }

  /// Cancels the answer if it's still running and removes it (used for speculative answers).
  func discard(_ id: UUID) {
    if currentAnswerID == id {
      currentTask?.cancel()
      currentTask = nil
      currentBuffer = nil
      currentSessionID = nil
      currentAnswerID = nil
      currentTrigger = nil
    }
    state.removeAnswer(id)
    historyStore.deleteAnswer(id)
  }

  func stop() {
    let answerID = currentAnswerID
    let sessionID = currentSessionID
    currentBuffer?.flush()
    currentTask?.cancel()
    currentTask = nil
    currentBuffer = nil
    if let id = answerID {
      state.updateAnswer(id) { answer in
        if answer.isInProgress { answer.status = .stopped }
      }
      if let sessionID, let answer = state.answers.first(where: { $0.id == id }) {
        historyStore.recordAnswer(answer, sessionID: sessionID)
      }
    }
    currentAnswerID = nil
    currentTrigger = nil
    currentSessionID = nil
  }

  func retry(_ answer: AssistantAnswer) {
    ask(trigger: answer.trigger)
  }

  // MARK: - Streaming

  private func run(answerID: UUID, sessionID: String, stream: AsyncThrowingStream<String, Error>) async {
    defer {
      if currentAnswerID == answerID {
        currentTask = nil
        currentAnswerID = nil
        currentTrigger = nil
        currentBuffer = nil
        currentSessionID = nil
      }
    }
    guard currentAnswerID == answerID, state.sessionID == sessionID, !Task.isCancelled else { return }
    let clock = ContinuousClock()
    let start = clock.now
    let buffer = StreamBuffer(interval: Self.flushInterval) { [weak self] text in
      guard let self, self.currentAnswerID == answerID, self.state.sessionID == sessionID else { return }
      self.state.updateAnswer(answerID) { $0.markdown = text }
    }
    currentBuffer = buffer

    do {
      for try await delta in stream {
        try Task.checkCancellation()
        guard currentAnswerID == answerID, state.sessionID == sessionID else { return }
        if buffer.text.isEmpty {
          let latency = clock.now - start
          state.updateAnswer(answerID) {
            $0.status = .streaming
            $0.firstTokenLatency = latency
          }
          logger.info("[latency] first token \(Self.ms(latency))ms")
        }
        buffer.append(delta)
      }
      try Task.checkCancellation()
      guard currentAnswerID == answerID, state.sessionID == sessionID else { return }
      buffer.flush()
      let isEmpty = buffer.text.isEmpty
      state.updateAnswer(answerID) { $0.status = isEmpty ? .failed("The model returned an empty answer.") : .done }
      logger.info("[latency] answer complete \(Self.ms(clock.now - start))ms chars=\(buffer.text.count)")
    } catch {
      guard currentAnswerID == answerID, state.sessionID == sessionID else { return }
      buffer.flush()
      state.updateAnswer(answerID) { answer in
        if error is CancellationError || Task.isCancelled {
          answer.status = .stopped
        } else {
          answer.status = .failed((error as? LLMError)?.detailedDescription ?? error.localizedDescription)
        }
      }
    }

    if let answer = state.answers.first(where: { $0.id == answerID }) {
      historyStore.recordAnswer(answer, sessionID: sessionID)
    }
  }

  private static func ms(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}

/// Accumulates streamed text and publishes it at most once per `interval`,
/// always delivering the latest text (trailing flush).
@MainActor
private final class StreamBuffer {
  private(set) var text = ""
  private let interval: Duration
  private let publish: (String) -> Void
  private let clock = ContinuousClock()
  private var lastFlush: ContinuousClock.Instant
  private var pending: Task<Void, Never>?

  init(interval: Duration, publish: @escaping (String) -> Void) {
    self.interval = interval
    self.publish = publish
    lastFlush = clock.now
  }

  func append(_ delta: String) {
    text += delta
    let elapsed = clock.now - lastFlush
    if elapsed >= interval {
      flush()
    } else if pending == nil {
      pending = Task { [weak self, interval] in
        try? await Task.sleep(for: interval - elapsed)
        guard !Task.isCancelled else { return }
        self?.flush()
      }
    }
  }

  func flush() {
    pending?.cancel()
    pending = nil
    lastFlush = clock.now
    publish(text)
  }
}
