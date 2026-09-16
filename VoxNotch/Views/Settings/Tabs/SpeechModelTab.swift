//
//  SpeechModelTab.swift
//  VoxNotch
//
//  Speech model selection: built-in models, custom models, quick-switch
//

import SwiftUI
import os.log

private let settingsLogger = Logger(subsystem: "com.voxnotch", category: "SpeechModelTab")

struct SpeechModelTab: View {

  @Bindable private var settings = SettingsManager.shared
  @State private var fluidModelManager = FluidAudioModelManager.shared
  @State private var mlxModelManager = MLXAudioModelManager.shared
  @State private var customRegistry = CustomModelRegistry.shared
  @State private var modelError: String?

  private var selectedBuiltinModel: SpeechModel? {
    SpeechModel(rawValue: settings.speechModel)
  }

  private var selectedCustomModel: CustomSpeechModel? {
    CustomModelRegistry.shared.model(withID: settings.speechModel)
  }

  var body: some View {
    Form {
      // Built-in Models
      Section {
        // Privacy badge
        Label("On-device transcription after model download", systemImage: "checkmark.shield")
          .foregroundStyle(.green)
          .font(InterfaceScale.Typography.body)

        ForEach(SpeechModel.allCases) { model in
          ModelCard(
            model: model,
            isSelected: selectedBuiltinModel == model,
            downloadState: downloadState(for: model),
            onSelect: { selectModel(model) },
            onDownload: { downloadModel(model) }
          )
        }
      } header: {
        Text("Built-in Models")
          .settingsSectionHeading()
      } footer: {
        Text("Speech-to-text models that run locally on your Mac. Model accuracy varies by language and audio; larger models use more memory.")
          .settingsSectionNote()
      }

      // Keep existing imports manageable, but do not offer unsupported arbitrary imports.
      if !customRegistry.models.isEmpty {
        Section {
          ForEach(customRegistry.models) { model in
            CustomModelCard(
              model: model,
              isSelected: selectedCustomModel?.id == model.id,
              downloadState: customDownloadState(for: model),
              onSelect: { settings.speechModel = model.id },
              onDownload: { downloadCustomModel(model) },
              onDelete: { deleteCustomModel(model) }
            )
          }
        } header: {
          Text("Previously Added Models")
          .settingsSectionHeading()
        } footer: {
          Text("Existing imports can still be used or removed. New Hugging Face imports are unavailable; choose a built-in model above.")
          .settingsSectionNote()
        }
      }

      // Quick-Switch
      Section {
        QuickSwitchOrderedList(
          pinnedIDs: $settings.pinnedModelIDs,
          availableItems: allModelOptions,
          maxItems: 3
        )
      } header: {
        Text("Quick-Switch (\u{2190} \u{2192})")
          .settingsSectionHeading()
      } footer: {
        Text("Pin up to 3 models to quickly switch between them using hotkey + arrow keys.")
          .settingsSectionNote()
      }
    }
    .settingsFormLayout()
    .onAppear {
      fluidModelManager.refreshAllModelStates()
      mlxModelManager.refreshAllModelStates()
      refreshModelsNeeded()
    }
    .onChange(of: settings.speechModel) { _, _ in
      TranscriptionService.shared.reconfigure()
      refreshModelsNeeded()
    }
    .alert("Model operation failed", isPresented: Binding(
      get: { modelError != nil },
      set: { if !$0 { modelError = nil } }
    )) {
      Button("OK") { modelError = nil }
    } message: {
      Text(modelError ?? "")
    }
  }

  // MARK: - Quick-Switch Helpers

  private var allModelOptions: [(id: String, name: String)] {
    var options: [(id: String, name: String)] = SpeechModel.allCases.map { ($0.rawValue, $0.displayName) }
    options += customRegistry.models.map { ($0.id, $0.displayName) }
    return options
  }

  // MARK: - Built-in Model Helpers

  private func downloadState(for model: SpeechModel) -> UIDownloadState {
    switch model.engine {
    case .fluidAudio:
      guard let version = model.fluidAudioVersion else { return .notDownloaded }
      let state = fluidModelManager.modelStates[version] ?? .notDownloaded
      return state.uiState
    case .mlxAudio:
      guard let version = model.mlxAudioVersion else { return .notDownloaded }
      let state = mlxModelManager.modelStates[version] ?? .notDownloaded
      return state.uiState
    }
  }

  private func selectModel(_ model: SpeechModel) {
    settings.speechModel = model.rawValue
  }

  private func downloadModel(_ model: SpeechModel) {
    Task {
      do {
        switch model.engine {
        case .fluidAudio:
          guard let version = model.fluidAudioVersion else { return }
          try await fluidModelManager.downloadBatchModel(version: version)
          await MainActor.run {
            fluidModelManager.refreshAllModelStates()
            refreshModelsNeeded()
          }
        case .mlxAudio:
          guard let version = model.mlxAudioVersion else { return }
          try await mlxModelManager.downloadAndLoad(version: version)
          await MainActor.run {
            mlxModelManager.refreshAllModelStates()
            refreshModelsNeeded()
          }
        }
      } catch {
        settingsLogger.error("Model download failed: \(error.localizedDescription)")
        modelError = error.localizedDescription
      }
    }
  }

  // MARK: - Custom Model Helpers

  private func customDownloadState(for model: CustomSpeechModel) -> UIDownloadState {
    if let state = mlxModelManager.customModelStates[model.id] {
      return state.uiState
    }
    return mlxModelManager.isCustomModelOnDisk(model) ? .ready : .notDownloaded
  }

  private func downloadCustomModel(_ model: CustomSpeechModel) {
    Task {
      do {
        try await mlxModelManager.downloadAndLoadCustom(model: model)
      } catch {
        settingsLogger.error("Custom model download failed (\(model.hfRepoID)): \(error.localizedDescription)")
        modelError = error.localizedDescription
      }
      await MainActor.run { refreshModelsNeeded() }
    }
  }

  private func deleteCustomModel(_ model: CustomSpeechModel) {
    do {
      try mlxModelManager.deleteCustomModel(model)
    } catch {
      modelError = error.localizedDescription
      return
    }
    // If this was the selected model, fall back to default
    if settings.speechModel == model.id {
      settings.speechModel = SpeechModel.defaultModel.rawValue
    }
    // Remove from pinned slots
    settings.pinnedModelIDs = settings.pinnedModelIDs.filter { $0 != model.id }
    refreshModelsNeeded()
  }

  private func refreshModelsNeeded() {
    let appState = AppState.shared
    let isReady: Bool
    let displayName: String

    if let builtin = selectedBuiltinModel {
      let state = downloadState(for: builtin)
      isReady = state == .ready
      displayName = builtin.displayName
    } else if let custom = selectedCustomModel {
      isReady = customDownloadState(for: custom) == .ready
      displayName = custom.displayName
    } else {
      isReady = false
      displayName = "Unknown"
    }

    appState.modelDownload.isModelReady = isReady
    appState.modelDownload.modelsNeeded = !isReady
    appState.modelDownload.modelsNeededMessage = isReady ? "" : "Not downloaded: \(displayName)"
  }
}
