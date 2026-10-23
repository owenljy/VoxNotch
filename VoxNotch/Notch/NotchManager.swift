//
//  NotchManager.swift
//  VoxNotch
//
//  Owns a persistent NotchPanel and drives expand/collapse via SwiftUI
//  state changes. The panel is created once and never destroyed — only
//  the SwiftUI content inside animates, keeping the window frame fixed.
//

import AppKit
import SwiftUI

// MARK: - Notch State

enum NotchState: Equatable {
  case hidden
  case expanded
}

// MARK: - NotchManager

@MainActor @Observable
final class NotchManager {

  static let shared = NotchManager()

  // MARK: - Observable State

  var notchState: NotchState = .hidden

  /// Physical notch dimensions (or sensible defaults for non-notch Macs).
  var physicalNotchSize: CGSize = CGSize(width: 185, height: 32)

  /// Whether the current display has a physical camera notch.
  var hasPhysicalNotch: Bool = true

  /// Opacity multiplier for the entire notch overlay.
  /// Animated to 0 before `orderOut` to avoid the visible snap.
  var panelOpacity: CGFloat = 1.0

  // MARK: - Transient Display State

  /// Set when showing the output notification, cleared on hide.
  var outputNotification: OutputResult? = nil

  /// Brief confirmation shown after model/tone selection before auto-hide.
  var isShowingConfirmation = false
  var confirmationMessage: String = ""

  /// Clear all transient display state.
  func clearTransient() {
    outputNotification = nil
    isShowingConfirmation = false
    confirmationMessage = ""
  }

  // MARK: - Private

  private var panel: NotchPanel?
  private var autoHideTask: Task<Void, Never>?
  private var fadeOutTask: Task<Void, Never>?

  /// Fixed panel size — large enough for expanded content + shadow padding.
  private static let panelSize = CGSize(width: 640, height: 250)

  private init() {}

  // MARK: - Setup

  func setup() {
    let panel = NotchPanel(
      contentRect: NSRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
      backing: .buffered,
      defer: false
    )

    let viewModel = NotchViewModel(appState: AppState.shared, notchManager: self, audioViz: AudioVisualizationState.shared)
    let hostingView = NSHostingView(
      rootView: NotchContentView()
        .environment(AppState.shared)
        .environment(self)
        .environment(AudioVisualizationState.shared)
        .environment(viewModel)
    )
    hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
    panel.contentView = hostingView

    self.panel = panel
    detectPhysicalNotch()

    // Reposition when displays change.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.detectPhysicalNotch()
        self.repositionPanel()
      }
    }
  }

  // MARK: - Show Methods

  func showRecording() {
    cancelAutoHide()
    showExpanded()
  }

  func showTranscribing() {
    cancelAutoHide()
    showExpanded()
  }

  func showProcessingLLM() {
    cancelAutoHide()
    showExpanded()
  }

  func showOutputResult(_ result: OutputResult) {
    cancelAutoHide()
    withAnimation(.smooth(duration: 0.4)) {
      outputNotification = result
      isShowingConfirmation = false
    }
    showExpanded()
    scheduleAutoHide(after: 1.25)
  }

  func showError(_ message: String) {
    cancelAutoHide()
    showExpanded()
    scheduleAutoHide(after: 1.25)
  }

  func showModelSelector() {
    cancelAutoHide()
    showExpanded()
  }

  func showToneSelector() {
    cancelAutoHide()
    showExpanded()
  }

  func showModelsNeeded(_ message: String) {
    cancelAutoHide()
    showExpanded()
    scheduleAutoHide(after: 1.25)
  }

  func showConfirmation(_ message: String) {
    cancelAutoHide()
    withAnimation(.smooth(duration: 0.4)) {
      isShowingConfirmation = true
      confirmationMessage = message
      outputNotification = nil
    }
    showExpanded()
    scheduleAutoHide(after: 1.25)
  }

  func hide() {
    cancelAutoHide()
    withAnimation(.smooth(duration: 0.4)) {
      outputNotification = nil
      isShowingConfirmation = false
    }
    withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
      notchState = .hidden
    }
    scheduleFadeAndOrderOut()
  }

  // MARK: - Private

  /// Show the expanded notch. If already expanded this is a no-op —
  /// content transitions are driven by AppState / displayPhase, not
  /// by re-expanding the panel.
  private func showExpanded() {
    // Cancel any pending fade/orderOut so it can't race with this expand.
    cancelFadeOut()
    panelOpacity = 1.0
    ensurePanelVisible()

    guard notchState != .expanded else { return }
    withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
      notchState = .expanded
    }
  }

  private func ensurePanelVisible() {
    guard let panel else { return }
    repositionPanel()
    if !panel.isVisible {
      panel.orderFrontRegardless()
    }
  }

  private func repositionPanel() {
    guard let panel, let screen = NSScreen.main else { return }
    let screenFrame = screen.frame
    let origin = NSPoint(
      x: screenFrame.origin.x + (screenFrame.width - Self.panelSize.width) / 2,
      y: screenFrame.origin.y + screenFrame.height - Self.panelSize.height
    )
    panel.setFrameOrigin(origin)
  }

  /// Detect the physical notch on the main screen and update sizing.
  ///
  /// On notched displays we read the real safe-area inset. On external /
  /// non-notched displays we mirror the connected MacBook's notch size (if
  /// any), falling back to standard MacBook Pro dimensions in clamshell mode.
  /// This keeps the expanded capsule visually identical across displays.
  private func detectPhysicalNotch() {
    guard let screen = NSScreen.main else { return }

    if let size = notchSize(of: screen) {
      hasPhysicalNotch = true
      physicalNotchSize = size
      return
    }

    hasPhysicalNotch = false
    if let notched = NSScreen.screens.first(where: { notchSize(of: $0) != nil }),
       let size = notchSize(of: notched)
    {
      physicalNotchSize = size
    } else {
      // Clamshell or no notched display connected — use MacBook Pro defaults.
      physicalNotchSize = CGSize(width: 200, height: 32)
    }
  }

  /// Returns the notch dimensions for `screen` if it has a camera notch.
  private func notchSize(of screen: NSScreen) -> CGSize? {
    guard let topLeft = screen.auxiliaryTopLeftArea?.width,
          let topRight = screen.auxiliaryTopRightArea?.width
    else { return nil }
    return CGSize(
      width: screen.frame.width - topLeft - topRight,
      height: screen.safeAreaInsets.top
    )
  }

  // MARK: - Fade and Order Out (tracked, cancellable)

  /// Fade the notch overlay to transparent, then order out the panel.
  /// Timeline: 0.35s wait (spring mostly settled) → 0.2s opacity fade → orderOut.
  private func scheduleFadeAndOrderOut() {
    cancelFadeOut()
    fadeOutTask = Task { [weak self] in
      // Wait for the spring collapse to mostly settle.
      try? await Task.sleep(for: .seconds(0.50))
      guard let self, !Task.isCancelled else { return }

      withAnimation(.easeOut(duration: 0.2)) {
        self.panelOpacity = 0
      }

      // Wait for the opacity fade to complete, then remove the panel.
      try? await Task.sleep(for: .seconds(0.25))
      guard !Task.isCancelled else { return }
      self.panel?.orderOut(nil)
    }
  }

  private func cancelFadeOut() {
    fadeOutTask?.cancel()
    fadeOutTask = nil
  }

  // MARK: - Auto Hide

  private func scheduleAutoHide(after seconds: Double) {
    autoHideTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard let self, !Task.isCancelled else { return }
      withAnimation(.smooth(duration: 0.4)) {
        self.outputNotification = nil
        self.isShowingConfirmation = false
        AppState.shared.error.clear()
        AppState.shared.error.clearLLMWarning()
      }
      withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
        self.notchState = .hidden
      }
      self.scheduleFadeAndOrderOut()
    }
  }

  private func cancelAutoHide() {
    autoHideTask?.cancel()
    autoHideTask = nil
  }
}
