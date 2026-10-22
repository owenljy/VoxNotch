//
//  AlwaysOnHistoryStore.swift
//  VoxNotch
//
//  Persists Always-On sessions, finalized transcript segments, and terminal
//  AI answers to the shared GRDB database. Gated by `AssistantSettings
//  .saveHistory` (on by default); crash recovery and retention cleanup run
//  once at launch.
//

import Foundation
import GRDB
import os

// MARK: - Dependency Seams

/// The subset of `DatabaseManager` this store needs. Lets tests swap in an
/// isolated, in-memory `DatabaseQueue` instead of the real on-disk database.
protocol AlwaysOnDatabaseWriting: Sendable {
  func read<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T
  func write<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T
}

extension DatabaseManager: AlwaysOnDatabaseWriting {}

/// `DatabaseQueue` already implements matching `read`/`write` via GRDB's
/// `DatabaseWriter` protocol extensions — useful as a fast in-memory stand-in
/// for tests and previews. Declared here (in this module) so the conformance
/// doesn't become a disallowed cross-module "retroactive conformance" when
/// written from the test target.
extension DatabaseQueue: AlwaysOnDatabaseWriting {}

/// The settings this store reads. Lets tests supply a fake instead of the
/// real `AssistantSettings` singleton.
protocol AlwaysOnHistorySettingsProviding: AnyObject {
  var saveHistory: Bool { get }
  var historyRetentionDays: Int { get }
}

extension AssistantSettings: AlwaysOnHistorySettingsProviding {}

// MARK: - Store

@MainActor
final class AlwaysOnHistoryStore {

  static let shared = AlwaysOnHistoryStore()

  private let databaseAccess: any AlwaysOnDatabaseWriting
  private let settings: any AlwaysOnHistorySettingsProviding
  private let logger = Logger(subsystem: "com.voxnotch", category: "AlwaysOnHistoryStore")

  /// Tail of the write chain. Writes run strictly in call order, so a segment or
  /// answer can never reach the database before its session row (FOREIGN KEY).
  private var lastWrite: Task<Void, Never>?

  init(
    databaseManager: (any AlwaysOnDatabaseWriting)? = nil,
    settings: (any AlwaysOnHistorySettingsProviding)? = nil
  ) {
    self.databaseAccess = databaseManager ?? DatabaseManager.shared
    self.settings = settings ?? AssistantSettings.shared
  }

  // MARK: Session Lifecycle

  /// Creates the session row. Call once per Always-On start, after sources
  /// are confirmed non-empty. A no-op when history saving is off.
  @discardableResult
  func startSession(id: String, sources: Set<AudioSource>, startedAt: Date) -> Task<Void, Never> {
    guard settings.saveHistory else { return Task {} }
    let sourceString = AudioSource.allCases.filter(sources.contains).map(\.rawValue).joined(separator: ",")
    let record = AlwaysOnSessionRecord(
      id: id, startedAt: startedAt, endedAt: nil, sources: sourceString, title: nil, closedCleanly: false
    )
    return enqueueWrite("session") { db in
      var row = record
      try row.save(db)
    }
  }

  /// Marks the session as ended. `cleanly` is true for a normal stop; pass
  /// false for failures. Always runs (even if `saveHistory` is currently
  /// off) so a session started while saving was on still gets closed; if the
  /// row was never written this is a harmless no-op.
  @discardableResult
  func endSession(id: String, endedAt: Date, cleanly: Bool) -> Task<Void, Never> {
    enqueueWrite("session end") { db in
      guard var row = try AlwaysOnSessionRecord.fetchOne(db, key: id) else { return }
      row.endedAt = endedAt
      if cleanly { row.closedCleanly = true }
      try row.update(db)
    }
  }

  // MARK: Transcript

  /// Upserts a finalized transcript line, keyed by the segment's own id so
  /// consecutive finals merged in-memory (same id, growing text) overwrite
  /// the same row instead of duplicating it.
  @discardableResult
  func recordSegment(_ segment: LiveTranscriptSegment, sessionID: String) -> Task<Void, Never> {
    guard settings.saveHistory else { return Task {} }
    let record = AlwaysOnSegmentRecord(
      id: segment.id.uuidString,
      sessionID: sessionID,
      source: segment.source.rawValue,
      text: segment.text,
      startedAt: segment.startedAt,
      endedAt: segment.endedAt
    )
    return enqueueWrite("segment") { db in
      try Self.ensureSession(sessionID, startedAt: record.startedAt, in: db)
      var row = record
      try row.save(db)
    }
  }

  // MARK: AI Answers

  /// Persists an answer once it reaches a terminal state (`done`, `stopped`,
  /// or `failed`). Streaming/waiting answers are ignored — callers may invoke
  /// this on every status change without special-casing in-progress ones.
  @discardableResult
  func recordAnswer(_ answer: AssistantAnswer, sessionID: String) -> Task<Void, Never> {
    guard settings.saveHistory else { return Task {} }

    let status: String
    let failureMessage: String?
    switch answer.status {
    case .done:
      status = "done"
      failureMessage = nil
    case .stopped:
      status = "stopped"
      failureMessage = nil
    case .failed(let message):
      status = "failed"
      failureMessage = message
    case .waiting, .streaming:
      return Task {}
    }

    let record = AlwaysOnAnswerRecord(
      id: answer.id.uuidString,
      sessionID: sessionID,
      trigger: answer.trigger.rawValue,
      model: answer.model,
      templateName: answer.templateName,
      markdown: answer.markdown,
      status: status,
      failureMessage: failureMessage,
      createdAt: answer.createdAt,
      firstTokenLatencyMs: answer.firstTokenLatency?.milliseconds
    )
    return enqueueWrite("answer") { db in
      try Self.ensureSession(sessionID, startedAt: record.createdAt, in: db)
      var row = record
      try row.save(db)
    }
  }

  // MARK: Write Ordering

  private func enqueueWrite(
    _ label: String,
    _ work: @escaping @Sendable (Database) throws -> Void
  ) -> Task<Void, Never> {
    let previous = lastWrite
    let task = Task { [databaseAccess, logger] in
      await previous?.value
      do {
        try await databaseAccess.write { db in try work(db) }
      } catch {
        logger.error("Failed to save Always-On \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
    lastWrite = task
    return task
  }

  /// Creates a placeholder session row when history saving was switched on mid-session.
  private nonisolated static func ensureSession(_ id: String, startedAt: Date, in db: Database) throws {
    guard try AlwaysOnSessionRecord.fetchOne(db, key: id) == nil else { return }
    var session = AlwaysOnSessionRecord(
      id: id, startedAt: startedAt, endedAt: nil, sources: "", title: nil, closedCleanly: false
    )
    try session.insert(db)
  }

  // MARK: Reading & Deletion

  func sessions(matching query: String = "") async throws -> [AlwaysOnSessionRecord] {
    try await databaseAccess.read { db in
      if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try AlwaysOnSessionRecord.allOrdered().fetchAll(db)
      } else {
        try AlwaysOnSessionRecord.search(query: query, in: db)
      }
    }
  }

  func segments(for sessionID: String) async throws -> [AlwaysOnSegmentRecord] {
    try await databaseAccess.read { db in
      try AlwaysOnSegmentRecord.forSession(sessionID).fetchAll(db)
    }
  }

  func answers(for sessionID: String) async throws -> [AlwaysOnAnswerRecord] {
    try await databaseAccess.read { db in
      try AlwaysOnAnswerRecord.forSession(sessionID).fetchAll(db)
    }
  }

  func counts() async throws -> (sessions: Int, segments: Int, answers: Int) {
    try await databaseAccess.read { db in
      (
        try AlwaysOnSessionRecord.fetchCount(db),
        try AlwaysOnSegmentRecord.fetchCount(db),
        try AlwaysOnAnswerRecord.fetchCount(db)
      )
    }
  }

  func renameSession(id: String, title: String?) async throws {
    try await databaseAccess.write { db in
      guard var row = try AlwaysOnSessionRecord.fetchOne(db, key: id) else { return }
      let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
      row.title = trimmed?.isEmpty == false ? trimmed : nil
      try row.update(db)
    }
  }

  func deleteSession(id: String) async throws {
    _ = try await databaseAccess.write { db in
      try AlwaysOnSessionRecord.deleteOne(db, key: id)
    }
  }

  func deleteAllHistory() async throws {
    _ = try await databaseAccess.write { db in
      try AlwaysOnSessionRecord.deleteAll(db)
    }
  }

  // MARK: Retention & Crash Recovery

  /// Deletes sessions (and their segments/answers, via cascade) started
  /// before the retention window. A no-op when retention is "Forever" (0).
  @discardableResult
  func pruneExpiredSessions(now: Date = Date()) -> Task<Void, Never> {
    let days = settings.historyRetentionDays
    guard days > 0 else { return Task {} }
    let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? .distantPast
    return Task { [databaseAccess, logger] in
      do {
        _ = try await databaseAccess.write { db in
          try AlwaysOnSessionRecord.olderThan(cutoff).deleteAll(db)
        }
      } catch {
        logger.error("Failed to prune Always-On history: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// Closes sessions left open by a crash or force-quit (no `endedAt`).
  /// `endedAt` is backfilled from the session's last known activity so it
  /// displays sensibly; `closedCleanly` is intentionally left false — that
  /// flag is the permanent record that this session wasn't shut down
  /// normally. Call once per launch, after migrations run.
  @discardableResult
  func recoverCrashedSessions() -> Task<Void, Never> {
    Task { [databaseAccess, logger] in
      do {
        _ = try await databaseAccess.write { db in
          let openSessions = try AlwaysOnSessionRecord.openSessions().fetchAll(db)
          for var session in openSessions {
            let segments = try AlwaysOnSegmentRecord.forSession(session.id).fetchAll(db)
            let answers = try AlwaysOnAnswerRecord.forSession(session.id).fetchAll(db)
            let lastActivity = (segments.map(\.endedAt) + answers.map(\.createdAt)).max()
            session.endedAt = lastActivity ?? session.startedAt
            try session.update(db)
          }
        }
      } catch {
        logger.error("Failed to recover crashed Always-On sessions: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}

// MARK: - Duration Helper

private extension Duration {
  var milliseconds: Double {
    let (seconds, attoseconds) = components
    return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
  }
}
