//
//  TranscriptionServiceTests.swift
//  VoxNotchTests
//

import XCTest
@testable import VoxNotch

/// Spy provider that records calls without performing real transcription
final class SpyTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
  let name: String
  var isReady: Bool { get async { isReadyValue } }

  var isReadyValue = true
  var unloadCallCount = 0
  var onTranscribe: (() async -> Void)?
  func unloadModel() { unloadCallCount += 1 }
  var transcribeCallCount = 0
  var lastAudioURL: URL?
  var lastLanguage: String?
  var stubbedResult: TranscriptionResult?
  var stubbedError: Error?

  init(name: String = "Spy") {
    self.name = name
  }

  func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
    transcribeCallCount += 1
    lastAudioURL = audioURL
    lastLanguage = language
    await onTranscribe?()
    if let error = stubbedError { throw error }
    return stubbedResult ?? TranscriptionResult(
      text: "test transcription",
      confidence: 0.95,
      audioDuration: 1.0,
      processingTime: 0.1,
      provider: name,
      language: language,
      segments: nil
    )
  }
}

@MainActor
final class TranscriptionServiceTests: XCTestCase {

  func testMemoryPressureKeepsActiveInferenceAndReleasesIdleProvider() async throws {
    let service = TranscriptionService.shared
    service.cancelStreaming()
    let spy = SpyTranscriptionProvider()
    service.setPrimaryProvider(spy)
    defer { service.reconfigure() }
    let entered = expectation(description: "inference entered")
    var resume: CheckedContinuation<Void, Never>?
    spy.onTranscribe = {
      await withCheckedContinuation { continuation in
        resume = continuation
        entered.fulfill()
      }
    }
    let wav = createMinimalWAV()
    defer { try? FileManager.default.removeItem(at: wav) }
    let task = Task { try await service.transcribe(audioURL: wav) }
    await fulfillment(of: [entered], timeout: 2)
    // Real memory-pressure notifications may have evicted this idle spy before
    // inference began; assert changes only within the phase under test.
    let activeBaseline = spy.unloadCallCount
    service.unloadIfIdle(idleFor: 0)
    XCTAssertEqual(spy.unloadCallCount, activeBaseline)
    resume?.resume()
    _ = try await task.value
    let idleBaseline = spy.unloadCallCount
    service.unloadIfIdle(idleFor: 0)
    XCTAssertEqual(spy.unloadCallCount, idleBaseline + 1)
  }

  // MARK: - Provider Routing

  func testSetPrimaryProviderIsUsedForTranscription() async throws {
    let service = TranscriptionService.shared
    let spy = SpyTranscriptionProvider(name: "TestSpy")
    service.setPrimaryProvider(spy)

    let wavURL = createMinimalWAV()
    defer { try? FileManager.default.removeItem(at: wavURL) }

    let result = try await service.transcribe(audioURL: wavURL)

    XCTAssertEqual(spy.transcribeCallCount, 1)
    XCTAssertEqual(result.provider, "TestSpy")
    XCTAssertEqual(result.text, "test transcription")
  }

  func testTranscribeRejectsNonexistentFile() async {
    let service = TranscriptionService.shared
    service.setPrimaryProvider(SpyTranscriptionProvider())

    let fakeURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).wav")

    do {
      _ = try await service.transcribe(audioURL: fakeURL)
      XCTFail("Should have thrown fileNotFound")
    } catch {
      XCTAssertTrue(error is TranscriptionError, "Expected TranscriptionError, got \(type(of: error))")
      if case TranscriptionError.fileNotFound = error {} else {
        XCTFail("Expected .fileNotFound, got \(error)")
      }
    }
  }

  func testTranscribeRejectsTinyFile() async throws {
    let service = TranscriptionService.shared
    service.setPrimaryProvider(SpyTranscriptionProvider())

    let tinyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("tiny_\(UUID().uuidString).wav")
    try Data(count: 100).write(to: tinyURL)
    defer { try? FileManager.default.removeItem(at: tinyURL) }

    do {
      _ = try await service.transcribe(audioURL: tinyURL)
      XCTFail("Should have thrown fileTooSmall")
    } catch {
      XCTAssertTrue(error is TranscriptionError, "Expected TranscriptionError, got \(type(of: error))")
      if case TranscriptionError.fileTooSmall = error {} else {
        XCTFail("Expected .fileTooSmall, got \(error)")
      }
    }
  }

  func testCurrentProviderNameReflectsSetProvider() {
    let service = TranscriptionService.shared
    let spy = SpyTranscriptionProvider(name: "CustomEngine")
    service.setPrimaryProvider(spy)
    XCTAssertEqual(service.currentProviderName, "CustomEngine")
  }

  // MARK: - Error Messages

  func testErrorMessagesAreShort() {
    let errors: [TranscriptionError] = [
      .providerNotReady, .fileNotFound, .invalidFormat,
      .fileTooSmall, .fileCorrupted, .audioTooShort,
      .noSpeechDetected, .modelNotLoaded, .timeout,
      .transcriptionFailed("some underlying error"),
    ]
    for error in errors {
      let desc = error.errorDescription ?? ""
      XCTAssertLessThanOrEqual(
        desc.count, 40,
        "Error '\(error)' description too long for notch: \"\(desc)\" (\(desc.count) chars)"
      )
    }
  }

  func testAllErrorsHaveRecoverySuggestion() {
    let errors: [TranscriptionError] = [
      .providerNotReady, .fileNotFound, .invalidFormat,
      .fileTooSmall, .fileCorrupted, .audioTooShort,
      .noSpeechDetected, .modelNotLoaded, .timeout,
      .transcriptionFailed("some error"),
    ]
    for error in errors {
      XCTAssertNotNil(
        error.recoverySuggestion,
        "Error '\(error)' is missing a recoverySuggestion"
      )
    }
  }

  func testErrorMessagesAreUserFriendly() {
    let errors: [TranscriptionError] = [
      .providerNotReady, .invalidFormat, .fileCorrupted,
      .transcriptionFailed("engine error"), .modelNotLoaded,
    ]
    let jargon = ["FluidAudio", "MLX", "16kHz", "mono", "Float32", "provider", "engine"]
    for error in errors {
      let desc = (error.errorDescription ?? "") + (error.recoverySuggestion ?? "")
      for term in jargon {
        XCTAssertFalse(
          desc.contains(term),
          "Error '\(error)' contains developer jargon '\(term)': \"\(desc)\""
        )
      }
    }
  }

  // MARK: - Helpers

  /// Create a minimal valid WAV file (44-byte header + 2000 bytes of silence)
  private func createMinimalWAV() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("test_\(UUID().uuidString).wav")

    var header = Data()
    let dataSize: UInt32 = 2000
    let fileSize: UInt32 = 36 + dataSize

    header.append(contentsOf: "RIFF".utf8)
    header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
    header.append(contentsOf: "WAVE".utf8)

    header.append(contentsOf: "fmt ".utf8)
    header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
    header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
    header.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Array($0) })
    header.append(contentsOf: withUnsafeBytes(of: UInt32(32000).littleEndian) { Array($0) })
    header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
    header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })

    header.append(contentsOf: "data".utf8)
    header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
    header.append(Data(count: Int(dataSize)))

    try! header.write(to: url)
    return url
  }
}
