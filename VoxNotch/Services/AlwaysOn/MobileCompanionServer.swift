import Darwin
import Foundation
import Network
import Security

nonisolated struct MobileCompanionAddress: Identifiable, Equatable, Sendable {
  let interface: String
  let host: String
  var id: String { host }

  static func available() -> [Self] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0, let first else { return [] }
    defer { freeifaddrs(first) }
    var result: [Self] = []
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
      defer { pointer = current.pointee.ifa_next }
      let entry = current.pointee
      let flags = Int32(entry.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
            flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
            let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
      let name = String(cString: entry.ifa_name)
      // Avoid VPN, VM and peer-to-peer interfaces in the phone picker.
      guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
      let host = String(cString: buffer)
      if !result.contains(where: { $0.host == host }) { result.append(Self(interface: name, host: host)) }
    }
    return result.sorted { ($0.interface == "en0" ? 0 : 1, $0.interface, $0.host) < ($1.interface == "en0" ? 0 : 1, $1.interface, $1.host) }
  }
}

@MainActor @Observable
final class MobileCompanionServer {
  static let shared = MobileCompanionServer()

  enum Status: Equatable {
    case off, starting, ready, failed(String)
  }

  private(set) var status: Status = .off
  private(set) var accessURL: URL?
  private(set) var hasConnectedClient = false
  private(set) var address: MobileCompanionAddress?
  var isEnabled: Bool { status == .starting || status == .ready }

  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var connections: [UUID: MobileCompanionConnection] = [:]
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private let state: AlwaysOnState
  @ObservationIgnored private var router: MobileCompanionHTTP?

  init(state: AlwaysOnState? = nil) { self.state = state ?? .shared }

  func start(address: MobileCompanionAddress) {
    stop()
    guard state.isActive else { status = .failed("Start Always-On before connecting your phone."); return }
    guard let ip = IPv4Address(address.host) else { status = .failed("Choose a local IPv4 address."); return }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      status = .failed("Could not create a private connection link.")
      return
    }
    let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(ip), port: .any)
    do {
      let listener = try NWListener(using: parameters)
      self.listener = listener
      self.address = address
      status = .starting
      let generation = self.generation
      listener.stateUpdateHandler = { [weak self] update in
        Task { @MainActor in
          guard let self, self.generation == generation else { return }
          switch update {
          case .ready:
            guard let port = self.listener?.port else { return }
            let host = "\(address.host):\(port.rawValue)"
            self.router = MobileCompanionHTTP(host: host, token: token)
            var url = URLComponents()
            url.scheme = "http"; url.host = address.host; url.port = Int(port.rawValue); url.path = "/"; url.fragment = token
            self.accessURL = url.url
            self.status = .ready
          case .failed(let error), .waiting(let error):
            self.stop()
            self.status = .failed("Could not connect: \(error.localizedDescription). Check Local Network permission and Wi-Fi.")
          default: break
          }
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in
          guard let self, self.generation == generation, self.status == .ready, self.connections.count < 16 else {
            connection.cancel()
            return
          }
          self.accept(connection)
        }
      }
      listener.start(queue: .main)
    } catch {
      stop()
      status = .failed(error.localizedDescription)
    }
  }

  func stop() {
    generation = UUID()
    listener?.stateUpdateHandler = nil
    listener?.newConnectionHandler = nil
    listener?.cancel()
    listener = nil
    let open = Array(connections.values)
    connections.removeAll()
    open.forEach { $0.close() }
    router = nil
    accessURL = nil
    address = nil
    hasConnectedClient = false
    status = .off
  }

  func refreshLink() {
    if let address { start(address: address) }
  }

  private func accept(_ connection: NWConnection) {
    let client = MobileCompanionConnection(connection: connection) { [weak self] request in
      guard let self, let router = self.router, self.state.isActive else { return .init(status: 403) }
      let response = router.response(to: request) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(MobileCompanionSnapshot(state: self.state))) ?? Data()
      }
      if !self.hasConnectedClient, request.path == "/api/state", response.status == 200 || response.status == 304 {
        self.hasConnectedClient = true
      }
      return response
    } onClose: { [weak self] id in
      self?.connections[id] = nil
    }
    connections[client.id] = client
    client.start()
  }
}

@MainActor
private final class MobileCompanionConnection {
  let id = UUID()
  private let connection: NWConnection
  private let response: (MobileCompanionHTTPRequest) -> MobileCompanionHTTPResponse
  private let onClose: (UUID) -> Void
  private var buffer = Data()
  private var timeout: Task<Void, Never>?
  private var isClosed = false

  init(connection: NWConnection,
       response: @escaping (MobileCompanionHTTPRequest) -> MobileCompanionHTTPResponse,
       onClose: @escaping (UUID) -> Void) {
    self.connection = connection
    self.response = response
    self.onClose = onClose
  }

  func start() {
    connection.start(queue: .main)
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      self?.close()
    }
    receive()
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    timeout?.cancel()
    timeout = nil
    connection.cancel()
    onClose(id)
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: MobileCompanionHTTPRequest.maximumHeaderSize + 1) { [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, !self.isClosed else { return }
        if let data { self.buffer.append(data) }
        do {
          if let request = try MobileCompanionHTTPRequest.parse(self.buffer) {
            self.send(self.response(request))
          } else if complete || error != nil {
            self.close()
          } else {
            self.receive()
          }
        } catch MobileCompanionHTTPRequest.ParseError.tooLarge {
          self.send(.init(status: 413))
        } catch {
          self.send(.init(status: 400))
        }
      }
    }
  }

  private func send(_ response: MobileCompanionHTTPResponse) {
    connection.send(content: response.data, completion: .contentProcessed { [weak self] _ in
      Task { @MainActor in self?.close() }
    })
  }
}
