//
//  ShortcutRecorderField.swift
//  VoxNotch
//
//  Click-to-record field for a global key + modifier shortcut.
//

import AppKit
import SwiftUI

struct ShortcutRecorderField: View {

  @Binding var shortcut: KeyShortcut?
  let defaultShortcut: KeyShortcut

  @State private var isRecording = false
  @State private var monitor: Any?
  @State private var hint: String?

  var body: some View {
    HStack(spacing: 6) {
      Button {
        isRecording ? stopRecording() : startRecording()
      } label: {
        Text(isRecording ? (hint ?? "Type shortcut…") : (shortcut?.displayString ?? "None"))
          .font(.system(.body, design: .rounded).weight(.medium))
          .monospacedDigit()
          .frame(minWidth: 90)
      }
      .buttonStyle(.bordered)
      .tint(isRecording ? .accentColor : nil)

      if !isRecording {
        if shortcut != defaultShortcut {
          Button("Reset") { shortcut = defaultShortcut }
            .buttonStyle(.borderless)
        }
        if shortcut != nil {
          Button {
            shortcut = nil
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .help("Disable shortcut")
        }
      }
    }
    .onDisappear { stopRecording() }
  }

  private func startRecording() {
    isRecording = true
    hint = nil
    // Keep the global tap from acting on keys while recording.
    HotkeyManager.shared.isPaused = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
        stopRecording()
        return nil
      }
      if let recorded = KeyShortcut(event: event) {
        shortcut = recorded
        stopRecording()
      } else {
        hint = "Include ⌘, ⌃ or ⌥"
      }
      return nil
    }
  }

  private func stopRecording() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if isRecording { HotkeyManager.shared.isPaused = false }
    isRecording = false
    hint = nil
  }
}
