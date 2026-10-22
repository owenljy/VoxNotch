import XCTest
@testable import VoxNotch

final class LiveTranscriberTests: XCTestCase {
  private func makeTranscriber() -> LiveTranscriber {
    LiveTranscriber(
      decode: { _ in "short answer" },
      detectSpeech: { samples, state in (samples.first == 1 ? 0.9 : 0.0, state) }
    )
  }

  private func collect(_ transcriber: LiveTranscriber) -> Task<[TranscriptUpdate], Never> {
    Task {
      var received: [TranscriptUpdate] = []
      for await update in transcriber.updates { received.append(update) }
      return received
    }
  }

  func testQuarterSecondSpeechSurvivesFinalNoiseGate() async {
    let transcriber = makeTranscriber()
    let collector = collect(transcriber)
    await transcriber.startSource(.microphone)
    await transcriber.ingest([Float](repeating: 1, count: 4096), from: .microphone)
    await transcriber.ingest([Float](repeating: 0, count: 8192), from: .microphone)
    await transcriber.finish()
    let updates = await collector.value
    XCTAssertEqual(updates.filter(\.isFinal).map(\.text), ["short answer"])
  }

  func testFinishFlushesLastUtteranceAndWaitsForItsDecode() async {
    let transcriber = makeTranscriber()
    let collector = collect(transcriber)
    await transcriber.startSource(.systemAudio)
    await transcriber.ingest([Float](repeating: 1, count: 4096 + 100), from: .systemAudio)
    await transcriber.finish()
    let finals = await collector.value.filter(\.isFinal)
    XCTAssertEqual(finals.map(\.text), ["short answer"])
    if let final = finals.first {
      XCTAssertEqual(final.endedAt.timeIntervalSince(final.startedAt), 4196.0 / 16_000, accuracy: 0.0001)
    }
  }

  func testRestartedSourceIgnoresVADResultFromOldPipeline() async throws {
    let gate = DetectorGate()
    let transcriber = LiveTranscriber(
      decode: { samples in String(samples.filter { $0 == 1 }.count) },
      detectSpeech: { samples, state in
        await gate.waitOnFirstCall()
        return (samples.first == 1 ? 0.9 : 0.0, state)
      }
    )
    let collector = collect(transcriber)
    await transcriber.startSource(.microphone)
    let oldIngest = Task { await transcriber.ingest([Float](repeating: 1, count: 4096), from: .microphone) }
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await gate.isWaiting) {
      guard ContinuousClock.now < deadline else { return XCTFail("detector never started") }
      await Task.yield()
    }
    await transcriber.startSource(.microphone)
    await gate.release()
    await oldIngest.value
    await transcriber.ingest([Float](repeating: 1, count: 4096), from: .microphone)
    await transcriber.ingest([Float](repeating: 0, count: 8192), from: .microphone)
    await transcriber.finish()
    let finals = await collector.value.filter(\.isFinal)
    XCTAssertEqual(finals.map(\.text), ["4096"], "the old VAD chunk must not enter the new source pipeline")
  }
}

private actor DetectorGate {
  private var isFirstCall = true
  private var continuation: CheckedContinuation<Void, Never>?
  var isWaiting: Bool { continuation != nil }

  func waitOnFirstCall() async {
    guard isFirstCall else { return }
    isFirstCall = false
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
