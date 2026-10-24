import AppKit

/// Keeps the compatibility capture request consistent across app-owned windows.
/// `.none` is best effort; it is not a guarantee that another app cannot capture us.
/// A window-server capture exclusion is applied alongside it as a fallback when available.
@MainActor
final class WindowPrivacyManager: NSObject {
  static let shared = WindowPrivacyManager(
    hidesContent: { SettingsManager.shared.hideFromScreenRecording }
  )

  private let hidesContent: () -> Bool
  private let windows: () -> [NSWindow]
  private let applyCaptureExclusion: @MainActor (NSWindow, CGSize?) -> Bool
  private let refreshCaptureSurface: @MainActor (NSWindow, CGSize?) -> Void
  private let notifications: NotificationCenter
  private let workspaceNotifications: NotificationCenter
  private let registered = NSHashTable<NSWindow>.weakObjects()
  /// Last exclusion the window server accepted, so per-update passes only call it on change.
  private let exclusions = NSMapTable<NSWindow, AppliedExclusion>.weakToStrongObjects()
  private var isApplying = false

  init(
    hidesContent: @escaping () -> Bool,
    windows: @escaping () -> [NSWindow] = { NSApp.windows },
    applyCaptureExclusion: @escaping @MainActor (NSWindow, CGSize?) -> Bool = {
      CaptureExclusion.apply(to: $0, size: $1)
    },
    refreshCaptureSurface: @escaping @MainActor (NSWindow, CGSize?) -> Void = {
      CaptureExclusion.refreshSurface(of: $0, size: $1)
    },
    notifications: NotificationCenter = .default,
    workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
  ) {
    self.hidesContent = hidesContent
    self.windows = windows
    self.applyCaptureExclusion = applyCaptureExclusion
    self.refreshCaptureSurface = refreshCaptureSurface
    self.notifications = notifications
    self.workspaceNotifications = workspaceNotifications
    super.init()

    for name in [
      Notification.Name.hideFromScreenRecordingChanged,
      NSApplication.didBecomeActiveNotification,
      NSApplication.didChangeScreenParametersNotification,
    ] {
      notifications.addObserver(self, selector: #selector(reapplyAll), name: name, object: nil)
    }
    for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
      workspaceNotifications.addObserver(self, selector: #selector(reapplyAll), name: name, object: nil)
    }
    for name in [
      NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification,
      NSWindow.didChangeScreenNotification, NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification, NSWindow.willBeginSheetNotification,
      NSWindow.didResizeNotification,
    ] {
      notifications.addObserver(self, selector: #selector(windowLifecycleChanged), name: name, object: nil)
    }
    notifications.addObserver(
      self, selector: #selector(windowUpdated), name: NSWindow.didUpdateNotification, object: nil
    )
  }

  /// Call before ordering a window on screen, even if the preference did not change.
  func prepare(_ window: NSWindow) {
    apply([window], force: true)
  }

  @objc func reapplyAll() {
    apply(registered.allObjects + windows(), force: true)
  }

  @objc private func windowLifecycleChanged(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    prepare(window)
  }

  @objc private func windowUpdated(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    // AppKit-created sheets and panels may not have a controller of our own.
    // Avoid rewriting unchanged properties on every UI update.
    apply([window], force: false)
  }

  private func apply(_ roots: [NSWindow], force: Bool) {
    guard !isApplying else { return }
    isApplying = true
    defer { isApplying = false }
    let hides = hidesContent()
    let sharingType: NSWindow.SharingType = hides ? .none : .readOnly
    var visited = Set<ObjectIdentifier>()

    func visit(_ window: NSWindow) {
      guard visited.insert(ObjectIdentifier(window)).inserted else { return }
      registered.add(window)
      if force || window.sharingType != sharingType { window.sharingType = sharingType }
      // The region is in window coordinates, so it must follow the window's size.
      let exclusion = AppliedExclusion(
        windowNumber: window.windowNumber, size: hides ? window.frame.size : nil
      )
      let changed = exclusions.object(forKey: window) != exclusion
      if force || changed {
        if applyCaptureExclusion(window, exclusion.size) {
          exclusions.setObject(exclusion, forKey: window)
          // A successful CGS call alone can leave the previous unredacted surface in
          // an active capture. Refresh on transitions, including clearing/resizing,
          // but never on unchanged preparation during a view's drawing pass.
          if changed { refreshCaptureSurface(window, exclusion.size) }
        } else {
          // Retry on the next update, e.g. once a deferred window gets its window number.
          exclusions.removeObject(forKey: window)
        }
      }
      for child in window.childWindows ?? [] { visit(child) }
      if let sheet = window.attachedSheet { visit(sheet) }
    }
    for window in roots { visit(window) }
  }
}

private final class AppliedExclusion: NSObject {
  let windowNumber: Int
  let size: CGSize?

  init(windowNumber: Int, size: CGSize?) {
    self.windowNumber = windowNumber
    self.size = size
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? AppliedExclusion else { return false }
    return windowNumber == other.windowNumber && size == other.size
  }

  override var hash: Int { windowNumber }
}

/// Prepares persistent document/settings windows before every show, including reopens.
final class PrivacyWindow: NSWindow {
  override func makeKeyAndOrderFront(_ sender: Any?) {
    WindowPrivacyManager.shared.prepare(self)
    super.makeKeyAndOrderFront(sender)
  }

  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    if place != .out { WindowPrivacyManager.shared.prepare(self) }
    super.order(place, relativeTo: otherWin)
  }

  override func orderFrontRegardless() {
    WindowPrivacyManager.shared.prepare(self)
    super.orderFrontRegardless()
  }
}
