import Foundation
import os
import XCTest
@testable import VoxNotch

@MainActor
final class FirstTokenRetryTests: XCTestCase {
  private let primary = OpenAICompatibleConfig(
    baseURL: "https://example.invalid/v1", apiKey: "test", model: "primary", temperature: 0.3, maxTokens: 100)

  private func eventually(_ condition: @escaping () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        XCTFail("Timed out waiting for test condition")
        throw URLError(.timedOut)
      }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private func consume(_ stream: AsyncThrowingStream<String, Error>) -> Task<String, Error> {
    Task {
      var text = ""
      for try await delta in stream { text += delta }
      try Task.checkCancellation()
      return text
    }
  }

  func testDeadlineCancelsStalledRequestAndUsesFallbackWithoutLeakingWhitespaceOrLateText() async throws {
    let clock = ManualFirstTokenDeadline()
    let harness = FirstTokenStreamHarness()
    var backup = primary
    backup.model = "backup"
    let task = consume(FirstTokenRetryStream.stream(
      messages: [.init(role: .user, content: "question")], primary: primary, retry: backup,
      timeout: .seconds(1.5), makeStream: { harness.stream($0, $1) }, sleep: { try await clock.sleep($0) }))
    try await eventually { let pending = await clock.pendingCount; return harness.count == 1 && pending == 1 }
    harness.yield(" \n", attempt: 0)
    await clock.fire()
    try await eventually { harness.count == 2 }
    XCTAssertTrue(harness.isTerminated(0), "Old stream must be cancelled before retry starts")
    harness.yield("stale", attempt: 0)
    harness.yield("backup answer", attempt: 1)
    harness.finish(attempt: 1)
    let text = try await task.value
    XCTAssertEqual(text, "backup answer")
    XCTAssertEqual(harness.configs.map(\.model), ["primary", "backup"])
    XCTAssertEqual(harness.messages[0], harness.messages[1])
    XCTAssertEqual(harness.configs[1].apiKey, primary.apiKey)
    let deadlines = await clock.durations
    XCTAssertTrue(deadlines.allSatisfy { $0 == .seconds(1.5) })
  }

  func testSecondDeadlineFailsWithoutAThirdAttempt() async throws {
    let clock = ManualFirstTokenDeadline()
    let harness = FirstTokenStreamHarness()
    let task = consume(FirstTokenRetryStream.stream(
      messages: [], primary: primary, retry: primary, timeout: .seconds(1.5),
      makeStream: { harness.stream($0, $1) }, sleep: { try await clock.sleep($0) }))
    try await eventually { let pending = await clock.pendingCount; return harness.count == 1 && pending == 1 }
    await clock.fire()
    try await eventually { let pending = await clock.pendingCount; return harness.count == 2 && pending == 1 }
    await clock.fire()
    do {
      _ = try await task.value
      XCTFail("Both attempts should time out")
    } catch {
      XCTAssertTrue(error is FirstTokenRetryStream.TimedOut)
    }
    XCTAssertEqual(harness.count, 2)
    XCTAssertTrue(harness.isTerminated(1))
  }

  func testFirstTextDisarmsDeadlineWithoutTruncatingSlowRemainingAnswer() async throws {
    let clock = ManualFirstTokenDeadline()
    let harness = FirstTokenStreamHarness()
    let received = OSAllocatedUnfairLock(initialState: "")
    let stream = FirstTokenRetryStream.stream(
      messages: [], primary: primary, retry: primary, timeout: .seconds(1.5),
      makeStream: { harness.stream($0, $1) }, sleep: { try await clock.sleep($0) })
    let task = Task {
      for try await delta in stream { received.withLock { $0 += delta } }
    }
    try await eventually { let pending = await clock.pendingCount; return harness.count == 1 && pending == 1 }
    harness.yield("Hello", attempt: 0)
    try await eventually { received.withLock { $0 == "Hello" } }
    await clock.fire()
    await Task.yield()
    XCTAssertFalse(harness.isTerminated(0))
    harness.yield(" world", attempt: 0)
    harness.finish(attempt: 0)
    try await task.value
    XCTAssertEqual(received.withLock { $0 }, "Hello world")
    XCTAssertEqual(harness.count, 1)
  }

  func testCancellationBeforeDeadlineDoesNotRetry() async throws {
    let clock = ManualFirstTokenDeadline()
    let harness = FirstTokenStreamHarness()
    let task = consume(FirstTokenRetryStream.stream(
      messages: [], primary: primary, retry: primary, timeout: .seconds(1.5),
      makeStream: { harness.stream($0, $1) }, sleep: { try await clock.sleep($0) }))
    try await eventually { let pending = await clock.pendingCount; return harness.count == 1 && pending == 1 }
    task.cancel()
    _ = await task.result
    try await eventually { let pending = await clock.pendingCount; return harness.isTerminated(0) && pending == 0 }
    XCTAssertEqual(harness.count, 1)
  }

  func testAPIRejectionDoesNotRetryOrReplaceModel() async throws {
    let harness = FirstTokenStreamHarness()
    let task = consume(FirstTokenRetryStream.stream(
      messages: [], primary: primary, retry: primary, timeout: .seconds(1.5),
      makeStream: { harness.stream($0, $1) }))
    try await eventually { harness.count == 1 }
    harness.finish(attempt: 0, error: LLMError.apiError("401: bad key"))
    do {
      _ = try await task.value
      XCTFail("API rejection must be surfaced")
    } catch {
      XCTAssertEqual((error as? LLMError)?.detailedDescription, "401: bad key")
    }
    XCTAssertEqual(harness.count, 1)
  }

  func testFallbackKeepsProviderAndRecalculatesAutomaticReasoningEffort() {
    let settings = AssistantSettings.shared
    let oldFallback = settings.fallbackModel
    let oldEffort = settings.reasoningEffort
    defer { settings.fallbackModel = oldFallback; settings.reasoningEffort = oldEffort }
    settings.reasoningEffort = .automatic
    settings.fallbackModel = "  openai/gpt-oss-20b\n"
    let backup = settings.retryConfig(primary: primary)
    XCTAssertEqual(backup.model, "openai/gpt-oss-20b")
    XCTAssertEqual(backup.baseURL, primary.baseURL)
    XCTAssertEqual(backup.apiKey, primary.apiKey)
    XCTAssertEqual(backup.reasoningEffort, "low")
    settings.fallbackModel = " \n"
    XCTAssertEqual(settings.retryConfig(primary: primary), primary)
    XCTAssertEqual(AssistantSettings.normalizedFirstTokenTimeout(.nan), 1.5)
  }

  func testDeadlineCancelsURLSessionThatNeverReturnsHeaders() async throws {
    let clock = ManualFirstTokenDeadline()
    StalledFirstTokenURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StalledFirstTokenURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = OpenAICompatibleClient(session: session)
    var backup = primary
    backup.model = "backup"
    let task = consume(FirstTokenRetryStream.stream(
      messages: [.init(role: .user, content: "test")], primary: primary, retry: backup,
      timeout: .seconds(1.5), makeStream: { client.streamChat(messages: $0, config: $1) },
      sleep: { try await clock.sleep($0) }))
    defer { task.cancel() }
    try await eventually {
      let pending = await clock.pendingCount
      return StalledFirstTokenURLProtocol.requestCount == 1 && pending == 1
    }
    await clock.fire()
    let text = try await task.value
    XCTAssertEqual(text, "Transport recovered")
    try await eventually { StalledFirstTokenURLProtocol.cancelledStall }
    XCTAssertEqual(StalledFirstTokenURLProtocol.requestCount, 2)
  }
}

actor ManualFirstTokenDeadline {
  private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
  private var cancelled: Set<UUID> = []
  private(set) var durations: [Duration] = []
  var pendingCount: Int { waiters.count }

  func sleep(_ duration: Duration) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if cancelled.remove(id) != nil || Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          durations.append(duration)
          waiters.append((id, continuation))
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func fire() { if !waiters.isEmpty { waiters.removeFirst().1.resume() } }

  private func cancel(_ id: UUID) {
    if let index = waiters.firstIndex(where: { $0.0 == id }) {
      waiters.remove(at: index).1.resume(throwing: CancellationError())
    } else { cancelled.insert(id) }
  }
}

final class FirstTokenStreamHarness: Sendable {
  private struct Attempt {
    let config: OpenAICompatibleConfig
    let messages: [ChatMessage]
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    var terminated = false
  }
  private let attempts = OSAllocatedUnfairLock(initialState: [Attempt]())
  var count: Int { attempts.withLock { $0.count } }
  var configs: [OpenAICompatibleConfig] { attempts.withLock { $0.map(\.config) } }
  var messages: [[ChatMessage]] { attempts.withLock { $0.map(\.messages) } }
  func isTerminated(_ index: Int) -> Bool { attempts.withLock { $0[index].terminated } }
  func yield(_ text: String, attempt: Int) { attempts.withLock { $0[attempt].continuation }.yield(text) }
  func finish(attempt: Int, error: Error? = nil) { attempts.withLock { $0[attempt].continuation }.finish(throwing: error) }

  func stream(_ messages: [ChatMessage], _ config: OpenAICompatibleConfig) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let index = attempts.withLock { value in
        value.append(Attempt(config: config, messages: messages, continuation: continuation))
        return value.count - 1
      }
      continuation.onTermination = { [attempts] _ in attempts.withLock { $0[index].terminated = true } }
    }
  }
}

private final class StalledFirstTokenURLProtocol: URLProtocol, @unchecked Sendable {
  private struct State { var requests = 0; var cancelledStall = false }
  private static let state = OSAllocatedUnfairLock(initialState: State())
  private var isStall = false
  static var requestCount: Int { state.withLock { $0.requests } }
  static var cancelledStall: Bool { state.withLock { $0.cancelledStall } }
  static func reset() { state.withLock { $0 = State() } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    isStall = Self.state.withLock { $0.requests += 1; return $0.requests == 1 }
    guard !isStall else { return } // No headers or bytes, modelling a hung provider.
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"Transport recovered\"}}]}\n\ndata: [DONE]\n\n".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    if isStall { Self.state.withLock { $0.cancelledStall = true } }
  }
}
