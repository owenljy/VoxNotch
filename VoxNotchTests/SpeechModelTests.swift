//
//  SpeechModelTests.swift
//  VoxNotchTests
//

import XCTest
import AVFoundation
import MLX
import MLXAudioSTT
@testable import VoxNotch

final class SpeechModelTests: XCTestCase {

  // MARK: - Model Identity

  func testBuiltinModelResolves() {
    let (builtin, custom) = SpeechModel.resolve("fluidaudio-v2")
    XCTAssertEqual(builtin, .parakeetV2)
    XCTAssertNil(custom)
  }

  func testAllBuiltinModelsResolve() {
    for model in SpeechModel.allCases {
      let (builtin, custom) = SpeechModel.resolve(model.rawValue)
      XCTAssertEqual(builtin, model, "SpeechModel.resolve(\(model.rawValue)) should return \(model)")
      XCTAssertNil(custom)
    }
  }

  func testUnknownModelResolvesToCustom() {
    let (builtin, _) = SpeechModel.resolve("unknown-model-id-that-does-not-exist")
    XCTAssertNil(builtin)
  }

  func testLegacyFluidAudioV3ResolvesToDefault() {
    let (builtin, custom) = SpeechModel.resolve("fluidaudio-v3")
    XCTAssertEqual(builtin, SpeechModel.defaultModel)
    XCTAssertNil(custom)
  }

  // MARK: - Engine Mapping

  func testFluidAudioModelsMapToFluidAudioEngine() {
    XCTAssertEqual(SpeechModel.parakeetV2.engine, .fluidAudio)
  }

  func testMLXModelsMapToMLXEngine() {
    XCTAssertEqual(SpeechModel.glmAsrNano.engine, .mlxAudio)
    XCTAssertEqual(SpeechModel.qwen3Asr.engine, .mlxAudio)
    XCTAssertEqual(SpeechModel.voxtralMini.engine, .mlxAudio)
  }

  // MARK: - Version Conversion

  func testFluidAudioVersionConversion() {
    XCTAssertEqual(SpeechModel.parakeetV2.fluidAudioVersion, .v2English)
    XCTAssertNil(SpeechModel.glmAsrNano.fluidAudioVersion)
    XCTAssertNil(SpeechModel.qwen3Asr.fluidAudioVersion)
    XCTAssertNil(SpeechModel.voxtralMini.fluidAudioVersion)
  }

  func testMLXAudioVersionConversion() {
    XCTAssertNil(SpeechModel.parakeetV2.mlxAudioVersion)
    XCTAssertEqual(SpeechModel.glmAsrNano.mlxAudioVersion, .glmAsrNano)
    XCTAssertEqual(SpeechModel.qwen3Asr.mlxAudioVersion, .qwen3Asr)
    XCTAssertEqual(SpeechModel.voxtralMini.mlxAudioVersion, .voxtralMini)
  }

  func testQwenVariantsKeepIndependentDownloadIdentities() {
    let models: [SpeechModel] = [.qwen3Asr, .qwen3AsrSmall, .qwen3AsrQuantized]
    let versions = models.compactMap { $0.mlxAudioVersion }
    XCTAssertEqual(versions.count, models.count)
    XCTAssertEqual(Set(versions.map(\.rawValue)).count, models.count)
    XCTAssertEqual(Set(versions.map { $0.folderName }).count, models.count)
    for model in models {
      XCTAssertEqual(model.engine, .mlxAudio)
      XCTAssertEqual(model.estimatedSizeMB, model.mlxAudioVersion?.estimatedSizeMB)
      XCTAssertEqual(model.mlxAudioVersion?.loaderClass, .qwen3ASR)
    }
    // Existing saved settings must continue to select the original BF16 weights.
    let (legacy, _) = SpeechModel.resolve("mlx-qwen3-asr")
    XCTAssertEqual(legacy?.mlxAudioVersion?.rawValue, "mlx-community/Qwen3-ASR-1.7B-bf16")
    XCTAssertEqual(SpeechModel.qwen3AsrSmall.mlxAudioVersion?.rawValue,
                   "mlx-community/Qwen3-ASR-0.6B-4bit")
    XCTAssertEqual(SpeechModel.qwen3AsrQuantized.mlxAudioVersion?.rawValue,
                   "mlx-community/Qwen3-ASR-1.7B-4bit")
  }


  /// Opt-in hardware evaluation. Normal test runs never download model weights.
  @MainActor
  func testQwenRecordingBenchmark() async throws {
    guard let manifestPath = ProcessInfo.processInfo.environment["VOXNOTCH_ASR_MANIFEST"] else {
      throw XCTSkip("Set TEST_RUNNER_VOXNOTCH_ASR_MANIFEST to a local recording manifest")
    }
    struct Sample: Decodable {
      let id: String
      let audioPath: String
      let reference: String
    }
    struct Manifest: Decodable {
      let models: [String]
      let samples: [Sample]
    }
    struct Result: Encodable {
      let model: String
      let sample: String
      let reference: String
      let transcript: String
      let audioSeconds: Double
      let inferenceSeconds: Double
      let loadSeconds: Double
    }
    let manifestURL = URL(fileURLWithPath: manifestPath)
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    XCTAssertFalse(manifest.models.isEmpty)
    XCTAssertFalse(manifest.samples.isEmpty)
    let allowedModels: Set<String> = [
      MLXAudioModelVersion.qwen3Asr.rawValue,
      MLXAudioModelVersion.qwen3AsrSmall.rawValue,
      MLXAudioModelVersion.qwen3AsrQuantized.rawValue,
    ]
    // Validate every recording before starting potentially large downloads.
    var recordings: [(Sample, [Float])] = []
    for sample in manifest.samples {
      let url = sample.audioPath.hasPrefix("/")
        ? URL(fileURLWithPath: sample.audioPath)
        : manifestURL.deletingLastPathComponent().appendingPathComponent(sample.audioPath)
      let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
      XCTAssertEqual(file.processingFormat.sampleRate, 16000)
      XCTAssertEqual(file.processingFormat.channelCount, 1)
      guard file.processingFormat.sampleRate == 16000,
            file.processingFormat.channelCount == 1, file.length > 0,
            file.length <= 16000 * 60,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: AVAudioFrameCount(file.length)) else {
        XCTFail("Use non-empty mono 16 kHz recordings up to 60 seconds: \(sample.id)")
        return
      }
      try file.read(into: buffer)
      let data = try XCTUnwrap(buffer.floatChannelData)
      recordings.append((sample, Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))))
    }
    guard manifest.models.allSatisfy({ allowedModels.contains($0) }) else {
      XCTFail("Manifest contains an unsupported model repository")
      return
    }
    var results: [Result] = []
    for repo in manifest.models {
      let loadStart = ProcessInfo.processInfo.systemUptime
      if let version = MLXAudioModelVersion(rawValue: repo) {
        try await HFModelDownload.ensureCached(repoID: repo, directory: MLXAudioModelManager.shared.modelDirectory(for: version))
      }
      let model = try await Qwen3ASRModel.fromPretrained(repo)
      if let version = MLXAudioModelVersion(rawValue: repo) {
        XCTAssertTrue(ModelCacheValidation.isComplete(MLXAudioModelManager.shared.modelDirectory(for: version)))
      }
      let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
      // Match the app's Metal warmup; exclude it from timed transcription.
      _ = model.generate(audio: MLXArray(Array(repeating: Float.zero, count: 1600)))
      for (sample, samples) in recordings {
        let start = ProcessInfo.processInfo.systemUptime
        let output = try ASRInference.generate(model: model, samples: samples, language: nil, cancellation: ASRCancellation())
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertFalse(output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Empty transcript for \(repo): \(sample.id)")
        results.append(Result(model: repo, sample: sample.id, reference: sample.reference,
                              transcript: output.text, audioSeconds: Double(samples.count) / 16000,
                              inferenceSeconds: elapsed, loadSeconds: loadSeconds))
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let report = try encoder.encode(results)
    let attachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
    attachment.name = "qwen-recording-benchmark.json"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("Qwen recording benchmark:\n" + String(decoding: report, as: UTF8.self))
  }

}
