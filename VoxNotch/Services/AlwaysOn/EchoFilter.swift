//
//  EchoFilter.swift
//  VoxNotch
//
//  Detects microphone utterances that are just speaker playback of system audio.
//

import Foundation

nonisolated enum EchoFilter {

  /// True when most words of `micText` also appear in the overlapping system-audio text.
  static func isLikelyEcho(micText: String, systemText: String, coverageThreshold: Double = 0.7) -> Bool {
    let micTokens = tokens(micText)
    guard micTokens.count >= 2 else { return false }
    let systemTokens = Set(tokens(systemText))
    guard !systemTokens.isEmpty else { return false }
    let covered = micTokens.filter(systemTokens.contains).count
    return Double(covered) / Double(micTokens.count) >= coverageThreshold
  }

  static func tokens(_ text: String) -> [String] {
    text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
      .filter { !$0.isEmpty }
  }
}
