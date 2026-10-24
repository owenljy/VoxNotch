import AppKit
import QuartzCore

/// Best-effort window-server redaction, in addition to `NSWindow.sharingType`.
/// On macOS 27.0.1, ScreenCaptureKit renders the excluded region as a grey box
/// when it includes the window. A successful call is not proof a capturer honors it.
/// Kept independent of app settings so the pixel probe compiles this same implementation.
enum CaptureExclusion {
  private typealias MainConnectionID = @convention(c) () -> UInt32
  private typealias SetWindowCaptureExcludeShape = @convention(c) (UInt32, Int, CFTypeRef?) -> Int32
  private typealias RegionCreateWithRect = @convention(c) (CGRect) -> Unmanaged<CFTypeRef>?

  private struct Symbols: @unchecked Sendable {
    let mainConnectionID: MainConnectionID
    let setExcludeShape: SetWindowCaptureExcludeShape
    let regionCreate: RegionCreateWithRect
  }

  private static let symbols: Symbols? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let connection = dlsym(handle, "CGSMainConnectionID"),
          let exclude = dlsym(handle, "CGSSetWindowCaptureExcludeShape"),
          let region = dlsym(handle, "CGRegionCreateWithRect")
    else { return nil }
    return Symbols(
      mainConnectionID: unsafeBitCast(connection, to: MainConnectionID.self),
      setExcludeShape: unsafeBitCast(exclude, to: SetWindowCaptureExcludeShape.self),
      regionCreate: unsafeBitCast(region, to: RegionCreateWithRect.self)
    )
  }()

  static var isAvailable: Bool { symbols != nil }

  @MainActor
  private static let refreshes = NSMapTable<NSWindow, CaptureRefreshView>.weakToStrongObjects()

  /// Excludes a window-local region, or clears it when `size` is nil.
  @MainActor
  static func apply(to window: NSWindow, size: CGSize?) -> Bool {
    guard let symbols, window.windowNumber > 0 else { return false }
    var region: CFTypeRef?
    if let size {
      guard size.width > 0, size.height > 0,
            size.width.isFinite, size.height.isFinite,
            let created = symbols.regionCreate(CGRect(origin: .zero, size: size)) else { return false }
      region = created.takeRetainedValue()
    }
    return symbols.setExcludeShape(symbols.mainConnectionID(), window.windowNumber, region) == 0
  }

  /// CGS can leave a capturer's old surface visible until the window is redrawn.
  /// Defer the redraw so preparation from viewWillDraw never recursively draws.
  @MainActor
  static func refreshSurface(of window: NSWindow, size: CGSize?) {
    let marker = refreshes.object(forKey: window) ?? CaptureRefreshView(
      frame: NSRect(x: 0, y: 0, width: 1, height: 1)
    )
    let generation = UUID()
    marker.generation = generation
    refreshes.setObject(marker, forKey: window)
    DispatchQueue.main.async { [weak window] in
      guard marker.generation == generation else { return }
      guard let window, window.isVisible, let content = window.contentView else {
        marker.removeFromSuperview()
        if let window { refreshes.removeObject(forKey: window) }
        return
      }
      // AppKit may commit the resized surface after didResize. Reapply once that
      // transaction has reached the window server, rather than caching a clipped region.
      CATransaction.flush()
      _ = apply(to: window, size: size)
      // Redisplaying identical pixels can reuse the old surface. Invalidate the
      // whole surface with a very faint scrim: partial damage can leave enlarged
      // edges unredacted, or leave a cached grey mask after protection is cleared.
      marker.setAccessibilityElement(false)
      marker.frame = content.bounds
      marker.autoresizingMask = [.width, .height]
      if marker.superview !== content {
        marker.removeFromSuperview()
        content.addSubview(marker, positioned: .above, relativeTo: nil)
      }
      marker.isWhite.toggle()
      marker.needsDisplay = true
      window.display()
      CATransaction.flush()
      // Alternating the tint also works on a uniformly black/white background.
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak window] in
        guard marker.generation == generation, let window, window.isVisible else { return }
        _ = apply(to: window, size: size)
        marker.isWhite.toggle()
        marker.needsDisplay = true
        window.display()
        CATransaction.flush()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak window] in
        guard marker.generation == generation else { return }
        marker.removeFromSuperview()
        if let window {
          refreshes.removeObject(forKey: window)
          if window.isVisible { window.display() }
        }
      }
    }
  }
}

@MainActor
private final class CaptureRefreshView: NSView {
  var generation = UUID()
  var isWhite = false

  override func draw(_ dirtyRect: NSRect) {
    (isWhite ? NSColor.white : NSColor.black).withAlphaComponent(1.0 / 255).setFill()
    bounds.fill()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
