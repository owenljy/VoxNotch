//
//  SettingsView.swift
//  VoxNotch
//
//  SwiftUI Settings window with mode-based sidebar navigation
//

import SwiftUI

// MARK: - Settings Panel

/// Settings panel identifiers organized by mode
enum SettingsPanel: String, CaseIterable, Identifiable {
  case general
  case recording
  case speechModel
  case output
  case ai
  case history
  case diagnostics

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .recording: "Recording"
    case .speechModel: "Speech Model"
    case .output: "Transcription"
    case .ai: "Tones"
    case .history: "History"
    case .diagnostics: "Diagnostics"
    }
  }

  var icon: String {
    switch self {
    case .general: "gear"
    case .recording: "waveform.circle"
    case .speechModel: "waveform"
    case .output: "text.cursor"
    case .ai: "sparkles"
    case .history: "clock.arrow.circlepath"
    case .diagnostics: "chart.bar.xaxis"
    }
  }
}

// MARK: - Main Settings View

/// Main settings view with mode-based sidebar navigation
struct SettingsView: View {

  @State private var selectedPanel: SettingsPanel = .recording

  var body: some View {
    HStack(spacing: 0) {
      List(selection: $selectedPanel) {
        Section("Input") {
          Label("Recording", systemImage: "waveform.circle")
            .tag(SettingsPanel.recording)
          Label("Speech Model", systemImage: "waveform")
            .tag(SettingsPanel.speechModel)
        }

        Section("Output") {
          Label("Transcription", systemImage: "text.cursor")
            .tag(SettingsPanel.output)
          Label("Tones", systemImage: "sparkles")
            .tag(SettingsPanel.ai)
        }

        Section("App") {
          Label("General", systemImage: "gear")
            .tag(SettingsPanel.general)
          Label("History", systemImage: "clock.arrow.circlepath")
            .tag(SettingsPanel.history)
          Label("Diagnostics", systemImage: "chart.bar.xaxis")
            .tag(SettingsPanel.diagnostics)
        }
      }
      .listStyle(.sidebar)
      .font(InterfaceScale.Typography.body)
      .frame(width: 200)

      Divider()

      VStack(alignment: .leading, spacing: 0) {
        Text(selectedPanel.title)
          .font(InterfaceScale.Typography.title)
          .fontWeight(.semibold)
          .padding(.horizontal, InterfaceScale.Space.section)
          .padding(.top, InterfaceScale.Space.section)
          .padding(.bottom, InterfaceScale.Space.medium)

        detailView
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: 860, height: 580)
    .onReceive(NotificationCenter.default.publisher(for: .settingsNavigateTo)) { notification in
      if let rawValue = notification.userInfo?["panel"] as? String,
         let panel = SettingsPanel(rawValue: rawValue)
      {
        selectedPanel = panel
      }
    }
  }

  @ViewBuilder
  private var detailView: some View {
    switch selectedPanel {
    case .general:
      GeneralTab()

    case .recording:
      RecordingTab()

    case .speechModel:
      SpeechModelTab()

    case .output:
      TranscriptionTab()

    case .ai:
      TonesTab()

    case .history:
      HistoryTab()

    case .diagnostics:
      DiagnosticsTab()
    }
  }
}


#Preview {
  SettingsView()
}
