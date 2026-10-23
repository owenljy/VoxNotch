//
//  AlwaysOnHistoryWindowController.swift
//  VoxNotch
//
//  Window controller for persisted Always-On sessions.
//

import AppKit
import SwiftUI

@available(macOS 26.0, *)
final class AlwaysOnHistoryWindowController: NSWindowController {

  static let shared = AlwaysOnHistoryWindowController()

  private init() {
    let window = PrivacyWindow(
      contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Always-On History"
    window.minSize = NSSize(width: 760, height: 480)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: AlwaysOnHistoryWindowView().privacyProtectedWindow())
    window.setFrameAutosaveName("VoxNotchAlwaysOnHistoryWindow")
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show() {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
}
