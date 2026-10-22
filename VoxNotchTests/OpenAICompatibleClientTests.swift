//
//  OpenAICompatibleClientTests.swift
//  VoxNotchTests
//

import XCTest
@testable import VoxNotch

final class OpenAICompatibleClientTests: XCTestCase {

  private func config(baseURL: String = "https://api.example.com/v1", apiKey: String = "sk-test") -> OpenAICompatibleConfig {
    OpenAICompatibleConfig(baseURL: baseURL, apiKey: apiKey, model: "m1", temperature: 0.3, maxTokens: 256)
  }

  // MARK: - SSE

  func testParsesContentDelta() {
    let line = #"data: {"id":"x","choices":[{"index":0,"delta":{"content":"Hel"}}]}"#
    XCTAssertEqual(OpenAICompatibleClient.parseSSELine(line), .delta("Hel"))
  }

  func testParsesDeltaWithoutSpaceAfterColon() {
    let line = #"data:{"choices":[{"delta":{"content":"lo"}}]}"#
    XCTAssertEqual(OpenAICompatibleClient.parseSSELine(line), .delta("lo"))
  }

  func testDoneMarker() {
    XCTAssertEqual(OpenAICompatibleClient.parseSSELine("data: [DONE]"), .done)
  }

  func testIgnoresRoleOnlyEmptyAndUsageChunks() {
    XCTAssertEqual(OpenAICompatibleClient.parseSSELine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), .ignored)
    XCTAssertEqual(OpenAICompatibleClient.parseSSELine(#"data: {"choices":[],"usage":{"total_tokens":3}}"#), .ignored)
    XCTAssertEqual(OpenAICompatibleClient.parseSSELine(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#), .ignored)
    XCTAssertEqual(OpenAICompatibleClient.parseSSELine(": keep-alive"), .ignored)
    XCTAssertEqual(OpenAICompatibleClient.parseSSELine(""), .ignored)
  }

  func testMidStreamError() {
    let line = #"data: {"error":{"message":"context length exceeded"}}"#
    XCTAssertEqual(OpenAICompatibleClient.parseSSELine(line), .error("context length exceeded"))
  }

  // MARK: - Endpoint

  func testEndpointNormalizesTrailingSlashesAndWhitespace() throws {
    let url = try config(baseURL: "  https://api.example.com/v1// ").endpoint("/chat/completions")
    XCTAssertEqual(url.absoluteString, "https://api.example.com/v1/chat/completions")
  }

  func testEndpointRejectsInvalidURLs() {
    XCTAssertThrowsError(try config(baseURL: "").endpoint("/models"))
    XCTAssertThrowsError(try config(baseURL: "api.example.com/v1").endpoint("/models"))
    XCTAssertThrowsError(try config(baseURL: "ftp://example.com").endpoint("/models"))
  }

  // MARK: - Request

  func testChatRequestShape() throws {
    let request = try OpenAICompatibleClient.makeChatRequest(
      messages: [ChatMessage(role: .system, content: "s"), ChatMessage(role: .user, content: "u")],
      config: config()
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

    let body = try XCTUnwrap(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    XCTAssertEqual(body["model"] as? String, "m1")
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(body["max_tokens"] as? Int, 256)
    XCTAssertNil(body["max_completion_tokens"])
    XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] }, ["system", "user"])
  }

  func testNoAuthHeaderWithoutKey() throws {
    let request = try OpenAICompatibleClient.makeChatRequest(messages: [], config: config(apiKey: ""))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
  }

  func testAdjustedShapeForReasoningModelErrors() throws {
    let maxTokensError = Data(#"{"error":{"message":"Unsupported parameter: 'max_tokens'. Use 'max_completion_tokens'."}}"#.utf8)
    let step1 = try XCTUnwrap(OpenAICompatibleClient.adjustedShape(.init(), forErrorBody: maxTokensError))
    XCTAssertTrue(step1.useMaxCompletionTokens)

    let temperatureError = Data(#"{"error":{"message":"Unsupported value: 'temperature' does not support 0.3"}}"#.utf8)
    let step2 = try XCTUnwrap(OpenAICompatibleClient.adjustedShape(step1, forErrorBody: temperatureError))
    XCTAssertTrue(step2.omitTemperature)

    let request = try OpenAICompatibleClient.makeChatRequest(messages: [], config: config(), shape: step2)
    let body = try XCTUnwrap(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    XCTAssertNil(body["max_tokens"])
    XCTAssertNil(body["temperature"])
    XCTAssertEqual(body["max_completion_tokens"] as? Int, 256)

    XCTAssertNil(OpenAICompatibleClient.adjustedShape(step2, forErrorBody: Data("bad request".utf8)))
  }

  // MARK: - Errors

  func testHTTPErrorUsesServerMessage() {
    let body = Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8)
    XCTAssertEqual(OpenAICompatibleClient.httpError(status: 401, body: body).detailedDescription, "401: Incorrect API key provided")
    if case .rateLimited = OpenAICompatibleClient.httpError(status: 429, body: Data()) {} else {
      XCTFail("429 should map to rateLimited")
    }
  }
}
