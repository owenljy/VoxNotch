//
//  TranscriptPaneView.swift
//  VoxNotch
//
//  Live, source-tagged transcript with stick-to-bottom auto-scroll.
//

import SwiftUI

struct TranscriptPaneView: View {

  let style: AlwaysOnStyle

  @Environment(AlwaysOnState.self) private var state
  @State private var position = ScrollPosition(edge: .bottom)
  @State private var isPinnedToBottom = true

  var body: some View {
    let rows = state.displayRows

    ZStack(alignment: .bottom) {
      if rows.isEmpty {
        placeholder
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { segment in
              TranscriptRowView(segment: segment, style: style)
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
        }
        .scrollIndicators(.automatic)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
          geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
        } action: { _, pinned in
          isPinnedToBottom = pinned
        }
        .onChange(of: state.revision) {
          if isPinnedToBottom { position.scrollTo(edge: .bottom) }
        }

        if !isPinnedToBottom {
          Button {
            withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
          } label: {
            Label("Latest", systemImage: "arrow.down")
              .font(.system(size: 10, weight: .semibold))
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .background(Capsule().fill(Color.white.opacity(0.16)))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.white)
          .padding(.bottom, 8)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
    }
    .animation(.easeOut(duration: 0.15), value: isPinnedToBottom)
  }

  @ViewBuilder
  private var placeholder: some View {
    VStack(spacing: 8) {
      switch state.status {
      case .preparing:
        ProgressView().controlSize(.small)
        Text(state.preparingMessage)
      case .failed(let message):
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 18))
          .foregroundStyle(Color.notchAmber)
        Text(message)
          .multilineTextAlignment(.center)
        Button("Try Again") { AlwaysOnController.shared.restart() }
          .controlSize(.small)
      case .running where state.isPaused:
        Image(systemName: "pause.circle")
          .font(.system(size: 18))
        Text("Paused — microphone and system audio are off")
      case .running, .idle:
        Image(systemName: "waveform")
          .font(.system(size: 18))
          .symbolEffect(.variableColor.iterative, isActive: state.status == .running)
        Text("Listening… speak or play audio")
      }
    }
    .font(.system(size: 12))
    .foregroundStyle(style.text.opacity(0.55))
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct TranscriptRowView: View {

  let segment: LiveTranscriptSegment
  let style: AlwaysOnStyle

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(AlwaysOnStyle.label(for: segment.source))
        .font(.system(size: max(style.fontSize - 3.5, 9), weight: .bold))
        .tracking(0.6)
        .foregroundStyle(style.color(for: segment.source))
        .lineLimit(1)
        .fixedSize()
        .frame(width: max(38, style.fontSize * 3.2), alignment: .leading)

      Text(segment.text)
        .font(.system(size: style.fontSize))
        .italic(!segment.isFinal)
        .foregroundStyle(style.text.opacity(segment.isFinal ? 0.95 : 0.55))
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
