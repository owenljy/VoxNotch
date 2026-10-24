import XCTest
@testable import VoxNotch

@MainActor
final class PreparedModelCacheTests: XCTestCase {
  private func waitForLoad(_ loader: ModelLoadGate, count: Int = 1) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await loader.count < count {
      guard ContinuousClock.now < deadline else { return XCTFail("Load did not start") }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  func testLaunchPreloadAndImmediateStartShareOneLoadAndReuseWarmModels() async throws {
    let loader = ModelLoadGate()
    let cache = PreparedModelCache { try await loader.load() }
    cache.preload()
    XCTAssertEqual(cache.status, .preparing)
    let start = Task { try await cache.models() }
    try await waitForLoad(loader)
    await loader.succeed(42)
    let result = try await start.value
    XCTAssertEqual(result, 42)
    let secondSession = try await cache.models()
    XCTAssertEqual(secondSession, 42)
    let count = await loader.count
    XCTAssertEqual(count, 1)
    XCTAssertEqual(cache.status, .ready)
  }

  func testStoppingStartDoesNotCancelBackgroundPreload() async throws {
    let loader = ModelLoadGate()
    let cache = PreparedModelCache { try await loader.load() }
    cache.preload()
    let cancelled = Task { try await cache.models() }
    try await waitForLoad(loader)
    cancelled.cancel()
    let replacement = Task { try await cache.models() }
    await loader.succeed(7)
    _ = await cancelled.result
    let ready = try await replacement.value
    XCTAssertEqual(ready, 7)
    XCTAssertEqual(cache.status, .ready)
    let count = await loader.count
    XCTAssertEqual(count, 1)
  }

  func testFailedPreloadDoesNotPoisonLaterStart() async throws {
    let loader = ModelLoadGate()
    let cache = PreparedModelCache { try await loader.load() }
    let first = Task { try await cache.models() }
    try await waitForLoad(loader)
    await loader.fail()
    _ = await first.result
    guard case .failed = cache.status else { return XCTFail("Expected failed preparation") }
    let retry = Task { try await cache.models() }
    try await waitForLoad(loader, count: 2)
    await loader.succeed(9)
    let value = try await retry.value
    XCTAssertEqual(value, 9)
    XCTAssertEqual(cache.status, .ready)
  }

  func testMemoryReleaseDropsLateLoadAndAllowsFreshPreparation() async throws {
    let loader = ModelLoadGate()
    let cache = PreparedModelCache { try await loader.load() }
    let first = Task { try await cache.models() }
    try await waitForLoad(loader)
    cache.release()
    // Models CoreML calls that finish despite cancellation.
    await loader.succeed(1)
    guard case .failure = await first.result else { return XCTFail("Released load must be discarded") }
    XCTAssertEqual(cache.status, .idle)
    let second = Task { try await cache.models() }
    try await waitForLoad(loader, count: 2)
    await loader.succeed(2)
    let value = try await second.value
    XCTAssertEqual(value, 2)
  }
}

private actor ModelLoadGate {
  private(set) var count = 0
  private var pending: [CheckedContinuation<Int, Error>] = []
  func load() async throws -> Int {
    count += 1
    return try await withCheckedThrowingContinuation { pending.append($0) }
  }
  func succeed(_ value: Int) { pending.removeFirst().resume(returning: value) }
  func fail() { pending.removeFirst().resume(throwing: LLMError.invalidResponse) }
}
