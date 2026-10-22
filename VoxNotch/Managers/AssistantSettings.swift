//
//  AssistantSettings.swift
//  VoxNotch
//
//  Settings for the Always-On assistant and its OpenAI-compatible LLM provider.
//  Non-secret values persist to UserDefaults; the API key lives in the Keychain.
//

import Foundation

extension Notification.Name {
  static let alwaysOnShortcutsChanged = Notification.Name("alwaysOnShortcutsChanged")
}

@Observable
final class AssistantSettings {

  static let shared = AssistantSettings()

  private enum Keys {
    static let baseURL = "assistant.baseURL"
    static let model = "assistant.model"
    static let temperature = "assistant.temperature"
    static let maxTokens = "assistant.maxTokens"
    static let textColorHex = "assistant.textColorHex"
    static let meColorHex = "assistant.meColorHex"
    static let themColorHex = "assistant.themColorHex"
    static let backgroundOpacity = "assistant.backgroundOpacity"
    static let fontSize = "assistant.fontSize"
    static let transcriptFraction = "assistant.transcriptFraction"
    static let panelWidth = "assistant.panelWidth"
    static let panelHeight = "assistant.panelHeight"
    static let isDocked = "assistant.isDocked"
    static let floatingLeft = "assistant.floatingLeft"
    static let floatingTop = "assistant.floatingTop"
    static let legacySystemPrompt = "assistant.systemPrompt"
    static let promptTemplateID = "assistant.promptTemplateID"
    static let promptOverrides = "assistant.promptOverrides"
    static let contextWindowMinutes = "assistant.contextWindowMinutes"
    static let includePreviousAnswers = "assistant.includePreviousAnswers"
    static let useMicrophone = "assistant.useMicrophone"
    static let useSystemAudio = "assistant.useSystemAudio"
    static let suppressEcho = "assistant.suppressEcho"
    static let autoAnswer = "assistant.autoAnswer"
    static let answerQuestionsImmediately = "assistant.answerQuestionsImmediately"
    static let autoAnswerSilence = "assistant.autoAnswerSilence"
    static let toggleShortcut = "assistant.toggleShortcut"
    static let askShortcut = "assistant.askShortcut"
    static let previousAnswerShortcut = "assistant.previousAnswerShortcut"
    static let nextAnswerShortcut = "assistant.nextAnswerShortcut"
  }

  private static let apiKeyAccount = "assistant.openai.apiKey"

  enum Defaults {
    static let baseURL = "https://api.openai.com/v1"
    static let model = "gpt-4o-mini"
    static let temperature = 0.3
    static let maxTokens = 2000
    static let textColorHex = "#F5F5F7"
    static let meColorHex = "#4DD68F"
    static let themColorHex = "#66B8FF"
    static let backgroundOpacity = 0.55
    static let fontSize = 13.0
    static let transcriptFraction = 0.5
    static let panelWidth = 560.0
    static let panelHeight = 440.0
    /// 0 = the entire session.
    static let contextWindowMinutes = 0.0
    static let autoAnswerSilence = 1.5
  }

  // MARK: - Provider

  var baseURL: String {
    didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL) }
  }

  var model: String {
    didSet { UserDefaults.standard.set(model, forKey: Keys.model) }
  }

  var temperature: Double {
    didSet { UserDefaults.standard.set(temperature, forKey: Keys.temperature) }
  }

  var maxTokens: Int {
    didSet { UserDefaults.standard.set(maxTokens, forKey: Keys.maxTokens) }
  }

  var apiKey: String {
    didSet { KeychainStore.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.apiKeyAccount) }
  }

  // MARK: - Assistant

  var promptTemplateID: String {
    didSet { UserDefaults.standard.set(promptTemplateID, forKey: Keys.promptTemplateID) }
  }

  /// User edits keyed by template ID; a missing entry means the built-in text.
  private var promptOverrides: [String: String] {
    didSet { UserDefaults.standard.set(promptOverrides, forKey: Keys.promptOverrides) }
  }

  var selectedTemplate: AssistantPromptTemplate {
    AssistantPromptTemplate.template(id: promptTemplateID)
  }

  /// The active template's prompt, including any edits.
  var systemPrompt: String {
    get { promptOverrides[selectedTemplate.id] ?? selectedTemplate.prompt }
    set {
      let id = selectedTemplate.id
      promptOverrides[id] = newValue == selectedTemplate.prompt ? nil : newValue
    }
  }

  var isPromptCustomized: Bool {
    promptOverrides[selectedTemplate.id] != nil
  }

  func resetPrompt() {
    promptOverrides[selectedTemplate.id] = nil
  }

  /// Minutes of transcript sent with each request; 0 sends the entire session.
  var contextWindowMinutes: Double {
    didSet { UserDefaults.standard.set(contextWindowMinutes, forKey: Keys.contextWindowMinutes) }
  }

  /// Include earlier AI answers so follow-ups build on what was already suggested.
  var includePreviousAnswers: Bool {
    didSet { UserDefaults.standard.set(includePreviousAnswers, forKey: Keys.includePreviousAnswers) }
  }

  // MARK: - Always-On Behavior

  var useMicrophone: Bool {
    didSet { UserDefaults.standard.set(useMicrophone, forKey: Keys.useMicrophone) }
  }

  var useSystemAudio: Bool {
    didSet { UserDefaults.standard.set(useSystemAudio, forKey: Keys.useSystemAudio) }
  }

  /// Drop microphone lines that are just speaker playback of system audio.
  var suppressEcho: Bool {
    didSet { UserDefaults.standard.set(suppressEcho, forKey: Keys.suppressEcho) }
  }

  var autoAnswer: Bool {
    didSet { UserDefaults.standard.set(autoAnswer, forKey: Keys.autoAnswer) }
  }

  /// Answer as soon as the other person pauses after a question, before the line is finalized.
  var answerQuestionsImmediately: Bool {
    didSet { UserDefaults.standard.set(answerQuestionsImmediately, forKey: Keys.answerQuestionsImmediately) }
  }

  /// Seconds of silence after the other person speaks before an automatic answer.
  var autoAnswerSilence: Double {
    didSet { UserDefaults.standard.set(autoAnswerSilence, forKey: Keys.autoAnswerSilence) }
  }

  var enabledSources: Set<AudioSource> {
    var sources: Set<AudioSource> = []
    if useMicrophone { sources.insert(.microphone) }
    if useSystemAudio { sources.insert(.systemAudio) }
    return sources
  }

  // MARK: - Shortcuts

  var toggleShortcut: KeyShortcut? {
    didSet { Self.save(toggleShortcut, forKey: Keys.toggleShortcut) }
  }

  var askShortcut: KeyShortcut? {
    didSet { Self.save(askShortcut, forKey: Keys.askShortcut) }
  }

  var previousAnswerShortcut: KeyShortcut? {
    didSet { Self.save(previousAnswerShortcut, forKey: Keys.previousAnswerShortcut) }
  }

  var nextAnswerShortcut: KeyShortcut? {
    didSet { Self.save(nextAnswerShortcut, forKey: Keys.nextAnswerShortcut) }
  }

  /// Missing key → default shortcut; empty data → explicitly cleared.
  private static func loadShortcut(forKey key: String, default defaultShortcut: KeyShortcut) -> KeyShortcut? {
    guard let data = UserDefaults.standard.data(forKey: key) else { return defaultShortcut }
    return try? JSONDecoder().decode(KeyShortcut.self, from: data)
  }

  private static func save(_ shortcut: KeyShortcut?, forKey key: String) {
    let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
    UserDefaults.standard.set(data, forKey: key)
    NotificationCenter.default.post(name: .alwaysOnShortcutsChanged, object: nil)
  }

  // MARK: - Appearance

  var textColorHex: String {
    didSet { UserDefaults.standard.set(textColorHex, forKey: Keys.textColorHex) }
  }

  var meColorHex: String {
    didSet { UserDefaults.standard.set(meColorHex, forKey: Keys.meColorHex) }
  }

  var themColorHex: String {
    didSet { UserDefaults.standard.set(themColorHex, forKey: Keys.themColorHex) }
  }

  /// Opacity of the dark tint over the blurred background (0 = pure glass).
  var backgroundOpacity: Double {
    didSet { UserDefaults.standard.set(backgroundOpacity, forKey: Keys.backgroundOpacity) }
  }

  var fontSize: Double {
    didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
  }

  // MARK: - Panel Layout

  /// Share of the content height given to the transcript pane.
  var transcriptFraction: Double {
    didSet { UserDefaults.standard.set(transcriptFraction, forKey: Keys.transcriptFraction) }
  }

  var panelWidth: Double {
    didSet { UserDefaults.standard.set(panelWidth, forKey: Keys.panelWidth) }
  }

  var panelHeight: Double {
    didSet { UserDefaults.standard.set(panelHeight, forKey: Keys.panelHeight) }
  }

  var isDocked: Bool {
    didSet { UserDefaults.standard.set(isDocked, forKey: Keys.isDocked) }
  }

  /// Top-left corner of the floating panel in screen coordinates.
  var floatingTopLeft: CGPoint? {
    didSet {
      if let floatingTopLeft {
        UserDefaults.standard.set(Double(floatingTopLeft.x), forKey: Keys.floatingLeft)
        UserDefaults.standard.set(Double(floatingTopLeft.y), forKey: Keys.floatingTop)
      } else {
        UserDefaults.standard.removeObject(forKey: Keys.floatingLeft)
        UserDefaults.standard.removeObject(forKey: Keys.floatingTop)
      }
    }
  }

  var providerConfig: OpenAICompatibleConfig {
    OpenAICompatibleConfig(
      baseURL: baseURL,
      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      model: model.trimmingCharacters(in: .whitespacesAndNewlines),
      temperature: temperature,
      maxTokens: maxTokens
    )
  }

  /// API key is optional so keyless local servers (Ollama, LM Studio) work.
  var isProviderConfigured: Bool {
    let config = providerConfig
    return !config.model.isEmpty && (try? config.endpoint("/chat/completions")) != nil
  }

  // MARK: - Init

  private init() {
    let defaults = UserDefaults.standard
    baseURL = defaults.string(forKey: Keys.baseURL) ?? Defaults.baseURL
    model = defaults.string(forKey: Keys.model) ?? Defaults.model
    temperature = defaults.object(forKey: Keys.temperature) as? Double ?? Defaults.temperature
    maxTokens = defaults.object(forKey: Keys.maxTokens) as? Int ?? Defaults.maxTokens
    apiKey = KeychainStore.string(for: Self.apiKeyAccount) ?? ""

    promptTemplateID = defaults.string(forKey: Keys.promptTemplateID) ?? AssistantPromptTemplate.general.id
    var overrides = defaults.dictionary(forKey: Keys.promptOverrides) as? [String: String] ?? [:]
    if let legacy = defaults.string(forKey: Keys.legacySystemPrompt) {
      if legacy != AssistantPromptTemplate.general.prompt, overrides[AssistantPromptTemplate.general.id] == nil {
        overrides[AssistantPromptTemplate.general.id] = legacy
      }
      defaults.set(overrides, forKey: Keys.promptOverrides)
      defaults.removeObject(forKey: Keys.legacySystemPrompt)
    }
    promptOverrides = overrides
    contextWindowMinutes = defaults.object(forKey: Keys.contextWindowMinutes) as? Double ?? Defaults.contextWindowMinutes
    includePreviousAnswers = defaults.object(forKey: Keys.includePreviousAnswers) as? Bool ?? true

    useMicrophone = defaults.object(forKey: Keys.useMicrophone) as? Bool ?? true
    useSystemAudio = defaults.object(forKey: Keys.useSystemAudio) as? Bool ?? true
    suppressEcho = defaults.object(forKey: Keys.suppressEcho) as? Bool ?? true
    autoAnswer = defaults.object(forKey: Keys.autoAnswer) as? Bool ?? true
    answerQuestionsImmediately = defaults.object(forKey: Keys.answerQuestionsImmediately) as? Bool ?? true
    autoAnswerSilence = defaults.object(forKey: Keys.autoAnswerSilence) as? Double ?? Defaults.autoAnswerSilence
    toggleShortcut = Self.loadShortcut(forKey: Keys.toggleShortcut, default: .defaultToggleAlwaysOn)
    askShortcut = Self.loadShortcut(forKey: Keys.askShortcut, default: .defaultAsk)
    previousAnswerShortcut = Self.loadShortcut(forKey: Keys.previousAnswerShortcut, default: .defaultPreviousAnswer)
    nextAnswerShortcut = Self.loadShortcut(forKey: Keys.nextAnswerShortcut, default: .defaultNextAnswer)

    textColorHex = defaults.string(forKey: Keys.textColorHex) ?? Defaults.textColorHex
    meColorHex = defaults.string(forKey: Keys.meColorHex) ?? Defaults.meColorHex
    themColorHex = defaults.string(forKey: Keys.themColorHex) ?? Defaults.themColorHex
    backgroundOpacity = defaults.object(forKey: Keys.backgroundOpacity) as? Double ?? Defaults.backgroundOpacity
    fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? Defaults.fontSize
    transcriptFraction = defaults.object(forKey: Keys.transcriptFraction) as? Double ?? Defaults.transcriptFraction
    panelWidth = defaults.object(forKey: Keys.panelWidth) as? Double ?? Defaults.panelWidth
    panelHeight = defaults.object(forKey: Keys.panelHeight) as? Double ?? Defaults.panelHeight
    isDocked = defaults.object(forKey: Keys.isDocked) as? Bool ?? true
    if let left = defaults.object(forKey: Keys.floatingLeft) as? Double,
       let top = defaults.object(forKey: Keys.floatingTop) as? Double
    {
      floatingTopLeft = CGPoint(x: left, y: top)
    } else {
      floatingTopLeft = nil
    }
  }
}
