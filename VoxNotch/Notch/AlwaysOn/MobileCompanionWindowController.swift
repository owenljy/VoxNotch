import AppKit
import SwiftUI

/// Pairing must survive hiding the Always-On panel and its attached popover.
@MainActor
final class MobileCompanionWindowController: NSWindowController, NSWindowDelegate {
  static let shared = MobileCompanionWindowController()
  private var closesAfterPairing = false
  private let content: () -> AnyView

  init(content: (() -> AnyView)? = nil) {
    self.content = content ?? { AnyView(MobileCompanionView()) }
    super.init(window: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func showForPairing() {
    show()
    closesAfterPairing = true
  }

  func show() {
    closesAfterPairing = false
    if window == nil {
      let height = min(620, (NSScreen.main?.visibleFrame.height ?? 720) - 60)
      let window = PrivacyWindow(contentRect: NSRect(x: 0, y: 0, width: 346, height: height),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = "VoxNotch · Phone & iPad"
      window.isReleasedWhenClosed = false
      window.level = .floating
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.delegate = self
      window.contentView = NSHostingView(rootView: ScrollView {
        content().padding(18).frame(maxWidth: .infinity, alignment: .leading)
      }.privacyProtectedWindow())
      window.center()
      self.window = window
    }
    window?.orderFrontRegardless()
  }

  func hideAfterPairing() {
    if closesAfterPairing { hide() }
  }

  func hide() {
    closesAfterPairing = false
    window?.orderOut(nil)
  }

  func windowWillClose(_ notification: Notification) { closesAfterPairing = false }
}
