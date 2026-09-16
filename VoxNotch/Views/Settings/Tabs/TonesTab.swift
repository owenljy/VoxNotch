//
//  TonesTab.swift
//  VoxNotch
//
//  Tones settings: preset tones, custom tones, AI provider, quick-switch
//

import SwiftUI
import os.log

struct TonesTab: View {

  @Bindable private var settings = SettingsManager.shared
  @State private var isTestingConnection = false
  @State private var connectionTestResult: String?
  @State private var llmModelManager = LLMModelManager.shared
  @State private var customOllamaTag: String = ""
  @State private var registry = ToneRegistry.shared
  @State private var selectedCustomToneID: String? = nil
  @State private var promptText: String = ""
  @State private var nameText: String = ""
  @State private var showDeleteConfirm = false
  @State private var showNewToneSheet = false
  @State private var showAdvancedTones = false

  private var availableModels: [String] {
    switch settings.llmProvider {
    case "apple": return ["on-device"]
    default: return []
    }
  }

  private var builtInTones: [ToneTemplate] {
    registry.tones.filter { $0.isBuiltIn }
  }

  private var customTones: [ToneTemplate] {
    registry.tones.filter { !$0.isBuiltIn }
  }

  private var selectedCustomTone: ToneTemplate? {
    guard let id = selectedCustomToneID else { return nil }
    return registry.tone(forID: id)
  }

  var body: some View {
    Form {
      // MARK: — Preset Tones
      Section {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: InterfaceScale.Space.medium) {
          ForEach(builtInTones) { tone in
            TonePresetCard(
              tone: tone,
              isActive: settings.activeToneID == tone.id,
              onActivate: { settings.activeToneID = tone.id }
            )
          }
        }
      } header: {
        Text("Tones")
          .settingsSectionHeading()
      } footer: {
        Text("Tones use AI to refine your transcription \u{2014} fixing grammar, adjusting formality, or rewriting in a specific style. Choose \u{201C}None\u{201D} to get the raw transcription.")
          .settingsSectionNote()
      }

      // MARK: — Custom Tones
      DisclosureGroup(isExpanded: $showAdvancedTones) {
        // Custom tone list
        if customTones.isEmpty {
          Text("No custom tones yet. Create one to write your own prompt.")
            .font(InterfaceScale.Typography.body)
            .foregroundStyle(.secondary)
            .padding(.vertical, InterfaceScale.Space.small)
        } else {
          ForEach(customTones) { tone in
            ToneRowView(
              tone: tone,
              isActive: settings.activeToneID == tone.id,
              isSelected: selectedCustomToneID == tone.id,
              onSelect: {
                selectedCustomToneID = tone.id
                promptText = tone.prompt
                nameText = tone.displayName
              },
              onActivate: { settings.activeToneID = tone.id },
              onDelete: {
                registry.remove(id: tone.id)
                if settings.activeToneID == tone.id { settings.activeToneID = "none" }
                settings.pinnedToneIDs.removeAll { $0 == tone.id }
                if selectedCustomToneID == tone.id { selectedCustomToneID = nil }
              }
            )
          }
        }

        // New tone button
        Button {
          showNewToneSheet = true
        } label: {
          Label("Create Custom Tone", systemImage: "plus")
            .font(InterfaceScale.Typography.body)
        }
        .buttonStyle(.borderless)
        .padding(.top, InterfaceScale.Space.small)

        // Selected custom tone editor
        if let tone = selectedCustomTone {
          VStack(alignment: .leading, spacing: InterfaceScale.Space.medium) {
            Divider()

            // Name + action row
            HStack {
              TextField("Tone Name", text: $nameText)
                .textFieldStyle(.plain)
                .font(InterfaceScale.Typography.heading)
                .onChange(of: nameText) { _, newVal in
                  var updated = tone
                  updated.displayName = newVal
                  registry.update(updated)
                }

              Spacer()

              if settings.activeToneID != tone.id {
                Button("Use This Tone") {
                  settings.activeToneID = tone.id
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
              } else {
                Label("Active", systemImage: "checkmark.circle.fill")
                  .font(InterfaceScale.Typography.caption)
                  .foregroundStyle(.green)
              }
            }

            // Prompt editor
            PromptEditorView(text: $promptText)
              .onChange(of: promptText) { _, newVal in
                var updated = tone
                updated.prompt = newVal
                registry.update(updated)
              }
              .onChange(of: selectedCustomToneID) { _, _ in
                if let t = selectedCustomTone {
                  promptText = t.prompt
                  nameText = t.displayName
                }
              }

            // Action buttons
            HStack(spacing: InterfaceScale.Space.large) {
              // Duplicate
              Button {
                let copy = ToneTemplate(
                  id: UUID().uuidString,
                  displayName: "\(tone.displayName) Copy",
                  prompt: tone.prompt,
                  isBuiltIn: false,
                  originalPrompt: nil
                )
                registry.add(copy)
                selectedCustomToneID = copy.id
                promptText = copy.prompt
                nameText = copy.displayName
              } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
                  .font(InterfaceScale.Typography.caption)
              }
              .buttonStyle(.borderless)

              Spacer()

              // Delete
              Button(role: .destructive) {
                showDeleteConfirm = true
              } label: {
                Label("Delete", systemImage: "trash")
                  .font(InterfaceScale.Typography.caption)
              }
              .buttonStyle(.borderless)
              .confirmationDialog("Delete \"\(tone.displayName)\"?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                  let id = tone.id
                  registry.remove(id: id)
                  if settings.activeToneID == id { settings.activeToneID = "none" }
                  settings.pinnedToneIDs.removeAll { $0 == id }
                  selectedCustomToneID = nil
                }
              }
            }
          }
        }
      } label: {
        HStack {
          Label("Custom Tones", systemImage: "slider.horizontal.3")
            .font(InterfaceScale.Typography.body)
          InfoIcon(tooltip: "Write your own AI prompt to control exactly how transcriptions are refined. Full Markdown supported.")
          if !customTones.isEmpty {
            Text("\(customTones.count)")
              .font(InterfaceScale.Typography.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, InterfaceScale.Space.medium)
              .padding(.vertical, InterfaceScale.Space.micro)
              .background(Color.secondary.opacity(0.1))
              .clipShape(Capsule())
          }
        }
      }

      // MARK: Provider Selection -- only when a processing tone is active
      if settings.activeToneID != "none" {
        Section {
          Picker(selection: $settings.llmProvider) {
            if AnyLanguageModelProvider.isAppleIntelligenceSupported {
              if AnyLanguageModelProvider.isAppleIntelligenceAvailable {
                Text("Apple Intelligence (On-device)").tag("apple")
              } else {
                Text("Apple Intelligence (Unavailable)").tag("apple")
              }
            }
            Text("Ollama (Local)").tag("local")
          } label: {
            InfoLabel(title: "Provider", tooltip: "Which AI service processes your transcription. Apple Intelligence runs on-device. Ollama requires a local server.")
          }

          if settings.llmProvider == "apple" {
            if AnyLanguageModelProvider.isAppleIntelligenceAvailable {
              Label("On-device, private, no API costs", systemImage: "checkmark.shield")
                .foregroundStyle(.green)
                .font(InterfaceScale.Typography.caption)
            } else {
              Label(
                "Enable Apple Intelligence in System Settings \u{2192} Apple Intelligence & Siri",
                systemImage: "exclamationmark.triangle"
              )
              .foregroundStyle(.orange)
              .font(InterfaceScale.Typography.caption)
            }
          }

          if settings.llmProvider == "local" {
            TextField("Endpoint URL", text: $settings.llmEndpointURL)
              .textFieldStyle(.roundedBorder)
            Text("Default: http://localhost:11434")
              .font(InterfaceScale.Typography.caption)
              .foregroundStyle(.secondary)
          }

          if !availableModels.isEmpty && settings.llmProvider != "apple" {
            Picker("Model", selection: $settings.llmModel) {
              ForEach(availableModels, id: \.self) { model in
                Text(model).tag(model)
              }
            }
          }

          if settings.llmProvider == "local" {
            HStack {
              TextField("Model Name", text: $settings.llmModel)
                .textFieldStyle(.roundedBorder)
              InfoIcon(tooltip: "Ollama model name (e.g., llama3.2:3b)")
            }
          }

          HStack {
            Button("Test Connection") {
              testConnection()
            }
            .disabled(isTestingConnection)

            if isTestingConnection {
              ProgressView()
                .scaleEffect(0.7)
            }

            if let result = connectionTestResult {
              Text(result)
                .font(InterfaceScale.Typography.caption)
                .foregroundStyle(result.contains("Success") ? .green : .red)
            }
          }
        } header: {
          Text("Provider")
          .settingsSectionHeading()
        } footer: {
          Text("Apple Intelligence processes text on-device. Ollama requires running a local AI server.")
          .settingsSectionNote()
        }

        // MARK: Ollama Model Management
        if settings.llmProvider == "local" {
          Section {
            if !llmModelManager.isOllamaReachable && !llmModelManager.isLoadingModels {
              HStack(spacing: InterfaceScale.Space.medium) {
                Image(systemName: "exclamationmark.triangle")
                  .foregroundStyle(.orange)
                Text("Cannot connect to Ollama server")
                  .font(InterfaceScale.Typography.caption)
                  .foregroundStyle(.secondary)
              }

              if let error = llmModelManager.lastError {
                Text(error)
                  .font(InterfaceScale.Typography.caption)
                  .foregroundStyle(.red)
              }

              Button("Retry Connection") {
                Task { await llmModelManager.refreshOllamaModels() }
              }
              .font(InterfaceScale.Typography.caption)
            }

            if llmModelManager.isLoadingModels {
              HStack {
                ProgressView()
                  .scaleEffect(0.7)
                Text("Checking Ollama server...")
                  .font(InterfaceScale.Typography.caption)
                  .foregroundStyle(.secondary)
              }
            }

            if llmModelManager.isOllamaReachable {
              Label("Connected to Ollama", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(InterfaceScale.Typography.caption)
            }

            ForEach(LLMModelManager.curatedModels) { model in
              OllamaModelRow(
                model: model,
                state: llmModelManager.pullStates[model.id] ?? .idle,
                onPull: {
                  Task { await llmModelManager.pullModel(model) }
                },
                onDelete: {
                  Task { await llmModelManager.deleteModel(model) }
                },
                onSelect: {
                  settings.llmModel = model.ollamaTag
                }
              )
            }

            HStack {
              TextField("Custom model tag", text: $customOllamaTag)
                .textFieldStyle(.roundedBorder)

              Button("Pull") {
                guard !customOllamaTag.isEmpty else { return }
                let tag = customOllamaTag
                Task { await llmModelManager.pullCustomModel(tag: tag) }
              }
              .disabled(customOllamaTag.isEmpty)
            }
          } header: {
            HStack {
              Text("Ollama Models")
              Spacer()
              Button {
                Task { await llmModelManager.refreshOllamaModels() }
              } label: {
                Image(systemName: "arrow.clockwise")
                  .font(InterfaceScale.Typography.caption)
              }
              .buttonStyle(.borderless)
            }
          }
        }
      }

      // MARK: Quick-Switch -- always visible
      Section {
        QuickSwitchOrderedList(
          pinnedIDs: $settings.pinnedToneIDs,
          availableItems: registry.tones.map { ($0.id, $0.displayName) },
          maxItems: 3,
          fixedFirstItem: (id: "none", name: "Original")
        )
      } header: {
        Text("Quick-Switch (\u{2191}\u{2193})")
          .settingsSectionHeading()
      } footer: {
        Text("Pin tones to quickly switch between them using hotkey + up/down arrow keys while recording.")
          .settingsSectionNote()
      }
    }
    .settingsFormLayout()
    .sheet(isPresented: $showNewToneSheet) {
      NewToneSheet(registry: registry) { name, prompt in
        let tone = ToneTemplate(
          id: UUID().uuidString,
          displayName: name,
          prompt: prompt,
          isBuiltIn: false,
          originalPrompt: nil
        )
        registry.add(tone)
        selectedCustomToneID = tone.id
        promptText = tone.prompt
        nameText = tone.displayName
      }
    }
    .onAppear {
      if settings.llmProvider == "local" {
        Task { await llmModelManager.refreshOllamaModels() }
      }
    }
    .onChange(of: settings.llmProvider) { _, newValue in
      connectionTestResult = nil
      if newValue == "local" {
        Task { await llmModelManager.refreshOllamaModels() }
      }
    }
  }

  private func testConnection() {
    isTestingConnection = true
    connectionTestResult = nil

    Task {
      do {
        let provider = try AnyLanguageModelProvider.create(
          provider: settings.llmProvider,
          modelName: settings.llmModel,
          endpointURL: settings.llmEndpointURL
        )
        let result = try await provider.process(text: "Hello", prompt: "Reply with 'OK' only.")
        await MainActor.run {
          isTestingConnection = false
          connectionTestResult = "Success - \(result.prefix(20))"
        }
      } catch {
        await MainActor.run {
          isTestingConnection = false
          connectionTestResult = "Error - \(error.localizedDescription)"
        }
      }
    }
  }
}
