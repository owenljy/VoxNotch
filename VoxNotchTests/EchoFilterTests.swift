//
//  EchoFilterTests.swift
//  VoxNotchTests
//

import XCTest
@testable import VoxNotch

final class EchoFilterTests: XCTestCase {

  func testTokenizationIgnoresCaseAndPunctuation() {
    XCTAssertEqual(EchoFilter.tokens("It's GREAT, isn't it?"), ["it's", "great", "isn't", "it"])
  }

  func testHighOverlapIsEcho() {
    XCTAssertTrue(EchoFilter.isLikelyEcho(micText: "revenue grew thirty percent", systemText: "Our revenue grew thirty percent this year."))
  }

  func testLowOverlapIsNotEcho() {
    XCTAssertFalse(EchoFilter.isLikelyEcho(micText: "I think we should ship it", systemText: "Our revenue grew thirty percent"))
  }

  func testSingleWordIsNeverEcho() {
    XCTAssertFalse(EchoFilter.isLikelyEcho(micText: "Yes.", systemText: "yes yes"))
  }

  func testEmptySystemTextIsNotEcho() {
    XCTAssertFalse(EchoFilter.isLikelyEcho(micText: "hello there friend", systemText: ""))
  }
}
