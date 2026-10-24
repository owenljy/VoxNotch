//
//  AlwaysOnPermissions.swift
//  VoxNotch
//
//  Permission status for Always-On without ever triggering a macOS prompt.
//  System permission dialogs are drawn by macOS and can't be hidden from screen
//  sharing, so during a session VoxNotch only checks status; asking happens in
//  the explicit pre-interview check in Settings.
//

import AppKit
import AVFoundation
import CoreGraphics

@MainActor
enum AlwaysOnPermissions {

  static let localNetworkVerifiedKey = "alwaysOn.localNetworkVerified"

  static var microphoneStatus: AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  /// System audio is captured with ScreenCaptureKit, which needs Screen & System Audio Recording.
  static var systemAudioGranted: Bool {
    CGPreflightScreenCaptureAccess()
  }

  static var accessibilityGranted: Bool {
    AXIsProcessTrusted()
  }

  /// Set after a phone has connected once, i.e. the Local Network prompt has been answered.
  static var localNetworkVerified: Bool {
    UserDefaults.standard.bool(forKey: localNetworkVerifiedKey)
  }

  static func isGranted(_ source: AudioSource) -> Bool {
    switch source {
    case .microphone: microphoneStatus == .authorized
    case .systemAudio: systemAudioGranted
    }
  }

  // MARK: - Explicit requests (Settings only)

  static func requestMicrophone() async -> Bool {
    guard microphoneStatus == .notDetermined else { return microphoneStatus == .authorized }
    return await AVCaptureDevice.requestAccess(for: .audio)
  }

  @discardableResult
  static func requestSystemAudio() -> Bool {
    CGRequestScreenCaptureAccess()
  }

  enum SettingsPane: String {
    case microphone = "Privacy_Microphone"
    case screenRecording = "Privacy_ScreenCapture"
    case accessibility = "Privacy_Accessibility"
    case localNetwork = "Privacy_LocalNetwork"
  }

  static func openSystemSettings(_ pane: SettingsPane) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
      NSWorkspace.shared.open(url)
    }
  }
}

/// A source was skipped because its permission isn't granted; nothing was requested.
struct AlwaysOnPermissionError: LocalizedError {
  let source: AudioSource

  var errorDescription: String? {
    switch source {
    case .microphone: "Microphone permission isn't granted."
    case .systemAudio: "Screen & System Audio Recording permission isn't granted."
    }
  }
}
