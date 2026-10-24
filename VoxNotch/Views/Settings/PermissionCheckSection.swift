//
//  PermissionCheckSection.swift
//  VoxNotch
//
//  "Before Your Interview" check: shows every permission Always-On relies on and
//  lets the user answer all macOS prompts up front, before the screen is shared.
//

import AppKit
import AVFoundation
import SwiftUI

struct PermissionCheckSection: View {

  private let settings = AssistantSettings.shared

  @State private var microphone: AVAuthorizationStatus = .notDetermined
  @State private var systemAudio = false
  @State private var apiKey: AssistantSettings.APIKeyAccess = .missing
  @State private var accessibility = false
  @State private var localNetwork = false
  @State private var isRunning = false

  var body: some View {
    Section {
      PermissionRow(title: "Microphone (Me)", icon: "mic.fill", status: microphoneStatus)
      PermissionRow(title: "Screen & System Audio Recording (Them)", icon: "speaker.wave.2.fill", status: systemAudioStatus)
      PermissionRow(title: "Saved API key (Keychain)", icon: "key.fill", status: apiKeyStatus)
      PermissionRow(title: "Accessibility (global shortcuts)", icon: "keyboard", status: accessibilityStatus)
      PermissionRow(title: "Local Network (Phone View)", icon: "iphone", status: localNetworkStatus)

      HStack {
        Spacer()
        Button {
          Task { await runCheck() }
        } label: {
          if isRunning {
            ProgressView().controlSize(.small)
          } else {
            Text("Run Permission Check")
          }
        }
        .disabled(isRunning)
      }
    } header: {
      Text("Before Your Interview")
    } footer: {
      Text("Run this once after installing or updating, before you share your screen. macOS draws permission dialogs itself and they can't be hidden, so during a session VoxNotch never asks — a source without permission is simply turned off and flagged in the panel.")
    }
    .onAppear(perform: refresh)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refresh()
    }
  }

  // MARK: - Statuses

  private var microphoneStatus: PermissionRow.Status {
    switch microphone {
    case .authorized: .ok("Allowed")
    case .notDetermined: .action("Not asked yet", "Allow…") { Task { _ = await AlwaysOnPermissions.requestMicrophone(); refresh() } }
    default: .action("Denied", "Open Settings") { AlwaysOnPermissions.openSystemSettings(.microphone) }
    }
  }

  private var systemAudioStatus: PermissionRow.Status {
    systemAudio
      ? .ok("Allowed")
      : .action("Not allowed — if you just enabled it, quit and reopen VoxNotch", "Open Settings") {
        AlwaysOnPermissions.requestSystemAudio()
        AlwaysOnPermissions.openSystemSettings(.screenRecording)
      }
  }

  private var apiKeyStatus: PermissionRow.Status {
    switch apiKey {
    case .available: .ok("Readable")
    case .missing: .info("No key saved (fine for local servers)")
    case .needsApproval: .action("macOS needs your approval", "Approve…") { settings.approveAPIKeyAccess(); refresh() }
    }
  }

  private var accessibilityStatus: PermissionRow.Status {
    accessibility
      ? .ok("Allowed")
      : .action("Needed for shortcuts like ⌃⌘↩", "Open Settings") { AlwaysOnPermissions.openSystemSettings(.accessibility) }
  }

  private var localNetworkStatus: PermissionRow.Status {
    localNetwork
      ? .ok("Phone connected before")
      : .info("If you use Phone View, connect your phone once beforehand — macOS asks the first time")
  }

  // MARK: - Actions

  private func refresh() {
    microphone = AlwaysOnPermissions.microphoneStatus
    systemAudio = AlwaysOnPermissions.systemAudioGranted
    apiKey = settings.checkAPIKeyAccess()
    accessibility = AlwaysOnPermissions.accessibilityGranted
    localNetwork = AlwaysOnPermissions.localNetworkVerified
  }

  /// Raises every pending macOS prompt now, one after another.
  private func runCheck() async {
    isRunning = true
    defer { isRunning = false; refresh() }
    refresh()
    if microphone == .notDetermined { _ = await AlwaysOnPermissions.requestMicrophone() }
    if !systemAudio { AlwaysOnPermissions.requestSystemAudio() }
    if settings.checkAPIKeyAccess() == .needsApproval { settings.approveAPIKeyAccess() }
  }
}

private struct PermissionRow: View {

  enum Status {
    case ok(String)
    case info(String)
    case action(String, String, () -> Void)
  }

  let title: String
  let icon: String
  let status: Status

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: icon)
        .frame(width: 18)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        detail
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      trailing
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch status {
    case .ok(let text), .info(let text), .action(let text, _, _):
      Text(text)
    }
  }

  @ViewBuilder
  private var trailing: some View {
    switch status {
    case .ok:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .info:
      Image(systemName: "info.circle").foregroundStyle(.secondary)
    case .action(_, let button, let action):
      Button(button, action: action)
    }
  }
}
