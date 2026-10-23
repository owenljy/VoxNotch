//
//  OnboardingWindowController.swift
//  VoxNotch
//
//  Window controller for the first-run setup wizard
//

import AppKit
import SwiftUI

final class OnboardingWindowController: NSWindowController {

  // MARK: - Singleton

  static let shared = OnboardingWindowController()

  // MARK: - Properties

  /// Called when onboarding completes (used by AppDelegate to continue startup)
  var onComplete: (() -> Void)?

  // MARK: - Initialization

  private init() {
    let window = PrivacyWindow(
      contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    window.title = "Welcome to VoxNotch"
    window.center()
    window.isReleasedWhenClosed = false

    super.init(window: window)

    installFreshView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Public

  func show() {
    // Recreate the view so re-showing always starts from the welcome step
    installFreshView()
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  // MARK: - Private

  private func installFreshView() {
    let onboardingView = OnboardingView { [weak self] in
      self?.onComplete?()
      self?.close()
    }
    window?.contentView = NSHostingView(rootView: onboardingView.privacyProtectedWindow())
  }
}
