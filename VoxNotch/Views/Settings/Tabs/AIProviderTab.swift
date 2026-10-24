//
//  AIProviderTab.swift
//  VoxNotch
//
//  OpenAI-compatible provider settings for the Always-On assistant.
//

import SwiftUI

struct AIProviderTab: View {

  @Bindable private var settings = AssistantSettings.shared

  @State private var isKeyVisible = false
  @State private var availableModels: [String] = []
  @State private var isFetchingModels = false
  @State private var modelsError: String?
  @State private var testState: TestState = .idle
  @FocusState private var isAPIKeyFocused: Bool

  private enum TestState {
    case idle
    case running
    case success(ConnectionTestResult)
    case failure(String)
  }

  var body: some View {
    Form {
      endpointSection
      modelSection
      responseSection
      connectionSection
    }
    .formStyle(.grouped)
    .task { await fetchModels(silently: true) }
    .onAppear {
      // Arriving here from a "set up AI" prompt: put the cursor in the key field.
      if settings.apiKey.isEmpty { isAPIKeyFocused = true }
    }
    .onChange(of: settings.baseURL) { availableModels = []; testState = .idle }
    .onChange(of: settings.apiKey) { testState = .idle }
    .onChange(of: settings.model) { testState = .idle }
  }

  // MARK: - Sections

  private var endpointSection: some View {
    Section {
      TextField("Base URL", text: $settings.baseURL, prompt: Text(AssistantSettings.Defaults.baseURL))
        .textContentType(.URL)
        .autocorrectionDisabled()

      HStack {
        Group {
          if isKeyVisible {
            TextField("API Key", text: $settings.apiKey, prompt: Text("sk-…"))
          } else {
            SecureField("API Key", text: $settings.apiKey, prompt: Text("sk-…"))
          }
        }
        .focused($isAPIKeyFocused)
        .autocorrectionDisabled()

        Button {
          isKeyVisible.toggle()
        } label: {
          Image(systemName: isKeyVisible ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
        .privacyAwareHelp(isKeyVisible ? "Hide API key" : "Show API key")
      }
    } header: {
      Text("OpenAI-Compatible Endpoint")
    } footer: {
      Text("Works with OpenAI, OpenRouter, Groq, DeepSeek, LM Studio and Ollama (http://localhost:11434/v1). Leave the key empty for local servers. The key is stored in your macOS Keychain.")
    }
  }

  private var modelSection: some View {
    Section {
      HStack {
        TextField("Model", text: $settings.model, prompt: Text(AssistantSettings.Defaults.model))
          .autocorrectionDisabled()

        PrivacyMenu {
          ForEach(availableModels, id: \.self) { model in
            Button(model) { settings.model = model }
          }
        } label: {
          Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(availableModels.isEmpty)
        .privacyAwareHelp(availableModels.isEmpty ? "Fetch models first" : "Choose from \(availableModels.count) models")

        Button {
          Task { await fetchModels(silently: false) }
        } label: {
          if isFetchingModels {
            ProgressView().controlSize(.small)
          } else {
            Label("Fetch", systemImage: "arrow.clockwise")
          }
        }
        .disabled(isFetchingModels)
      }

      if let modelsError {
        Text(modelsError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      LabeledContent {
        HStack {
          Slider(value: $settings.temperature, in: 0...1.5, step: 0.1)
          Text(settings.temperature, format: .number.precision(.fractionLength(1)))
            .monospacedDigit()
            .frame(width: 30, alignment: .trailing)
        }
      } label: {
        InfoLabel(title: "Temperature", tooltip: "Lower values give more focused, consistent answers.")
      }

      Stepper(value: $settings.maxTokens, in: 64...8192, step: 64) {
        LabeledContent {
          Text("\(settings.maxTokens)").monospacedDigit()
        } label: {
          InfoLabel(title: "Max answer tokens", tooltip: "Upper bound on answer length. Shorter answers finish faster.")
        }
      }

      Picker(selection: $settings.reasoningEffort) {
        ForEach(AssistantSettings.ReasoningEffort.allCases, id: \.self) { effort in
          Text(effort.label).tag(effort)
        }
      } label: {
        InfoLabel(
          title: "Reasoning effort",
          tooltip: "How much a reasoning model thinks before answering (sent as reasoning_effort). More thinking means a slower first token. Automatic sends Low for gpt-oss models and nothing for others. If a provider rejects it, VoxNotch retries without it."
        )
      }
      if let sent = settings.reasoningEffort.value(forModel: settings.model.trimmingCharacters(in: .whitespaces)) {
        Text("Sends reasoning_effort: \(sent)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Model")
    } footer: {
      Text("For live answers, fast models give the lowest latency. With reasoning models such as openai/gpt-oss-120b, keep reasoning effort Low.")
    }
  }

  private var connectionSection: some View {
    Section {
      HStack(spacing: 12) {
        Button("Test Connection") {
          Task { await runTest() }
        }
        .disabled(!settings.isProviderConfigured || isTestRunning)

        testStatusView
        Spacer()
      }
    } header: {
      Text("Connection")
    } footer: {
      Text("Sends a tiny prompt and measures time to first token.")
    }
  }

  private var responseSection: some View {
    Section("Response timing") {
      Stepper(value: $settings.firstTokenTimeout, in: 0.5...30, step: 0.5) {
        LabeledContent("First token timeout") {
          Text(settings.firstTokenTimeout, format: .number.precision(.fractionLength(1))) + Text(" s")
        }
      }
      HStack {
        TextField("Fallback model", text: $settings.fallbackModel, prompt: Text("Same model if empty"))
          .autocorrectionDisabled()
        PrivacyMenu {
          Button("Retry the same model") { settings.fallbackModel = "" }
          ForEach(availableModels, id: \.self) { model in
            Button(model) { settings.fallbackModel = model }
          }
        } label: {
          Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Choose fallback model")
      }
      Text("If no answer text appears before the deadline, cancel that request and retry once. The fallback uses the same provider and API key. Once text starts, the answer is never restarted automatically.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var testStatusView: some View {
    switch testState {
    case .idle:
      EmptyView()
    case .running:
      ProgressView().controlSize(.small)
    case .success(let result):
      Label {
        Text("Connected · first token \(milliseconds(result.firstTokenLatency)) ms")
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
      .font(.callout)
    case .failure(let message):
      Label {
        Text(message).lineLimit(2).textSelection(.enabled)
      } icon: {
        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
      }
      .font(.callout)
    }
  }

  // MARK: - Actions

  private var isTestRunning: Bool {
    if case .running = testState { return true }
    return false
  }

  private func fetchModels(silently: Bool) async {
    guard settings.isProviderConfigured || !silently else { return }
    isFetchingModels = true
    modelsError = nil
    defer { isFetchingModels = false }
    do {
      availableModels = try await OpenAICompatibleClient.shared.listModels(config: settings.providerConfig)
      if availableModels.isEmpty, !silently { modelsError = "The server returned no models." }
    } catch {
      availableModels = []
      if !silently { modelsError = describe(error) }
    }
  }

  private func runTest() async {
    testState = .running
    do {
      let result = try await OpenAICompatibleClient.shared.testConnection(config: settings.providerConfig)
      testState = .success(result)
    } catch {
      testState = .failure(describe(error))
    }
  }

  private func describe(_ error: Error) -> String {
    (error as? LLMError)?.detailedDescription ?? error.localizedDescription
  }

  private func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
  }
}
