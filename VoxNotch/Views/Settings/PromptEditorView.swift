//
//  PromptEditorView.swift
//  VoxNotch
//
//  Markdown-aware prompt editor with Edit/Preview toggle and prompt engineering helpers
//

import SwiftUI

struct PromptEditorView: View {

  @Binding var text: String
  var isReadOnly: Bool = false

  @State private var mode: EditorMode = .edit

  private enum EditorMode: String, CaseIterable {
    case edit = "Edit"
    case preview = "Preview"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: InterfaceScale.Space.medium) {
      // Toolbar: mode picker + helpers
      HStack(spacing: InterfaceScale.Space.large) {
        Picker("", selection: $mode) {
          ForEach(EditorMode.allCases, id: \.self) { m in
            Text(m.rawValue).tag(m)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 140)

        if mode == .edit && !isReadOnly {
          promptHelpers
        }

        Spacer()

        Text("\(text.count) chars")
          .font(InterfaceScale.Typography.caption)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }

      // Editor / Preview
      Group {
        switch mode {
        case .edit:
          editView
        case .preview:
          previewView
        }
      }
      .frame(minHeight: 200, idealHeight: 280)
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
  }

  // MARK: - Edit Mode

  private var editView: some View {
    Group {
      if isReadOnly {
        ScrollView {
          Text(text)
            .font(InterfaceScale.Typography.body.monospaced())
            .lineSpacing(InterfaceScale.Space.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(InterfaceScale.Space.medium)
        }
        .background(Color.secondary.opacity(0.06))
      } else {
        TextEditor(text: $text)
          .font(InterfaceScale.Typography.body.monospaced())
            .lineSpacing(InterfaceScale.Space.small)
          .scrollContentBackground(.hidden)
          .padding(InterfaceScale.Space.small)
          .background(Color.secondary.opacity(0.06))
      }
    }
  }

  // MARK: - Preview Mode

  private var previewView: some View {
    ScrollView {
      Group {
        if let rendered = try? AttributedString(
          markdown: text,
          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
          Text(rendered)
        } else {
          Text(text)
        }
      }
      .font(InterfaceScale.Typography.body)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(InterfaceScale.Space.medium)
    }
    .background(Color.secondary.opacity(0.06))
  }

  // MARK: - Prompt Helpers

  private var promptHelpers: some View {
    HStack(spacing: InterfaceScale.Space.small) {
      Divider()
        .frame(height: 16)

      Menu {
        ForEach(PromptTemplate.helperSnippets, id: \.label) { snippet in
          Button(snippet.label) {
            insertSnippet(snippet.snippet)
          }
        }
      } label: {
        Label("Insert", systemImage: "plus.rectangle.on.rectangle")
          .font(InterfaceScale.Typography.caption)
      }
      .menuStyle(.button)
      .fixedSize()
    }
  }

  private func insertSnippet(_ snippet: String) {
    if text.isEmpty || text.hasSuffix("\n") || text.hasSuffix(" ") {
      text += snippet
    } else {
      text += " " + snippet
    }
  }
}
