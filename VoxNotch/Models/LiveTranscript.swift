//
//  LiveTranscript.swift
//  VoxNotch
//
//  Value types for the Always-On live transcript.
//

import Foundation

nonisolated struct LiveTranscriptSegment: Identifiable, Equatable, Sendable {
  let id: UUID
  let source: AudioSource
  var text: String
  let startedAt: Date
  var endedAt: Date
  var isFinal: Bool
}

nonisolated struct TranscriptUpdate: Sendable {
  let utteranceID: UUID
  let source: AudioSource
  let text: String
  let isFinal: Bool
  let startedAt: Date
  let endedAt: Date
  /// Time from the triggering audio arriving to the text being ready.
  let processingLatency: Duration
  /// Silence detected after the speech. On a partial, a non-zero value means the
  /// speaker has paused and the text already covers the whole utterance.
  let trailingSilence: Duration
}
