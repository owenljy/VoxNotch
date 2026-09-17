//
//  DatabaseManager.swift
//  VoxNotch
//
//  SQLite database management using GRDB.swift
//

import Foundation
import GRDB
import os.log

// MARK: - Database Error

/// Errors from database operations
enum DatabaseError: LocalizedError {

  case notInitialized
  case migrationFailed(String)
  case queryFailed(String)

  var errorDescription: String? {
    switch self {
    case .notInitialized:
      return "Database not initialized"

    case .migrationFailed(let message):
      return "Migration failed: \(message)"

    case .queryFailed(let message):
      return "Query failed: \(message)"
    }
  }
}

// MARK: - Database Manager

/// Database manager for persisting transcriptions
///
/// Uses GRDB.swift with SQLite for local storage including FTS5 full-text search.
///
/// Thread Safety: serial `DispatchQueue` (`queue`) protects all access to `dbPool`.
final class DatabaseManager: @unchecked Sendable {

  // MARK: - Singleton

  static let shared = DatabaseManager()

  // MARK: - Properties

  private var dbPool: DatabasePool?
  private let queue = DispatchQueue(label: "com.voxnotch.database", qos: .userInitiated)
  private let logger = Logger(subsystem: "com.voxnotch", category: "DatabaseManager")

  /// Database file URL
  let databaseURL: URL

  /// Directory containing the database
  let databaseDirectory: URL

  /// Whether the database is ready
  var isReady: Bool {
    queue.sync { dbPool != nil }
  }

  // MARK: - Initialization

  private init() {
    /// Set up database path
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    self.databaseDirectory = appSupport.appendingPathComponent("VoxNotch", isDirectory: true)
    self.databaseURL = databaseDirectory.appendingPathComponent("voxnotch.sqlite")
  }

  // MARK: - Setup

  /// Initialize the database (call on app launch)
  func initialize() async throws {
    logger.info("Initializing database at \(self.databaseURL.path)")

    /// Create directory if needed
    try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)

    /// Configure database
    var config = Configuration()
    #if DEBUG
    config.prepareDatabase { db in
      db.trace { [weak self] event in
        self?.logger.debug("SQL: \(event.description)")
      }
    }
    #endif

    /// Open database pool
    let pool = try DatabasePool(path: databaseURL.path, configuration: config)
    queue.sync { self.dbPool = pool }

    /// Run migrations
    try await runMigrations(pool)

    logger.info("Database initialized successfully")
  }

  // MARK: - Migrations

  private func runMigrations(_ pool: DatabasePool) async throws {
    var migrator = DatabaseMigrator()

    /// v1: Create transcription table with FTS5
    migrator.registerMigration("v1_transcription") { db in
      /// Main transcription table
      try db.create(table: "transcription") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("rawText", .text).notNull()
        t.column("processedText", .text)
        t.column("model", .text).notNull()
        t.column("duration", .double).notNull()
        t.column("confidence", .double)
        t.column("timestamp", .datetime).notNull()
        t.column("audioPath", .text)
        t.column("metadata", .text)
      }

      /// Index on timestamp for sorting
      try db.create(index: "idx_transcription_timestamp", on: "transcription", columns: ["timestamp"])

      /// FTS5 virtual table for full-text search
      try db.execute(sql: """
        CREATE VIRTUAL TABLE transcription_fts USING fts5(
          rawText,
          processedText,
          content='transcription',
          content_rowid='id'
        )
        """)

      /// Sync triggers to keep FTS5 in sync with main table

      /// After INSERT: add new row to FTS
      try db.execute(sql: """
        CREATE TRIGGER transcription_ai AFTER INSERT ON transcription BEGIN
          INSERT INTO transcription_fts(rowid, rawText, processedText)
          VALUES (new.id, new.rawText, new.processedText);
        END
        """)

      /// After DELETE: remove row from FTS
      try db.execute(sql: """
        CREATE TRIGGER transcription_ad AFTER DELETE ON transcription BEGIN
          INSERT INTO transcription_fts(transcription_fts, rowid, rawText, processedText)
          VALUES('delete', old.id, old.rawText, old.processedText);
        END
        """)

      /// After UPDATE: update row in FTS (delete + insert)
      try db.execute(sql: """
        CREATE TRIGGER transcription_au AFTER UPDATE ON transcription BEGIN
          INSERT INTO transcription_fts(transcription_fts, rowid, rawText, processedText)
          VALUES('delete', old.id, old.rawText, old.processedText);
          INSERT INTO transcription_fts(rowid, rawText, processedText)
          VALUES (new.id, new.rawText, new.processedText);
        END
        """)
    }

    migrator.registerMigration("v2_dictation_diagnostic") { db in
      try db.create(table: "dictation_diagnostic") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("timestamp", .datetime).notNull()
        t.column("model", .text).notNull()
        t.column("source", .text).notNull()
        t.column("audioDuration", .double).notNull()
        t.column("modelReadyDuration", .double)
        t.column("asrDuration", .double)
        t.column("cleanupDuration", .double)
        t.column("llmDuration", .double)
        t.column("outputDuration", .double)
        t.column("releaseToOutputDuration", .double)
        t.column("outcome", .text).notNull()
        t.column("failureReason", .text)
      }
      try db.create(index: "idx_diagnostic_timestamp", on: "dictation_diagnostic", columns: ["timestamp"])
    }

    /// Run all pending migrations
    do {
      try migrator.migrate(pool)
      logger.info("Migrations completed successfully")
    } catch {
      logger.error("Migration failed: \(error.localizedDescription)")
      throw DatabaseError.migrationFailed(error.localizedDescription)
    }
  }

  // MARK: - Database Access

  /// Get the database file path
  var databasePath: String {
    databaseURL.path
  }

  /// Check if database file exists
  var databaseFileExists: Bool {
    FileManager.default.fileExists(atPath: databaseURL.path)
  }

  /// Perform a read-only database operation
  func read<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
    guard let pool = queue.sync(execute: { dbPool }) else {
      throw DatabaseError.notInitialized
    }

    return try await pool.read(block)
  }

  /// Perform a write database operation
  func write<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
    guard let pool = queue.sync(execute: { dbPool }) else {
      throw DatabaseError.notInitialized
    }

    return try await pool.write(block)
  }

}
