import Foundation

/// An explicit allowlist of view data. Provider credentials, prompts, audio and
/// persisted history are never part of the phone connection.
nonisolated struct MobileCompanionSnapshot: Codable, Equatable, Sendable {
  struct Transcript: Codable, Equatable, Sendable {
    let id: String
    let source: String
    let text: String
    let isFinal: Bool
  }

  struct Answer: Codable, Equatable, Sendable {
    let id: String
    let markdown: String
    let template: String
    let model: String
    let status: String
    let error: String?
    let retryCount: Int
  }

  let sessionID: String
  let status: String
  let message: String
  let isPaused: Bool
  let startedAt: Double?
  let sources: [String]
  let transcript: [Transcript]
  let answers: [Answer]
  let displayedAnswerID: String?

  @MainActor init(state: AlwaysOnState) {
    sessionID = state.sessionID
    isPaused = state.isPaused
    startedAt = state.startedAt?.timeIntervalSince1970
    sources = state.activeSources.map(\.rawValue).sorted()
    switch state.status {
    case .idle: status = "idle"; message = "Always-On stopped"
    case .preparing: status = "preparing"; message = state.preparingMessage
    case .running: status = "running"; message = state.isPaused ? "Paused" : "Live"
    case .failed(let error): status = "failed"; message = error
    }
    transcript = state.displayRows.map {
      Transcript(id: $0.id.uuidString, source: $0.source.rawValue, text: $0.text, isFinal: $0.isFinal)
    }
    answers = state.answers.map { answer in
      let status: String
      let error: String?
      switch answer.status {
      case .waiting: status = "waiting"; error = nil
      case .streaming: status = "streaming"; error = nil
      case .done: status = "done"; error = nil
      case .stopped: status = "stopped"; error = nil
      case .failed(let message): status = "failed"; error = message
      }
      return Answer(id: answer.id.uuidString, markdown: answer.markdown, template: answer.templateName,
                    model: answer.model, status: status, error: error, retryCount: answer.retryCount)
    }
    displayedAnswerID = state.displayedAnswer?.id.uuidString
  }
}
