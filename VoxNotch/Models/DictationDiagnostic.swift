import Foundation
import GRDB

/// Operational metadata only. Never stores dictated text, audio, or target app names.
struct DictationDiagnostic: Codable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "dictation_diagnostic"

    var id: Int64?
    var timestamp: Date
    var model: String
    var source: String
    var audioDuration: Double
    var modelReadyDuration: Double?
    var asrDuration: Double?
    var cleanupDuration: Double?
    var llmDuration: Double?
    var outputDuration: Double?
    var releaseToOutputDuration: Double?
    var outcome: String
    var failureReason: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    static func recent(limit: Int = 50) -> QueryInterfaceRequest<DictationDiagnostic> {
        order(Column("timestamp").desc).limit(limit)
    }
}

enum DiagnosticStatistics {
    static func percentile(_ values: [Double], fraction: Double) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }
}
