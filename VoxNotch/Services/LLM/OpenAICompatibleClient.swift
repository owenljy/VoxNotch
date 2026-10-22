//
//  OpenAICompatibleClient.swift
//  VoxNotch
//
//  Streaming client for any OpenAI-compatible `/chat/completions` endpoint
//  (OpenAI, OpenRouter, Groq, DeepSeek, LM Studio, Ollama `/v1`, ...).
//

import Foundation
import os

// MARK: - Types

nonisolated struct ChatMessage: Encodable, Sendable, Equatable {
  enum Role: String, Encodable, Sendable {
    case system, user, assistant
  }

  let role: Role
  let content: String
}

nonisolated struct OpenAICompatibleConfig: Sendable, Equatable {
  var baseURL: String
  var apiKey: String
  var model: String
  var temperature: Double
  var maxTokens: Int

  func endpoint(_ path: String) throws -> URL {
    var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    guard let url = URL(string: base + path),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host?.isEmpty == false
    else { throw LLMError.invalidURL }
    return url
  }
}

nonisolated enum SSEEvent: Equatable {
  case delta(String)
  case done
  case error(String)
  case ignored
}

nonisolated struct ConnectionTestResult: Sendable {
  let firstTokenLatency: Duration
  let reply: String
}

// MARK: - Client

nonisolated final class OpenAICompatibleClient: Sendable {

  static let shared = OpenAICompatibleClient()

  /// Parameter variants some models require (e.g. OpenAI reasoning models
  /// reject `max_tokens` and custom `temperature`). Learned from 400 responses
  /// and remembered per endpoint+model so only the first request pays a retry.
  struct RequestShape: Sendable, Hashable {
    var useMaxCompletionTokens = false
    var omitTemperature = false
  }

  private let session: URLSession
  private let learnedShapes = OSAllocatedUnfairLock<[String: RequestShape]>(initialState: [:])
  private let logger = Logger(subsystem: "com.voxnotch", category: "OpenAICompatibleClient")

  init(session: URLSession? = nil) {
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.default
      configuration.timeoutIntervalForRequest = 30
      configuration.timeoutIntervalForResource = 300
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.urlCache = nil
      self.session = URLSession(configuration: configuration)
    }
  }

  // MARK: - Chat

  /// Streams content deltas. Cancelling the consuming task cancels the request.
  func streamChat(messages: [ChatMessage], config: OpenAICompatibleConfig) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let bytes = try await openStream(messages: messages, config: config)
          for try await line in bytes.lines {
            switch Self.parseSSELine(line) {
            case .delta(let text):
              continuation.yield(text)
            case .done:
              continuation.finish()
              return
            case .error(let message):
              throw LLMError.apiError(message)
            case .ignored:
              continue
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: Self.normalize(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func openStream(messages: [ChatMessage], config: OpenAICompatibleConfig) async throws -> URLSession.AsyncBytes {
    let shapeKey = "\(config.baseURL)|\(config.model)"
    var shape = learnedShapes.withLock { $0[shapeKey] } ?? RequestShape()

    for _ in 0..<3 {
      let request = try Self.makeChatRequest(messages: messages, config: config, shape: shape)
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
      if (200..<300).contains(http.statusCode) { return bytes }

      let body = try await Self.collect(bytes)
      if http.statusCode == 400, let adjusted = Self.adjustedShape(shape, forErrorBody: body) {
        logger.info("Retrying with adjusted request shape for model \(config.model, privacy: .public)")
        shape = adjusted
        learnedShapes.withLock { $0[shapeKey] = adjusted }
        continue
      }
      throw Self.httpError(status: http.statusCode, body: body)
    }
    throw LLMError.invalidResponse
  }

  // MARK: - Models / Warm-up / Test

  func listModels(config: OpenAICompatibleConfig) async throws -> [String] {
    var request = URLRequest(url: try config.endpoint("/models"))
    Self.applyAuth(to: &request, apiKey: config.apiKey)
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
      guard (200..<300).contains(http.statusCode) else {
        throw Self.httpError(status: http.statusCode, body: data)
      }
      let list = try JSONDecoder().decode(ModelList.self, from: data)
      return list.data.map(\.id).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    } catch {
      throw Self.normalize(error)
    }
  }

  /// Opens the TLS/HTTP2 connection ahead of time so the first real request skips the handshake.
  func warmUp(config: OpenAICompatibleConfig) {
    Task.detached(priority: .utility) { [self] in
      _ = try? await listModels(config: config)
    }
  }

  func testConnection(config: OpenAICompatibleConfig) async throws -> ConnectionTestResult {
    let clock = ContinuousClock()
    let start = clock.now
    var firstTokenLatency: Duration?
    var reply = ""
    let stream = streamChat(
      messages: [ChatMessage(role: .user, content: "Reply with exactly: OK")],
      config: config
    )
    for try await delta in stream {
      if firstTokenLatency == nil { firstTokenLatency = clock.now - start }
      reply += delta
      if reply.count > 200 { break }
    }
    guard let firstTokenLatency else { throw LLMError.invalidResponse }
    return ConnectionTestResult(firstTokenLatency: firstTokenLatency, reply: reply)
  }

  // MARK: - Request Building

  static func makeChatRequest(
    messages: [ChatMessage],
    config: OpenAICompatibleConfig,
    shape: RequestShape = RequestShape()
  ) throws -> URLRequest {
    var request = URLRequest(url: try config.endpoint("/chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    applyAuth(to: &request, apiKey: config.apiKey)

    request.httpBody = try JSONEncoder().encode(
      ChatRequestBody(
        model: config.model,
        messages: messages,
        stream: true,
        temperature: shape.omitTemperature ? nil : config.temperature,
        maxTokens: shape.useMaxCompletionTokens ? nil : config.maxTokens,
        maxCompletionTokens: shape.useMaxCompletionTokens ? config.maxTokens : nil
      )
    )
    return request
  }

  private static func applyAuth(to request: inout URLRequest, apiKey: String) {
    guard !apiKey.isEmpty else { return }
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
  }

  static func adjustedShape(_ shape: RequestShape, forErrorBody body: Data) -> RequestShape? {
    let text = String(decoding: body, as: UTF8.self).lowercased()
    var adjusted = shape
    if !shape.useMaxCompletionTokens, text.contains("max_tokens") {
      adjusted.useMaxCompletionTokens = true
    } else if !shape.omitTemperature, text.contains("temperature") {
      adjusted.omitTemperature = true
    }
    return adjusted == shape ? nil : adjusted
  }

  // MARK: - Parsing

  static func parseSSELine(_ line: String) -> SSEEvent {
    guard line.hasPrefix("data:") else { return .ignored }
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    if payload == "[DONE]" { return .done }
    guard let data = payload.data(using: .utf8),
          let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data)
    else { return .ignored }

    if let error = chunk.error { return .error(error.message ?? "Unknown error") }
    guard let content = chunk.choices?.first?.delta?.content, !content.isEmpty else { return .ignored }
    return .delta(content)
  }

  static func httpError(status: Int, body: Data) -> LLMError {
    if status == 429 { return .rateLimited }
    let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error.message
      ?? String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = HTTPURLResponse.localizedString(forStatusCode: status)
    return .apiError("\(status): \(message.isEmpty ? fallback : message)")
  }

  private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int = 65_536) async throws -> Data {
    var data = Data()
    for try await byte in bytes {
      data.append(byte)
      if data.count >= limit { break }
    }
    return data
  }

  private static func normalize(_ error: Error) -> Error {
    switch error {
    case is CancellationError, is LLMError:
      return error
    case let urlError as URLError where urlError.code == .cancelled:
      return CancellationError()
    case let urlError as URLError where urlError.code == .timedOut:
      return LLMError.timeout
    default:
      return LLMError.networkError(error)
    }
  }

  // MARK: - Wire Types

  private struct ChatRequestBody: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let temperature: Double?
    let maxTokens: Int?
    let maxCompletionTokens: Int?

    enum CodingKeys: String, CodingKey {
      case model, messages, stream, temperature
      case maxTokens = "max_tokens"
      case maxCompletionTokens = "max_completion_tokens"
    }
  }

  private struct StreamChunk: Decodable {
    struct Choice: Decodable {
      struct Delta: Decodable { let content: String? }
      let delta: Delta?
    }
    struct APIError: Decodable { let message: String? }

    let choices: [Choice]?
    let error: APIError?
  }

  private struct ErrorEnvelope: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
  }

  private struct ModelList: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
  }
}
