import CryptoKit
import Foundation

/// A deliberately small, read-only HTTP surface: one page and one authenticated
/// snapshot endpoint. No file paths, commands, CORS, cookies or request bodies.
nonisolated struct MobileCompanionHTTPRequest: Sendable {
  enum ParseError: Error { case invalid, tooLarge }
  static let maximumHeaderSize = 8_192
  let method: String
  let path: String
  let headers: [String: String]

  static func parse(_ data: Data) throws -> Self? {
    guard data.count <= maximumHeaderSize else { throw ParseError.tooLarge }
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    guard end.upperBound == data.endIndex,
          let text = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw ParseError.invalid }
    let lines = text.components(separatedBy: "\r\n")
    let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0",
          request[1].hasPrefix("/"), !request[1].hasPrefix("//"),
          !request[1].contains("#") else { throw ParseError.invalid }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { throw ParseError.invalid }
      let name = String(line[..<colon]).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
            !value.utf8.contains(where: { $0 < 32 || $0 == 127 }), headers[name] == nil else { throw ParseError.invalid }
      headers[name] = value
    }
    guard headers["host"] != nil, headers["transfer-encoding"] == nil,
          headers["content-length"] == nil || headers["content-length"] == "0" else { throw ParseError.invalid }
    return Self(method: String(request[0]), path: String(request[1]), headers: headers)
  }
}

nonisolated struct MobileCompanionHTTPResponse: Sendable {
  let status: Int
  var body = Data()
  var contentType = "text/plain; charset=utf-8"
  var extraHeaders: [String: String] = [:]

  var data: Data {
    let reason = [200: "OK", 304: "Not Modified", 400: "Bad Request", 401: "Unauthorized",
                  403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large"]
    var headers = ["Content-Length": String(body.count), "Content-Type": contentType,
                   "Cache-Control": "no-store", "Connection": "close", "Referrer-Policy": "no-referrer",
                   "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY"]
    headers.merge(extraHeaders) { _, new in new }
    if status == 304 { headers["Content-Length"] = nil }
    let head = "HTTP/1.1 \(status) \(reason[status] ?? "Error")\r\n"
      + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
    return Data(head.utf8) + body
  }
}

nonisolated struct MobileCompanionHTTP {
  let host: String
  let token: String

  func response(to request: MobileCompanionHTTPRequest, snapshot: () -> Data) -> MobileCompanionHTTPResponse {
    guard request.headers["host"] == host,
          request.headers["origin"].map({ $0 == "http://\(host)" }) ?? true else { return .init(status: 403) }
    guard request.method == "GET" else { return .init(status: 405, extraHeaders: ["Allow": "GET"]) }
    switch request.path {
    case "/":
      let scriptHash = Data(SHA256.hash(data: Data(MobileCompanionPage.javascript.utf8))).base64EncodedString()
      return .init(status: 200, body: Data(MobileCompanionPage.html.utf8), contentType: "text/html; charset=utf-8",
                   extraHeaders: ["Content-Security-Policy": "default-src 'none'; script-src 'sha256-\(scriptHash)'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"])
    case "/api/state":
      guard let auth = request.headers["authorization"], Self.matches(auth, "Bearer \(token)") else { return .init(status: 401) }
      let data = snapshot()
      let etag = "\"\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())\""
      if request.headers["if-none-match"] == etag { return .init(status: 304, extraHeaders: ["ETag": etag]) }
      return .init(status: 200, body: data, contentType: "application/json; charset=utf-8", extraHeaders: ["ETag": etag])
    default: return .init(status: 404)
    }
  }

  private static func matches(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8), b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}
