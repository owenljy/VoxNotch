//
//  LiveTranscriber.swift
//  VoxNotch
//
//  Low-latency streaming transcription for Always-On mode.
//
//  Each audio source runs its own pipeline: 16kHz samples → 256ms Silero VAD
//  chunks → UtteranceSegmenter. Segmenter events become decode jobs on one
//  shared, pre-warmed Parakeet `AsrManager`. Finals always run before partials,
//  only the newest partial per source is kept, and partials that went stale
//  while queued or decoding are dropped.
//

import FluidAudio
import Foundation
import os

actor LiveTranscriber {

  typealias Decoder = @Sendable ([Float]) async throws -> String
  typealias SpeechDetector = @Sendable ([Float], VadStreamState) async throws -> (probability: Float, state: VadStreamState)

  struct Config: Sendable {
    var segmenter = UtteranceSegmenter.Config()
    /// Finals shorter than this (after silence trimming) are treated as noise.
    var minFinalSamples = 16_000 / 4
  }

  nonisolated let updates: AsyncStream<TranscriptUpdate>
  private let continuation: AsyncStream<TranscriptUpdate>.Continuation

  private let config: Config
  private let decodeAudio: Decoder?
  private let detectSpeech: SpeechDetector?
  private var asr: AsrManager?
  private var decoderLayers = 2
  private var vad: VadManager?
  private var pipelines: [AudioSource: Pipeline] = [:]
  private var finalJobs: [Job] = []
  private var partialJobs: [AudioSource: Job] = [:]
  private var lastPartialSource: AudioSource?
  private var isDraining = false
  private var isShutdown = false
  private var drainTask: Task<Void, Never>?

  private let clock = ContinuousClock()
  private let logger = Logger(subsystem: "com.voxnotch", category: "LiveTranscriber")

  private static let sampleRate = 16_000
  private static let minDecodeSamples = 16_000

  private struct Pipeline {
    let id = UUID()
    var pending: [Float] = []
    var vadState = VadStreamState.initial()
    var segmenter: UtteranceSegmenter
    var activeUtterance: UUID?
    let streamStart = Date()
    var level: Float = 0
    /// Most recent partial decode, reused when the final covers identical audio.
    var lastDecoded: (utterance: UUID, sampleCount: Int, text: String)?
  }

  private struct Job {
    let source: AudioSource
    let utterance: UtteranceSegmenter.Utterance
    let isFinal: Bool
    let audioArrivedAt: ContinuousClock.Instant
    /// Wall-clock start, fixed at enqueue so restarting a source can't skew it.
    let startedAt: Date
  }

  init(config: Config = Config(), decode: Decoder? = nil, detectSpeech: SpeechDetector? = nil) {
    self.config = config
    self.decodeAudio = decode
    self.detectSpeech = detectSpeech
    (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
  }

  // MARK: - Lifecycle

  nonisolated struct PreparedModels: Sendable {
    let asr: AsrManager
    let vad: VadManager
    let decoderLayers: Int
  }

  /// Takes a loaded Parakeet TDT manager and warms it and the VAD up so the first
  /// utterance doesn't pay compile/load cost.
  func prepare(asr: AsrManager) async throws {
    try prepare(models: await Self.prepareModels(asr: asr))
  }

  nonisolated static func prepareModels(asr: AsrManager) async throws -> PreparedModels {
    let clock = ContinuousClock()
    let start = clock.now

    let vad = try await VadManager()
    let layers = await asr.decoderLayerCount

    let silence = [Float](repeating: 0, count: Self.minDecodeSamples)
    if var warmUpState = try? TdtDecoderState(decoderLayers: layers) {
      _ = try? await asr.transcribe(silence, decoderState: &warmUpState)
    }
    _ = try? await vad.processStreamingChunk(Array(silence.prefix(VadManager.chunkSize)), state: VadStreamState.initial())

    try Task.checkCancellation()
    Logger(subsystem: "com.voxnotch", category: "LiveTranscriber")
      .info("Transcription models prepared in \(Self.ms(clock.now - start)) ms")
    return PreparedModels(asr: asr, vad: vad, decoderLayers: layers)
  }

  func prepare(models: PreparedModels) throws {
    try Task.checkCancellation()
    guard !isShutdown else { throw CancellationError() }
    asr = models.asr
    decoderLayers = models.decoderLayers
    vad = models.vad
  }

  func startSource(_ source: AudioSource) {
    guard !isShutdown else { return }
    pipelines[source] = Pipeline(segmenter: UtteranceSegmenter(config: config.segmenter))
  }

  func shutdown() {
    isShutdown = true
    pipelines.removeAll()
    finalJobs.removeAll()
    partialJobs.removeAll()
    continuation.finish()
  }

  /// Capture has ended and its ingest streams have drained. Finish the last
  /// utterances and deliver their finals before closing the update stream.
  func finish() async {
    flush()
    await drainTask?.value
    shutdown()
  }

  func level(for source: AudioSource) -> Float {
    pipelines[source]?.level ?? 0
  }

  // MARK: - Ingest

  func ingest(_ samples: [Float], from source: AudioSource) async {
    guard let pipelineID = pipelines[source]?.id, vad != nil || detectSpeech != nil else { return }
    let arrivedAt = clock.now
    pipelines[source]?.pending += samples
    pipelines[source]?.level = Self.rms(samples)

    while let pipeline = pipelines[source], pipeline.pending.count >= VadManager.chunkSize {
      let chunk = Array(pipeline.pending.prefix(VadManager.chunkSize))
      pipelines[source]?.pending.removeFirst(VadManager.chunkSize)

      let result: (probability: Float, state: VadStreamState)?
      if let detectSpeech {
        result = try? await detectSpeech(chunk, pipeline.vadState)
      } else if let vad, let detected = try? await vad.processStreamingChunk(chunk, state: pipeline.vadState) {
        result = (detected.probability, detected.state)
      } else {
        result = nil
      }
      guard pipelines[source]?.id == pipelineID else { return }
      if let result { pipelines[source]?.vadState = result.state }

      if let event = pipelines[source]?.segmenter.process(chunk: chunk, speechProbability: result?.probability ?? 0) {
        enqueue(event, from: source, audioArrivedAt: arrivedAt)
      }
    }
  }

  /// Finalize every in-progress utterance now (used when the user asks the AI mid-sentence).
  func flush(source only: AudioSource? = nil) {
    let now = clock.now
    for source in Array(pipelines.keys) where only == nil || only == source {
      guard var pipeline = pipelines[source] else { continue }
      let tail = pipeline.pending
      pipeline.pending = []
      let event = pipeline.segmenter.flush(appending: tail)
      pipelines[source] = pipeline
      if let event { enqueue(event, from: source, audioArrivedAt: now) }
    }
  }

  // MARK: - Scheduling

  private func enqueue(_ event: UtteranceSegmenter.Event, from source: AudioSource, audioArrivedAt: ContinuousClock.Instant) {
    guard let streamStart = pipelines[source]?.streamStart else { return }
    switch event {
    case .partial(let utterance):
      pipelines[source]?.activeUtterance = utterance.id
      partialJobs[source] = Job(
        source: source, utterance: utterance, isFinal: false, audioArrivedAt: audioArrivedAt,
        startedAt: streamStart.addingTimeInterval(Double(utterance.startSample) / Double(Self.sampleRate)))
    case .final(let utterance):
      pipelines[source]?.activeUtterance = nil
      partialJobs[source] = nil
      finalJobs.append(Job(
        source: source, utterance: utterance, isFinal: true, audioArrivedAt: audioArrivedAt,
        startedAt: streamStart.addingTimeInterval(Double(utterance.startSample) / Double(Self.sampleRate))))
    }

    guard !isDraining else { return }
    isDraining = true
    drainTask = Task { await drain() }
  }

  private func drain() async {
    while let job = nextJob() {
      await decode(job)
    }
    isDraining = false
  }

  private func nextJob() -> Job? {
    if !finalJobs.isEmpty { return finalJobs.removeFirst() }
    let source = partialJobs.keys.first { $0 != lastPartialSource } ?? partialJobs.keys.first
    guard let source, let job = partialJobs.removeValue(forKey: source) else { return nil }
    lastPartialSource = source
    return job
  }

  private func isStale(_ job: Job) -> Bool {
    !job.isFinal && pipelines[job.source]?.activeUtterance != job.utterance.id
  }

  private func decode(_ job: Job) async {
    guard !isShutdown, !isStale(job), asr != nil || decodeAudio != nil else { return }

    var samples = job.utterance.samples
    let speechSamples = samples.count - (job.isFinal ? min(job.utterance.retainedSilenceSamples, samples.count) : 0)
    var text = ""
    let reusable = pipelines[job.source]?.lastDecoded
    let canReuse = job.isFinal
      && reusable?.utterance == job.utterance.id
      && reusable?.sampleCount == samples.count

    if canReuse, let reusable {
      text = reusable.text
    } else if !job.isFinal || speechSamples >= config.minFinalSamples {
      if samples.count < Self.minDecodeSamples {
        samples += [Float](repeating: 0, count: Self.minDecodeSamples - samples.count)
      }
      do {
        // Every snapshot is decoded independently, so each starts from a fresh decoder state.
        if let decodeAudio {
          text = try await decodeAudio(samples)
        } else if let asr {
          var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
          text = try await asr.transcribe(samples, decoderState: &decoderState).text
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
      } catch {
        logger.error("Decode failed (\(job.source.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        guard job.isFinal else { return }
      }
    }

    guard !isShutdown, !isStale(job), job.isFinal || !text.isEmpty else { return }
    pipelines[job.source]?.lastDecoded = job.isFinal ? nil : (job.utterance.id, job.utterance.samples.count, text)

    let start = job.startedAt
    let end = start.addingTimeInterval(Double(job.utterance.samples.count) / Double(Self.sampleRate))
    let latency = clock.now - job.audioArrivedAt
    let trailingSilence = Duration.seconds(Double(job.utterance.trailingSilenceSamples) / Double(Self.sampleRate))

    continuation.yield(TranscriptUpdate(
      utteranceID: job.utterance.id,
      source: job.source,
      text: text,
      isFinal: job.isFinal,
      startedAt: start,
      endedAt: end,
      processingLatency: latency,
      trailingSilence: trailingSilence
    ))

    let audioMs = job.utterance.samples.count * 1000 / Self.sampleRate
    if job.isFinal {
      logger.info("[latency] final \(job.source.rawValue, privacy: .public) audio=\(audioMs)ms processing=\(Self.ms(latency))ms silence=\(Self.ms(trailingSilence))ms reused=\(canReuse)")
    } else {
      logger.debug("[latency] partial \(job.source.rawValue, privacy: .public) audio=\(audioMs)ms processing=\(Self.ms(latency))ms")
    }
  }

  // MARK: - Helpers

  private static func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sumOfSquares / Float(samples.count)).squareRoot()
  }

  private nonisolated static func ms(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}
