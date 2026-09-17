import SwiftUI
import GRDB

struct DiagnosticsTab: View {
    @State private var records: [DictationDiagnostic] = []
    @State private var selectedID: Int64?
    @State private var showClearConfirmation = false
    @State private var loadError: String?

    private var selected: DictationDiagnostic? { records.first { $0.id == selectedID } }
    private var latencies: [Double] { records.compactMap(\.releaseToOutputDuration) }

    var body: some View {
        Form {
            Section("Recent 50 dictations") {
                HStack(spacing: 24) {
                    metric("Median", DiagnosticStatistics.percentile(latencies, fraction: 0.5))
                    metric("P95", DiagnosticStatistics.percentile(latencies, fraction: 0.95))
                    VStack(alignment: .leading) {
                        Text("Delivered").font(.caption).foregroundStyle(.secondary)
                        Text("\(records.filter { $0.outcome == "inserted" }.count) / \(records.count)")
                            .font(.title3.monospacedDigit())
                    }
                }
                Text("From releasing the hotkey to delivery. Streaming models may process audio while recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Outcomes") {
                HStack(spacing: 18) {
                    Text("Inserted: \(count("inserted"))")
                    Text("Clipboard: \(count("clipboard") + count("clipboardAborted"))")
                    Text("Rejected: \(count("rejected"))")
                    Text("Failed: \(count("failed") + count("failedOutput"))")
                }
                .font(.caption.monospacedDigit())
            }

            Section("Recent records") {
                Button("Refresh") { Task { await reload() } }
                if records.isEmpty {
                    ContentUnavailableView("No diagnostics yet", systemImage: "chart.bar.xaxis")
                } else {
                    List(records, selection: $selectedID) { record in
                        HStack {
                            Text(record.timestamp, style: .date)
                            Text(record.timestamp, style: .time)
                            Spacer()
                            Text(record.model).lineLimit(1)
                            Text(record.releaseToOutputDuration.map { String(format: "%.2f s", $0) } ?? "—")
                                .monospacedDigit()
                            Text(outcomeLabel(record.outcome))
                        }
                        .font(.caption)
                        .tag(record.id)
                    }
                    .frame(height: 170)
                }
                if let selected {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Details").font(.headline)
                        Text("Source: \(selected.source) · Recording: \(format(selected.audioDuration))")
                        Text("Model ready: \(format(selected.modelReadyDuration)) · ASR after release: \(format(selected.asrDuration))")
                        Text("Cleanup: \(format(selected.cleanupDuration)) · LLM: \(format(selected.llmDuration)) · Output: \(format(selected.outputDuration))")
                        if let reason = selected.failureReason { Text("Reason: \(reasonLabel(reason))") }
                    }
                    .font(.caption.monospacedDigit())
                    .textSelection(.enabled)
                }
            }

            Section("Privacy") {
                Text("Diagnostics stay on this Mac. They contain timings, model, audio source and outcome—never audio, dictated text or target app names.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear diagnostics", role: .destructive) { showClearConfirmation = true }
                    .disabled(records.isEmpty)
                    .confirmationDialog("Clear all diagnostic records?", isPresented: $showClearConfirmation) {
                        Button("Clear diagnostics", role: .destructive) { Task { await clear() } }
                    }
                if let loadError { Text(loadError).foregroundStyle(.red).font(.caption) }
            }
        }
        .settingsFormLayout()
        .task { await reload() }
    }

    private func metric(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.2f s", $0) } ?? "—")
                .font(.title3.monospacedDigit())
        }
    }

    private func count(_ outcome: String) -> Int { records.filter { $0.outcome == outcome }.count }
    private func format(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "—" }
    private func format(_ value: Double) -> String { String(format: "%.2f s", value) }

    private func outcomeLabel(_ outcome: String) -> String {
        switch outcome {
        case "inserted": "Inserted"
        case "clipboard": "Copied"
        case "clipboardAborted": "Target changed"
        case "rejected": "Rejected"
        case "failed", "failedOutput": "Failed"
        default: "Cancelled"
        }
    }

    private func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "tooShort": "Recording too short"
        case "capture": "Audio capture failed"
        case "noSpeech": "No speech detected"
        case "lowConfidence": "Low ASR confidence"
        case "targetChanged": "Target window or input changed"
        case "transcriptionOrModel": "Model preparation or transcription failed"
        default: reason
        }
    }

    private func reload() async {
        do {
            records = try await DatabaseManager.shared.read { db in
                try DictationDiagnostic.recent().fetchAll(db)
            }
            loadError = nil
        } catch {
            loadError = "Could not load diagnostics: \(error.localizedDescription)"
        }
    }

    private func clear() async {
        do {
            _ = try await DatabaseManager.shared.write { db in
                try DictationDiagnostic.deleteAll(db)
            }
            selectedID = nil
            await reload()
        } catch {
            loadError = "Could not clear diagnostics: \(error.localizedDescription)"
        }
    }
}
