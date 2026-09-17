import AVFoundation
import FluidAudio
import Foundation

nonisolated protocol RecordingAudioSession: Sendable {
  func append(_ samples: [Float])
  func cancel()
  func finish() async throws -> TranscriptionResult
}

/// Narrow engine interface also allows lifecycle tests without downloading weights.
nonisolated protocol EOUStreamingEngine: Sendable {
  func reset() async
  func process(samples: [Float]) async throws
  func finish() async throws -> String
}

nonisolated struct CoreMLEOUEngine: EOUStreamingEngine {
  let manager: StreamingEouAsrManager

  func reset() async { await manager.reset() }
  func finish() async throws -> String {
    // The 320 ms model needs right context. The SDK flushes only one remaining
    // window; two silent shifts let it decode trailing speech before finalizing.
    // Padding is internal to the engine and does not extend the recorded duration.
    try await process(samples: Array(repeating: 0, count: 2 * 5120))
    return try await manager.finish()
  }
  func process(samples: [Float]) async throws {
    guard !samples.isEmpty else { return }
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                    channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
          let destination = buffer.floatChannelData?[0] else {
      throw TranscriptionError.invalidFormat
    }
    samples.withUnsafeBufferPointer { source in
      destination.update(from: source.baseAddress!, count: source.count)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    _ = try await manager.process(audioBuffer: buffer)
  }
}

/// Serialize whole recordings, since the SDK's actor is reentrant during inference.
/// A canceled session must finish its in-flight encoder call before the next reset.
actor EOUDecoder {
  private let engine: any EOUStreamingEngine
  private var pending: Task<Void, Never>?

  init(engine: any EOUStreamingEngine) { self.engine = engine }

  func transcribe(_ input: AsyncStream<[Float]>) async throws -> TranscriptionResult {
    let previous = pending
    let engine = self.engine
    let operation = Task {
      await previous?.value
      try Task.checkCancellation()
      await engine.reset()
      var count = 0
      var processingTime = 0.0
      for await samples in input {
        try Task.checkCancellation()
        count += samples.count
        let start = ProcessInfo.processInfo.systemUptime
        try await engine.process(samples: samples)
        processingTime += ProcessInfo.processInfo.systemUptime - start
      }
      try Task.checkCancellation()
      let start = ProcessInfo.processInfo.systemUptime
      let text = try await engine.finish()
      try Task.checkCancellation()
      processingTime += ProcessInfo.processInfo.systemUptime - start
      return TranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
        confidence: nil, audioDuration: Double(count) / 16000, processingTime: processingTime,
        provider: "FluidAudio (EOU streaming)", language: "en", segments: nil)
    }
    pending = Task { _ = try? await operation.value }
    return try await withTaskCancellationHandler {
      let result = try await operation.value
      try Task.checkCancellation()
      return result
    } onCancel: { operation.cancel() }
  }
}

nonisolated final class EOURecordingSession: RecordingAudioSession, @unchecked Sendable {
  private let input: AsyncStream<[Float]>.Continuation
  private let task: Task<TranscriptionResult, Error>
  private let lock = NSLock()
  private var overflow = false

  init(loadDecoder: @escaping @Sendable () async throws -> EOUDecoder) {
    let pair = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingOldest(4096))
    input = pair.continuation
    task = Task {
      let decoder = try await loadDecoder()
      try Task.checkCancellation()
      return try await decoder.transcribe(pair.stream)
    }
  }
  func append(_ samples: [Float]) {
    guard !samples.isEmpty else { return }
    if case .dropped = input.yield(samples) {
      lock.withLock { overflow = true }
      cancel()
    }
  }
  func cancel() {
    task.cancel()
    input.finish()
  }
  func finish() async throws -> TranscriptionResult {
    input.finish()
    return try await withTaskCancellationHandler {
      let result: TranscriptionResult
      do { result = try await task.value }
      catch {
        if lock.withLock({ overflow }) {
          throw TranscriptionError.transcriptionFailed("Streaming audio queue overflow")
        }
        throw error
      }
      try Task.checkCancellation()
      return result
    } onCancel: { self.cancel() }
  }
}
