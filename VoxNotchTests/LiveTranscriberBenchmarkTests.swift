//
//  LiveTranscriberBenchmarkTests.swift
//  VoxNotchTests
//
//  Real-model latency benchmark for the Always-On pipeline. Feeds synthesized
//  speech for two overlapping sources in real time through LiveTranscriber.
//  Opt-in (needs downloaded Parakeet v2 + Silero models):
//    TEST_RUNNER_VOXNOTCH_LIVE_ASR_TESTS=1 xcodebuild test -only-testing:VoxNotchTests/LiveTranscriberBenchmarkTests
//

import AVFoundation
import FluidAudio
import XCTest
@testable import VoxNotch

final class LiveTranscriberBenchmarkTests: XCTestCase {

  func testRealTimeTwoSourceLatency() async throws {
    let clock = ContinuousClock()
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VOXNOTCH_LIVE_ASR_TESTS"] == "1", "opt-in benchmark")

    let systemSpeech = try Self.synthesize(
      "Thanks for joining us today. So tell me, how would you reduce customer churn next quarter?", voice: "Samantha")
    let micSpeech = try Self.synthesize("I would start by looking at the onboarding funnel data.", voice: "Daniel")

    let transcriber = LiveTranscriber()
    let prepareStart = clock.now
    let asr = AsrManager()
    try await asr.loadModels(AsrModels.downloadAndLoad(version: .v2))
    try await transcriber.prepare(asr: asr)
    print("BENCH prepare=\(Self.ms(clock.now - prepareStart))ms")

    await transcriber.startSource(.systemAudio)
    await transcriber.startSource(.microphone)

    let collector = Task { () -> [(TranscriptUpdate, ContinuousClock.Instant)] in
      var received: [(TranscriptUpdate, ContinuousClock.Instant)] = []
      for await update in transcriber.updates { received.append((update, ContinuousClock.now)) }
      return received
    }

    let start = clock.now
    let micOffset = Duration.seconds(Double(systemSpeech.count) / 16_000 + 0.6)
    async let systemFeed: Void = Self.feed(systemSpeech, from: .systemAudio, into: transcriber, after: .zero)
    async let micFeed: Void = Self.feed(micSpeech, from: .microphone, into: transcriber, after: micOffset)
    _ = await (systemFeed, micFeed)
    try await Task.sleep(for: .milliseconds(500))
    await transcriber.shutdown()
    let updates = await collector.value

    for (update, at) in updates {
      print(String(
        format: "BENCH t=%5dms %@ %@ processing=%dms silence=%dms \"%@\"",
        Self.ms(at - start), update.source.rawValue, update.isFinal ? "FINAL  " : "partial",
        Self.ms(update.processingLatency), Self.ms(update.trailingSilence), update.text))
    }

    let partialLatencies = updates.filter { !$0.0.isFinal }.map { Self.ms($0.0.processingLatency) }.sorted()
    let finals = updates.filter { $0.0.isFinal && !$0.0.text.isEmpty }.map(\.0)
    if !partialLatencies.isEmpty {
      print("BENCH partial processing p50=\(partialLatencies[partialLatencies.count / 2])ms max=\(partialLatencies.last!)ms n=\(partialLatencies.count)")
    }
    for final in finals {
      print("BENCH final \(final.source.rawValue) speech-end→final≈\(Self.ms(final.trailingSilence + final.processingLatency))ms")
    }
    for paused in updates.map(\.0) where !paused.isFinal && paused.trailingSilence > .zero {
      print("BENCH pause-signal \(paused.source.rawValue) speech-end→complete-text≈\(Self.ms(paused.trailingSilence + paused.processingLatency))ms \"\(paused.text)\"")
    }

    var policy = AutoTriggerPolicy()
    let systemSpeechEnd = start + .seconds(Double(Self.speechEndSample(systemSpeech)) / 16_000)
    for (update, at) in updates {
      let wallClock = Date(timeIntervalSinceReferenceDate: Double(Self.ms(at - start)) / 1000)
      for action in policy.handle(update, accepted: !update.text.isEmpty, now: wallClock) {
        print("BENCH auto-trigger \(action) at speech-end+\(Self.ms(at - systemSpeechEnd))ms")
      }
    }

    let systemText = finals.filter { $0.source == .systemAudio }.map(\.text).joined(separator: " ").lowercased()
    let micText = finals.filter { $0.source == .microphone }.map(\.text).joined(separator: " ").lowercased()
    XCTAssertTrue(systemText.contains("churn"), systemText)
    XCTAssertTrue(systemText.contains("?"), "question punctuation needed for auto-trigger: \(systemText)")
    XCTAssertTrue(micText.contains("onboarding"), micText)
  }

  // MARK: - Helpers

  /// Streams samples in 20ms frames at real-time pace, followed by 1.2s of silence.
  private static func feed(_ samples: [Float], from source: VoxNotch.AudioSource, into transcriber: LiveTranscriber, after delay: Duration) async {
    try? await Task.sleep(for: delay)
    let frame = 320
    let padded = samples + [Float](repeating: 0, count: 16_000 * 6 / 5)
    let clock = ContinuousClock()
    var next = clock.now
    for offset in stride(from: 0, to: padded.count, by: frame) {
      await transcriber.ingest(Array(padded[offset..<min(offset + frame, padded.count)]), from: source)
      next = next.advanced(by: .milliseconds(20))
      try? await clock.sleep(until: next)
    }
  }

  private static func synthesize(_ text: String, voice: String) throws -> [Float] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", voice, "--file-format=WAVE", "--data-format=LEF32@16000", "-o", url.path, text]
    try process.run()
    process.waitUntilExit()

    let file = try AVAudioFile(forReading: url)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
  }

  /// Index just past the last sample above -50 dBFS (TTS output has trailing silence).
  private static func speechEndSample(_ samples: [Float]) -> Int {
    (samples.lastIndex { abs($0) > 0.003 } ?? samples.count - 1) + 1
  }

  private static func ms(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}
