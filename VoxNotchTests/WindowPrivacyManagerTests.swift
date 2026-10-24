import AppKit
import XCTest
@testable import VoxNotch

@MainActor
final class WindowPrivacyManagerTests: XCTestCase {
  private func window() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    return window
  }

  func testPreferenceChangesUpdateExistingHiddenAndLateWindows() {
    var hidden = true
    let notifications = NotificationCenter()
    var appWindows: [NSWindow] = []
    let privacy = WindowPrivacyManager(
      hidesContent: { hidden }, windows: { appWindows }, notifications: notifications,
      workspaceNotifications: NotificationCenter()
    )
    let first = window()
    privacy.prepare(first)
    XCTAssertFalse(first.isVisible)
    XCTAssertEqual(first.sharingType, .none)

    let late = window()
    appWindows = [late]
    hidden = false
    notifications.post(name: .hideFromScreenRecordingChanged, object: nil)
    XCTAssertEqual(first.sharingType, .readOnly)
    XCTAssertEqual(late.sharingType, .readOnly)

    hidden = true
    notifications.post(name: .hideFromScreenRecordingChanged, object: nil)
    XCTAssertEqual(first.sharingType, .none)
    XCTAssertEqual(late.sharingType, .none)
  }

  func testChildWindowsFollowParentAndRestoreWhenDisabled() {
    var hidden = true
    let parent = window()
    let child = window()
    parent.addChildWindow(child, ordered: .above)
    defer { parent.removeChildWindow(child) }
    let privacy = WindowPrivacyManager(
      hidesContent: { hidden }, windows: { [] }, notifications: NotificationCenter(),
      workspaceNotifications: NotificationCenter()
    )
    privacy.prepare(parent)
    XCTAssertEqual(child.sharingType, .none)
    hidden = false
    privacy.reapplyAll()
    XCTAssertEqual(parent.sharingType, .readOnly)
    XCTAssertEqual(child.sharingType, .readOnly)
  }

  func testLifecycleEventsRepairDriftWithoutChangingPreference() {
    let notifications = NotificationCenter()
    let workspace = NotificationCenter()
    let window = window()
    let privacy = WindowPrivacyManager(
      hidesContent: { true }, windows: { [] }, notifications: notifications,
      workspaceNotifications: workspace
    )
    privacy.prepare(window)
    for event in [
      NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification,
      NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification,
    ] {
      window.sharingType = .readOnly
      notifications.post(name: event, object: window)
      XCTAssertEqual(window.sharingType, .none, event.rawValue)
    }
    for event in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
      window.sharingType = .readOnly
      workspace.post(name: event, object: nil)
      XCTAssertEqual(window.sharingType, .none, event.rawValue)
    }
    window.sharingType = .readOnly
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(window.sharingType, .none)
  }

  func testAppKitCreatedWindowIsDiscoveredOnUpdate() {
    let notifications = NotificationCenter()
    let privacy = WindowPrivacyManager(
      hidesContent: { true }, windows: { [] }, notifications: notifications,
      workspaceNotifications: NotificationCenter()
    )
    let popup = window()
    popup.sharingType = .readOnly
    notifications.post(name: NSWindow.didUpdateNotification, object: popup)
    XCTAssertEqual(popup.sharingType, .none)
    withExtendedLifetime(privacy) {}
  }

  func testContentAttachmentProtectsWindowBeforeItIsShown() {
    let privacy = WindowPrivacyManager(
      hidesContent: { true }, windows: { [] }, notifications: NotificationCenter(),
      workspaceNotifications: NotificationCenter()
    )
    let window = window()
    let attachment = WindowPrivacyAttachment.AttachmentView()
    attachment.privacy = privacy
    window.contentView = attachment
    XCTAssertFalse(window.isVisible)
    XCTAssertEqual(window.sharingType, .none)
    XCTAssertNil(attachment.hitTest(.zero), "The privacy attachment must not intercept clicks")
  }

  func testTrackingDoesNotKeepClosedWindowsAlive() {
    let privacy = WindowPrivacyManager(
      hidesContent: { true }, windows: { [] }, notifications: NotificationCenter(),
      workspaceNotifications: NotificationCenter()
    )
    weak var weakWindow: NSWindow?
    autoreleasepool {
      let window = window()
      weakWindow = window
      privacy.prepare(window)
      window.close()
    }
    XCTAssertNil(weakWindow)
    privacy.reapplyAll()
  }

  func testPopoverIsProtectedBeforeItsFirstContentDraw() async {
    let privacy = WindowPrivacyManager(
      hidesContent: { true }, windows: { [] }, notifications: NotificationCenter(),
      workspaceNotifications: NotificationCenter()
    )
    let parent = window()
    let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    parent.contentView = anchor
    parent.orderFront(nil)

    let drawn = expectation(description: "Popover's first draw")
    let probe = FirstDrawProbe(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    probe.onFirstDraw = { sharingType in
      XCTAssertEqual(sharingType, NSWindow.SharingType.none)
      drawn.fulfill()
    }
    let attachment = WindowPrivacyAttachment.AttachmentView()
    attachment.privacy = privacy
    probe.addSubview(attachment)
    let content = NSViewController()
    content.view = probe
    let popover = NSPopover()
    popover.animates = false
    popover.contentViewController = content
    defer {
      popover.close()
      parent.orderOut(nil)
    }
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    await fulfillment(of: [drawn], timeout: 3)
  }

  func testCaptureExclusionFollowsPreferenceAndWindowSize() {
    var hidden = true
    var calls: [CGSize?] = []
    let notifications = NotificationCenter()
    let privacy = WindowPrivacyManager(
      hidesContent: { hidden }, windows: { [] },
      applyCaptureExclusion: { _, size in calls.append(size); return true },
      notifications: notifications, workspaceNotifications: NotificationCenter()
    )
    let window = window()
    privacy.prepare(window)
    XCTAssertEqual(calls, [CGSize(width: 320, height: 200)])

    window.setContentSize(NSSize(width: 480, height: 260))
    notifications.post(name: NSWindow.didResizeNotification, object: window)
    XCTAssertEqual(calls.last, CGSize(width: 480, height: 260), "Resizing must widen the excluded region")

    hidden = false
    notifications.post(name: .hideFromScreenRecordingChanged, object: nil)
    XCTAssertEqual(calls.last, .some(nil), "Disabling must clear the exclusion")
  }

  func testCaptureExclusionUpdatesOnlyOnChangeAndRetriesFailures() {
    var accepts = false
    var calls = 0
    let notifications = NotificationCenter()
    let privacy = WindowPrivacyManager(
      hidesContent: { true }, windows: { [] },
      applyCaptureExclusion: { _, _ in calls += 1; return accepts },
      notifications: notifications, workspaceNotifications: NotificationCenter()
    )
    let window = window()
    privacy.prepare(window)
    XCTAssertEqual(calls, 1)

    accepts = true
    notifications.post(name: NSWindow.didUpdateNotification, object: window)
    XCTAssertEqual(calls, 2, "A rejected exclusion is retried on the next update")
    notifications.post(name: NSWindow.didUpdateNotification, object: window)
    XCTAssertEqual(calls, 2, "An accepted exclusion is not resent on every update")
  }

  func testCaptureSurfaceRefreshesOnTransitionsWithoutDrawingLoop() {
    var hidden = false
    var accepts = true
    var refreshes = 0
    let notifications = NotificationCenter()
    let privacy = WindowPrivacyManager(
      hidesContent: { hidden }, windows: { [] },
      applyCaptureExclusion: { _, _ in accepts },
      refreshCaptureSurface: { _, _ in refreshes += 1 },
      notifications: notifications, workspaceNotifications: NotificationCenter()
    )
    let window = window()
    privacy.prepare(window)
    refreshes = 0

    hidden = true
    notifications.post(name: .hideFromScreenRecordingChanged, object: nil)
    XCTAssertEqual(refreshes, 1, "Enabling must refresh an existing captured surface")

    // viewWillDraw calls prepare again. That must not schedule an endless redraw.
    privacy.prepare(window)
    notifications.post(name: NSWindow.didUpdateNotification, object: window)
    XCTAssertEqual(refreshes, 1)

    window.setContentSize(NSSize(width: 480, height: 260))
    notifications.post(name: NSWindow.didResizeNotification, object: window)
    XCTAssertEqual(refreshes, 2, "Newly covered pixels must be refreshed after resizing")

    hidden = false
    accepts = false
    notifications.post(name: .hideFromScreenRecordingChanged, object: nil)
    XCTAssertEqual(refreshes, 2, "A rejected request must remain retryable")
    accepts = true
    notifications.post(name: NSWindow.didUpdateNotification, object: window)
    XCTAssertEqual(refreshes, 3, "Clearing a mask must refresh the restored surface")
  }

  func testSystemCaptureExclusionAcceptsOwnWindows() throws {
    try XCTSkipUnless(CaptureExclusion.isAvailable, "SkyLight capture exclusion is not exported")
    let window = window()
    XCTAssertTrue(CaptureExclusion.apply(to: window, size: window.frame.size))
    XCTAssertTrue(CaptureExclusion.apply(to: window, size: nil))
    XCTAssertFalse(CaptureExclusion.apply(to: window, size: .zero))
    XCTAssertFalse(CaptureExclusion.apply(to: window, size: CGSize(width: CGFloat.nan, height: 100)))

    let deferred = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 50, height: 50),
      styleMask: [.borderless], backing: .buffered, defer: true
    )
    deferred.isReleasedWhenClosed = false
    XCTAssertFalse(
      CaptureExclusion.apply(to: deferred, size: deferred.frame.size),
      "A window without a window-server window cannot be excluded yet"
    )
  }

  func testRefreshCoalescesTransitionsAndRestoresViewHierarchyWithoutTakingFocus() async throws {
    let window = window()
    let content = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
    window.contentView = content
    window.orderFront(nil)
    defer { window.close() }
    let frame = window.frame
    let keyWindow = NSApp.keyWindow
    let active = NSApp.isActive

    CaptureExclusion.refreshSurface(of: window, size: window.frame.size)
    // An old queued enable must not override a newer clear request.
    CaptureExclusion.refreshSurface(of: window, size: nil)
    try await Task.sleep(for: .milliseconds(180))

    XCTAssertTrue(content.subviews.isEmpty, "The temporary refresh must leave no visible overlay behind")
    XCTAssertEqual(window.frame, frame)
    XCTAssertTrue(NSApp.keyWindow === keyWindow)
    XCTAssertEqual(NSApp.isActive, active)
  }

  func testUnavailableCaptureExclusionStillAppliesSharingPreference() {
    var hidden = true
    let window = window()
    let privacy = WindowPrivacyManager(
      hidesContent: { hidden }, windows: { [] }, applyCaptureExclusion: { _, _ in false },
      notifications: NotificationCenter(), workspaceNotifications: NotificationCenter()
    )
    privacy.prepare(window)
    XCTAssertEqual(window.sharingType, .none)
    hidden = false
    privacy.reapplyAll()
    XCTAssertEqual(window.sharingType, .readOnly)
  }

  func testPreparingPanelDoesNotActivateOrReplaceKeyWindow() {
    let panel = NotchPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
      backing: .buffered, defer: false
    )
    let keyWindow = NSApp.keyWindow
    let wasActive = NSApp.isActive
    WindowPrivacyManager.shared.prepare(panel)
    XCTAssertTrue(NSApp.keyWindow === keyWindow)
    XCTAssertEqual(NSApp.isActive, wasActive)
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertFalse(panel.hidesOnDeactivate)
    XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    XCTAssertFalse(panel.collectionBehavior.contains(.stationary))
  }
}

private final class FirstDrawProbe: NSView {
  var onFirstDraw: ((NSWindow.SharingType?) -> Void)?
  private var didDraw = false

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !didDraw else { return }
    didDraw = true
    onFirstDraw?(window?.sharingType)
  }
}
