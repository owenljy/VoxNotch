//
//  UtteranceSegmenter.swift
//  VoxNotch
//
//  Turns a stream of fixed-size VAD chunks into utterances. While speech is
//  active every chunk yields a `.partial` snapshot of the whole utterance (for
//  live re-decoding); a run of silent chunks, a length cap or a manual flush
//  yields `.final`.
//

import Foundation

nonisolated struct UtteranceSegmenter {

  struct Config: Sendable {
    /// Speech starts at or above this probability.
    var speechThreshold: Float = 0.5
    /// A chunk below this probability counts toward ending the utterance (hysteresis).
    var silenceThreshold: Float = 0.35
    /// Consecutive silent chunks that end an utterance (2 × 256ms by default).
    var endSilenceChunks = 2
    /// Chunks of audio kept from before speech onset so first syllables aren't clipped.
    var preRollChunks = 1
    /// Past this length, split at the next non-speech chunk.
    var softMaxSamples = 16_000 * 12
    /// Past this length, split unconditionally (Parakeet handles ~15s per pass).
    var hardMaxSamples = 16_000 * 14
  }

  struct Utterance: Equatable, Sendable {
    let id: UUID
    let startSample: Int
    let samples: [Float]
    let trailingSilenceSamples: Int
  }

  enum Event: Equatable, Sendable {
    case partial(Utterance)
    case final(Utterance)
  }

  let config: Config

  private(set) var isSpeaking = false
  private var preRoll: [[Float]] = []
  private var utterance: [Float] = []
  private var utteranceID = UUID()
  private var utteranceStart = 0
  private var silentChunkSizes: [Int] = []
  private var processedSamples = 0

  init(config: Config = Config()) {
    self.config = config
  }

  mutating func process(chunk: [Float], speechProbability probability: Float) -> Event? {
    defer { processedSamples += chunk.count }

    guard isSpeaking else {
      guard probability >= config.speechThreshold else {
        preRoll.append(chunk)
        if preRoll.count > config.preRollChunks { preRoll.removeFirst() }
        return nil
      }
      let pre = preRoll.joined()
      isSpeaking = true
      utteranceID = UUID()
      utteranceStart = processedSamples - pre.count
      utterance = Array(pre) + chunk
      preRoll = []
      silentChunkSizes = []
      return .partial(snapshot(trimSilence: false))
    }

    utterance += chunk
    if probability < config.silenceThreshold {
      silentChunkSizes.append(chunk.count)
    } else {
      silentChunkSizes = []
    }

    if silentChunkSizes.count >= config.endSilenceChunks {
      return finish(continueSpeaking: false)
    }
    if utterance.count >= config.hardMaxSamples
      || (utterance.count >= config.softMaxSamples && probability < config.speechThreshold)
    {
      return finish(continueSpeaking: true)
    }
    return .partial(snapshot(trimSilence: false))
  }

  /// Finalize the in-progress utterance immediately, including audio not yet chunked.
  mutating func flush(appending tail: [Float] = []) -> Event? {
    guard isSpeaking else { return nil }
    utterance += tail
    processedSamples += tail.count
    silentChunkSizes = []
    return finish(continueSpeaking: false)
  }

  private mutating func finish(continueSpeaking: Bool) -> Event {
    let event = Event.final(snapshot(trimSilence: true))
    if continueSpeaking {
      utteranceStart += utterance.count
      utteranceID = UUID()
    } else {
      isSpeaking = false
      preRoll = []
    }
    utterance = []
    silentChunkSizes = []
    return event
  }

  /// Keeps the first trailing silent chunk (helps the decoder close the sentence) and drops the rest.
  private func snapshot(trimSilence: Bool) -> Utterance {
    let silence = silentChunkSizes.reduce(0, +)
    let dropped = trimSilence ? silence - (silentChunkSizes.first ?? 0) : 0
    return Utterance(
      id: utteranceID,
      startSample: utteranceStart,
      samples: Array(utterance.dropLast(dropped)),
      trailingSilenceSamples: silence
    )
  }
}
