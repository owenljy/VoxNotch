import AppKit
import ScreenCaptureKit
import XCTest

/// Pixel-level check that protected content is absent from ScreenCaptureKit captures, the
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

  private func samples(in rect: CGRect) -> [CGPoint] {
    [0.15, 0.5, 0.85].flatMap { x in
      [0.15, 0.5, 0.85].map { y in
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
      }
    }
  }

  func testProtectedContentIsAbsentFromScreenCaptureKit() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["VOXNOTCH_CAPTURE_PIXEL_TESTS"] == "1", "opt-in pixel test"
    )
    try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "test host lacks Screen Recording permission")
    let probe = try compileProbe()
    defer { try? FileManager.default.removeItem(at: probe.deletingLastPathComponent()) }
    var report: [String] = []

    for mode in ["none", "cgs", "both", "cgs-swiftui", "both-swiftui"] {
      let result = try await capture(mode: mode, probe: probe)
      let label = mode.padding(toLength: max(5, mode.count), withPad: " ", startingAt: 0)
      report.append("\(label) \(result.summary)")
      XCTAssertTrue(result.unprotected.allSamplesVisible, "\(mode): positive control must see the whole probe")
      XCTAssertFalse(result.desktop.visible, "\(mode): the sample point must not already be magenta")
      XCTAssertTrue(result.restored.allSamplesVisible, "\(mode): disabling must restore content")
      XCTAssertTrue(result.rapidlyRestored.allSamplesVisible, "\(mode): an obsolete refresh must not re-enable protection")
      if mode != "none" {
        // Both the CGS fallback and the combined policy must protect content.
        // A grey mask is an acceptable fallback, and remains distinct in the report.
        for (name, observation) in result.protected {
          XCTAssertFalse(observation.visible, "\(mode): content leaked in \(name)")
        }
      }
    }
    print("CAPTURE_EXCLUSION_REPORT macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    for line in report { print("CAPTURE_EXCLUSION_REPORT \(line)") }
  }

  func testMissingCapturedFramesCannotPassAsHiddenContent() async {
    do {
      _ = try await FrameSink().observe(at: sample, after: 0)
      XCTFail("No captured image must never count as successful protection")
    } catch CaptureProbeError.noFrame {
      // Expected: a stalled/failed capture is inconclusive, not invisible.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // MARK: - Capture scenarios

  private struct Result {
    var desktop: Observation
    var unprotected: Observation
    var restored: Observation
    var rapidlyRestored: Observation
    var protected: [(String, Observation)]

    var summary: String {
      "desktop=\(desktop.rgb) unprotected=\(unprotected) restored=\(restored) rapidOff=\(rapidlyRestored) "
        + protected.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
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

    let sink = FrameSink(samplePoints: samples(in: probeRect))
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
    let screenshot = Observation(
      rgb: try color(image, at: sample), fresh: true, baseline: desktop.rgb,
      otherPixels: try samples(in: probeRect).map { try color(image, at: $0) }
    )

    let freshSink = FrameSink(samplePoints: samples(in: probeRect))
    freshSink.baseline = desktop.rgb
    let fresh = SCStream(filter: filter, configuration: config, delegate: nil)
    try fresh.addStreamOutput(freshSink, type: .screen, sampleHandlerQueue: freshSink.queue)
    try await fresh.startCapture()
    let freshStream = try await freshSink.observe(at: sample, after: 0)
    try await fresh.stopCapture()

    mark = sink.frameCount
    try window.send("grow")
    // This point was outside the original region and is inside the enlarged window.
    let afterResize = try await sink.observe(
      at: CGPoint(x: probeRect.maxX + 40, y: sample.y),
      additionalPoints: samples(in: CGRect(origin: probeRect.origin, size: CGSize(width: 240, height: 240))),
      after: mark
    )

    mark = sink.frameCount
    try window.send("unprotect")
    let restored = try await sink.observe(at: sample, after: mark)

    mark = sink.frameCount
    try window.send("rapidOn")
    let afterRapidToggle = try await sink.observe(at: sample, after: mark)
    mark = sink.frameCount
    try window.send("rapidOff")
    let rapidlyRestored = try await sink.observe(at: sample, after: mark)

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

    return Result(desktop: desktop, unprotected: unprotected, restored: restored,
                  rapidlyRestored: rapidlyRestored, protected: [
      ("whileStreaming", whileStreaming), ("afterRepaint", afterRepaint),
      ("afterFilterUpdate", afterFilterUpdate), ("screenshot", screenshot),
      ("freshStream", freshStream), ("afterResize", afterResize),
      ("afterRapidToggle", afterRapidToggle), ("protectedBeforeShow", protectedBeforeShow),
    ])
  }

  private func color(_ image: CGImage, at point: CGPoint) throws -> (r: Int, g: Int, b: Int) {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let x = floor(point.x * CGFloat(image.width) / bounds.width)
    let y = floor(point.y * CGFloat(image.height) / bounds.height)
    guard x >= 0, y >= 0, x < CGFloat(image.width), y < CGFloat(image.height),
          let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
          let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { throw CaptureProbeError.invalidPixel }
    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let rgba = context.data!.assumingMemoryBound(to: UInt8.self)
    return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
  }

  fileprivate static func isMagenta(r: Int, g: Int, b: Int) -> Bool {
    r > 180 && g < 90 && b > 180
  }

  private func compileProbe() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("capture-exclusion-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("main.swift")
    try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/capture-exclusion-probe.swift"), to: source)
    let output = directory.appendingPathComponent("probe")
    let swiftc = Process()
    swiftc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    swiftc.arguments = ["swiftc", "-swift-version", "6", "-framework", "AppKit", "-framework", "SwiftUI", source.path,
                       root.appendingPathComponent("VoxNotch/Managers/CaptureExclusion.swift").path,
                       "-o", output.path]
    try swiftc.run()
    swiftc.waitUntilExit()
    guard swiftc.terminationStatus == 0 else {
      try? FileManager.default.removeItem(at: directory)
      throw NSError(domain: "CaptureExclusionPixelTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "failed to compile \(source.path)",
      ])
    }
    return output
  }
}

private enum CaptureProbeError: Error {
  case noFrame, invalidPixel
}

/// Whether the sampled pixel showed the window, and whether a frame newer than the event
/// arrived. SCK only delivers frames for changed content, and a meeting app keeps sending
/// the last frame it got, so a stale visible frame is still what a receiver sees.
private struct Observation: CustomStringConvertible {
  let rgb: (r: Int, g: Int, b: Int)
  let fresh: Bool
  /// What the desktop looks like at the sample point without the window.
  var baseline: (r: Int, g: Int, b: Int)?
  var otherPixels: [(r: Int, g: Int, b: Int)] = []

  var visible: Bool { ([rgb] + otherPixels).contains { CaptureExclusionPixelTests.isMagenta(r: $0.r, g: $0.g, b: $0.b) } }
  var allSamplesVisible: Bool { ([rgb] + otherPixels).allSatisfy { CaptureExclusionPixelTests.isMagenta(r: $0.r, g: $0.g, b: $0.b) } }
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
  private let samplePoints: [CGPoint]

  init(samplePoints: [CGPoint] = []) {
    self.samplePoints = samplePoints
  }

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
  func observe(at point: CGPoint, additionalPoints: [CGPoint] = [], after mark: Int) async throws -> Observation {
    try await Task.sleep(nanoseconds: 700_000_000)
    let (pixels, count) = lock.withLock { (latest, self.count) }
    guard let pixels else { throw CaptureProbeError.noFrame }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let bounds = CGDisplayBounds(CGMainDisplayID())
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixels) else { throw CaptureProbeError.invalidPixel }
    let row = CVPixelBufferGetBytesPerRow(pixels)
    let colors = try ([point] + samplePoints + additionalPoints).map { point -> (r: Int, g: Int, b: Int) in
      let x = Int(point.x * CGFloat(CVPixelBufferGetWidth(pixels)) / bounds.width)
      let y = Int(point.y * CGFloat(CVPixelBufferGetHeight(pixels)) / bounds.height)
      guard x >= 0, y >= 0, x < CVPixelBufferGetWidth(pixels), y < CVPixelBufferGetHeight(pixels) else {
        throw CaptureProbeError.invalidPixel
      }
      let bgra = baseAddress.assumingMemoryBound(to: UInt8.self).advanced(by: y * row + x * 4)
      return (Int(bgra[2]), Int(bgra[1]), Int(bgra[0]))
    }
    return Observation(rgb: colors[0], fresh: count > mark, baseline: baseline,
                       otherPixels: Array(colors.dropFirst()))
  }
}

/// The window-owning probe process, driven over stdin/stdout.
private final class ProbeProcess: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let lock = NSLock()
  private var lines: [String] = []
  private var pending = Data()

  init(probe: URL, mode: String, rect: CGRect, hidden: Bool) throws {
    process.executableURL = probe
    process.arguments = [mode.replacingOccurrences(of: "-swiftui", with: "")]
      + [rect.minX, rect.minY, rect.width, rect.height].map { "\(Int($0))" }
      + (hidden ? ["hidden"] : [])
    var environment = ProcessInfo.processInfo.environment
    environment["VOXNOTCH_PROBE_SWIFTUI"] = mode.hasSuffix("-swiftui") ? "1" : "0"
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self else { return }
      self.lock.withLock {
        self.pending.append(data)
        while let newline = self.pending.firstIndex(of: 10) {
          self.lines.append(String(decoding: self.pending[..<newline], as: UTF8.self))
          self.pending.removeSubrange(...newline)
        }
      }
    }
    do {
      try process.run()
      try waitFor("READY")
    } catch {
      stop()
      throw error
    }
  }

  func send(_ command: String) throws {
    input.fileHandleForWriting.write("\(command)\n".data(using: .utf8)!)
    try waitFor("OK \(command)")
  }

  func stop() {
    output.fileHandleForReading.readabilityHandler = nil
    if process.isRunning { process.terminate() }
  }

  deinit { stop() }

  private func waitFor(_ prefix: String) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if let line = lock.withLock({ () -> String? in
        guard let index = lines.firstIndex(where: { $0.hasPrefix(prefix) }) else { return nil }
        return lines.remove(at: index)
      }) {
        if line.hasSuffix("false") { throw NSError(domain: "ProbeProcess", code: 2, userInfo: [NSLocalizedDescriptionKey: line]) }
        return
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw NSError(domain: "ProbeProcess", code: 1, userInfo: [NSLocalizedDescriptionKey: "probe did not print \(prefix)"])
  }
}
