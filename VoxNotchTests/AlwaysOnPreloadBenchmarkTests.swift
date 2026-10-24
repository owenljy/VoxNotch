import XCTest
@testable import VoxNotch

@MainActor
final class AlwaysOnPreloadBenchmarkTests: XCTestCase {
  /// Opt-in local model test; generated silence only, no device capture or AI API.
  /// TEST_RUNNER_VOXNOTCH_PRELOAD_BENCHMARK=1 xcodebuild test -only-testing:VoxNotchTests/AlwaysOnPreloadBenchmarkTests
  func testPreparedModelsAreReusedByNewSessionsWithoutCompilingAgain() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VOXNOTCH_PRELOAD_BENCHMARK"] == "1", "opt-in model preparation benchmark")
    try XCTSkipUnless(FluidAudioModelManager.shared.isVersionDownloaded(.v2English), "requires downloaded Parakeet v2")
    let cache = AlwaysOnModelPreloader.cache
    cache.release()
    defer { cache.release() }
    let clock = ContinuousClock()
    let coldStart = clock.now
    AlwaysOnModelPreloader.prepareNow()
    let prepared = try await AlwaysOnModelPreloader.models()
    let cold = clock.now - coldStart
    let warmStart = clock.now
    let reused = try await AlwaysOnModelPreloader.models()
    let transcriber = LiveTranscriber()
    try await transcriber.prepare(models: reused)
    let warm = clock.now - warmStart
    XCTAssertTrue(prepared.asr === reused.asr)
    XCTAssertTrue(prepared.vad === reused.vad)
    XCTAssertEqual(cache.status, .ready)
    XCTAssertLessThan(warm, .seconds(1), "A prepared session should not load or compile models again")
    print("PRELOAD_BENCH cold=\(cold) warmSession=\(warm)")
    await transcriber.shutdown()
  }
}
