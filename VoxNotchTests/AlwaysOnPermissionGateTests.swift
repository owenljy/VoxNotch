//
//  AlwaysOnPermissionGateTests.swift
//  VoxNotchTests
//

import XCTest
@testable import VoxNotch

final class AlwaysOnPermissionGateTests: XCTestCase {

  func testSilentKeychainReadOfMissingItemReturnsNotFoundWithoutPrompting() {
    let clock = ContinuousClock()
    let start = clock.now
    let result = KeychainStore.read("voxnotch.tests.missing.\(UUID().uuidString)", interactive: false)
    XCTAssertEqual(result, .notFound)
    XCTAssertLessThan(clock.now - start, .seconds(1), "a silent read must never block on a dialog")
  }

  func testPermissionErrorExplainsWhichSource() {
    XCTAssertEqual(AlwaysOnPermissionError(source: .systemAudio).errorDescription,
                   "Screen & System Audio Recording permission isn't granted.")
    XCTAssertEqual(AlwaysOnPermissionError(source: .microphone).errorDescription,
                   "Microphone permission isn't granted.")
  }

  @MainActor
  func testPermissionBannerStateResetsPerSession() {
    let state = AlwaysOnState()
    state.begin(sources: [.microphone, .systemAudio])
    state.permissionIssues.insert(.systemAudio)
    state.begin(sources: [.microphone])
    XCTAssertTrue(state.permissionIssues.isEmpty)
  }
}
