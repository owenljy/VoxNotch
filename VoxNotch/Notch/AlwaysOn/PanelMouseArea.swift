//
//  PanelMouseArea.swift
//  VoxNotch
//
//  AppKit mouse tracking for moving and resizing the Always-On panel.
//
//  Window moves must not be driven from SwiftUI gestures: SwiftUI's "global"
//  coordinate space is window-relative, so moving the window re-fires the
//  gesture inside SwiftUI's layout pass and the resulting frame changes loop
//  until AppKit throws ("more Update Constraints in Window passes than there
//  are views"). AppKit mouse events arrive from the event loop instead.
//

import AppKit
import SwiftUI

struct PanelMouseArea: NSViewRepresentable {

  enum Role {
    case move
    case resize
  }

  let role: Role
  var onDoubleClick: (() -> Void)?

  func makeNSView(context: Context) -> TrackingView {
    TrackingView(role: role)
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    nsView.onDoubleClick = onDoubleClick
  }

  final class TrackingView: NSView {

    let role: Role
    var onDoubleClick: (() -> Void)?
    private var isTracking = false

    init(role: Role) {
      self.role = role
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
      if role == .resize {
        addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
      }
    }

    override func mouseDown(with event: NSEvent) {
      if event.clickCount == 2, let onDoubleClick {
        onDoubleClick()
        return
      }
      isTracking = true
      switch role {
      case .move: AlwaysOnPanelController.shared.beginDrag()
      case .resize: AlwaysOnPanelController.shared.beginResize()
      }
    }

    override func mouseDragged(with event: NSEvent) {
      guard isTracking else { return }
      switch role {
      case .move: AlwaysOnPanelController.shared.dragChanged()
      case .resize: AlwaysOnPanelController.shared.resizeChanged()
      }
    }

    override func mouseUp(with event: NSEvent) {
      guard isTracking else { return }
      isTracking = false
      switch role {
      case .move: AlwaysOnPanelController.shared.dragEnded()
      case .resize: AlwaysOnPanelController.shared.resizeEnded()
      }
    }
  }
}
