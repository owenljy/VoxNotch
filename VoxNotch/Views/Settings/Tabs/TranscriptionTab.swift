//
//  TranscriptionTab.swift
//  VoxNotch
//
//  Transcription settings: delivery, text cleanup, sound feedback
//

import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionTab: View {

  @Bindable private var settings = SettingsManager.shared

  var body: some View {
    Form {
      // MARK: Delivery
      Section {
        Toggle(isOn: $settings.useClipboardForOutput) {
          InfoLabel(title: "Instant output (paste via clipboard)", tooltip: "Pastes transcription directly into the active app using the clipboard. Temporarily replaces your clipboard contents.")
        }

        Toggle(isOn: $settings.restoreClipboard) {
          InfoLabel(title: "Restore clipboard after paste", tooltip: "After pasting, restores whatever was on your clipboard before the transcription.")
        }

        Toggle("Add space after transcription", isOn: $settings.addSpaceAfterTranscription)
      } header: {
        Text("Delivery")
          .settingsSectionHeading()
      } footer: {
        Text("Transcribed text is pasted into whichever app was active when you started recording.")
          .settingsSectionNote()
      }

      // MARK: Text Cleanup
      Section {
        Toggle(isOn: $settings.removeFillerWords) {
          InfoLabel(title: "Remove filler words", tooltip: "Removes \"um\", \"uh\", \"like\", \"you know\" and similar filler words from transcriptions.")
        }

        Toggle(isOn: $settings.applyITN) {
          InfoLabel(title: "Normalize numbers & currency", tooltip: "Convert spoken numbers to written form: \"two hundred\" \u{2192} \"200\", \"five dollars\" \u{2192} \"$5\"")
        }
      } header: {
        Text("Text Cleanup")
          .settingsSectionHeading()
      } footer: {
        Text("Automatic corrections applied to transcriptions before output. These run locally and don't use AI.")
          .settingsSectionNote()
      }

      // MARK: Sound Feedback
      Section {
        Toggle(isOn: $settings.successSoundEnabled) {
          InfoLabel(title: "Play sound on success", tooltip: "Play an audio cue when transcription is delivered.")
        }

        if settings.successSoundEnabled {
          HStack {
            Text("Sound")
            Spacer()
            Text(successSoundDisplayName)
              .foregroundStyle(.secondary)

            Button("Change\u{2026}") {
              pickCustomSound()
            }
            .buttonStyle(.borderless)

            if !settings.customSuccessSoundPath.isEmpty {
              Button {
                settings.customSuccessSoundPath = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .help("Reset to default system sound")
            }
          }

          HStack {
            Text("Volume")
            Slider(
              value: Binding(
                get: { Double(settings.successSoundVolume) },
                set: { settings.successSoundVolume = Float($0) }
              ),
              in: 0...1
            )
            Button {
              SoundManager.shared.previewSound()
            } label: {
              Label("Preview", systemImage: "speaker.wave.2")
                .font(InterfaceScale.Typography.caption)
            }
            .buttonStyle(.borderless)
          }
        }
      } header: {
        Text("Sound Feedback")
          .settingsSectionHeading()
      } footer: {
        Text("Plays an audio cue when transcription is complete and pasted.")
          .settingsSectionNote()
      }
    }
    .settingsFormLayout()
  }

  private var successSoundDisplayName: String {
    let path = settings.customSuccessSoundPath
    if path.isEmpty {
      return "Default"
    }
    return URL(fileURLWithPath: path).lastPathComponent
  }

  private func pickCustomSound() {
    let panel = NSOpenPanel()
    panel.title = "Choose a Success Sound"
    panel.allowedContentTypes = [.wav, .aiff, .mp3, .mpeg4Audio]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url {
      settings.customSuccessSoundPath = url.path
    }
  }
}
