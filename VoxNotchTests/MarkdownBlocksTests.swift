//
//  MarkdownBlocksTests.swift
//  VoxNotchTests
//

import XCTest
@testable import VoxNotch

final class MarkdownBlocksTests: XCTestCase {

  func testTildeCodeFencesKeepMathAndCloseDuringStreaming() {
    let code = "~~~sh\necho $PATH$\n\n# **literal"
    XCTAssertEqual(MarkdownBlocks.split(code), [code])
    XCTAssertEqual(MarkdownBlocks.plainMath(code), code)
    XCTAssertEqual(MarkdownBlocks.closingOpenMarkers(code), code + "\n~~~")
  }

  func testShorterOrDifferentFenceInsideCodeDoesNotCloseIt() {
    let code = "````markdown\n```python\n~~~\n\n$x$\n````"
    XCTAssertEqual(MarkdownBlocks.split(code + "\n\nAfter"), [code, "After"])
    XCTAssertEqual(MarkdownBlocks.plainMath(code), code)
    XCTAssertEqual(MarkdownBlocks.closingOpenMarkers(code), code)
  }

  func testMarkersInsideFinishedCodeAreNotClosedAsMarkdown() {
    let code = "```python\nprint('**')\n```"
    XCTAssertEqual(MarkdownBlocks.closingOpenMarkers(code), code)
    let mixed = "Cost $O(n)$\n~~~sh\necho $PATH$\n~~~"
    XCTAssertEqual(MarkdownBlocks.plainMath(mixed), "Cost O(n)\n~~~sh\necho $PATH$\n~~~")
  }

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

  func testPlainMathConvertsInlineLatex() {
    XCTAssertEqual(MarkdownBlocks.plainMath("Time is $O(N \\log N)$ overall."), "Time is O(N log N) overall.")
    XCTAssertEqual(MarkdownBlocks.plainMath("Keep a heap of size $k$ where $k \\le N$."), "Keep a heap of size k where k ≤ N.")
    XCTAssertEqual(MarkdownBlocks.plainMath("Distance is $x^2 + y^2$"), "Distance is x² + y²")
  }

  func testPlainMathLeavesCurrencyAndCodeAlone() {
    XCTAssertEqual(MarkdownBlocks.plainMath("It costs $5 and $10 per seat."), "It costs $5 and $10 per seat.")
    XCTAssertEqual(MarkdownBlocks.plainMath("Run `echo $HOME$` then $N$"), "Run `echo $HOME$` then N")
    XCTAssertEqual(MarkdownBlocks.plainMath("```bash\necho $A$\n```"), "```bash\necho $A$\n```")
  }
}
