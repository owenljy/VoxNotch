import XCTest
@testable import VoxNotch

@MainActor
final class AlwaysOnCaptureCoordinatorTests: XCTestCase {
  func testReplacementWaitsForCancelledStartAndItsCleanup() async throws {
    var events: [String] = []
    var pending: CheckedContinuation<Void, Never>?
    let coordinator = AlwaysOnCaptureCoordinator { _ in events.append("stop") }
    let first = coordinator.start(.systemAudio) {
      events.append("first start")
      // Models a system API that ignores cancellation while prompting for permission.
      await withCheckedContinuation { pending = $0 }
      events.append("first returned")
    }
    while pending == nil { await Task.yield() }
    coordinator.stopAll()
    let second = coordinator.start(.systemAudio) { events.append("second start") }
    await Task.yield()
    XCTAssertFalse(events.contains("second start"))
    pending?.resume()
    try await second.value
    guard case .failure(let error) = await first.result else { return XCTFail("first start must cancel") }
    XCTAssertTrue(error is CancellationError)
    XCTAssertEqual(Array(events.suffix(3)), ["first returned", "stop", "second start"])
  }

  func testStopBeforeStartRunsDoesNotOpenDevice() async {
    var starts = 0
    let coordinator = AlwaysOnCaptureCoordinator { _ in }
    let task = coordinator.start(.microphone) { starts += 1 }
    coordinator.stopAll()
    _ = await task.result
    XCTAssertEqual(starts, 0)
  }

  func testFailedStartCleansUpDevice() async {
    struct Failed: Error {}
    var stops = 0
    let coordinator = AlwaysOnCaptureCoordinator { _ in stops += 1 }
    let task = coordinator.start(.microphone) { throw Failed() }
    _ = await task.result
    XCTAssertEqual(stops, 2, "stop before starting and cleanup after a failed start")
  }
}
