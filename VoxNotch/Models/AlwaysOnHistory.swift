//
//  AlwaysOnHistory.swift
//  VoxNotch
//
//  GRDB records for persisted Always-On sessions: the session itself, its
//  finalized transcript segments, and terminal (non-streaming) AI answers.
//

import Foundation
import GRDB

// MARK: - Session Record

/// One Always-On run, from start to stop (or crash recovery).
struct AlwaysOnSessionRecord: Codable, Identifiable, Equatable, Hashable, Sendable,
                               FetchableRecord, MutablePersistableRecord {

  static var databaseTableName: String { "always_on_session" }

  /// Stable UUID string, shared with `AlwaysOnState.sessionID` for the live session.
  var id: String

  var startedAt: Date

  /// Set when the session is stopped, fails, or is recovered at next launch after a crash.
  var endedAt: Date?

  /// Comma-separated `AudioSource` raw values, e.g. "microphone,systemAudio".
  var sources: String

  /// Optional user-editable title. Nil means the UI derives a timestamp title.
  var title: String?

  /// False until an explicit stop/failure closes it out. A session still false after
  /// the app has fully launched means it was never cleanly closed (crash/force-quit).
  var closedCleanly: Bool

  enum Columns {
    static let id = Column(CodingKeys.id)
    static let startedAt = Column(CodingKeys.startedAt)
    static let endedAt = Column(CodingKeys.endedAt)
    static let sources = Column(CodingKeys.sources)
    static let title = Column(CodingKeys.title)
    static let closedCleanly = Column(CodingKeys.closedCleanly)
  }

  var sourceList: [AudioSource] {
    sources.split(separator: ",").compactMap { AudioSource(rawValue: String($0)) }
  }

  static func allOrdered() -> QueryInterfaceRequest<AlwaysOnSessionRecord> {
    order(Columns.startedAt.desc)
  }

  /// Sessions still missing an `endedAt` — left open by a crash or force-quit.
  static func openSessions() -> QueryInterfaceRequest<AlwaysOnSessionRecord> {
    filter(Columns.endedAt == nil)
  }

  /// Sessions started before `date`, for retention cleanup.
  static func olderThan(_ date: Date) -> QueryInterfaceRequest<AlwaysOnSessionRecord> {
    filter(Columns.startedAt < date)
  }

  /// Substring search across this session's transcript text and AI answers.
  /// Returns matching sessions ordered newest-first. Empty/blank queries return nothing.
  static func search(query: String, in db: Database) throws -> [AlwaysOnSessionRecord] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let like = "%" + Self.escapeForLike(trimmed) + "%"
    let sql = """
      SELECT s.*
      FROM always_on_session s
      WHERE EXISTS (
        SELECT 1 FROM always_on_segment seg
        WHERE seg.sessionID = s.id AND seg.text LIKE ? ESCAPE '\\'
      ) OR EXISTS (
        SELECT 1 FROM always_on_answer ans
        WHERE ans.sessionID = s.id AND ans.markdown LIKE ? ESCAPE '\\'
      )
      ORDER BY s.startedAt DESC
      """
    return try AlwaysOnSessionRecord.fetchAll(db, sql: sql, arguments: [like, like])
  }

  /// Escapes SQLite LIKE wildcards so a literal search term doesn't act as a pattern.
  private static func escapeForLike(_ string: String) -> String {
    string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }
}

// MARK: - Segment Record

/// One finalized transcript line. Keyed by the live `LiveTranscriptSegment.id` so
/// consecutive finals from the same source that merge in-memory upsert the same row.
struct AlwaysOnSegmentRecord: Codable, Identifiable, Equatable, Hashable, Sendable,
                               FetchableRecord, MutablePersistableRecord {

  static var databaseTableName: String { "always_on_segment" }

  var id: String
  var sessionID: String
  var source: String
  var text: String
  var startedAt: Date
  var endedAt: Date

  enum Columns {
    static let id = Column(CodingKeys.id)
    static let sessionID = Column(CodingKeys.sessionID)
    static let source = Column(CodingKeys.source)
    static let text = Column(CodingKeys.text)
    static let startedAt = Column(CodingKeys.startedAt)
    static let endedAt = Column(CodingKeys.endedAt)
  }

  var audioSource: AudioSource? { AudioSource(rawValue: source) }

  static func forSession(_ sessionID: String) -> QueryInterfaceRequest<AlwaysOnSegmentRecord> {
    filter(Columns.sessionID == sessionID).order(Columns.startedAt)
  }
}

// MARK: - Answer Record

/// One terminal (done/stopped/failed) AI answer. Streaming/in-progress answers are
/// never persisted — only the final text once the answer stops changing.
struct AlwaysOnAnswerRecord: Codable, Identifiable, Equatable, Hashable, Sendable,
                              FetchableRecord, MutablePersistableRecord {

  static var databaseTableName: String { "always_on_answer" }

  var id: String
  var sessionID: String
  var trigger: String
  var model: String
  var templateName: String
  var markdown: String
  /// "done" | "stopped" | "failed"
  var status: String
  var failureMessage: String?
  var createdAt: Date
  var firstTokenLatencyMs: Double?

  enum Columns {
    static let id = Column(CodingKeys.id)
    static let sessionID = Column(CodingKeys.sessionID)
    static let trigger = Column(CodingKeys.trigger)
    static let model = Column(CodingKeys.model)
    static let templateName = Column(CodingKeys.templateName)
    static let markdown = Column(CodingKeys.markdown)
    static let status = Column(CodingKeys.status)
    static let failureMessage = Column(CodingKeys.failureMessage)
    static let createdAt = Column(CodingKeys.createdAt)
    static let firstTokenLatencyMs = Column(CodingKeys.firstTokenLatencyMs)
  }

  static func forSession(_ sessionID: String) -> QueryInterfaceRequest<AlwaysOnAnswerRecord> {
    filter(Columns.sessionID == sessionID).order(Columns.createdAt)
  }
}
