//
//  CustomModelSheet.swift
//  VoxNotch
//
//  Sheet for adding a custom Hugging Face ASR model
//

import SwiftUI
import os.log

#if canImport(MLXAudioSTT)
import MLXAudioSTT
#endif

// MARK: - Custom Model Sheet

struct CustomModelSheet: View {

  @Environment(\.dismiss) private var dismiss

  @State private var repoID: String = ""
  @State private var displayName: String = ""
  @State private var errorMessage: String?
  @State private var isValidating: Bool = false
  /// Whether the display name was auto-derived (so it updates with repoID changes)
  @State private var nameIsAuto: Bool = true

  let onAdd: (CustomSpeechModel) -> Void

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Add Custom Model")
        .font(.title2)
        .fontWeight(.semibold)

      // Repo ID field
      VStack(alignment: .leading, spacing: 6) {
        Text("Hugging Face Repo ID")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("mlx-community/your-model-name", text: $repoID)
          .textFieldStyle(.roundedBorder)
          .onChange(of: repoID) { _, _ in
            errorMessage = nil
            if nameIsAuto {
              displayName = autoName(from: repoID)
            }
          }
        Text("Only MLX-format ASR models are supported (e.g. from mlx-community).")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      // Display name field
      VStack(alignment: .leading, spacing: 6) {
        Text("Display Name (optional)")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("Auto-derived from repo name", text: $displayName)
          .textFieldStyle(.roundedBorder)
          .onChange(of: displayName) { _, newValue in
            // Once the user manually edits the name, stop auto-updating it
            nameIsAuto = newValue == autoName(from: repoID) || newValue.isEmpty
          }
      }

      // Error banner
      if let error = errorMessage {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout)
          Text(error)
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }

      Spacer(minLength: 0)

      // Action buttons
      HStack {
        Button("Cancel") { dismiss() }
          .buttonStyle(.bordered)

        Spacer()

        Button {
          Task { await addModel() }
        } label: {
          if isValidating {
            HStack(spacing: 6) {
              ProgressView()
                .scaleEffect(0.7)
              Text("Validating...")
            }
          } else {
            Text("Add & Download")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(repoID.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
      }
    }
    .padding(24)
    .frame(width: 420)
  }

  // MARK: - Helpers

  private func autoName(from repoID: String) -> String {
    String(repoID.split(separator: "/").last ?? Substring(repoID))
  }

  // MARK: - Add Action

  private func addModel() async {
    let trimmedID = repoID.trimmingCharacters(in: .whitespaces)

    // Validate format
    guard trimmedID.contains("/") else {
      errorMessage = "Must be in 'org/model-name' format."
      return
    }

    // Check duplicate
    guard !CustomModelRegistry.shared.contains(repoID: trimmedID) else {
      errorMessage = "This model is already in your list."
      return
    }

    let name = displayName.trimmingCharacters(in: .whitespaces).isEmpty
      ? autoName(from: trimmedID)
      : displayName.trimmingCharacters(in: .whitespaces)

    isValidating = true
    errorMessage = nil

    do {
      #if canImport(MLXAudioSTT)
      // Reject unsupported architectures before downloading weights.
      _ = try await MLXAudioModelManager.shared.inferLoaderClass(hfRepoID: trimmedID)
      let customModel = CustomModelRegistry.shared.add(repoID: trimmedID, displayName: name)
      do {
        try await MLXAudioModelManager.shared.downloadAndLoadCustom(model: customModel)
      } catch {
        CustomModelRegistry.shared.remove(id: customModel.id)
        throw error
      }
      CustomModelRegistry.shared.markDownloaded(id: customModel.id)

      await MainActor.run {
        isValidating = false
        onAdd(customModel)
        dismiss()
      }
      #else
      // MLXAudioSTT not available -- add to registry in unverified state
      let customModel = CustomModelRegistry.shared.add(repoID: trimmedID, displayName: name)
      await MainActor.run {
        isValidating = false
        onAdd(customModel)
        dismiss()
      }
      #endif

    } catch {
      let msg = error.localizedDescription.lowercased()
      await MainActor.run {
        isValidating = false
        if msg.contains("not found") || msg.contains("404") || msg.contains("does not exist") {
          errorMessage = "Model not found. Double-check the Hugging Face repo ID."
        } else if msg.contains("network") || msg.contains("offline") || msg.contains("connection") {
          errorMessage = "Network error. Check your connection and try again."
        } else {
          errorMessage = "This model may not be compatible with VoxNotch. Only MLX-format ASR models (e.g. from mlx-community) are supported."
        }
      }
    }
  }
}

// MARK: - Preview

#Preview {
  CustomModelSheet { _ in }
}
