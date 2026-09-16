//
//  HistoryTab.swift
//  VoxNotch
//
//  History settings: toggle, retention, storage
//

import SwiftUI
import GRDB
import os.log

struct HistoryTab: View {

  @Bindable private var settings = SettingsManager.shared
  @State private var showClearAllConfirmation = false
  @State private var transcriptionCount: Int = 0

  private let retentionOptions: [(label: String, days: Int)] = [
    ("Forever", 0),
    ("7 days", 7),
    ("30 days", 30),
    ("90 days", 90),
    ("1 year", 365),
  ]

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $settings.historyEnabled) {
          InfoLabel(title: "Save dictation history", tooltip: "Saves all your transcriptions locally so you can search and review them later.")
        }
      } header: {
        Text("History")
          .settingsSectionHeading()
      } footer: {
        Text("View your history from the menu bar icon → History.")
          .settingsSectionNote()
      }

      if settings.historyEnabled {
        Section {
          Picker(selection: $settings.historyRetentionDays) {
            ForEach(retentionOptions, id: \.days) { option in
              Text(option.label).tag(option.days)
            }
          } label: {
            InfoLabel(title: "Auto-delete after", tooltip: "Automatically removes transcriptions older than this. Set to \"Forever\" to keep everything.")
          }

          Toggle(isOn: $settings.saveAudioRecordings) {
            InfoLabel(title: "Save audio recordings", tooltip: "Also saves the original audio alongside each transcription. Uses more disk space.")
          }
        } header: {
          Text("Retention")
          .settingsSectionHeading()
        } footer: {
          Text("Audio recordings let you re-transcribe with a different model later.")
          .settingsSectionNote()
        }
      }

      Section {
        if transcriptionCount > 0 {
          LabeledContent("Saved transcriptions") {
            Text("\(transcriptionCount)")
              .foregroundStyle(.secondary)
          }
        }

        Button("Clear All History", role: .destructive) {
          showClearAllConfirmation = true
        }
        .disabled(transcriptionCount == 0)
        .confirmationDialog("Clear all dictation history?", isPresented: $showClearAllConfirmation) {
          Button("Clear All", role: .destructive) {
            clearAllHistory()
          }
        } message: {
          Text("This will permanently delete all saved transcriptions and audio recordings. This cannot be undone.")
        }
      } header: {
        Text("Storage")
          .settingsSectionHeading()
      }
    }
    .settingsFormLayout()
    .onAppear {
      loadTranscriptionCount()
    }
  }

  private func loadTranscriptionCount() {
    Task {
      do {
        let count = try await DatabaseManager.shared.read { db in
          try TranscriptionRecord.fetchCount(db)
        }
        await MainActor.run {
          transcriptionCount = count
        }
      } catch {
        transcriptionCount = 0
      }
    }
  }

  private func clearAllHistory() {
    Task {
      do {
        _ = try await DatabaseManager.shared.write { db in
          try TranscriptionRecord.deleteAll(db)
        }
        await MainActor.run {
          transcriptionCount = 0
        }
      } catch {
        Logger(subsystem: "com.voxnotch", category: "HistoryTab").error("Failed to clear history: \(error.localizedDescription)")
      }
    }
  }
}
