import AppKit
import XCTest
@testable import VoxNotch

@MainActor
final class AnswerNavigationTests: XCTestCase {
  private var state: AlwaysOnState!
  private var ids: [UUID]!

  override func setUp() async throws {
    state = AlwaysOnState()
    ids = (0..<4).map { _ in UUID() }
    ids.forEach { state.appendAnswer(answer($0)) }
  }

  private func answer(_ id: UUID = UUID()) -> AssistantAnswer {
    var answer = AssistantAnswer(id: id, createdAt: Date(), trigger: .auto, model: "test")
    answer.markdown = id.uuidString
    answer.status = .done
    return answer
  }

  func testHoverScrubsAndExitRestoresOriginalPage() {
    state.showAnswer(offset: -1)
    state.previewAnswer(ids[0])
    state.previewAnswer(ids[1])
    XCTAssertEqual(state.displayedAnswer?.id, ids[1])
    XCTAssertTrue(state.isPreviewingAnswer)
    state.endAnswerPreview()
    XCTAssertEqual(state.displayedAnswer?.id, ids[2])
    XCTAssertFalse(state.isPreviewingAnswer)
  }

  func testClickLocksAndIgnoresFurtherHoverUntilUnlocked() {
    state.previewAnswer(ids[0])
    state.lockAnswer(ids[0])
    state.endAnswerPreview()
    state.previewAnswer(ids[1])
    XCTAssertEqual(state.displayedAnswer?.id, ids[0])
    XCTAssertTrue(state.isAnswerLocked)
    state.unlockAnswer()
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
    XCTAssertNil(state.selectedAnswerID)
    XCTAssertFalse(state.isAnswerLocked)
  }

  func testClickingAnotherTickKeepsTheOriginalReturnPage() {
    state.lockAnswer(ids[0])
    state.lockAnswer(ids[1])
    state.unlockAnswer()
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
  }

  func testNewAnswerDuringHoverDoesNotChangePreviewOrReturnPage() {
    state.previewAnswer(ids[0])
    state.appendAnswer(answer())
    XCTAssertEqual(state.displayedAnswer?.id, ids[0])
    state.endAnswerPreview()
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
    XCTAssertEqual(state.selectedAnswerID, ids[3])
  }

  func testLockedPageSurvivesNewAnswerAndReceivesStreamingUpdates() {
    state.lockAnswer(ids[1])
    state.appendAnswer(answer())
    state.updateAnswer(ids[1]) { $0.markdown = "updated"; $0.status = .streaming }
    XCTAssertEqual(state.displayedAnswer?.id, ids[1])
    XCTAssertEqual(state.displayedAnswer?.markdown, "updated")
    XCTAssertEqual(state.displayedAnswer?.status, .streaming)
    state.unlockAnswer()
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
  }

  func testKeyboardNavigationCommitsFromTheVisiblePreview() {
    state.previewAnswer(ids[0])
    state.showAnswer(offset: 1)
    state.endAnswerPreview()
    XCTAssertEqual(state.displayedAnswer?.id, ids[1])
    XCTAssertFalse(state.isPreviewingAnswer)
    state.lockAnswer(ids[0])
    state.showAnswer(offset: 100)
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
    XCTAssertFalse(state.isAnswerLocked)
    XCTAssertNil(state.selectedAnswerID)
  }

  func testRemovingPreviewOrLockRestoresOrigin() {
    state.previewAnswer(ids[0])
    state.removeAnswer(ids[0])
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
    XCTAssertFalse(state.isPreviewingAnswer)
    state.lockAnswer(ids[1])
    state.removeAnswer(ids[1])
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
    XCTAssertFalse(state.isAnswerLocked)
  }

  func testEvictedOriginFallsBackToLatestOnUnlock() {
    state.showAnswer(offset: -3)
    state.lockAnswer(ids[3])
    for _ in 0..<47 { state.appendAnswer(answer()) }
    XCTAssertEqual(state.answers.count, 50)
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
    state.unlockAnswer()
    XCTAssertEqual(state.displayedAnswer?.id, state.answers.last?.id)
    XCTAssertNil(state.selectedAnswerID)
  }

  func testEvictedLockedAnswerReleasesLockAndKeepsValidOrigin() {
    state.lockAnswer(ids[0])
    for _ in 0..<47 { state.appendAnswer(answer()) }
    XCTAssertFalse(state.isAnswerLocked)
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
  }

  func testRemovingAllAnswersAndSessionResetClearBrowsing() {
    state.lockAnswer(ids[0])
    ids.forEach { state.removeAnswer($0) }
    XCTAssertNil(state.displayedAnswer)
    XCTAssertFalse(state.isAnswerLocked)
    state.appendAnswer(answer())
    state.lockAnswer(state.answers[0].id)
    state.clearTranscript()
    XCTAssertNil(state.displayedAnswer)
    XCTAssertFalse(state.isAnswerLocked)
    state.appendAnswer(answer())
    state.previewAnswer(state.answers[0].id)
    state.begin(sources: [.microphone])
    XCTAssertNil(state.displayedAnswer)
    XCTAssertFalse(state.isPreviewingAnswer)
  }

  func testInvalidIDsCannotDisplaceCurrentPage() {
    state.previewAnswer(UUID())
    state.lockAnswer(UUID())
    state.unlockAnswer()
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
  }

  func testRailMapsAllTicksAndRejectsOutsideOrEmptyGeometry() {
    let index = AnswerNavigationMouseArea.TrackingView.answerIndex
    XCTAssertEqual(index(0, 400, 50), 0)
    XCTAssertEqual(index(199, 400, 50), 24)
    XCTAssertEqual(index(400, 400, 50), 49)
    XCTAssertNil(index(-1, 400, 50))
    XCTAssertNil(index(401, 400, 50))
    XCTAssertNil(index(0, 0, 50))
    XCTAssertNil(index(0, 400, 0))
    XCTAssertNil(index(.nan, 400, 50))
  }

  func testDoubleClickReturnsWithoutRepreviewUntilPointerLeaves() throws {
    let (window, view) = makeMouseArea()
    defer { window.close() }
    let hover = try event(.mouseMoved, x: 20, window: window)
    view.mouseEntered(with: hover)
    view.mouseDown(with: try event(.leftMouseDown, x: 20, window: window, clicks: 1))
    view.mouseUp(with: try event(.leftMouseUp, x: 20, window: window, clicks: 1))
    XCTAssertTrue(state.isAnswerLocked)
    view.mouseDown(with: try event(.leftMouseDown, x: 20, window: window, clicks: 2))
    view.mouseUp(with: try event(.leftMouseUp, x: 20, window: window, clicks: 2))
    view.mouseMoved(with: hover)
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
    XCTAssertFalse(state.isAnswerLocked)
    view.mouseExited(with: hover)
    view.mouseEntered(with: hover)
    XCTAssertEqual(state.displayedAnswer?.id, ids[0])
    XCTAssertTrue(view.acceptsFirstMouse(for: hover))
    XCTAssertFalse(view.mouseDownCanMoveWindow)
  }

  func testDragPreviewsAndReleaseLocksTheLandingTick() throws {
    let (window, view) = makeMouseArea()
    defer { window.close() }
    view.mouseDown(with: try event(.leftMouseDown, x: 20, window: window, clicks: 1))
    view.mouseDragged(with: try event(.leftMouseDragged, x: 220, window: window))
    XCTAssertEqual(state.displayedAnswer?.id, ids[2])
    XCTAssertFalse(state.isAnswerLocked)
    view.mouseUp(with: try event(.leftMouseUp, x: 220, window: window, clicks: 1))
    view.mouseExited(with: try event(.mouseMoved, x: 450, window: window))
    XCTAssertEqual(state.displayedAnswer?.id, ids[2])
    XCTAssertTrue(state.isAnswerLocked)
  }

  func testReleaseOutsideRailCancelsUncommittedPreview() throws {
    let (window, view) = makeMouseArea()
    defer { window.close() }
    view.mouseDown(with: try event(.leftMouseDown, x: 20, window: window, clicks: 1))
    view.mouseUp(with: try event(.leftMouseUp, x: 450, window: window, clicks: 1))
    XCTAssertEqual(state.displayedAnswer?.id, ids[3])
    XCTAssertFalse(state.isAnswerLocked)
  }

  private func makeMouseArea() -> (NSWindow, AnswerNavigationMouseArea.TrackingView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 24),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = AnswerNavigationMouseArea.TrackingView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
    window.contentView = view
    view.answerIDs = ids
    view.onPreview = state.previewAnswer
    view.onExit = state.endAnswerPreview
    view.onLock = state.lockAnswer
    view.onUnlock = state.unlockAnswer
    return (window, view)
  }

  private func event(_ type: NSEvent.EventType, x: CGFloat, window: NSWindow, clicks: Int = 0) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 12), modifierFlags: [],
                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 0, clickCount: clicks, pressure: 0))
  }
}
