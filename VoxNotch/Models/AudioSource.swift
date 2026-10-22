//
//  AudioSource.swift
//  VoxNotch
//
//  Audio input source selection (microphone vs system audio)
//

import Foundation

nonisolated enum AudioSource: String, CaseIterable, Sendable {
    case microphone
    case systemAudio

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System Audio"
        }
    }

    var iconName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        }
    }
}
