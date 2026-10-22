//
//  AlwaysOnTab.swift
//  VoxNotch
//
//  Settings for Always-On mode: shortcuts, audio sources, automatic answers,
//  system prompt and panel appearance.
//

import SwiftUI

struct AlwaysOnTab: View {

  @Bindable private var settings = AssistantSettings.shared
  private let state = AlwaysOnState.shared

  /// 0 = entire session.
  private static let contextWindows: [Double] = [0, 5, 10, 20, 30]

  var body: some View {
    Form {
      sessionSection
      promptSection
      answersSection
      sourcesSection
      appearanceSection
    }
    .formStyle(.grouped)
  }

  // MARK: - Session

  private var sessionSection: some View {
    Section {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(state.isActive ? "Always-On is running" : "Always-On is off")
          Text("Live transcript and AI answers in a panel under the notch.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(state.isActive ? "Stop" : "Start") { AlwaysOnController.shared.toggle() }
      }

      LabeledContent("Start / stop") {
        ShortcutRecorderField(shortcut: $settings.toggleShortcut, defaultShortcut: .defaultToggleAlwaysOn)
      }
      LabeledContent("Ask AI now") {
        ShortcutRecorderField(shortcut: $settings.askShortcut, defaultShortcut: .defaultAsk)
      }
    } header: {
      Text("Session")
    } footer: {
      Text("Shortcuts work from any app. Ask is only captured while Always-On is running.")
    }
  }

  // MARK: - Sources

  private var sourcesSection: some View {
    Section {
      Toggle(isOn: $settings.useMicrophone) {
        Label("Microphone — your voice (Me)", systemImage: "mic.fill")
      }
      Toggle(isOn: $settings.useSystemAudio) {
        Label("System audio — meeting or video (Them)", systemImage: "speaker.wave.2.fill")
      }
      Toggle(isOn: $settings.suppressEcho) {
        InfoLabel(
          title: "Ignore speaker echo",
          tooltip: "Without headphones the microphone also hears the meeting. Microphone lines that repeat what system audio just said are dropped."
        )
      }
      .disabled(!(settings.useMicrophone && settings.useSystemAudio))
    } header: {
      Text("Audio Sources")
    } footer: {
      Text("Transcribed on-device with Parakeet v2 (English). System audio needs Screen Recording permission. Changes apply the next time Always-On starts.")
    }
  }

  // MARK: - Answers

  private var answersSection: some View {
    Section {
      Toggle("Answer automatically", isOn: $settings.autoAnswer)

      Toggle(isOn: $settings.answerQuestionsImmediately) {
        InfoLabel(
          title: "Answer questions instantly",
          tooltip: "Starts answering the moment the other person pauses after a question. If they keep talking, that answer is discarded."
        )
      }
      .disabled(!settings.autoAnswer)

      LabeledContent {
        HStack {
          Slider(value: $settings.autoAnswerSilence, in: 0.8...5, step: 0.1)
          Text(String(format: "%.1fs", settings.autoAnswerSilence))
            .monospacedDigit()
            .frame(width: 36, alignment: .trailing)
        }
      } label: {
        InfoLabel(
          title: "Answer after silence",
          tooltip: "When the other person stops without asking a question, wait this long before answering."
        )
      }
      .disabled(!settings.autoAnswer)

      Picker(selection: $settings.contextWindowMinutes) {
        ForEach(Self.contextWindows, id: \.self) { minutes in
          Text(minutes == 0 ? "Entire session" : "Last \(Int(minutes)) min").tag(minutes)
        }
      } label: {
        InfoLabel(
          title: "Transcript sent to AI",
          tooltip: "The whole conversation gives the best answers. A shorter window gives a faster first token and lower cost in long sessions."
        )
      }

      Toggle(isOn: $settings.includePreviousAnswers) {
        InfoLabel(
          title: "Include earlier AI answers",
          tooltip: "Earlier suggestions are sent with each request, so the AI builds on what it already gave you (e.g. moves from clarifying questions to code) instead of repeating itself."
        )
      }

      if !settings.isProviderConfigured {
        HStack {
          Label("No AI provider configured", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Spacer()
          Button("Set Up API Key…") {
            SettingsNavigation.shared.requestedPanel = .aiProvider
          }
        }
      }
    } header: {
      Text("AI Answers")
    }
  }

  // MARK: - Prompt

  private var promptSection: some View {
    Section {
      Picker(selection: $settings.promptTemplateID) {
        ForEach(AssistantPromptTemplate.all) { template in
          Label(template.name, systemImage: template.icon).tag(template.id)
        }
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text("Template")
          Text(settings.selectedTemplate.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      PromptEditorView(text: $settings.systemPrompt)
        .id(settings.promptTemplateID)

      HStack {
        if settings.isPromptCustomized {
          Label("Edited", systemImage: "pencil")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Reset Template") { settings.resetPrompt() }
          .disabled(!settings.isPromptCustomized)
      }
    } header: {
      Text("Prompt")
    } footer: {
      Text("Each template keeps its own edits. Switch templates any time from the AI pane in the panel. The transcript and your earlier AI answers are added automatically.")
    }
  }

  // MARK: - Appearance

  private var appearanceSection: some View {
    Section {
      ColorPicker("Text color", selection: hexBinding(\.textColorHex, fallback: .white), supportsOpacity: false)
      ColorPicker("“Me” label", selection: hexBinding(\.meColorHex, fallback: .notchGreen), supportsOpacity: false)
      ColorPicker("“Them” label", selection: hexBinding(\.themColorHex, fallback: .notchBlue), supportsOpacity: false)

      LabeledContent("Background tint") {
        HStack {
          Slider(value: $settings.backgroundOpacity, in: 0...0.9)
          Text("\(Int((settings.backgroundOpacity * 100).rounded()))%")
            .monospacedDigit()
            .frame(width: 36, alignment: .trailing)
        }
      }

      LabeledContent("Text size") {
        HStack {
          Slider(value: $settings.fontSize, in: 11...18, step: 1)
          Text("\(Int(settings.fontSize)) pt")
            .monospacedDigit()
            .frame(width: 36, alignment: .trailing)
        }
      }

      AppearancePreview(style: AlwaysOnStyle(settings: settings))

      HStack {
        Spacer()
        Button("Reset Appearance") { resetAppearance() }
      }
    } header: {
      Text("Appearance")
    } footer: {
      Text("Lower tint shows more of the blurred background; higher tint is easier to read.")
    }
  }

  private func hexBinding(_ keyPath: ReferenceWritableKeyPath<AssistantSettings, String>, fallback: Color) -> Binding<Color> {
    Binding(
      get: { Color(hex: settings[keyPath: keyPath]) ?? fallback },
      set: { settings[keyPath: keyPath] = $0.hexString }
    )
  }

  private func resetAppearance() {
    typealias Defaults = AssistantSettings.Defaults
    settings.textColorHex = Defaults.textColorHex
    settings.meColorHex = Defaults.meColorHex
    settings.themColorHex = Defaults.themColorHex
    settings.backgroundOpacity = Defaults.backgroundOpacity
    settings.fontSize = Defaults.fontSize
  }
}

// MARK: - Preview

private struct AppearancePreview: View {

  let style: AlwaysOnStyle

  private static func segment(_ source: AudioSource, _ text: String) -> LiveTranscriptSegment {
    LiveTranscriptSegment(id: UUID(), source: source, text: text, startedAt: .now, endedAt: .now, isFinal: true)
  }

  private static let rows = [
    segment(.systemAudio, "How would you validate that hypothesis?"),
    segment(.microphone, "I'd start with the funnel data."),
  ]

  var body: some View {
    ZStack {
      // Stand-in for whatever is on screen behind the panel.
      LinearGradient(
        colors: [.purple.opacity(0.7), .blue.opacity(0.6), .orange.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      VStack(alignment: .leading, spacing: 8) {
        ForEach(Self.rows) { TranscriptRowView(segment: $0, style: style) }
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
        Text(try! AttributedString(markdown: "**Say:** I'd compare activation before and after the redesign."))
          .font(.system(size: style.fontSize))
          .foregroundStyle(style.text)
      }
      .padding(14)
      .background {
        ZStack {
          Rectangle().fill(.ultraThinMaterial)
          Color.black.opacity(style.tintOpacity)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12)))
      .environment(\.colorScheme, .dark)
      .padding(18)
    }
    .frame(maxWidth: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
