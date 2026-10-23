//
//  AnswerNavigationView.swift
//  VoxNotch
//

import AppKit
import SwiftUI

/// A compact horizontal history rail. The answer pane itself is the preview.
struct AnswerNavigationView: View {
  let style: AlwaysOnStyle

  @Environment(AlwaysOnState.self) private var state

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 0) {
        ForEach(state.answers) { answer in
          Capsule()
            .fill(tickColor(answer))
            .frame(width: answer.id == state.displayedAnswer?.id ? 3 : 2,
                   height: answer.id == state.displayedAnswer?.id ? 14 : 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(height: 24)
      .overlay {
        AnswerNavigationMouseArea(
          answerIDs: state.answers.map(\.id),
          onPreview: state.previewAnswer,
          onExit: state.endAnswerPreview,
          onLock: state.lockAnswer,
          onUnlock: state.unlockAnswer
        )
        .accessibilityHidden(true)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Answer history")
      .accessibilityValue(accessibilityValue)
      .accessibilityHint("Move to preview. Click to lock. Double-click to return to the previous answer.")
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: state.showAnswer(offset: 1)
        case .decrement: state.showAnswer(offset: -1)
        @unknown default: break
        }
      }

      Button(action: toggleLock) {
        HStack(spacing: 5) {
          Text("\((state.displayedAnswerIndex ?? 0) + 1)/\(state.answers.count)")
            .monospacedDigit()
          Image(systemName: state.isAnswerLocked ? "lock.fill" : "lock.open")
            .font(.system(size: 9))
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(state.isAnswerLocked ? 0.85 : 0.45))
        .frame(minWidth: 52, minHeight: 24, alignment: .trailing)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(state.isAnswerLocked ? "Unlock and return to previous answer" : "Lock current answer")
    }
    .padding(.horizontal, 14)
    .onDisappear { state.endAnswerPreview() }
  }

  private var accessibilityValue: String {
    let mode = state.isAnswerLocked ? "locked" : state.isPreviewingAnswer ? "preview" : "selected"
    return "Answer \((state.displayedAnswerIndex ?? 0) + 1) of \(state.answers.count), \(mode)"
  }

  private func tickColor(_ answer: AssistantAnswer) -> Color {
    if answer.id == state.displayedAnswer?.id { return .white.opacity(0.9) }
    return answer.isInProgress ? style.them : .white.opacity(0.25)
  }

  private func toggleLock() {
    if state.isAnswerLocked {
      state.unlockAnswer()
    } else if let id = state.displayedAnswer?.id {
      state.lockAnswer(id)
    }
  }
}

/// AppKit tracking receives hover and click counts in a nonactivating panel,
/// including its first click while another app owns keyboard focus.
struct AnswerNavigationMouseArea: NSViewRepresentable {
  let answerIDs: [UUID]
  let onPreview: (UUID) -> Void
  let onExit: () -> Void
  let onLock: (UUID) -> Void
  let onUnlock: () -> Void

  func makeNSView(context: Context) -> TrackingView { TrackingView() }

  func updateNSView(_ view: TrackingView, context: Context) {
    view.answerIDs = answerIDs
    view.onPreview = onPreview
    view.onExit = onExit
    view.onLock = onLock
    view.onUnlock = onUnlock
  }

  final class TrackingView: NSView {
    var answerIDs: [UUID] = []
    var onPreview: ((UUID) -> Void)?
    var onExit: (() -> Void)?
    var onLock: ((UUID) -> Void)?
    var onUnlock: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isPressed = false
    private var suppressPreviewUntilExit = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let trackingArea { removeTrackingArea(trackingArea) }
      let area = NSTrackingArea(rect: .zero,
                                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited,
                                          .mouseMoved, .enabledDuringMouseDrag],
                                owner: self)
      addTrackingArea(area)
      trackingArea = area
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.acceptsMouseMovedEvents = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseEntered(with event: NSEvent) { preview(with: event) }
    override func mouseMoved(with event: NSEvent) { preview(with: event) }

    override func mouseExited(with event: NSEvent) {
      suppressPreviewUntilExit = false
      onExit?()
    }

    override func mouseDown(with event: NSEvent) {
      if event.clickCount == 2 {
        isPressed = false
        suppressPreviewUntilExit = true
        onUnlock?()
      } else {
        isPressed = true
        suppressPreviewUntilExit = false
        preview(with: event)
      }
    }

    override func mouseDragged(with event: NSEvent) { preview(with: event) }

    override func mouseUp(with event: NSEvent) {
      guard isPressed else { return }
      isPressed = false
      if let id = answerID(with: event) { onLock?(id) }
      else { onExit?() }
    }

    private func preview(with event: NSEvent) {
      guard !suppressPreviewUntilExit, let id = answerID(with: event) else { return }
      onPreview?(id)
    }

    private func answerID(with event: NSEvent) -> UUID? {
      let point = convert(event.locationInWindow, from: nil)
      guard point.y >= bounds.minY, point.y <= bounds.maxY,
            let index = Self.answerIndex(at: point.x - bounds.minX, width: bounds.width, count: answerIDs.count)
      else { return nil }
      return answerIDs[index]
    }

    static func answerIndex(at x: CGFloat, width: CGFloat, count: Int) -> Int? {
      guard count > 0, width > 0, x.isFinite, width.isFinite, x >= 0, x <= width else { return nil }
      return min(Int(x / width * CGFloat(count)), count - 1)
    }
  }
}
