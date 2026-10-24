//
//  AnswerPaneView.swift
//  VoxNotch
//
//  AI answer pane of the Always-On panel: history rail, status header and a
//  streaming Markdown body.
//

import AppKit
import SwiftUI
import Textual

struct AnswerPaneView: View {

  let style: AlwaysOnStyle

  @Environment(AlwaysOnState.self) private var state
  private let settings = AssistantSettings.shared

  var body: some View {
    let answer = state.displayedAnswer

    VStack(alignment: .leading, spacing: 0) {
      if !state.answers.isEmpty {
        AnswerNavigationView(style: style)
      }

      AnswerHeaderView(answer: answer, style: style)
        .padding(.horizontal, 14)
        .frame(height: 30)

      if let answer {
        AnswerBodyView(answer: answer, style: style)
      } else {
        placeholder
      }
    }
  }

  private var askHint: String {
    let shortcut = settings.askShortcut.map { " (\($0.displayString))" } ?? ""
    return settings.autoAnswer
      ? "Answers appear when the other person asks a question, or press Ask\(shortcut)."
      : "Press Ask\(shortcut) for help with the conversation so far."
  }

  private var placeholder: some View {
    VStack(spacing: 10) {
      if settings.isProviderConfigured {
        Text(askHint)
      } else {
        Text("Add your API key to get answers.")
        Button("Set Up API Key") { SettingsWindowController.shared.show(panel: .aiProvider) }
          .controlSize(.small)
      }
    }
    .font(.system(size: 12))
    .foregroundStyle(style.answerText.opacity(0.5))
    .multilineTextAlignment(.center)
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Header

private struct AnswerHeaderView: View {

  let answer: AssistantAnswer?
  let style: AlwaysOnStyle

  @Environment(AlwaysOnState.self) private var state
  private let settings = AssistantSettings.shared

  var body: some View {
    HStack(spacing: 6) {
      TemplateMenu(style: style)

      Text(statusText)
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.white.opacity(0.45))
        .lineLimit(1)

      Spacer(minLength: 6)

      MobileCompanionButton()

      if let answer, !answer.markdown.isEmpty {
        CopyButton(text: answer.markdown)
      }

      // Browsing history must not hide the control for an active request.
      if state.answers.last?.isInProgress == true {
        PillButton(title: "Stop", systemImage: "stop.fill", prominent: false) {
          AssistantService.shared.stop()
        }
      } else {
        PillButton(title: "Ask", systemImage: "sparkles", prominent: true) {
          AlwaysOnController.shared.askNow()
        }
        .disabled(!state.isActive)
        .privacyAwareHelp(settings.askShortcut.map { "Ask AI (\($0.displayString))" } ?? "Ask AI")
      }
    }
  }

  private var statusText: String {
    guard let answer else { return settings.model }
    var parts = [answer.model]
    if !answer.templateName.isEmpty, answer.templateName != settings.selectedTemplate.name {
      parts.insert(answer.templateName, at: 0)
    }
    if answer.trigger == .auto { parts.append("auto") }
    switch answer.status {
    case .waiting: parts.append(answer.retryCount > 0 ? "retrying…" : "thinking…")
    case .stopped: parts.append("stopped")
    case .failed: parts.append("failed")
    case .streaming, .done: break
    }
    if let latency = answer.firstTokenLatency {
      parts.append("\(Self.milliseconds(latency)) ms")
    }
    return parts.joined(separator: " · ")
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}

// MARK: - Template Menu

/// Switch prompt templates mid-session; applies to the next answer.
private struct TemplateMenu: View {

  let style: AlwaysOnStyle
  @Bindable private var settings = AssistantSettings.shared

  var body: some View {
    PrivacyMenu {
      ForEach(AssistantPromptTemplate.all) { template in
        Button {
          settings.promptTemplateID = template.id
        } label: {
          if template.id == settings.promptTemplateID {
            Label(template.name, systemImage: "checkmark")
          } else {
            Text(template.name)
          }
        }
      }
      Divider()
      Button("Edit Prompts…") { SettingsWindowController.shared.show(panel: .alwaysOn) }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: settings.selectedTemplate.icon)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(style.them)
        Text(settings.selectedTemplate.name)
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.white.opacity(0.85))
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(.white.opacity(0.5))
      }
      .padding(.horizontal, 6)
      .frame(height: 20)
      .background(Capsule().fill(Color.white.opacity(0.08)))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .privacyAwareHelp("Prompt template")
  }
}

// MARK: - Body

private struct AnswerBodyView: View {

  let answer: AssistantAnswer
  let style: AlwaysOnStyle

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if answer.markdown.isEmpty, answer.isInProgress {
          ThinkingIndicator(color: style.answerText)
        } else {
          StreamingMarkdownView(markdown: answer.markdown, style: style, isStreaming: answer.isInProgress)
        }

        if case .failed(let message) = answer.status {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(Color.notchAmber)
            Text(message)
              .foregroundStyle(style.answerText.opacity(0.8))
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if AssistantSettings.shared.isProviderConfigured {
              Button("Retry") { AssistantService.shared.retry(answer) }
                .controlSize(.small)
            } else {
              Button("Set Up API Key") { SettingsWindowController.shared.show(panel: .aiProvider) }
                .controlSize(.small)
            }
          }
          .font(.system(size: 12))
          .padding(10)
          .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.notchAmber.opacity(0.12)))
        }
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.automatic)
    .id(answer.id)
  }
}

/// Renders Markdown block by block; finished blocks are equatable and skip
/// re-rendering, so only the growing tail is re-parsed while streaming.
private struct StreamingMarkdownView: View {

  let markdown: String
  let style: AlwaysOnStyle

  let isStreaming: Bool

  var body: some View {
    var blocks = MarkdownBlocks.split(markdown).map(MarkdownBlocks.plainMath)
    if isStreaming, let last = blocks.popLast() {
      blocks.append(MarkdownBlocks.closingOpenMarkers(last))
    }
    return VStack(alignment: .leading, spacing: style.answerFontSize * 0.7) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        MarkdownBlockView(markdown: block, fontSize: style.answerFontSize, color: style.answerText)
          .equatable()
      }
    }
  }
}

private struct MarkdownBlockView: View, Equatable {

  let markdown: String
  let fontSize: CGFloat
  let color: Color

  var body: some View {
    StructuredText(markdown: markdown)
      .textual.headingStyle(CompactHeadingStyle())
      .font(.system(size: fontSize))
      .foregroundStyle(color)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Headings sized for a compact overlay rather than a document.
private struct CompactHeadingStyle: StructuredText.HeadingStyle {
  private static let fontScales: [CGFloat] = [1.3, 1.2, 1.1, 1.05, 1, 1]

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .textual.fontScale(Self.fontScales[min(configuration.headingLevel, 6) - 1])
      .textual.blockSpacing(.fontScaled(top: 0.6, bottom: 0.3))
      .fontWeight(.semibold)
  }
}

// MARK: - Small Views

private struct ThinkingIndicator: View {

  let color: Color

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "ellipsis")
        .symbolEffect(.variableColor.iterative, isActive: true)
      Text("Thinking…")
    }
    .font(.system(size: 12))
    .foregroundStyle(color.opacity(0.5))
    .padding(.top, 2)
  }
}

private struct CopyButton: View {

  let text: String
  @State private var copied = false

  var body: some View {
    PanelIconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: "Copy answer") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(1.2))
        copied = false
      }
    }
  }
}

private struct PillButton: View {

  let title: String
  let systemImage: String
  let prominent: Bool
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.system(size: 10.5, weight: .semibold))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 9)
        .frame(height: 20)
        .background(
          Capsule().fill(prominent
            ? Color.notchBlue.opacity(isHovering ? 0.55 : 0.4)
            : Color.white.opacity(isHovering ? 0.2 : 0.12))
        )
        .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.4))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}
