import AppKit
import CoreImage
import SwiftUI
import WebKit
import XCTest
@testable import VoxNotch

@MainActor
final class MobileCompanionTests: XCTestCase {
  private let token = String(repeating: "a", count: 43)
  private let host = "127.0.0.1:8123"

  private func request(_ path: String = "/api/state", auth: String? = nil,
                       headers: String = "", method: String = "GET") throws -> MobileCompanionHTTPRequest {
    let authorization = auth.map { "Authorization: Bearer \($0)\r\n" } ?? ""
    return try XCTUnwrap(MobileCompanionHTTPRequest.parse(Data("\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n\(authorization)\(headers)\r\n".utf8)))
  }

  func testAuthenticationIsRequiredBeforeReadingStateOrUsingETags() throws {
    let router = MobileCompanionHTTP(host: host, token: token)
    var reads = 0
    for value in [try request(), try request(auth: "wrong"), try request(auth: "", headers: "If-None-Match: \"cached\"\r\n")] {
      let result = router.response(to: value) { reads += 1; return Data("secret".utf8) }
      XCTAssertEqual(result.status, 401)
      XCTAssertTrue(result.body.isEmpty)
    }
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(router.response(to: try request(auth: token)) { Data("{}".utf8) }.status, 200)
  }

  func testCrossOriginAndReboundHostCannotReadTheSession() throws {
    let router = MobileCompanionHTTP(host: host, token: token)
    let origin = try request(auth: token, headers: "Origin: https://example.com\r\n")
    let rebinding = try XCTUnwrap(MobileCompanionHTTPRequest.parse(Data("GET /api/state HTTP/1.1\r\nHost: attacker.example\r\nAuthorization: Bearer \(token)\r\n\r\n".utf8)))
    for request in [origin, rebinding] {
      XCTAssertEqual(router.response(to: request) { XCTFail("must not read state"); return Data() }.status, 403)
    }
  }

  func testOnlyReadOnlyRoutesExistAndQueryTokensAreNotAccepted() throws {
    let router = MobileCompanionHTTP(host: host, token: token)
    for path in ["/api/ask", "/api/state?token=\(token)", "/../history.sqlite", "/api/settings"] {
      XCTAssertEqual(router.response(to: try request(path, auth: token)) { XCTFail(); return Data() }.status, 404)
    }
    XCTAssertEqual(router.response(to: try request(auth: token, method: "POST")) { XCTFail(); return Data() }.status, 405)
    let page = router.response(to: try request("/")) { XCTFail(); return Data() }
    XCTAssertEqual(page.status, 200)
    XCTAssertFalse(String(decoding: page.body, as: UTF8.self).contains(token))
    XCTAssertTrue(page.extraHeaders["Content-Security-Policy"]?.contains("script-src 'sha256-") == true)
    XCTAssertTrue(String(decoding: page.data, as: UTF8.self).contains("Cache-Control: no-store"))
  }

  func testSnapshotETagChangesOnlyWhenViewDataChanges() throws {
    let router = MobileCompanionHTTP(host: host, token: token)
    let first = router.response(to: try request(auth: token)) { Data("one".utf8) }
    let cachedRequest = try request(auth: token, headers: "If-None-Match: \(try XCTUnwrap(first.extraHeaders["ETag"]))\r\n")
    let same = router.response(to: cachedRequest) { Data("one".utf8) }
    XCTAssertEqual(same.status, 304)
    XCTAssertTrue(same.body.isEmpty)
    let changed = router.response(to: cachedRequest) { Data("two".utf8) }
    XCTAssertEqual(changed.status, 200)
    XCTAssertNotEqual(changed.extraHeaders["ETag"], first.extraHeaders["ETag"])
  }

  func testHTTPParserHandlesFragmentationAndRejectsAmbiguousRequests() throws {
    XCTAssertNil(try MobileCompanionHTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: local".utf8)))
    let invalid = [
      "GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /api/state HTTP/1.1\r\n\r\n",
      "GET http://example.com/ HTTP/1.1\r\nHost: x\r\n\r\n",
      "GET / HTTP/1.1\r\n\r\n",
    ]
    for raw in invalid { XCTAssertThrowsError(try MobileCompanionHTTPRequest.parse(Data(raw.utf8))) }
    XCTAssertThrowsError(try MobileCompanionHTTPRequest.parse(Data(repeating: 65, count: 8193)))
  }

  func testSnapshotIncludesPartialsAndStreamingAnswerButNoProviderSettings() throws {
    let state = fixture()
    let snapshot = MobileCompanionSnapshot(state: state)
    XCTAssertEqual(snapshot.transcript.count, 2)
    XCTAssertFalse(snapshot.transcript[1].isFinal)
    XCTAssertEqual(snapshot.answers[0].status, "streaming")
    XCTAssertEqual(snapshot.displayedAnswerID, state.answers[0].id.uuidString)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
    XCTAssertEqual(Set(try XCTUnwrap(json).keys), ["sessionID", "status", "message", "isPaused", "startedAt", "sources", "transcript", "answers", "displayedAnswerID"])
    state.updateAnswer(state.answers[0].id) { $0.markdown += "\nupdated" }
    XCTAssertNotEqual(MobileCompanionSnapshot(state: state), snapshot)
  }

  func testServerIsOffByDefaultAndRequiresAnActiveSession() {
    let server = MobileCompanionServer(state: AlwaysOnState())
    XCTAssertEqual(server.status, .off)
    XCTAssertNil(server.accessURL)
    server.start(address: .init(interface: "lo0", host: "127.0.0.1"))
    XCTAssertFalse(server.isEnabled)
    XCTAssertNil(server.accessURL)
  }

  func testLoopbackServerAuthenticatesRotatesLinkAndStops() async throws {
    let state = fixture(), server = MobileCompanionServer(state: state)
    defer { server.stop() }
    server.start(address: .init(interface: "lo0", host: "127.0.0.1"))
    let first = try await readyURL(server)
    let firstToken = try XCTUnwrap(first.fragment)
    XCTAssertEqual(firstToken.count, 43)
    var url = URLComponents(url: first, resolvingAgainstBaseURL: false)!
    url.fragment = nil; url.path = "/api/state"
    var request = URLRequest(url: try XCTUnwrap(url.url))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (_, unauthorized) = try await session.data(for: request)
    XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)
    request.setValue("Bearer \(firstToken)", forHTTPHeaderField: "Authorization")
    let (data, authorized) = try await session.data(for: request)
    XCTAssertEqual((authorized as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(try JSONDecoder().decode(MobileCompanionSnapshot.self, from: data), MobileCompanionSnapshot(state: state))
    XCTAssertTrue(server.hasConnectedClient)
    server.refreshLink()
    let second = try await readyURL(server)
    XCTAssertNotEqual(second.fragment, first.fragment)
    url = URLComponents(url: second, resolvingAgainstBaseURL: false)!
    url.fragment = nil; url.path = "/api/state"
    request.url = url.url
    let (_, revoked) = try await session.data(for: request)
    XCTAssertEqual((revoked as? HTTPURLResponse)?.statusCode, 401)
    server.stop()
    XCTAssertNil(server.accessURL)
    XCTAssertFalse(server.hasConnectedClient)
    XCTAssertEqual(server.status, .off)
  }

  func testQRImageRoundTripsTheEntireSessionLink() throws {
    let url = try XCTUnwrap(URL(string: "http://192.168.1.5:12345/#\(token)"))
    let image = try XCTUnwrap(MobileCompanionView.qrImage(for: url))
    let data = try XCTUnwrap(image.tiffRepresentation)
    let ciImage = try XCTUnwrap(CIImage(data: data))
    let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    let qr = detector.features(in: ciImage).first as? CIQRCodeFeature
    XCTAssertEqual(qr?.messageString, url.absoluteString)
  }

  func testPopoverSizedQRCodeIsScannableInTheRenderedView() async throws {
    let state = fixture(), server = MobileCompanionServer(state: state)
    defer { server.stop() }
    server.start(address: .init(interface: "lo0", host: "127.0.0.1"))
    let url = try await readyURL(server)
    let view = NSHostingView(rootView: MobileCompanionView(server: server, state: state)
      .padding(18).frame(width: 310).fixedSize(horizontal: false, vertical: true)
      .environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
    let size = view.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = view
    defer { window.close() }
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let image = try XCTUnwrap(CIImage(data: png))
    let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    XCTAssertEqual((detector.features(in: image).first as? CIQRCodeFeature)?.messageString, url.absoluteString)
    try? png.write(to: URL(fileURLWithPath: "/private/tmp/voxnotch-mobile-pairing.png"))
  }

  func testWebKitLoadsTheServedPageWithCSPAndPairsUsingTheQRFragment() async throws {
    let state = fixture(), server = MobileCompanionServer(state: state)
    defer { server.stop() }
    server.start(address: .init(interface: "lo0", host: "127.0.0.1"))
    let url = try await readyURL(server)
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let loaded = expectation(description: "served page loaded")
    let delegate = PageDelegate(loaded)
    view.navigationDelegate = delegate
    view.load(URLRequest(url: url))
    await fulfillment(of: [loaded], timeout: 10)
    // An offscreen test web view is hidden. Simulate bringing the paired phone
    // tab to the foreground, which resumes polling in the shipped page.
    _ = try await view.evaluateJavaScript("Object.defineProperty(document, 'hidden', {get: () => false}); document.dispatchEvent(new Event('visibilitychange'))")
    let deadline = ContinuousClock.now + .seconds(4)
    var paired = false
    while ContinuousClock.now < deadline {
      paired = (try await view.evaluateJavaScript("Boolean(window.VoxNotchMobile?.displayedAnswer())")) as? Bool == true
      if paired { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertTrue(paired, "the HTTP CSP must allow the exact inline script and authenticated polling")
    XCTAssertTrue(server.hasConnectedClient)
    let fragment = try await view.evaluateJavaScript("location.hash") as? String
    XCTAssertEqual(fragment, "", "remove the access key from the address bar after pairing")
    _ = try await view.evaluateJavaScript("document.getElementById('answer').scrollTop = 0")
    let image = try await view.takeSnapshot(configuration: nil)
    if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
       let png = bitmap.representation(using: .png, properties: [:]) {
      try? png.write(to: URL(fileURLWithPath: "/private/tmp/voxnotch-mobile-paired.png"))
    }
    view.stopLoading()
    withExtendedLifetime(delegate) {}
  }

  func testMobileWebKitRendersCodeSafelyAndKeepsIndependentNavigation() async throws {
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let loaded = expectation(description: "phone page loaded")
    let delegate = PageDelegate(loaded)
    view.navigationDelegate = delegate
    view.loadHTMLString(MobileCompanionPage.html, baseURL: URL(string: "http://127.0.0.1:8123/"))
    await fulfillment(of: [loaded], timeout: 10)
    let state = fixture()
    var second = AssistantAnswer(id: UUID(), createdAt: Date(), trigger: .manual, model: "demo")
    second.status = .done; second.markdown = "**Second answer**"
    state.appendAnswer(second)
    try await apply(state, to: view)
    let firstID = state.answers[0].id.uuidString
    _ = try await view.evaluateJavaScript("document.getElementById('history').value = 0; document.getElementById('history').dispatchEvent(new Event('input'))")
    let selected = try await view.evaluateJavaScript("VoxNotchMobile.displayedAnswer().id") as? String
    XCTAssertEqual(selected, firstID)
    let code = try await view.evaluateJavaScript("document.querySelector('pre').textContent") as? String
    XCTAssertEqual(code, "# easy\nprint('<img src=x onerror=alert(1)>')")
    let injected = try await view.evaluateJavaScript("document.querySelectorAll('#answer-body img, #answer-body script').length") as? Int
    XCTAssertEqual(injected, 0)
    XCTAssertEqual(state.displayedAnswer?.id, second.id, "phone navigation must not change the Mac page")
    state.updateAnswer(state.answers[0].id) { $0.markdown += "\nmore" }
    try await apply(state, to: view)
    let afterUpdate = try await view.evaluateJavaScript("VoxNotchMobile.displayedAnswer().id") as? String
    XCTAssertEqual(afterUpdate, firstID)
    _ = try await view.evaluateJavaScript("document.getElementById('follow').click()")
    let following = try await view.evaluateJavaScript("VoxNotchMobile.displayedAnswer().id") as? String
    XCTAssertEqual(following, second.id.uuidString)
    let width = try await view.evaluateJavaScript("document.documentElement.scrollWidth <= innerWidth") as? Bool
    XCTAssertEqual(width, true)
    let image = try await view.takeSnapshot(configuration: nil)
    let attachment = XCTAttachment(image: image)
    attachment.name = "Phone view 390x844"; attachment.lifetime = .keepAlways
    add(attachment)
    if let data = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
      try? png.write(to: URL(fileURLWithPath: "/private/tmp/voxnotch-mobile-portrait.png"))
    }
    view.frame.size = CGSize(width: 844, height: 390)
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    let layout = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('main')).flexDirection") as? String
    XCTAssertEqual(layout, "row")
    let landscape = try await view.takeSnapshot(configuration: nil)
    let landscapeAttachment = XCTAttachment(image: landscape)
    landscapeAttachment.name = "Phone view 844x390"; landscapeAttachment.lifetime = .keepAlways
    add(landscapeAttachment)
    if let data = landscape.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
       let png = bitmap.representation(using: .png, properties: [:]) {
      try? png.write(to: URL(fileURLWithPath: "/private/tmp/voxnotch-mobile-landscape.png"))
    }
    _ = try await view.evaluateJavaScript("VoxNotchMobile.clearContent('Disconnected')")
    let cleared = try await view.evaluateJavaScript("document.getElementById('answer-body').textContent") as? String
    XCTAssertEqual(cleared, "Reconnect to see answers.")
    state.begin(sources: [.microphone])
    try await apply(state, to: view)
    let old = try await view.evaluateJavaScript("document.getElementById('transcript-body').textContent.includes('question')") as? Bool
    XCTAssertEqual(old, false)
    withExtendedLifetime(delegate) {}
  }

  private func readyURL(_ server: MobileCompanionServer) async throws -> URL {
    let deadline = ContinuousClock.now + .seconds(4)
    while server.accessURL == nil && ContinuousClock.now < deadline {
      if case .failed(let message) = server.status { throw NSError(domain: message, code: 1) }
      try await Task.sleep(for: .milliseconds(20))
    }
    return try XCTUnwrap(server.accessURL)
  }

  private func fixture() -> AlwaysOnState {
    let state = AlwaysOnState()
    state.begin(sources: [.microphone, .systemAudio]); state.status = .running
    let now = Date()
    state.startedAt = now
    for (offset, source) in [AudioSource.systemAudio, .microphone].enumerated() {
      state.apply(TranscriptUpdate(utteranceID: UUID(), source: source, text: offset == 0 ? "A question" : "A partial reply",
                                   isFinal: offset == 0, startedAt: now.addingTimeInterval(Double(offset)), endedAt: now,
                                   processingLatency: .zero, trailingSilence: .zero))
    }
    var answer = AssistantAnswer(id: UUID(), createdAt: now, trigger: .auto, model: "Demo")
    answer.status = .streaming
    answer.markdown = "### Safe code\n\n```python\n# easy\nprint('<img src=x onerror=alert(1)>')\n```\n\n| Metric | Value |\n|---|---|\n| Retention | 41% |"
    state.appendAnswer(answer)
    return state
  }

  private func apply(_ state: AlwaysOnState, to view: WKWebView) async throws {
    let data = try JSONEncoder().encode(MobileCompanionSnapshot(state: state))
    _ = try await view.evaluateJavaScript("VoxNotchMobile.applySnapshot(\(String(decoding: data, as: UTF8.self)))")
  }

  private final class PageDelegate: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
  }
}
