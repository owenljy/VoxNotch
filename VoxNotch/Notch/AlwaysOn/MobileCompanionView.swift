import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct MobileCompanionButton: View {
  @State private var isPresented = false
  private let server = MobileCompanionServer.shared

  var body: some View {
    PanelIconButton(systemName: "iphone", help: "View on phone", tint: server.isEnabled ? .notchBlue : .white) {
      isPresented.toggle()
    }
    .privacyAwarePopover(isPresented: $isPresented, arrowEdge: .bottom) {
      MobileCompanionView()
        .padding(18)
        .frame(width: 310)
    }
  }
}

struct MobileCompanionSettingsSection: View {
  var body: some View {
    Section("Phone View") {
      MobileCompanionView()
        .frame(maxWidth: .infinity)
    }
  }
}

struct MobileCompanionView: View {
  private let server: MobileCompanionServer
  private let state: AlwaysOnState
  @State private var addresses: [MobileCompanionAddress] = []
  @State private var selectedHost = ""

  init(server: MobileCompanionServer? = nil, state: AlwaysOnState? = nil) {
    self.server = server ?? .shared
    self.state = state ?? .shared
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("View on Phone", systemImage: "iphone")
        .font(.headline)
      Text("Scan with your phone camera to see live transcription and AI answers. Keep both devices on the same Wi-Fi.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let url = server.accessURL {
        if let image = Self.qrImage(for: url) {
          Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .frame(width: 188, height: 188)
            .padding(16)
            .background(.white, in: .rect(cornerRadius: 12))
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Phone connection QR code")
        }
        Text(server.hasConnectedClient ? "Phone paired" : "Ready to scan")
          .font(.caption)
          .foregroundStyle(server.hasConnectedClient ? .green : .secondary)
        Text("\(url.host ?? ""):\(String(url.port ?? 80))")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        HStack {
          Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
          }
          Button("New QR Code") { server.refreshLink() }
          Spacer(minLength: 0)
        }
        Button("Turn Off Phone View", role: .destructive) { server.stop() }
      } else {
        if addresses.count > 1 {
          HStack {
            Text("Local address").font(.caption)
            Spacer()
            PrivacyMenu {
              ForEach(addresses) { address in
                Button(address.host) { selectedHost = address.host }
              }
            } label: {
              HStack(spacing: 4) {
                Text(selectedHost).font(.caption.monospaced())
                Image(systemName: "chevron.down").font(.system(size: 8))
              }
            }
            .accessibilityLabel("Local address")
          }
        }
        switch server.status {
        case .starting:
          HStack { ProgressView().controlSize(.small); Text("Starting connection…").font(.caption) }
          Button("Cancel") { server.stop() }
        case .failed(let message):
          Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
          enableButton
        case .off, .ready:
          if !state.isActive {
            Text("Start Always-On on your Mac first.").font(.caption).foregroundStyle(.secondary)
          } else if addresses.isEmpty {
            Text("Connect your Mac to Wi-Fi or Ethernet, then refresh.").font(.caption).foregroundStyle(.secondary)
          }
          enableButton
        }
      }
      Text("Read-only access. Anyone with this link can view the current session. Use trusted Wi-Fi; the local connection is not encrypted. Turning this off or stopping Always-On invalidates the link.")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear(perform: refreshAddresses)
  }

  private var enableButton: some View {
    HStack {
      Button("Enable Phone View") {
        if let address = addresses.first(where: { $0.host == selectedHost }) { server.start(address: address) }
      }
      .disabled(!state.isActive || addresses.isEmpty)
      Button(action: refreshAddresses) { Image(systemName: "arrow.clockwise") }
        .accessibilityLabel("Refresh Wi-Fi addresses")
    }
  }

  private func refreshAddresses() {
    addresses = MobileCompanionAddress.available()
    if !addresses.contains(where: { $0.host == selectedHost }) { selectedHost = addresses.first?.host ?? "" }
  }

  static func qrImage(for url: URL) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(url.absoluteString.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
          let image = CIContext().createCGImage(output.transformed(by: .init(scaleX: 8, y: 8)),
                                               from: output.extent.applying(.init(scaleX: 8, y: 8))) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}
