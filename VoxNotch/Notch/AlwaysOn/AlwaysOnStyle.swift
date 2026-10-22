//
//  AlwaysOnStyle.swift
//  VoxNotch
//
//  Visual tokens and small shared views for the Always-On panel.
//

import AppKit
import SwiftUI

// MARK: - Hex Colors

extension Color {
  /// Parses `#RRGGBB` or `#RRGGBBAA`; returns nil for anything else.
  init?(hex: String) {
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
    let hasAlpha = value.count == 8
    let r = Double((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    let g = Double((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    let b = Double((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    let a = hasAlpha ? Double(number & 0xFF) / 255 : 1
    self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
  }

  /// `#RRGGBB` in sRGB (alpha dropped).
  var hexString: String {
    let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
    let r = Int((color.redComponent * 255).rounded())
    let g = Int((color.greenComponent * 255).rounded())
    let b = Int((color.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
  }
}

// MARK: - Style

/// Resolved appearance for the panel, read from AssistantSettings.
struct AlwaysOnStyle {
  let text: Color
  let me: Color
  let them: Color
  let tintOpacity: Double
  let fontSize: CGFloat

  @MainActor init(settings: AssistantSettings) {
    text = Color(hex: settings.textColorHex) ?? .white
    me = Color(hex: settings.meColorHex) ?? .notchGreen
    them = Color(hex: settings.themColorHex) ?? .notchBlue
    tintOpacity = settings.backgroundOpacity
    fontSize = CGFloat(settings.fontSize)
  }

  func color(for source: AudioSource) -> Color {
    source == .microphone ? me : them
  }

  static func label(for source: AudioSource) -> String {
    source == .microphone ? "ME" : "THEM"
  }
}

// MARK: - Glass Background

/// Behind-window blur with a dark tint, always rendered in dark appearance.
struct GlassBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    view.appearance = NSAppearance(named: .darkAqua)
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Header Button

struct PanelIconButton: View {
  let systemName: String
  let help: String
  var tint: Color = .white
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint.opacity(isHovering ? 1 : 0.7))
        .frame(width: 24, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(isHovering ? 0.14 : 0))
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .onHover { isHovering = $0 }
  }
}

// MARK: - Level Meter

struct SourceLevelMeter: View {
  let level: Float
  let color: Color

  private static let barCount = 4

  /// RMS → 0...1 on a -55...-10 dBFS scale.
  private var normalized: Double {
    guard level > 0 else { return 0 }
    let db = 20 * log10(Double(level))
    return min(max((db + 55) / 45, 0), 1)
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 1.5) {
      ForEach(0..<Self.barCount, id: \.self) { index in
        let threshold = Double(index) / Double(Self.barCount)
        Capsule()
          .fill(normalized > threshold ? color : Color.white.opacity(0.18))
          .frame(width: 2.5, height: 4 + CGFloat(index) * 2.5)
      }
    }
    .animation(.easeOut(duration: 0.12), value: normalized)
  }
}
