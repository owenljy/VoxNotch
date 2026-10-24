//
//  AssistantAnswer.swift
//  VoxNotch
//
//  One AI answer in the Always-On panel.
//

import Foundation

nonisolated struct AssistantAnswer: Identifiable, Equatable, Sendable {

  enum Trigger: String, Sendable {
    case manual
    case auto
  }

  enum Status: Equatable, Sendable {
    case waiting
    case streaming
    case done
    case stopped
    case failed(String)
  }

  let id: UUID
  let createdAt: Date
  let trigger: Trigger
  var model: String
  var retryCount = 0
  var templateName = ""
  var markdown: String = ""
  var status: Status = .waiting
  var firstTokenLatency: Duration?

  var isInProgress: Bool {
    status == .waiting || status == .streaming
  }
}
