import Foundation
#if canImport(MLXAudioSTT)
import MLXAudioSTT

nonisolated struct ASRModelHandle: @unchecked Sendable {
    let model: any STTGenerationModel
}

/// Keeps audio in order and splits at pauses; caps each inference at 12 seconds.
/// No overlap is discarded or counted twice. Hard boundaries can split words.
nonisolated struct RecordingSegmenter {
    private(set) var pending: [Float] = []
    private var quietSamples = 0
    mutating func append(_ samples: [Float]) -> [[Float]] {
        var result: [[Float]] = []
        // Fixed 20ms energy frames make boundaries independent of capture buffer size.
        for sample in samples {
            pending.append(sample)
            if pending.count % 320 == 0 {
                let energy = pending.suffix(320).reduce(Float.zero) { $0 + $1 * $1 } / 320
                quietSamples = energy < 0.0001 ? quietSamples + 320 : 0
            }
            if pending.count >= 192000 || (pending.count >= 48000 && quietSamples >= 6400) {
                result.append(pending)
                pending.removeAll(keepingCapacity: true)
                quietSamples = 0
            }
        }
        return result
    }
    mutating func finish() -> [Float] {
        defer { pending.removeAll(); quietSamples = 0 }
        return pending
    }
}

/// Processes finalized speech segments during recording, then flushes the tail.
/// The bounded input queue fails rather than silently dropping captured audio.
nonisolated final class RecordingTranscriptionSession: RecordingAudioSession, @unchecked Sendable {
    private let input: AsyncStream<[Float]>.Continuation
    private let cancellation = ASRCancellation()
    private let stateLock = NSLock()
    private var overflow = false
    private let task: Task<TranscriptionResult, Error>

    init(language: String?, loadModel: @escaping @Sendable () async throws -> ASRModelHandle) {
        let pair = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingOldest(4096))
        input = pair.continuation
        let cancellation = self.cancellation
        task = Task {
            let handle = try await loadModel()
            try cancellation.check()
            var segmenter = RecordingSegmenter()
            var texts: [String] = []
            var sampleCount = 0
            var inferenceTime: Double = 0
            for await samples in pair.stream {
                try cancellation.check()
                sampleCount += samples.count
                for segment in segmenter.append(samples) {
                    let start = ProcessInfo.processInfo.systemUptime
                    let output = try await Self.decode(segment, handle: handle, language: language, cancellation: cancellation)
                    inferenceTime += ProcessInfo.processInfo.systemUptime - start
                    if !output.isEmpty { texts.append(output) }
                }
            }
            try cancellation.check()
            let tail = segmenter.finish()
            if !tail.isEmpty {
                let start = ProcessInfo.processInfo.systemUptime
                let output = try await Self.decode(tail, handle: handle, language: language, cancellation: cancellation)
                inferenceTime += ProcessInfo.processInfo.systemUptime - start
                if !output.isEmpty { texts.append(output) }
            }
            return TranscriptionResult(text: texts.joined(separator: " "), confidence: nil,
                audioDuration: Double(sampleCount) / 16000, processingTime: inferenceTime,
                provider: "MLX Audio (recording segments)", language: language, segments: nil)
        }
    }

    func append(_ samples: [Float]) {
        if case .dropped = input.yield(samples) {
            stateLock.withLock { overflow = true }
            cancel()
        }
    }
    func cancel() {
        cancellation.cancel()
        input.finish()
        task.cancel()
    }
    func finish() async throws -> TranscriptionResult {
        input.finish()
        if stateLock.withLock({ overflow }) { throw TranscriptionError.transcriptionFailed("Streaming audio queue overflow") }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { self.cancel() }
    }
    private static func decode(_ samples: [Float], handle: ASRModelHandle, language: String?, cancellation: ASRCancellation) async throws -> String {
        // Skip silent segments; final file-level VAD remains authoritative when enabled.
        let energy = samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(samples.count, 1))
        guard energy > 0.000001 else { return "" }
        return try await withCheckedThrowingContinuation { continuation in
            ASRInference.queue.async {
                do {
                    let output = try ASRInference.generate(model: handle.model, samples: samples, language: language, cancellation: cancellation)
                    continuation.resume(returning: output.text.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
#endif
