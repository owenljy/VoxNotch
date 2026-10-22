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
  @Bindable private var assistantSettings = AssistantSettings.shared
  @State private var showClearAllConfirmation = false
  @State private var showClearAlwaysOnConfirmation = false
  @State private var transcriptionCount: Int = 0
  @State private var alwaysOnCounts: (sessions: Int, segments: Int, answers: Int) = (0, 0, 0)

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
        Toggle(isOn: $assistantSettings.saveHistory) {
          InfoLabel(title: "Save Always-On history", tooltip: "Saves finalized live transcript turns and completed AI answers locally. This is on by default.")
        }

        Picker(selection: $assistantSettings.historyRetentionDays) {
          ForEach(retentionOptions, id: \.days) { option in
            Text(option.label).tag(option.days)
          }
        } label: {
          InfoLabel(title: "Auto-delete Always-On after", tooltip: "Automatically removes saved Always-On sessions older than this. Set to \"Forever\" to keep everything.")
        }
        .disabled(!assistantSettings.saveHistory)
      } header: {
        Text("Always-On History")
          .settingsSectionHeading()
      } footer: {
        Text("Always-On history can include other meeting participants. Data stays local in the VoxNotch database unless you copy or export it.")
          .settingsSectionNote()
      }

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
        Button("Open Always-On History") {
          if #available(macOS 26.0, *) {
            AlwaysOnHistoryWindowController.shared.show()
          }
        }
        .disabled(alwaysOnCounts.sessions == 0)

        if alwaysOnCounts.sessions > 0 {
          LabeledContent("Saved Always-On sessions") {
            Text("\(alwaysOnCounts.sessions) sessions · \(alwaysOnCounts.segments) turns · \(alwaysOnCounts.answers) answers")
              .foregroundStyle(.secondary)
          }
        }

        Button("Clear All Always-On History", role: .destructive) {
          showClearAlwaysOnConfirmation = true
        }
        .disabled(alwaysOnCounts.sessions == 0)
        .confirmationDialog("Clear all Always-On history?", isPresented: $showClearAlwaysOnConfirmation) {
          Button("Clear All", role: .destructive) {
            clearAlwaysOnHistory()
          }
        } message: {
          Text("This permanently deletes all saved Always-On sessions, transcripts, and AI answers. This cannot be undone.")
        }

        Divider()

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
      loadAlwaysOnCounts()
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

  private func loadAlwaysOnCounts() {
    Task {
      do {
        let counts = try await AlwaysOnHistoryStore.shared.counts()
        await MainActor.run {
          alwaysOnCounts = counts
        }
      } catch {
        alwaysOnCounts = (0, 0, 0)
      }
    }
  }

  private func clearAlwaysOnHistory() {
    Task {
      do {
        try await AlwaysOnHistoryStore.shared.deleteAllHistory()
        await MainActor.run {
          alwaysOnCounts = (0, 0, 0)
        }
      } catch {
        Logger(subsystem: "com.voxnotch", category: "HistoryTab").error("Failed to clear Always-On history: \(error.localizedDescription)")
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
