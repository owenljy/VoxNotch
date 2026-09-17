//
//  SpeechModel.swift
//  VoxNotch
//
//  Unified speech model abstraction that hides engine implementation details
//

import Foundation

// MARK: - Language Support

/// Language support capability
enum LanguageSupport: String, Sendable {
  case englishOptimized
  case multilingual
}

// MARK: - Speech Model

/// Unified speech model that abstracts away the underlying engine
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
  // FluidAudio models
  case parakeetV2 = "fluidaudio-v2"
  case parakeetUnified = "fluidaudio-unified-en-0.6b"
  case parakeetEOU = "fluidaudio-eou-120m"

  // MLX Audio models
  case glmAsrNano = "mlx-glm-asr-nano"
  case qwen3Asr = "mlx-qwen3-asr"
  case qwen3AsrSmall = "mlx-qwen3-asr-0.6b-4bit"
  case qwen3AsrQuantized = "mlx-qwen3-asr-1.7b-4bit"
  case voxtralMini = "mlx-voxtral-mini"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .parakeetV2: "Parakeet v2"
    case .parakeetUnified: "Parakeet Unified English 0.6B"
    case .parakeetEOU: "Parakeet EOU 120M"
    case .glmAsrNano: "GLM-ASR Nano"
    case .qwen3Asr: "Qwen3-ASR 1.7B (BF16)"
    case .qwen3AsrSmall: "Qwen3-ASR 0.6B (4-bit)"
    case .qwen3AsrQuantized: "Qwen3-ASR 1.7B (4-bit)"
    case .voxtralMini: "Voxtral Mini 4B"
    }
  }

  var engine: ASREngine {
    switch self {
    case .parakeetV2, .parakeetUnified, .parakeetEOU: .fluidAudio
    case .glmAsrNano, .qwen3Asr, .qwen3AsrSmall, .qwen3AsrQuantized, .voxtralMini: .mlxAudio
    }
  }

  var estimatedSizeMB: Int {
    switch self {
    case .parakeetV2: 500
    case .parakeetUnified: 615
    case .parakeetEOU: 225
    case .glmAsrNano: 400
    case .qwen3Asr: 3400
    case .qwen3AsrSmall: 713
    case .qwen3AsrQuantized: 1608
    case .voxtralMini: 3130
    }
  }

  var languageSupport: LanguageSupport {
    switch self {
    case .parakeetV2, .parakeetUnified, .parakeetEOU: .englishOptimized
    case .glmAsrNano, .qwen3Asr, .qwen3AsrSmall, .qwen3AsrQuantized, .voxtralMini: .multilingual
    }
  }

  var languageDescription: String {
    switch self {
    case .parakeetV2, .parakeetUnified, .parakeetEOU: "English optimized"
    case .glmAsrNano, .qwen3Asr, .qwen3AsrSmall, .qwen3AsrQuantized: "Multilingual"
    case .voxtralMini: "13 languages"
    }
  }

  var supportedLanguages: [String] {
    switch self {
    case .parakeetV2, .parakeetUnified, .parakeetEOU:
      ["en"]
    case .glmAsrNano, .qwen3Asr, .qwen3AsrSmall, .qwen3AsrQuantized:
      ["en", "zh", "ja", "ko", "es", "fr", "de", "it", "pt", "ru", "ar"]
    case .voxtralMini:
      ["en", "ar", "de", "es", "fr", "hi", "it", "ja", "ko", "nl", "pt", "ru", "zh"]
    }
  }

  /// Convert to underlying FluidAudio model version
  var fluidAudioVersion: FluidAudioModelVersion? {
    switch self {
    case .parakeetV2: .v2English
    case .parakeetUnified: .unifiedEnglish
    case .parakeetEOU: .eou120m
    default: nil
    }
  }

  /// Convert to underlying MLX Audio model version
  var mlxAudioVersion: MLXAudioModelVersion? {
    switch self {
    case .glmAsrNano: .glmAsrNano
    case .qwen3Asr: .qwen3Asr
    case .qwen3AsrSmall: .qwen3AsrSmall
    case .qwen3AsrQuantized: .qwen3AsrQuantized
    case .voxtralMini: .voxtralMini
    default: nil
    }
  }

  /// Whether this model's weights are present on disk and ready to load
  var isDownloaded: Bool {
    switch engine {
    case .fluidAudio:
      guard let version = fluidAudioVersion else { return false }
      return FluidAudioModelManager.shared.isVersionDownloaded(version)
    case .mlxAudio:
      guard let version = mlxAudioVersion else { return false }
      return MLXAudioModelManager.shared.isVersionDownloaded(version)
    }
  }

  /// Default model for new users
  static var defaultModel: SpeechModel { .parakeetV2 }

  // MARK: - Card Metadata

  var tagline: String {
    switch self {
    case .parakeetV2: "Best for English"
    case .parakeetUnified: "English · INT8"
    case .parakeetEOU: "English · Streaming"
    case .glmAsrNano: "Fast & Lightweight"
    case .qwen3Asr: "Best for Asian Languages"
    case .qwen3AsrSmall: "Compact Multilingual"
    case .qwen3AsrQuantized: "Lower Memory Qwen"
    case .voxtralMini: "Best Overall Accuracy"
    }
  }

  var modelDescription: String {
    switch self {
    case .parakeetV2:
      "Ultra-fast English transcription powered by NVIDIA Parakeet. Ideal for everyday dictation with the lowest latency."
    case .parakeetEOU:
      "Compact English model that processes audio while you record, using the 320 ms streaming variant. Release the hotkey to finish; sentence-end detection does not stop your recording."
    case .parakeetUnified:
      "NVIDIA’s unified English speech model with punctuation and capitalization. Uses the offline CoreML encoder on Apple Silicon; longer recordings are processed in overlapping windows."
    case .glmAsrNano:
      "Compact MLX model optimized for speed and low memory. Best when you need quick results with a minimal footprint."
    case .qwen3Asr:
      "High-accuracy multilingual model with strong support for Chinese, Japanese, Korean, and other Asian languages."
    case .qwen3AsrSmall:
      "Smaller Qwen3 speech model for multilingual dictation, including Chinese and English. Uses 4-bit weights to reduce storage and memory needs."
    case .qwen3AsrQuantized:
      "The 1.7B Qwen3 speech model with 4-bit weights. A smaller download than BF16; transcription quality and speed depend on your audio and Mac."
    case .voxtralMini:
      "Mistral's streaming ASR model with strong accuracy across 13 languages. Good balance of speed and quality at 4-bit quantization."
    }
  }

  var accuracyRating: Int? {
    switch self {
    case .parakeetV2: 4
    case .glmAsrNano: 3
    case .qwen3Asr: 5
    case .qwen3AsrSmall, .qwen3AsrQuantized, .parakeetUnified, .parakeetEOU: nil
    case .voxtralMini: 5
    }
  }

  var speedRating: Int? {
    switch self {
    case .parakeetV2: 5
    case .glmAsrNano: 5
    case .qwen3Asr: 3
    case .qwen3AsrSmall, .qwen3AsrQuantized, .parakeetUnified, .parakeetEOU: nil
    case .voxtralMini: 3
    }
  }

  var providerIconName: String {
    switch self {
    case .parakeetV2, .parakeetUnified, .parakeetEOU: "waveform"
    case .glmAsrNano: "cpu"
    case .qwen3Asr, .qwen3AsrSmall, .qwen3AsrQuantized: "globe.asia.australia"
    case .voxtralMini: "globe"
    }
  }
}

// MARK: - AnyModel Resolution

extension SpeechModel {
  /// Resolve a raw settings ID to either a built-in or custom speech model.
  /// Built-in models match their rawValue; custom models match a UUID string
  /// stored in `CustomModelRegistry`.
  /// Legacy ID "fluidaudio-v3" maps to the default model.
  static func resolve(_ rawValue: String) -> (builtin: SpeechModel?, custom: CustomSpeechModel?) {
    if let builtin = SpeechModel(rawValue: rawValue) { return (builtin, nil) }
    if rawValue == "fluidaudio-v3" { return (defaultModel, nil) }
    return (nil, CustomModelRegistry.shared.model(withID: rawValue))
  }
}
