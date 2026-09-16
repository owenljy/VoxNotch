//
//  SettingsComponents.swift
//  VoxNotch
//
//  Shared view components used across multiple settings tabs.
//  Extracted from SettingsView.swift for reuse.
//

import SwiftUI

// MARK: - Formatting Helpers

func formatBytes(_ bytes: Int64) -> String {
  if bytes == 0 { return "None" }
  let formatter = ByteCountFormatter()
  formatter.countStyle = .file
  return formatter.string(fromByteCount: bytes)
}

func formatSpeed(_ bytesPerSecond: Double) -> String {
  if bytesPerSecond == 0 { return "0 KB/s" }
  let formatter = ByteCountFormatter()
  formatter.countStyle = .file
  return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
}

// MARK: - Info Label

/// A label with a trailing ⓘ icon that shows a popover on click.
/// Use in place of plain string labels on settings controls
/// to make help text visually discoverable.
struct InfoLabel: View {
  let title: String
  let tooltip: String
  @State private var showPopover = false

  var body: some View {
    HStack(spacing: InterfaceScale.Space.small) {
      Text(title)
      Image(systemName: "info.circle")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .onTapGesture {
          showPopover.toggle()
        }
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
          Text(tooltip)
            .font(InterfaceScale.Typography.body)
            .foregroundStyle(.secondary)
            .padding(InterfaceScale.Space.medium)
            .frame(maxWidth: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
  }
}

/// Standalone ⓘ icon with popover tooltip — for cases where InfoLabel doesn't fit
/// (e.g., next to a Label with its own icon, or trailing a TextField).
struct InfoIcon: View {
  let tooltip: String
  @State private var showPopover = false

  var body: some View {
    Image(systemName: "info.circle")
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .onTapGesture {
        showPopover.toggle()
      }
      .popover(isPresented: $showPopover, arrowEdge: .trailing) {
        Text(tooltip)
          .font(InterfaceScale.Typography.body)
          .foregroundStyle(.secondary)
          .padding(InterfaceScale.Space.medium)
          .frame(maxWidth: 260, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
  }
}

// MARK: - Custom Model Card

struct CustomModelCard: View {
  let model: CustomSpeechModel
  let isSelected: Bool
  let downloadState: UIDownloadState
  let onSelect: () -> Void
  let onDownload: () -> Void
  let onDelete: () -> Void

  @State private var isHovered = false
  @State private var showDeleteConfirmation = false

  var body: some View {
    HStack(spacing: InterfaceScale.Space.large) {
      // Selection indicator
      Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)

      VStack(alignment: .leading, spacing: InterfaceScale.Space.micro) {
        Text(model.displayName)
          .fontWeight(isSelected ? .semibold : .medium)
        Text(model.hfRepoID)
          .font(InterfaceScale.Typography.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      actionView

      // Delete button
      Button(role: .destructive) {
        showDeleteConfirmation = true
      } label: {
        Image(systemName: "trash")
          .font(InterfaceScale.Typography.caption)
      }
      .buttonStyle(.borderless)
      .disabled({
        if case .downloading = downloadState { return true }
        return false
      }())
      .confirmationDialog("Remove \(model.displayName)?", isPresented: $showDeleteConfirmation) {
        Button("Remove", role: .destructive) { onDelete() }
      } message: {
        Text("This removes the model from your list. Downloaded files shared with another model are kept.")
      }
    }
    .padding(InterfaceScale.Space.large)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(isSelected ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
          lineWidth: isSelected ? 2 : 1
        )
    )
    .contentShape(RoundedRectangle(cornerRadius: 10))
    .onTapGesture {
      if downloadState == .ready { onSelect() }
    }
    .onHover { hovering in isHovered = hovering }
  }

  @ViewBuilder
  private var actionView: some View {
    switch downloadState {
    case .notDownloaded:
      Button("Download") { onDownload() }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

    case .downloading(let progress, let downloadedBytes, let totalBytes, let speedBytesPerSecond):
      VStack(alignment: .trailing, spacing: InterfaceScale.Space.micro) {
        HStack(spacing: InterfaceScale.Space.medium) {
          if progress > 0 {
            ProgressView(value: progress)
              .frame(width: 60)
            Text("\(Int(progress * 100))%")
              .font(InterfaceScale.Typography.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          } else {
            ProgressView().scaleEffect(0.7)
            Text("Downloading...")
              .font(InterfaceScale.Typography.caption)
              .foregroundStyle(.secondary)
          }
        }
        if totalBytes > 0 {
          Text("\(formatBytes(downloadedBytes)) / \(formatBytes(totalBytes)) \u{2022} \(formatSpeed(speedBytesPerSecond))")
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }

    case .ready:
      if isSelected {
        Label("Now Using", systemImage: "checkmark")
          .font(InterfaceScale.Typography.caption)
          .fontWeight(.medium)
          .foregroundStyle(.green)
      } else {
        HStack(spacing: InterfaceScale.Space.small) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("Ready")
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(.green)
        }
      }

    case .failed:
      HStack(spacing: InterfaceScale.Space.medium) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(InterfaceScale.Typography.caption)
        Button("Retry") { onDownload() }
          .controlSize(.small)
      }
    }
  }
}

// MARK: - Model Card

/// Full-width card for a built-in SpeechModel with rich metadata display
struct ModelCard: View {
  let model: SpeechModel
  let isSelected: Bool
  let downloadState: UIDownloadState
  let onSelect: () -> Void
  let onDownload: () -> Void

  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: InterfaceScale.Space.medium) {
      // Top row: icon + name + badge
      HStack(alignment: .center, spacing: InterfaceScale.Space.medium) {
        // Provider icon
        ZStack {
          RoundedRectangle(cornerRadius: 7)
            .fill(Color.accentColor.opacity(0.12))
            .frame(width: 34, height: 34)
          Image(systemName: model.providerIconName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }

        // Model name
        Text(model.displayName)
          .font(InterfaceScale.Typography.heading)

        // Tagline badge
        ModelBadge(text: model.tagline, model: model)

        Spacer()
      }

      // Description
      Text(model.modelDescription)
        .font(InterfaceScale.Typography.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      // Feature row
      HStack(spacing: InterfaceScale.Space.medium) {
        // Accuracy dots
        HStack(spacing: InterfaceScale.Space.small) {
          if let rating = model.accuracyRating {
            RatingDots(rating: rating, icon: "target")
          } else {
            Text("Unrated")
              .font(InterfaceScale.Typography.caption)
              .foregroundStyle(.secondary)
          }
          Text("Accuracy")
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(.secondary)
        }

        Text("\u{00B7}").foregroundStyle(.tertiary).font(InterfaceScale.Typography.caption)

        // Speed dots
        HStack(spacing: InterfaceScale.Space.small) {
          if let rating = model.speedRating {
            RatingDots(rating: rating, icon: "bolt.fill")
          } else {
            Text("Unrated")
              .font(InterfaceScale.Typography.caption)
              .foregroundStyle(.secondary)
          }
          Text("Speed")
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(.secondary)
        }

        Text("\u{00B7}").foregroundStyle(.tertiary).font(InterfaceScale.Typography.caption)

        // Size pill
        FeaturePill(icon: "internaldrive", text: formatSize(model.estimatedSizeMB))

        // Language pill
        FeaturePill(
          icon: "globe",
          text: model.languageDescription
        )

        Spacer()

        // Action area
        actionView
      }
    }
    .padding(InterfaceScale.Space.large)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(isSelected ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
          lineWidth: isSelected ? 2 : 1
        )
    )
    .contentShape(RoundedRectangle(cornerRadius: 10))
    .onTapGesture {
      if downloadState == .ready { onSelect() }
    }
    .onHover { hovering in isHovered = hovering }
  }

  @ViewBuilder
  private var actionView: some View {
    switch downloadState {
    case .notDownloaded:
      Button("Download") { onDownload() }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

    case .downloading(let progress, let downloadedBytes, let totalBytes, let speedBytesPerSecond):
      VStack(alignment: .trailing, spacing: InterfaceScale.Space.micro) {
        HStack(spacing: InterfaceScale.Space.medium) {
          if progress > 0 {
            ProgressView(value: progress)
              .frame(width: 60)
            Text("\(Int(progress * 100))%")
              .font(InterfaceScale.Typography.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          } else {
            ProgressView().scaleEffect(0.7)
            Text("Downloading\u{2026}")
              .font(InterfaceScale.Typography.caption)
              .foregroundStyle(.secondary)
          }
        }
        if totalBytes > 0 {
          Text("\(formatBytes(downloadedBytes)) / \(formatBytes(totalBytes)) \u{2022} \(formatSpeed(speedBytesPerSecond))")
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }

    case .ready:
      if isSelected {
        Label("Now Using", systemImage: "checkmark")
          .font(InterfaceScale.Typography.caption)
          .fontWeight(.medium)
          .foregroundStyle(.green)
      }

    case .failed:
      HStack(spacing: InterfaceScale.Space.medium) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(InterfaceScale.Typography.caption)
        Button("Retry") { onDownload() }
          .controlSize(.small)
      }
    }
  }

  private func formatSize(_ mb: Int) -> String {
    mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000.0) : "\(mb) MB"
  }
}

// MARK: - Rating Dots

struct RatingDots: View {
  let rating: Int
  let icon: String
  private let total = 5

  var body: some View {
    HStack(spacing: InterfaceScale.Space.micro) {
      ForEach(0..<total, id: \.self) { i in
        Circle()
          .fill(i < rating ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
          .frame(width: 6, height: 6)
      }
    }
  }
}

// MARK: - Feature Pill

struct FeaturePill: View {
  let icon: String
  let text: String

  var body: some View {
    HStack(spacing: InterfaceScale.Space.small) {
      Image(systemName: icon)
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
      Text(text)
        .font(InterfaceScale.Typography.caption)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Model Badge

struct ModelBadge: View {
  let text: String
  let model: SpeechModel

  private var badgeColor: Color {
    switch model {
    case .glmAsrNano: .orange
    case .qwen3Asr, .qwen3AsrSmall, .qwen3AsrQuantized: .purple
    default: .accentColor
    }
  }

  var body: some View {
    Text(text)
      .font(InterfaceScale.Typography.caption)
      .fontWeight(.semibold)
      .foregroundStyle(badgeColor)
      .padding(.horizontal, 7)
      .padding(.vertical, InterfaceScale.Space.small)
      .background(
        Capsule().fill(badgeColor.opacity(0.12))
      )
  }
}

// MARK: - Tone Preset Card

struct TonePresetCard: View {

  let tone: ToneTemplate
  let isActive: Bool
  let onActivate: () -> Void

  var body: some View {
    Button(action: onActivate) {
      VStack(alignment: .leading, spacing: InterfaceScale.Space.medium) {
        HStack {
          Text(tone.displayName)
            .font(InterfaceScale.Typography.heading)
            .foregroundStyle(isActive ? .white : .primary)

          Spacer()

          if isActive {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.white)
          }
        }

        if !tone.description.isEmpty {
          Text(tone.description)
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(isActive ? .white.opacity(0.85) : .secondary)
            .lineLimit(2)
        }
      }
      .padding(InterfaceScale.Space.large)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(isActive ? Color.clear : Color.secondary.opacity(0.15), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Quick-Switch Ordered List

/// Reusable ordered drag list for pinned quick-switch items (models or tones).
/// Shows up to `maxItems` pinned entries with drag-to-reorder and remove buttons,
/// plus a popover "+ Add" picker when there's room for more.
struct QuickSwitchOrderedList: View {

  @Binding var pinnedIDs: [String]
  let availableItems: [(id: String, name: String)]
  let maxItems: Int
  var fixedFirstItem: (id: String, name: String)? = nil

  @State private var showAddPopover = false

  var body: some View {
    VStack(alignment: .leading, spacing: InterfaceScale.Space.medium) {
      if fixedFirstItem != nil || !pinnedIDs.isEmpty {
        List {
          if let fixed = fixedFirstItem {
            HStack(spacing: InterfaceScale.Space.medium) {
              // Number badge
              Text("1")
                .font(InterfaceScale.Typography.caption.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.secondary.opacity(0.12))
                .clipShape(Circle())

              Text(fixed.name)
                .font(InterfaceScale.Typography.body)

              Spacer()

              Image(systemName: "lock.fill")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
            }
            .padding(.vertical, InterfaceScale.Space.micro)
            .moveDisabled(true)
          }

          ForEach(Array(zip(pinnedIDs.indices, pinnedIDs)), id: \.1) { index, id in
            HStack(spacing: InterfaceScale.Space.medium) {
              // Number badge
              Text("\(index + (fixedFirstItem != nil ? 2 : 1))")
                .font(InterfaceScale.Typography.caption.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.secondary.opacity(0.12))
                .clipShape(Circle())

              Text(name(for: id))
                .font(InterfaceScale.Typography.body)

              Spacer()

              Button {
                pinnedIDs.removeAll { $0 == id }
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
                  .imageScale(.medium)
              }
              .buttonStyle(.plain)
            }
            .padding(.vertical, InterfaceScale.Space.micro)
          }
          .onMove { from, to in pinnedIDs.move(fromOffsets: from, toOffset: to) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(pinnedIDs.count + (fixedFirstItem != nil ? 1 : 0)) * 40)
      }

      if pinnedIDs.count < maxItems {
        Button {
          showAddPopover = true
        } label: {
          Label("Add", systemImage: "plus.circle")
            .font(InterfaceScale.Typography.body)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.leading, InterfaceScale.Space.micro)
        .popover(isPresented: $showAddPopover, arrowEdge: .bottom) {
          addPicker
        }
      }
    }
  }

  private var addPicker: some View {
    let unpinned = availableItems.filter { item in
      !pinnedIDs.contains(item.id) && item.id != fixedFirstItem?.id
    }
    return VStack(alignment: .leading, spacing: 0) {
      if unpinned.isEmpty {
        Text("All items are pinned")
          .foregroundStyle(.secondary)
          .font(InterfaceScale.Typography.body)
          .padding()
      } else {
        ForEach(unpinned, id: \.id) { item in
          Button {
            if pinnedIDs.count < maxItems {
              pinnedIDs.append(item.id)
            }
            showAddPopover = false
          } label: {
            Text(item.name)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, InterfaceScale.Space.large)
              .padding(.vertical, InterfaceScale.Space.medium)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          if item.id != unpinned.last?.id {
            Divider()
          }
        }
      }
    }
    .frame(minWidth: 200)
    .padding(.vertical, InterfaceScale.Space.small)
  }

  private func name(for id: String) -> String {
    availableItems.first(where: { $0.id == id })?.name ?? id
  }
}

// MARK: - Tone Row View

struct ToneRowView: View {

  let tone: ToneTemplate
  let isActive: Bool
  let isSelected: Bool
  let onSelect: () -> Void
  let onActivate: () -> Void
  let onDelete: () -> Void

  @State private var showDeleteConfirm = false

  var body: some View {
    HStack(spacing: InterfaceScale.Space.medium) {
      // Active indicator
      Button(action: onActivate) {
        Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(isActive ? Color.accentColor : .secondary)
      }
      .buttonStyle(.plain)
      .help(isActive ? "Active tone" : "Set as active tone")

      // Name
      Text(tone.displayName)
        .font(InterfaceScale.Typography.body)
        .fontWeight(isSelected ? .semibold : .regular)

      Spacer()

      // Badge
      if tone.isBuiltIn && tone.id != "none" {
        Text("built-in")
          .font(InterfaceScale.Typography.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, InterfaceScale.Space.medium)
          .padding(.vertical, InterfaceScale.Space.micro)
          .background(Color.secondary.opacity(0.1))
          .clipShape(Capsule())
      }

      // Delete (custom only)
      if !tone.isBuiltIn {
        Button(role: .destructive) {
          showDeleteConfirm = true
        } label: {
          Image(systemName: "trash")
            .font(.system(size: 11))
            .foregroundStyle(.red.opacity(0.7))
        }
        .buttonStyle(.plain)
        .confirmationDialog("Delete \"\(tone.displayName)\"?", isPresented: $showDeleteConfirm) {
          Button("Delete", role: .destructive) { onDelete() }
        }
      }
    }
    .padding(.vertical, InterfaceScale.Space.micro)
    .contentShape(Rectangle())
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Color.accentColor.opacity(0.1) : .clear)
        .padding(.horizontal, -4)
    )
    .onTapGesture { onSelect() }
  }
}

// MARK: - New Tone Sheet

struct NewToneSheet: View {

  let registry: ToneRegistry
  let onCreate: (String, String) -> Void

  @State private var name = ""
  @State private var prompt = ""
  @State private var templateBase = "blank"
  @Environment(\.dismiss) private var dismiss

  private var templateOptions: [(id: String, name: String)] {
    var options: [(id: String, name: String)] = [("blank", "Blank")]
    for tone in registry.tones where tone.isBuiltIn && tone.id != "none" {
      options.append((tone.id, "Based on \(tone.displayName)"))
    }
    return options
  }

  var body: some View {
    VStack(alignment: .leading, spacing: InterfaceScale.Space.large) {
      Text("New Tone")
        .font(InterfaceScale.Typography.title)
        .fontWeight(.semibold)

      HStack(spacing: InterfaceScale.Space.large) {
        TextField("Name", text: $name)
          .textFieldStyle(.roundedBorder)

        Picker("Start from", selection: $templateBase) {
          ForEach(templateOptions, id: \.id) { option in
            Text(option.name).tag(option.id)
          }
        }
        .frame(width: 200)
        .onChange(of: templateBase) { _, newVal in
          if newVal == "blank" {
            prompt = ""
          } else if let tone = registry.tone(forID: newVal) {
            prompt = tone.prompt
          }
        }
      }

      PromptEditorView(text: $prompt)

      HStack {
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.escape)

        Spacer()

        Button("Create") {
          guard !name.isEmpty else { return }
          onCreate(name, prompt)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.isEmpty)
        .keyboardShortcut(.return)
      }
    }
    .padding(InterfaceScale.Space.section)
    .frame(width: 520, height: 520)
  }
}

// MARK: - Model Download Row

struct ModelDownloadRow: View {
  let title: String
  let description: String
  let state: ModelDownloadState
  let onDownload: () -> Void
  let onDelete: () -> Void
  let onRetry: () -> Void

  @State private var showDeleteConfirmation = false

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: InterfaceScale.Space.micro) {
        Text(title)
          .font(InterfaceScale.Typography.body)
        Text(description)
          .font(InterfaceScale.Typography.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      statusView
    }
    .padding(.vertical, InterfaceScale.Space.small)
  }

  @ViewBuilder
  private var statusView: some View {
    switch state {
    case .ready, .downloaded:
      HStack(spacing: InterfaceScale.Space.medium) {
        HStack(spacing: InterfaceScale.Space.small) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("Ready")
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(.green)
        }

        Button(role: .destructive) {
          showDeleteConfirmation = true
        } label: {
          Image(systemName: "trash")
            .font(InterfaceScale.Typography.caption)
        }
        .buttonStyle(.borderless)
        .confirmationDialog("Delete \(title)?", isPresented: $showDeleteConfirmation) {
          Button("Delete", role: .destructive) {
            onDelete()
          }
        } message: {
          Text("You can re-download this model at any time.")
        }
      }

    case .downloading(let progress, let downloadedBytes, let totalBytes, let speedBytesPerSecond):
      VStack(alignment: .trailing, spacing: InterfaceScale.Space.micro) {
        if progress > 0 {
          HStack(spacing: InterfaceScale.Space.medium) {
            ProgressView(value: progress)
              .frame(width: 60)
            Text("\(Int(progress * 100))%")
              .font(InterfaceScale.Typography.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        } else {
          HStack(spacing: InterfaceScale.Space.small) {
            ProgressView().scaleEffect(0.7)
            Text("Downloading...")
              .font(InterfaceScale.Typography.caption)
              .foregroundStyle(.secondary)
          }
        }
        if totalBytes > 0 {
          Text("\(formatBytes(downloadedBytes)) / \(formatBytes(totalBytes)) \u{2022} \(formatSpeed(speedBytesPerSecond))")
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }

    case .loading:
      HStack(spacing: InterfaceScale.Space.small) {
        ProgressView()
          .scaleEffect(0.7)
        Text("Loading...")
          .font(InterfaceScale.Typography.caption)
          .foregroundStyle(.secondary)
      }

    case .notDownloaded:
      Button("Download") {
        onDownload()
      }
      .font(InterfaceScale.Typography.caption)
      .buttonStyle(.borderedProminent)
      .controlSize(.small)

    case .failed(let message):
      HStack(spacing: InterfaceScale.Space.medium) {
        HStack(spacing: InterfaceScale.Space.small) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Text("Failed")
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(.red)
        }
        .help(message)

        Button("Retry") {
          onRetry()
        }
        .font(InterfaceScale.Typography.caption)
        .controlSize(.small)
      }
    }
  }
}

// MARK: - Ollama Model Row

struct OllamaModelRow: View {
  let model: CuratedOllamaModel
  let state: OllamaPullState
  let onPull: () -> Void
  let onDelete: () -> Void
  let onSelect: () -> Void

  @State private var showDeleteConfirmation = false

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: InterfaceScale.Space.micro) {
        Text(model.displayName)
          .font(InterfaceScale.Typography.body)
        HStack(spacing: InterfaceScale.Space.small) {
          Text(model.estimatedSizeDescription)
          Text("\u{00B7}")
          Text(model.description)
        }
        .font(InterfaceScale.Typography.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      statusView
    }
    .padding(.vertical, InterfaceScale.Space.micro)
  }

  @ViewBuilder
  private var statusView: some View {
    switch state {
    case .completed:
      HStack(spacing: InterfaceScale.Space.medium) {
        Button("Use") {
          onSelect()
        }
        .font(InterfaceScale.Typography.caption)
        .controlSize(.small)

        HStack(spacing: InterfaceScale.Space.small) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("Ready")
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(.green)
        }

        Button(role: .destructive) {
          showDeleteConfirmation = true
        } label: {
          Image(systemName: "trash")
            .font(InterfaceScale.Typography.caption)
        }
        .buttonStyle(.borderless)
        .confirmationDialog("Delete \(model.displayName)?", isPresented: $showDeleteConfirmation) {
          Button("Delete", role: .destructive) {
            onDelete()
          }
        }
      }

    case .pulling(let progress):
      HStack(spacing: InterfaceScale.Space.medium) {
        ProgressView(value: progress)
          .frame(width: 60)
        Text("\(Int(progress * 100))%")
          .font(InterfaceScale.Typography.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

    case .idle:
      Button("Pull") {
        onPull()
      }
      .font(InterfaceScale.Typography.caption)
      .buttonStyle(.borderedProminent)
      .controlSize(.small)

    case .failed(let message):
      HStack(spacing: InterfaceScale.Space.medium) {
        HStack(spacing: InterfaceScale.Space.small) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Text("Failed")
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(.red)
        }
        .help(message)

        Button("Retry") {
          onPull()
        }
        .font(InterfaceScale.Typography.caption)
        .controlSize(.small)
      }
    }
  }
}
