//
//  AlwaysOnRootView.swift
//  VoxNotch
//
//  Root of the Always-On panel: glass container, header, split panes and
//  the minimized bar.
//

import SwiftUI

struct AlwaysOnRootView: View {

  @Environment(AlwaysOnPanelController.self) private var panel

  private let settings = AssistantSettings.shared

  var body: some View {
    let style = AlwaysOnStyle(settings: settings)
    let shape = panelShape

    Group {
      if panel.isMinimized {
        AlwaysOnMinimizedView(style: style)
      } else {
        AlwaysOnExpandedView(style: style)
      }
    }
    .padding(.horizontal, panel.isDocked ? AlwaysOnPanelController.dockFlare : 0)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Without blur, a tight dark halo keeps the panel's text readable over any window.
    .compositingGroup()
    .shadow(color: .black.opacity(style.isSeeThrough ? 0.9 : 0), radius: 1.2)
    .background {
      if style.isSeeThrough {
        Color.black.opacity(style.tintOpacity)
      } else {
        ZStack {
          GlassBackground()
          Color.black.opacity(style.tintOpacity)
        }
      }
    }
    .clipShape(shape)
    .overlay {
      shape.stroke(
        panel.isNearDock ? Color.notchBlue.opacity(0.9) : Color.white.opacity(0.12),
        lineWidth: panel.isNearDock ? 1.5 : 1
      )
    }
    .shadow(color: .black.opacity(style.isSeeThrough ? 0.12 : 0.35), radius: 16, y: 8)
    .padding(panel.contentInsets)
    .scaleEffect(panel.isPresented ? 1 : 0.94, anchor: .top)
    .opacity(panel.isPresented ? 1 : 0)
    .environment(\.colorScheme, .dark)
  }

  private var panelShape: AnyShape {
    if panel.isDocked {
      AnyShape(NotchShape(topCornerRadius: AlwaysOnPanelController.dockFlare, bottomCornerRadius: 18))
    } else {
      AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
  }
}

// MARK: - Expanded

private struct AlwaysOnExpandedView: View {

  let style: AlwaysOnStyle

  @Environment(AlwaysOnPanelController.self) private var panel
  @State private var liveFraction: Double?
  @State private var dragStartFraction: Double?

  private let settings = AssistantSettings.shared

  var body: some View {
    VStack(spacing: 0) {
      AlwaysOnHeaderView(style: style)
      Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

      GeometryReader { geometry in
        let available = max(geometry.size.height - PaneDivider.height, 1)
        let fraction = liveFraction ?? settings.transcriptFraction

        VStack(spacing: 0) {
          TranscriptPaneView(style: style)
            .frame(height: available * fraction)

          PaneDivider { translation in
            let start = dragStartFraction ?? fraction
            dragStartFraction = start
            liveFraction = min(max(start + translation / available, 0.2), 0.8)
          } onEnded: {
            if let liveFraction { settings.transcriptFraction = liveFraction }
            liveFraction = nil
            dragStartFraction = nil
          }

          AnswerPaneView(style: style)
            .frame(maxHeight: .infinity)
        }
      }
    }
    .overlay(alignment: .bottomTrailing) {
      PanelResizeHandle()
        .padding(.trailing, panel.isDocked ? 6 : 4)
        .padding(.bottom, 4)
    }
  }
}

// MARK: - Header

private struct AlwaysOnHeaderView: View {

  let style: AlwaysOnStyle

  @Environment(AlwaysOnPanelController.self) private var panel
  @Environment(AlwaysOnState.self) private var state

  var body: some View {
    HStack(spacing: 10) {
      LiveStatusBadge()
        .layoutPriority(1)

      HStack(spacing: 6) {
        DeviceChip(source: .microphone, style: style)
        DeviceChip(source: .systemAudio, style: style)
      }

      Spacer(minLength: 6)

      HStack(spacing: 2) {
        PanelIconButton(
          systemName: state.isPaused ? "play.fill" : "pause.fill",
          help: state.isPaused ? "Resume listening" : "Pause listening"
        ) { AlwaysOnController.shared.togglePause() }
        .disabled(state.status != .running)

        PanelIconButton(systemName: "eraser", help: "Clear transcript") {
          AlwaysOnController.shared.clearTranscript()
        }

        PanelIconButton(
          systemName: style.isSeeThrough ? "eye.fill" : "eye",
          help: style.isSeeThrough ? "Switch to frosted background" : "See-through background",
          tint: style.isSeeThrough ? .notchBlue : .white
        ) {
          let settings = AssistantSettings.shared
          settings.panelBackground = settings.panelBackground == .frosted ? .seeThrough : .frosted
        }

        if !panel.isDocked {
          PanelIconButton(systemName: "pin", help: "Dock under the notch") { panel.dock() }
        }

        PanelIconButton(systemName: "gearshape", help: "Settings") {
          SettingsWindowController.shared.show(panel: .alwaysOn)
        }

        PanelIconButton(systemName: "minus", help: "Minimize") { panel.toggleMinimized() }

        PanelIconButton(systemName: "xmark", help: "Stop Always-On") {
          AlwaysOnController.shared.stop()
        }
      }
      .fixedSize()
      .layoutPriority(2)
    }
    .padding(.horizontal, 12)
    .frame(height: 36)
    .background(PanelMouseArea(role: .move))
  }
}

// MARK: - Minimized

private struct AlwaysOnMinimizedView: View {

  let style: AlwaysOnStyle

  @Environment(AlwaysOnPanelController.self) private var panel
  @Environment(AlwaysOnState.self) private var state

  var body: some View {
    HStack(spacing: 10) {
      LiveStatusBadge()

      ForEach(AudioSource.allCases.filter(state.activeSources.contains), id: \.self) { source in
        SourceLevelMeter(level: state.levels[source] ?? 0, color: style.color(for: source))
      }

      Spacer(minLength: 4)

      PanelIconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Expand") {
        panel.toggleMinimized()
      }
      PanelIconButton(systemName: "xmark", help: "Stop Always-On") {
        AlwaysOnController.shared.stop()
      }
    }
    .padding(.horizontal, 12)
    .background(PanelMouseArea(role: .move) { panel.toggleMinimized() })
  }
}

// MARK: - Live Status

private struct LiveStatusBadge: View {

  @Environment(AlwaysOnState.self) private var state

  var body: some View {
    HStack(spacing: 6) {
      indicator
      Text(title)
        .font(.system(size: 10, weight: .bold))
        .tracking(0.6)
        .foregroundStyle(.white.opacity(0.85))
      if state.status == .running, let startedAt = state.startedAt {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(Self.elapsed(from: startedAt, to: context.date))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
      }
    }
  }

  @ViewBuilder
  private var indicator: some View {
    switch state.status {
    case .preparing:
      ProgressView().controlSize(.mini)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 9))
        .foregroundStyle(Color.notchAmber)
    case .running where state.isPaused:
      Circle().fill(Color.white.opacity(0.4)).frame(width: 7, height: 7)
    case .running, .idle:
      Image(systemName: "circle.fill")
        .font(.system(size: 7))
        .foregroundStyle(Color.notchRed)
        .symbolEffect(.pulse, isActive: state.status == .running)
    }
  }

  private var title: String {
    switch state.status {
    case .preparing: "STARTING"
    case .failed: "ERROR"
    case .running: state.isPaused ? "PAUSED" : "LIVE"
    case .idle: "IDLE"
    }
  }

  private static func elapsed(from start: Date, to now: Date) -> String {
    let total = max(Int(now.timeIntervalSince(start)), 0)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
      : String(format: "%02d:%02d", minutes, seconds)
  }
}

// MARK: - Interaction Helpers

struct PaneDivider: View {

  static let height: CGFloat = 10

  let onChanged: (CGFloat) -> Void
  let onEnded: () -> Void

  @State private var isHovering = false

  var body: some View {
    ZStack {
      Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
      Capsule()
        .fill(Color.white.opacity(isHovering ? 0.5 : 0.2))
        .frame(width: 36, height: 4)
    }
    .frame(maxWidth: .infinity)
    .frame(height: Self.height)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .pointerStyle(.rowResize)
    .gesture(
      // Window coordinates: the divider itself moves while dragging.
      DragGesture(minimumDistance: 1, coordinateSpace: .global)
        .onChanged { onChanged($0.translation.height) }
        .onEnded { _ in onEnded() }
    )
  }
}

private struct PanelResizeHandle: View {

  var body: some View {
    Canvas { context, size in
      for offset in [4.0, 8.0] {
        var path = Path()
        path.move(to: CGPoint(x: size.width - offset, y: size.height - 1))
        path.addLine(to: CGPoint(x: size.width - 1, y: size.height - offset))
        context.stroke(path, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
      }
    }
    .frame(width: 14, height: 14)
    .overlay(PanelMouseArea(role: .resize))
    .help("Resize")
  }
}
