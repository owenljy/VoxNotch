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
      connectionSection
    }
    .formStyle(.grouped)
    .task { await fetchModels(silently: true) }
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
        .autocorrectionDisabled()

        Button {
          isKeyVisible.toggle()
        } label: {
          Image(systemName: isKeyVisible ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
        .help(isKeyVisible ? "Hide API key" : "Show API key")
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

        Menu {
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
        .help(availableModels.isEmpty ? "Fetch models first" : "Choose from \(availableModels.count) models")

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
    } header: {
      Text("Model")
    } footer: {
      Text("For live answers, fast non-reasoning models give the lowest latency.")
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
