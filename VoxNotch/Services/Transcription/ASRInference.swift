import Foundation
#if canImport(MLXAudioSTT)
import MLX
import MLXAudioSTT
import Tokenizers
#endif

/// Shared by queued work and its cancelling Swift task.
nonisolated final class ASRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

nonisolated enum ASRLanguage {
    static let names = [
        "en": "English", "zh": "Chinese", "yue": "Cantonese", "ja": "Japanese",
        "ko": "Korean", "de": "German", "fr": "French", "es": "Spanish",
        "pt": "Portuguese", "it": "Italian", "ru": "Russian", "ar": "Arabic",
        "hi": "Hindi", "nl": "Dutch", "tr": "Turkish", "vi": "Vietnamese",
        "th": "Thai", "id": "Indonesian", "ms": "Malay", "sv": "Swedish",
        "da": "Danish", "fi": "Finnish", "pl": "Polish", "cs": "Czech",
        "el": "Greek", "hu": "Hungarian", "ro": "Romanian", "fa": "Persian",
        "fil": "Filipino", "mk": "Macedonian"
    ]
    static func name(for language: String?) -> String? {
        guard let language, !language.isEmpty, language.lowercased() != "auto" else { return nil }
        let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? language
        return names[code] ?? names.values.first { $0.lowercased() == language.lowercased() }
    }
    static func assistantPrefix(language: String?) -> String {
        name(for: language).map { "language \($0)<asr_text>" } ?? ""
    }
    static func parse(_ raw: String, forcedLanguage: String?) -> (text: String, language: String?) {
        if let marker = raw.range(of: "<asr_text>") {
            let header = raw[..<marker.lowerBound].replacingOccurrences(of: "language ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let code = names.first { $0.value.lowercased() == header.lowercased() }?.key
            return (String(raw[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines), code)
        }
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), name(for: forcedLanguage).flatMap { name in names.first { $0.value == name }?.key })
    }
}

#if canImport(MLXAudioSTT)
/// Serialize Metal work across batch and recording-time inference.
nonisolated enum ASRInference {
    static let queue = DispatchQueue(label: "com.voxnotch.asr-inference", qos: .userInitiated)

    static func generate(model: any STTGenerationModel, samples: [Float], language: String?, cancellation: ASRCancellation) throws -> (text: String, language: String?) {
        try cancellation.check()
        if let qwen = model as? Qwen3ASRModel {
            return try generateQwen(model: qwen, samples: samples, language: language, cancellation: cancellation)
        }
        let defaults = model.defaultGenerationParameters
        let output = model.generate(audio: MLXArray(samples), generationParameters: STTGenerateParameters(
            maxTokens: min(defaults.maxTokens, max(128, samples.count / 16000 * 32)),
            temperature: defaults.temperature, topP: defaults.topP, topK: defaults.topK,
            verbose: false, language: language ?? "auto",
            chunkDuration: 30, minChunkDuration: defaults.minChunkDuration))
        try cancellation.check()
        // Voxtral's output.language merely echoes its input; do not report it as detected.
        return (output.text, language)
    }

    /// Uses the SDK's public forward pass with the official Qwen auto-language prompt.
    /// Unlike the pinned SDK's synchronous generator, checks cancellation per token.
    private static func generateQwen(model: Qwen3ASRModel, samples: [Float], language: String?, cancellation: ASRCancellation) throws -> (text: String, language: String?) {
        guard let tokenizer = model.tokenizer else { throw TranscriptionError.modelNotLoaded }
        let chunks = splitAudioIntoChunks(MLXArray(samples), sampleRate: 16000, chunkDuration: 30, minChunkDuration: 1)
        var texts: [String] = []
        var detected: String?
        for (chunk, _) in chunks {
            try cancellation.check()
            let (features, mask, audioTokens) = model.preprocessAudio(chunk)
            let prompt = "<|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>"
                + String(repeating: "<|audio_pad|>", count: audioTokens)
                + "<|audio_end|><|im_end|>\n<|im_start|>assistant\n"
                + ASRLanguage.assistantPrefix(language: language)
            let input = MLXArray(tokenizer.encode(text: prompt).map(Int32.init)).expandedDimensions(axis: 0)
            let cache = model.makeCache()
            var logits = model(inputIds: input, inputFeatures: features, featureAttentionMask: mask, cache: cache)
            eval(logits)
            var tokens: [Int] = []
            let budget = min(2048, max(128, chunk.size / 16000 * 32))
            for _ in 0..<budget {
                try cancellation.check()
                let token = logits[0..., -1, 0...].argMax(axis: -1).item(Int.self)
                if token == 151645 || token == 151643 { break }
                tokens.append(token)
                logits = model(inputIds: MLXArray([Int32(token)]).expandedDimensions(axis: 0), cache: cache)
                eval(logits)
            }
            let parsed = ASRLanguage.parse(tokenizer.decode(tokens: tokens), forcedLanguage: language)
            if !parsed.text.isEmpty { texts.append(parsed.text) }
            detected = detected ?? parsed.language
        }
        return (texts.joined(separator: " "), detected)
    }
}
#endif
