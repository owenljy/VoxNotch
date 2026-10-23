//
//  SettingsWindowController.swift
//  VoxNotch
//
//  NSWindowController for managing the Settings window
//

import AppKit
import SwiftUI

/// Window controller for the Settings window
final class SettingsWindowController: NSWindowController {

  // MARK: - Singleton

  static let shared = SettingsWindowController()

  /// Phone pairing has its own window, so an already-open settings page must
  /// not leave a second QR or other Always-On controls visible on the Mac.
  static func hideIfOpen() {
    for window in NSApp.windows where window.windowController is SettingsWindowController {
      window.orderOut(nil)
    }
  }

  // MARK: - Initialization

  private init() {
    let window = PrivacyWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    window.title = "VoxNotch Settings"
    window.center()
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SettingsView().privacyProtectedWindow())

    /// Restore window position
    window.setFrameAutosaveName("VoxNotchSettingsWindow")

    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Public Methods

  func show() {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func show(panel: SettingsPanel) {
    SettingsNavigation.shared.requestedPanel = panel
    show()
  }

  /// Show Settings and navigate to the Speech Model panel
  func showNavigatingToSpeechModel() {
    show()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      NotificationCenter.default.post(
        name: .settingsNavigateTo,
        object: nil,
        userInfo: ["panel": SettingsPanel.speechModel.rawValue]
      )
    }
  }

  /// Show Settings and navigate to the AI Enhancement panel
  func showNavigatingToAIEnhancement() {
    show()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      NotificationCenter.default.post(
        name: .settingsNavigateTo,
        object: nil,
        userInfo: ["panel": SettingsPanel.ai.rawValue]
      )
    }
  }
}
