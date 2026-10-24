import AppKit
import ScreenCaptureKit
import XCTest

/// Pixel-level check that protected windows are absent from ScreenCaptureKit captures, the
/// backend Chromium prefers for screen sharing. Opt-in because it needs Screen Recording for
/// the test host and briefly shows a magenta square near the top-left of the main display:
///
///   TEST_RUNNER_VOXNOTCH_CAPTURE_PIXEL_TESTS=1 xcodebuild ... \
///     -only-testing:VoxNotchTests/CaptureExclusionPixelTests test
///
/// The protected window belongs to a separate probe process (scripts/capture-exclusion-probe.swift)
/// so the test host captures it the way a meeting app would.
final class CaptureExclusionPixelTests: XCTestCase {
  private let probeRect = CGRect(x: 40, y: 80, width: 160, height: 160)
  private var sample: CGPoint { CGPoint(x: probeRect.midX, y: probeRect.midY) }

  func testProtectedWindowIsAbsentFromScreenCaptureKit() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["VOXNOTCH_CAPTURE_PIXEL_TESTS"] == "1", "opt-in pixel test"
    )
    try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "test host lacks Screen Recording permission")
    let probe = try compileProbe()
    var report: [String] = []

    for mode in ["none", "cgs", "both"] {
      let result = try await capture(mode: mode, probe: probe)
      report.append("\(mode.padding(toLength: 5, withPad: " ", startingAt: 0)) \(result.summary)")
      XCTAssertTrue(result.unprotected.visible, "\(mode): positive control must see the window")
      XCTAssertFalse(result.desktop.visible, "\(mode): the sample point must not already be magenta")
      if mode == "both" {
        // What VoxNotch ships: sharingType plus window-server exclusion.
        for (name, observation) in result.protected {
          XCTAssertFalse(observation.visible, "both: window leaked in \(name)")
          XCTAssertFalse(observation.masked, "both: window outline exposed in \(name)")
        }
      }
    }
    print("CAPTURE_EXCLUSION_REPORT macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    for line in report { print("CAPTURE_EXCLUSION_REPORT \(line)") }
  }

  // MARK: - Capture scenarios

  private struct Result {
    var desktop: Observation
    var unprotected: Observation
    var protected: [(String, Observation)]

    var summary: String {
      "desktop=\(desktop.rgb) unprotected=\(unprotected) " + protected.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
  }

  private func capture(mode: String, probe: URL) async throws -> Result {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
      throw XCTSkip("main display unavailable to ScreenCaptureKit")
    }
    let config = SCStreamConfiguration()
    config.width = display.width
    config.height = display.height
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.showsCursor = false
    let filter = SCContentFilter(display: display, excludingWindows: [])

    let sink = FrameSink()
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
    try await stream.startCapture()
    let desktop = try await sink.observe(at: sample, after: 0)
    sink.baseline = desktop.rgb

    // A visible window gets protected while a share is already running (setting toggled).
    let window = try ProbeProcess(probe: probe, mode: mode, rect: probeRect, hidden: false)
    defer { window.stop() }
    let unprotected = try await sink.observe(at: sample, after: 0)

    var mark = sink.frameCount
    try window.send("protect")
    let whileStreaming = try await sink.observe(at: sample, after: mark)

    mark = sink.frameCount
    try window.send("repaint")
    let afterRepaint = try await sink.observe(at: sample, after: mark)

    // FB21115847: the window reappeared after the capturer updated its filter mid-stream.
    let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
    mark = sink.frameCount
    try await stream.updateContentFilter(
      SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
    )
    let afterFilterUpdate = try await sink.observe(at: sample, after: mark)

    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let screenshot = Observation(rgb: color(image, at: sample), fresh: true, baseline: desktop.rgb)

    let freshSink = FrameSink()
    freshSink.baseline = desktop.rgb
    let fresh = SCStream(filter: filter, configuration: config, delegate: nil)
    try fresh.addStreamOutput(freshSink, type: .screen, sampleHandlerQueue: freshSink.queue)
    try await fresh.startCapture()
    let freshStream = try await freshSink.observe(at: sample, after: 0)
    try await fresh.stopCapture()

    // A window protected before it is first shown, while a share is running (Always-On
    // opened mid-meeting). This is how VoxNotch normally shows windows.
    window.stop()
    let late = try ProbeProcess(probe: probe, mode: mode, rect: probeRect, hidden: true)
    defer { late.stop() }
    try late.send("protect")
    mark = sink.frameCount
    try late.send("show")
    let protectedBeforeShow = try await sink.observe(at: sample, after: mark)
    try await stream.stopCapture()

    return Result(desktop: desktop, unprotected: unprotected, protected: [
      ("whileStreaming", whileStreaming), ("afterRepaint", afterRepaint),
      ("afterFilterUpdate", afterFilterUpdate), ("screenshot", screenshot),
      ("freshStream", freshStream), ("protectedBeforeShow", protectedBeforeShow),
    ])
  }

  private func color(_ image: CGImage, at point: CGPoint) -> (r: Int, g: Int, b: Int) {
    let scale = CGFloat(image.width) / CGFloat(CGDisplayPixelsWide(CGMainDisplayID()))
    guard let pixel = image.cropping(to: CGRect(x: point.x * scale, y: point.y * scale, width: 1, height: 1)),
          let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return (0, 0, 0) }
    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let rgba = context.data!.assumingMemoryBound(to: UInt8.self)
    return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
  }

  fileprivate static func isMagenta(r: Int, g: Int, b: Int) -> Bool {
    r > 180 && g < 90 && b > 180
  }

  private func compileProbe() throws -> URL {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("scripts/capture-exclusion-probe.swift")
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("capture-exclusion-probe-\(UUID().uuidString)")
    let swiftc = Process()
    swiftc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    swiftc.arguments = ["swiftc", "-framework", "AppKit", source.path, "-o", output.path]
    try swiftc.run()
    swiftc.waitUntilExit()
    guard swiftc.terminationStatus == 0 else {
      throw NSError(domain: "CaptureExclusionPixelTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "failed to compile \(source.path)",
      ])
    }
    return output
  }
}

/// Whether the sampled pixel showed the window, and whether a frame newer than the event
/// arrived. SCK only delivers frames for changed content, and a meeting app keeps sending
/// the last frame it got, so a stale visible frame is still what a receiver sees.
private struct Observation: CustomStringConvertible {
  let rgb: (r: Int, g: Int, b: Int)
  let fresh: Bool
  /// What the desktop looks like at the sample point without the window.
  var baseline: (r: Int, g: Int, b: Int)?

  var visible: Bool { CaptureExclusionPixelTests.isMagenta(r: rgb.r, g: rgb.g, b: rgb.b) }
  /// Hidden, but replaced by something other than the desktop (e.g. a black box).
  var masked: Bool {
    guard !visible, let baseline else { return false }
    return abs(rgb.r - baseline.r) + abs(rgb.g - baseline.g) + abs(rgb.b - baseline.b) > 60
  }

  var description: String {
    let state = visible ? "visible" : masked ? "masked(\(rgb.r),\(rgb.g),\(rgb.b))" : "hidden"
    return state + (fresh ? "" : "(no new frame)")
  }
}

/// Keeps the latest complete frame; SCK only delivers frames when screen content changes.
private final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
  let queue = DispatchQueue(label: "CaptureExclusionPixelTests.frames")
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var count = 0
  var baseline: (r: Int, g: Int, b: Int)?

  var frameCount: Int { lock.withLock { count } }

  func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, buffer.isValid,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
          let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
          let pixels = buffer.imageBuffer
    else { return }
    lock.withLock {
      latest = pixels
      count += 1
    }
  }

  /// Samples the newest frame after waiting for content to settle.
  func observe(at point: CGPoint, after mark: Int) async throws -> Observation {
    try await Task.sleep(nanoseconds: 700_000_000)
    let (pixels, count) = lock.withLock { (latest, self.count) }
    guard let pixels else { return Observation(rgb: (0, 0, 0), fresh: false) }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let scale = CGFloat(CVPixelBufferGetWidth(pixels)) / CGFloat(CGDisplayPixelsWide(CGMainDisplayID()))
    let row = CVPixelBufferGetBytesPerRow(pixels)
    let bgra = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
      .advanced(by: Int(point.y * scale) * row + Int(point.x * scale) * 4)
    return Observation(rgb: (Int(bgra[2]), Int(bgra[1]), Int(bgra[0])), fresh: count > mark, baseline: baseline)
  }
}

/// The window-owning probe process, driven over stdin/stdout.
private final class ProbeProcess: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let lock = NSLock()
  private var lines: [String] = []

  init(probe: URL, mode: String, rect: CGRect, hidden: Bool) throws {
    process.executableURL = probe
    process.arguments = [mode] + [rect.minX, rect.minY, rect.width, rect.height].map { "\(Int($0))" }
      + (hidden ? ["hidden"] : [])
    process.standardInput = input
    process.standardOutput = output
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let text = String(decoding: handle.availableData, as: UTF8.self)
      self?.lock.withLock { self?.lines += text.split(separator: "\n").map(String.init) }
    }
    try process.run()
    try waitFor("READY")
  }

  func send(_ command: String) throws {
    input.fileHandleForWriting.write("\(command)\n".data(using: .utf8)!)
    try waitFor("OK \(command)")
  }

  func stop() {
    output.fileHandleForReading.readabilityHandler = nil
    if process.isRunning { process.terminate() }
  }

  private func waitFor(_ prefix: String) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if let line = lock.withLock({ lines.first { $0.hasPrefix(prefix) } }) {
        if line.hasSuffix("false") { throw NSError(domain: "ProbeProcess", code: 2, userInfo: [NSLocalizedDescriptionKey: line]) }
        return
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw NSError(domain: "ProbeProcess", code: 1, userInfo: [NSLocalizedDescriptionKey: "probe did not print \(prefix)"])
  }
}
