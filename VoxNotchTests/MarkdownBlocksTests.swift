//
//  MarkdownBlocksTests.swift
//  VoxNotchTests
//

import XCTest
@testable import VoxNotch

final class MarkdownBlocksTests: XCTestCase {

  func testSplitsParagraphsOnBlankLines() {
    XCTAssertEqual(MarkdownBlocks.split("One.\n\nTwo.\n\n\nThree."), ["One.", "Two.", "Three."])
  }

  func testKeepsCodeFenceWithBlankLinesTogether() {
    let markdown = "Intro\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter"
    XCTAssertEqual(MarkdownBlocks.split(markdown), ["Intro", "```swift\nlet a = 1\n\nlet b = 2\n```", "After"])
  }

  func testUnclosedFenceWhileStreamingStaysOneBlock() {
    XCTAssertEqual(MarkdownBlocks.split("Text\n\n```\ncode\n\nmore"), ["Text", "```\ncode\n\nmore"])
  }

  func testLooseListStaysTogether() {
    let markdown = "Steps:\n\n1. First\n\n2. Second\n\n- tail item"
    XCTAssertEqual(MarkdownBlocks.split(markdown), ["Steps:", "1. First\n\n2. Second\n\n- tail item"])
  }

  func testIndentedContinuationAttachesToPreviousList() {
    XCTAssertEqual(MarkdownBlocks.split("- item\n\n  continued"), ["- item\n\n  continued"])
  }

  func testIndentedTextAfterParagraphIsSeparate() {
    XCTAssertEqual(MarkdownBlocks.split("Para\n\n    code"), ["Para", "    code"])
  }

  func testEmptyInput() {
    XCTAssertEqual(MarkdownBlocks.split(""), [])
    XCTAssertEqual(MarkdownBlocks.split("\n\n"), [])
  }

  func testJoinedBlocksPreserveContent() {
    let markdown = "# Title\n\nPara with **bold**.\n\n> quote\n\n| a | b |\n|---|---|\n| 1 | 2 |"
    XCTAssertEqual(MarkdownBlocks.split(markdown).joined(separator: "\n\n"), markdown)
  }

  func testClosingOpenMarkers() {
    XCTAssertEqual(MarkdownBlocks.closingOpenMarkers("- **A/B Test"), "- **A/B Test**")
    XCTAssertEqual(MarkdownBlocks.closingOpenMarkers("Run `git sta"), "Run `git sta`")
    XCTAssertEqual(MarkdownBlocks.closingOpenMarkers("```sql\nSELECT 1"), "```sql\nSELECT 1\n```")
    XCTAssertEqual(MarkdownBlocks.closingOpenMarkers("**done** and fine"), "**done** and fine")
  }
}
