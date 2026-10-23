//
//  AlwaysOnPanelController.swift
//  VoxNotch
//
//  Owns the Always-On overlay panel: presentation, docking under the notch,
//  free dragging with snap-back, resizing and minimizing.
//
//  Geometry is modelled as `contentFrame` (the visible panel in screen
//  coordinates); the window frame is that plus transparent shadow insets.
//

import AppKit
import SwiftUI

@MainActor @Observable
final class AlwaysOnPanelController {

  static let shared = AlwaysOnPanelController()

  private(set) var isPresented = false
  private(set) var isMinimized = false
  private(set) var isDocked: Bool
  /// True while a drag hovers close enough to snap back under the notch.
  private(set) var isNearDock = false

  static let shadowInset: CGFloat = 24
  static let dockFlare: CGFloat = 10
  static let minimizedSize = CGSize(width: 300, height: 38)
  static let minimumSize = CGSize(width: 380, height: 260)
  private static let snapDistance: CGFloat = 90
  private static let undockDistance: CGFloat = 6

  @ObservationIgnored private var panel: NotchPanel?
  @ObservationIgnored private var contentFrame: NSRect = .zero
  @ObservationIgnored private var dragStart: (mouse: NSPoint, frame: NSRect)?
  @ObservationIgnored private var resizeStart: (mouse: NSPoint, frame: NSRect)?
  @ObservationIgnored private var hideTask: Task<Void, Never>?
  @ObservationIgnored private let settings = AssistantSettings.shared

  private init() {
    isDocked = AssistantSettings.shared.isDocked
  }

  /// Docked panels hang from the menu bar, so there is no inset (and no window) above them.
  var contentInsets: EdgeInsets {
    let inset = Self.shadowInset
    return EdgeInsets(top: isDocked ? 0 : inset, leading: inset, bottom: inset, trailing: inset)
  }

  // MARK: - Presentation

  func show() {
    hideTask?.cancel()
    hideTask = nil
    let panel = self.panel ?? makePanel()
    if !panel.isVisible {
      isMinimized = false
      contentFrame = restoredContentFrame()
      applyFrame()
    }
    panel.orderFrontRegardless()
    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { isPresented = true }
  }

  func hide() {
    guard isPresented else { return }
    withAnimation(.easeIn(duration: 0.16)) { isPresented = false }
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      self?.panel?.orderOut(nil)
    }
  }

  /// Phone viewing hides the desktop text immediately while keeping capture
  /// and answer generation running. The pairing QR lives in a separate window.
  func hideForPhoneView() {
    hideTask?.cancel()
    hideTask = nil
    isPresented = false
    panel?.orderOut(nil)
  }

  func toggleMinimized() {
    guard dragStart == nil, resizeStart == nil else { return }
    let top = contentFrame.maxY
    let midX = contentFrame.midX
    isMinimized.toggle()
    if isDocked {
      contentFrame = dockedContentFrame()
    } else {
      let size = currentSize
      contentFrame = NSRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
      clampToScreen()
    }
    applyFrame(deferred: true)
  }

  func dock() {
    isDocked = true
    isNearDock = false
    settings.isDocked = true
    contentFrame = dockedContentFrame()
    applyFrame(deferred: true)
  }

  // MARK: - Dragging (driven by AppKit mouse events, see PanelMouseArea)

  func beginDrag() {
    dragStart = (NSEvent.mouseLocation, contentFrame)
  }

  func dragChanged() {
    guard let start = dragStart else { return }
    let mouse = NSEvent.mouseLocation
    let dx = mouse.x - start.mouse.x
    let dy = mouse.y - start.mouse.y
    if isDocked {
      guard hypot(dx, dy) > Self.undockDistance else { return }
      isDocked = false
    }
    contentFrame.origin = NSPoint(x: start.frame.minX + dx, y: start.frame.minY + dy)

    let nearDock = distanceToDock() < Self.snapDistance
    if nearDock != isNearDock {
      withAnimation(.easeOut(duration: 0.12)) { isNearDock = nearDock }
    }
    applyFrame()
  }

  func dragEnded() {
    dragStart = nil
    if isDocked || isNearDock {
      dock()
      return
    }
    clampToScreen()
    applyFrame()
    settings.isDocked = false
    settings.floatingTopLeft = CGPoint(x: contentFrame.minX, y: contentFrame.maxY)
  }

  // MARK: - Resizing

  func beginResize() {
    resizeStart = (NSEvent.mouseLocation, contentFrame)
  }

  func resizeChanged() {
    guard let start = resizeStart else { return }
    let mouse = NSEvent.mouseLocation
    let dx = mouse.x - start.mouse.x
    let dy = mouse.y - start.mouse.y
    let maximum = maximumSize()

    // Docked panels stay centered under the notch, so width grows on both sides.
    let width = min(max(start.frame.width + (isDocked ? 2 * dx : dx), Self.minimumSize.width), maximum.width)
    let height = min(max(start.frame.height - dy, Self.minimumSize.height), maximum.height)
    let x = isDocked ? start.frame.midX - width / 2 : start.frame.minX
    contentFrame = NSRect(x: x, y: start.frame.maxY - height, width: width, height: height)
    applyFrame()
  }

  func resizeEnded() {
    resizeStart = nil
    settings.panelWidth = contentFrame.width
    settings.panelHeight = contentFrame.height
    if !isDocked {
      settings.floatingTopLeft = CGPoint(x: contentFrame.minX, y: contentFrame.maxY)
    }
  }

  // MARK: - Geometry

  private var expandedSize: CGSize {
    let maximum = maximumSize()
    return CGSize(
      width: min(max(settings.panelWidth, Self.minimumSize.width), maximum.width),
      height: min(max(settings.panelHeight, Self.minimumSize.height), maximum.height)
    )
  }

  private var currentSize: CGSize {
    isMinimized ? Self.minimizedSize : expandedSize
  }

  private func dockScreen() -> NSScreen {
    NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main ?? NSScreen.screens[0]
  }

  private func dockedContentFrame() -> NSRect {
    let screen = dockScreen()
    let size = currentSize
    return NSRect(
      x: screen.frame.midX - size.width / 2,
      y: screen.visibleFrame.maxY - size.height,
      width: size.width,
      height: size.height
    )
  }

  private func restoredContentFrame() -> NSRect {
    if !isDocked, let topLeft = settings.floatingTopLeft {
      let size = currentSize
      let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
      if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
        return frame
      }
    }
    isDocked = true
    return dockedContentFrame()
  }

  private func distanceToDock() -> CGFloat {
    let dock = dockedContentFrame()
    return hypot(contentFrame.midX - dock.midX, contentFrame.maxY - dock.maxY)
  }

  private func clampToScreen() {
    let screen = NSScreen.screens.first { $0.visibleFrame.intersects(contentFrame) } ?? dockScreen()
    let visible = screen.visibleFrame
    contentFrame.origin.x = min(max(contentFrame.minX, visible.minX), visible.maxX - contentFrame.width)
    contentFrame.origin.y = min(max(contentFrame.minY, visible.minY), visible.maxY - contentFrame.height)
  }

  private func maximumSize() -> CGSize {
    let visible = dockScreen().visibleFrame
    return CGSize(width: min(1000, visible.width - 40), height: visible.height - 20)
  }

  private func windowFrame() -> NSRect {
    let insets = contentInsets
    return NSRect(
      x: contentFrame.minX - insets.leading,
      y: contentFrame.minY - insets.bottom,
      width: contentFrame.width + insets.leading + insets.trailing,
      height: contentFrame.height + insets.top + insets.bottom
    )
  }

  /// `deferred` must be used when called from a SwiftUI action, so the window
  /// resize happens on the next run-loop turn rather than inside SwiftUI's update.
  private func applyFrame(deferred: Bool = false) {
    guard deferred else {
      panel?.setFrame(windowFrame(), display: false)
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.panel?.setFrame(self.windowFrame(), display: false)
    }
  }

  // MARK: - Panel

  private func makePanel() -> NotchPanel {
    let panel = NotchPanel(
      contentRect: NSRect(origin: .zero, size: Self.minimumSize),
      styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    let hostingView = FirstMouseHostingView(
      rootView: AnyView(
        AlwaysOnRootView()
          .environment(self)
          .environment(AlwaysOnState.shared)
      )
    )
    // The controller owns the window size. The hosting view sits in a plain,
    // frame-based container so its Auto Layout constraints never feed back into
    // the window frame (which otherwise loops during moves/resizes).
    hostingView.sizingOptions = []
    let container = NSView(frame: NSRect(origin: .zero, size: Self.minimumSize))
    container.autoresizesSubviews = true
    hostingView.frame = container.bounds
    hostingView.autoresizingMask = [.width, .height]
    hostingView.translatesAutoresizingMaskIntoConstraints = true
    container.addSubview(hostingView)
    panel.contentView = container

    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.panel?.isVisible == true else { return }
        if self.isDocked {
          self.contentFrame = self.dockedContentFrame()
        } else {
          self.clampToScreen()
        }
        self.applyFrame()
      }
    }

    self.panel = panel
    return panel
  }
}

#if DEBUG
extension AlwaysOnPanelController {
  func debugSnapshot(to url: URL) {
    guard let view = panel?.contentView else { return }
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
  }

  /// Moves the panel through the same code path as a real drag, frame by frame.
  func debugSimulateDrag(steps: Int = 90) {
    let start = contentFrame
    Task {
      for step in 1...steps {
        if isDocked { isDocked = false }
        contentFrame.origin = NSPoint(x: start.minX - CGFloat(step) * 3, y: start.minY - CGFloat(step) * 2)
        applyFrame()
        print("DRAG step=\(step) frame=\(panel?.frame ?? .zero)")
        try? await Task.sleep(for: .milliseconds(16))
      }
      print("DRAG done frame=\(panel?.frame ?? .zero)")
    }
  }

  func debugFloat() {
    isDocked = false
    contentFrame.origin.y -= 160
    contentFrame.origin.x -= 300
    applyFrame()
  }
}
#endif

/// The panel never becomes key, so clicks must act on the first mouse-down.
/// Deliberately non-generic: a generic NSHostingView subclass crashes the Swift 6.3
/// optimizer (EarlyPerfInliner on its deinit) in Release builds.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
