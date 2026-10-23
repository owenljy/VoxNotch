//
//  HistoryWindowController.swift
//  VoxNotch
//
//  NSWindowController for managing the History window
//

import AppKit
import SwiftUI

/// Window controller for the History window
@available(macOS 26.0, *)
final class HistoryWindowController: NSWindowController {

  // MARK: - Singleton

  static let shared = HistoryWindowController()

  // MARK: - Initialization

  private init() {
    let window = PrivacyWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )

    window.title = "Transcription History"
    window.center()
    window.minSize = NSSize(width: 650, height: 420)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: HistoryWindowView().privacyProtectedWindow())

    /// Restore window position
    window.setFrameAutosaveName("VoxNotchHistoryWindow")

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
}
