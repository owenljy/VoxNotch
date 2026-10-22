import XCTest
import GRDB
@testable import VoxNotch

@MainActor
final class AlwaysOnHistoryStoreTests: XCTestCase {

  private final class TestSettings: AlwaysOnHistorySettingsProviding {
    var saveHistory = true
    var historyRetentionDays = 0
  }

  private func makeStore(settings: TestSettings = TestSettings()) throws -> (AlwaysOnHistoryStore, DatabaseQueue) {
    var config = Configuration()
    config.foreignKeysEnabled = true
    let queue = try DatabaseQueue(configuration: config)
    try DatabaseManager.makeMigrator().migrate(queue)
    return (AlwaysOnHistoryStore(databaseManager: queue, settings: settings), queue)
  }

  func testPersistsSessionSegmentsAnswersAndSearchesThenDeletes() async throws {
    let (store, queue) = try makeStore()
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let sessionID = "session-1"

    await store.startSession(id: sessionID, sources: [.microphone, .systemAudio], startedAt: startedAt).value
    await store.recordSegment(
      LiveTranscriptSegment(
        id: UUID(), source: .systemAudio, text: "Tell me about vector databases",
        startedAt: startedAt.addingTimeInterval(1), endedAt: startedAt.addingTimeInterval(3), isFinal: true
      ),
      sessionID: sessionID
    ).value
    var answer = AssistantAnswer(id: UUID(), createdAt: startedAt.addingTimeInterval(4), trigger: .manual, model: "gpt-test")
    answer.templateName = "RRK – AI Engineer"
    answer.markdown = "Use embeddings, indexes, and reranking."
    answer.status = .done
    await store.recordAnswer(answer, sessionID: sessionID).value
    await store.endSession(id: sessionID, endedAt: startedAt.addingTimeInterval(10), cleanly: true).value

    let sessions = try await store.sessions(matching: "reranking")
    XCTAssertEqual(sessions.map(\.id), [sessionID])
    let segmentTexts = try await store.segments(for: sessionID).map(\.text)
    let answerMarkdown = try await store.answers(for: sessionID).map(\.markdown)
    XCTAssertEqual(segmentTexts, ["Tell me about vector databases"])
    XCTAssertEqual(answerMarkdown, ["Use embeddings, indexes, and reranking."])

    try await store.deleteSession(id: sessionID)
    let counts = try await store.counts()
    XCTAssertEqual(counts.sessions, 0)
    XCTAssertEqual(counts.segments, 0, "segments cascade-delete with the session")
    XCTAssertEqual(counts.answers, 0, "answers cascade-delete with the session")

    let rawSegmentCount = try await queue.read { db in try AlwaysOnSegmentRecord.fetchCount(db) }
    XCTAssertEqual(rawSegmentCount, 0)
  }

  func testSaveHistoryOffDoesNotWriteNewRowsButStillClosesExistingSession() async throws {
    let settings = TestSettings()
    let (store, _) = try makeStore(settings: settings)
    let now = Date(timeIntervalSince1970: 2_000)

    await store.startSession(id: "existing", sources: [.microphone], startedAt: now).value
    settings.saveHistory = false
    await store.recordSegment(
      LiveTranscriptSegment(id: UUID(), source: .microphone, text: "private", startedAt: now, endedAt: now, isFinal: true),
      sessionID: "existing"
    ).value
    await store.endSession(id: "existing", endedAt: now.addingTimeInterval(5), cleanly: true).value

    let sessions = try await store.sessions()
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions[0].endedAt, now.addingTimeInterval(5))
    XCTAssertTrue(sessions[0].closedCleanly)
    let existingSegments = try await store.segments(for: "existing")
    XCTAssertTrue(existingSegments.isEmpty)
  }

  func testCrashRecoveryAndRetentionPrune() async throws {
    let settings = TestSettings()
    settings.historyRetentionDays = 7
    let (store, _) = try makeStore(settings: settings)
    let oldDate = Date(timeIntervalSince1970: 1_000)
    let recentDate = Date(timeIntervalSince1970: 1_000_000)

    await store.startSession(id: "old", sources: [.microphone], startedAt: oldDate).value
    await store.startSession(id: "recent", sources: [.systemAudio], startedAt: recentDate).value
    await store.recordSegment(
      LiveTranscriptSegment(id: UUID(), source: .systemAudio, text: "last activity", startedAt: recentDate, endedAt: recentDate.addingTimeInterval(42), isFinal: true),
      sessionID: "recent"
    ).value

    await store.recoverCrashedSessions().value
    let recoveredSessions = try await store.sessions()
    let recent = try XCTUnwrap(recoveredSessions.first { $0.id == "recent" })
    XCTAssertEqual(recent.endedAt, recentDate.addingTimeInterval(42))
    XCTAssertFalse(recent.closedCleanly)

    await store.pruneExpiredSessions(now: recentDate.addingTimeInterval(6 * 24 * 60 * 60)).value
    let remaining = try await store.sessions()
    XCTAssertEqual(remaining.map(\.id), ["recent"])
  }

  func testWritesKeepCallOrderWithoutAwaitingSessionStart() async throws {
    let (store, _) = try makeStore()
    let start = Date(timeIntervalSince1970: 2_000)
    // Fire-and-forget, exactly like the live controller does.
    store.startSession(id: "s", sources: [.systemAudio], startedAt: start)
    var lastWrite: Task<Void, Never>?
    for index in 0..<20 {
      lastWrite = store.recordSegment(
        LiveTranscriptSegment(
          id: UUID(), source: .systemAudio, text: "line \(index)",
          startedAt: start.addingTimeInterval(Double(index)), endedAt: start.addingTimeInterval(Double(index) + 0.5), isFinal: true
        ),
        sessionID: "s"
      )
    }
    store.endSession(id: "s", endedAt: start.addingTimeInterval(30), cleanly: true)
    await lastWrite?.value
    let segments = try await store.segments(for: "s")
    XCTAssertEqual(segments.count, 20)
    let sessions = try await store.sessions()
    XCTAssertEqual(sessions.first?.sources, "systemAudio")
  }

  func testSegmentAndAnswerCreateSessionWhenSavingTurnedOnMidSession() async throws {
    let settings = TestSettings()
    settings.saveHistory = false
    let (store, _) = try makeStore(settings: settings)
    let start = Date(timeIntervalSince1970: 3_000)
    store.startSession(id: "late", sources: [.microphone], startedAt: start)

    settings.saveHistory = true
    await store.recordSegment(
      LiveTranscriptSegment(id: UUID(), source: .microphone, text: "after enabling", startedAt: start, endedAt: start, isFinal: true),
      sessionID: "late"
    ).value
    var answer = AssistantAnswer(id: UUID(), createdAt: start.addingTimeInterval(1), trigger: .manual, model: "m")
    answer.markdown = "ok"
    answer.status = .done
    await store.recordAnswer(answer, sessionID: "late").value

    let segmentTexts = try await store.segments(for: "late").map(\.text)
    let answers = try await store.answers(for: "late")
    XCTAssertEqual(segmentTexts, ["after enabling"])
    XCTAssertEqual(answers.count, 1)
  }
}
