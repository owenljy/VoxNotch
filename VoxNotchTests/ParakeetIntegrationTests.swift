import XCTest
import FluidAudio
import AVFoundation
@testable import VoxNotch

@MainActor
final class ParakeetIntegrationTests: XCTestCase {
  func testIndependentModelRoutingAndCacheLocations() {
    let manager = FluidAudioModelManager.shared
    let versions: [FluidAudioModelVersion] = [.v2English, .unifiedEnglish, .eou120m]
    XCTAssertEqual(Set(versions.map { manager.modelDirectory(for: $0) }).count, 3)
    XCTAssertNil(FluidAudioModelVersion.unifiedEnglish.asrModelVersion)
    XCTAssertNil(FluidAudioModelVersion.eou120m.asrModelVersion)
    XCTAssertEqual(SpeechModel.parakeetUnified.fluidAudioVersion, .unifiedEnglish)
    XCTAssertEqual(SpeechModel.parakeetEOU.fluidAudioVersion, .eou120m)
    XCTAssertEqual(SpeechModel.parakeetUnified.supportedLanguages, ["en"])
    XCTAssertEqual(SpeechModel.parakeetEOU.supportedLanguages, ["en"])
    XCTAssertEqual(SpeechModel.defaultModel, .parakeetV2)
    XCTAssertFalse(FluidAudioModelVersion.v3Multilingual.supportedLanguages.contains("zh"))
  }

  func testCacheRejectsEmptyBundleMissingWeightsAndPartialDownload() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = dir.appendingPathComponent("encoder.mlmodelc")
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("weights"), withIntermediateDirectories: true)
    let required: Set<String> = ["encoder.mlmodelc", "vocab.json"]
    try Data("{}".utf8).write(to: dir.appendingPathComponent("vocab.json"))
    XCTAssertFalse(FluidModelCache.isComplete(dir, required: required))
    for file in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
      try Data([1, 2, 3]).write(to: bundle.appendingPathComponent(file))
    }
    XCTAssertTrue(FluidModelCache.isComplete(dir, required: required))
    try Data([1]).write(to: bundle.appendingPathComponent("weights/weight.bin.partial"))
    XCTAssertFalse(FluidModelCache.isComplete(dir, required: required))
  }

  func testEOUProcessesDuringRecordingAndFlushesTail() async throws {
    let processed = expectation(description: "processed before stop")
    let engine = TestEOUEngine(onProcess: { processed.fulfill() })
    let decoder = EOUDecoder(engine: engine)
    let session = EOURecordingSession { decoder }
    session.append([0.1, 0.2, 0.3])
    await fulfillment(of: [processed], timeout: 3)
    let result = try await session.finish()
    XCTAssertEqual(result.text, "3 samples")
    XCTAssertEqual(result.audioDuration, 3.0 / 16000)
    XCTAssertEqual(result.language, "en")
    let events = await engine.events
    XCTAssertEqual(events, ["reset", "process:3", "finish"])
  }

  func testEOUResetsBetweenRecordings() async throws {
    let engine = TestEOUEngine()
    let decoder = EOUDecoder(engine: engine)
    for count in [5, 2] {
      let session = EOURecordingSession { decoder }
      session.append(Array(repeating: 0.1, count: count))
      let result = try await session.finish()
      XCTAssertEqual(result.text, "\(count) samples")
    }
  }

  func testEOUCancelNeverReturnsTranscript() async throws {
    let decoder = EOUDecoder(engine: TestEOUEngine())
    let session = EOURecordingSession { decoder }
    session.append([0.1, 0.2])
    session.cancel()
    do {
      _ = try await session.finish()
      XCTFail("Canceled session returned a transcript")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testEOUResetsOnlyAfterPreviousInferenceEnds() async throws {
    let started = expectation(description: "first inference started")
    let gate = TestInferenceGate()
    let engine = TestEOUEngine(onProcess: { started.fulfill() }, gate: gate)
    let decoder = EOUDecoder(engine: engine)
    let first = EOURecordingSession { decoder }
    first.append([0.1])
    await fulfillment(of: [started], timeout: 3)
    first.cancel()
    let second = EOURecordingSession { decoder }
    second.append([0.2, 0.3])
    await gate.release()
    do { _ = try await first.finish(); XCTFail("Canceled inference succeeded") }
    catch { XCTAssertTrue(error is CancellationError) }
    let result = try await second.finish()
    XCTAssertEqual(result.text, "2 samples")
    let events = await engine.events
    XCTAssertEqual(events, ["reset", "process:1", "reset", "process:2", "finish"])
  }

  func testNativeTextNormalizationStillAvailable() {
    XCTAssertEqual(NemoTextProcessing.normalizeSentence("two hundred thirty two"), "232")
    XCTAssertFalse(NemoTextProcessing.normalizeSentence("hello world").isEmpty)
  }

  /// Hardware smoke: opt-in only; downloads the models and checks the real provider path.
  func testParakeetHardwareSmoke() async throws {
    guard let path = ProcessInfo.processInfo.environment["VOXNOTCH_PARAKEET_AUDIO"] else {
      throw XCTSkip("Set TEST_RUNNER_VOXNOTCH_PARAKEET_AUDIO to an English WAV")
    }
    let settings = SettingsManager.shared
    let originalModel = settings.speechModel
    let originalVAD = settings.useVADSpeechGate
    defer {
      settings.speechModel = originalModel
      settings.useVADSpeechGate = originalVAD
      FluidAudioModelManager.shared.unloadModels()
    }
    settings.useVADSpeechGate = false
    let audioURL = URL(fileURLWithPath: path)
    let samples = try AudioConverter().resampleAudioFile(audioURL)
    for model in [SpeechModel.parakeetUnified, .parakeetEOU, .parakeetV2] {
      settings.speechModel = model.rawValue
      let version = try XCTUnwrap(model.fluidAudioVersion)
      try await FluidAudioModelManager.shared.downloadAndLoad(version: version)
      XCTAssertTrue(FluidAudioModelManager.shared.isVersionDownloaded(version))
      XCTAssertTrue(FluidAudioModelManager.shared.isVersionReady(version))
      let provider = FluidAudioProvider()
      let result = try await provider.transcribe(audioURL: audioURL, language: nil)
      print("PARAKEET_SMOKE \(model.rawValue) duration=\(result.audioDuration) inference=\(result.processingTime) text=\(result.text)")
      XCTAssertFalse(result.text.isEmpty)
      if let suffix = ProcessInfo.processInfo.environment["VOXNOTCH_PARAKEET_EXPECTED_SUFFIX"] {
        let normalized = result.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        XCTAssertTrue(normalized.hasSuffix(suffix.lowercased()), "Missing final speech: \(result.text)")
      }
      XCTAssertEqual(result.language, "en")
      if case .eou(let decoder) = FluidAudioModelManager.shared.getLoadedModel(for: version) {
        // Repeat after file transcription to catch encoder/decoder state leaking across sessions.
        let stream = EOURecordingSession { decoder }
        for start in stride(from: 0, to: samples.count, by: 1024) {
          stream.append(Array(samples[start..<min(start + 1024, samples.count)]))
        }
        let second = try await stream.finish()
        XCTAssertEqual(second.text, result.text)
        XCTAssertEqual(second.audioDuration, result.audioDuration, accuracy: 0.001)
      }
    }
  }
}

private actor TestEOUEngine: EOUStreamingEngine {
  var events: [String] = []
  private var count = 0
  private var onProcess: (@Sendable () -> Void)?
  private let gate: TestInferenceGate?
  init(onProcess: (@Sendable () -> Void)? = nil, gate: TestInferenceGate? = nil) {
    self.onProcess = onProcess
    self.gate = gate
  }
  func reset() { count = 0; events.append("reset") }
  func process(samples: [Float]) async {
    count += samples.count
    events.append("process:\(samples.count)")
    let callback = onProcess
    onProcess = nil
    callback?()
    await gate?.wait()
  }
  func finish() -> String { events.append("finish"); return "\(count) samples" }
}

private actor TestInferenceGate {
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() { released = true; continuation?.resume(); continuation = nil }
}
