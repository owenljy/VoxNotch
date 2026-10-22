//
//  AlwaysOnController.swift
//  VoxNotch
//
//  Starts/stops Always-On mode: owns the LiveTranscriber, routes microphone and
//  system-audio streams into it, publishes transcript updates and input levels
//  to AlwaysOnState, and shows the overlay panel.
//

import FluidAudio
import Foundation
import os

@MainActor
final class AlwaysOnController {

  static let shared = AlwaysOnController()

  private let state = AlwaysOnState.shared
  private let panel = AlwaysOnPanelController.shared
  private let settings = AssistantSettings.shared
  private lazy var autoTrigger = AutoTriggerCoordinator(assistant: .shared, settings: settings)
  private let logger = Logger(subsystem: "com.voxnotch", category: "AlwaysOnController")

  private var transcriber: LiveTranscriber?
  private var sessionTask: Task<Void, Never>?
  private var updatesTask: Task<Void, Never>?
  private var levelTask: Task<Void, Never>?
  private var ingestTasks: [Task<Void, Never>] = []
  private var sampleContinuations: [AsyncStream<[Float]>.Continuation] = []

  private init() {}

  var isActive: Bool { state.isActive }

  func toggle() {
    isActive ? stop() : start()
  }

  func start() {
    start(sources: settings.enabledSources)
  }

  func start(sources: Set<AudioSource>) {
    guard !state.isActive else { return }
    panel.show()
    guard !sources.isEmpty else {
      state.status = .failed("Turn on the microphone or system audio in Always-On settings")
      return
    }

    guard !AudioCaptureManager.shared.isRecording, !SystemAudioCaptureManager.shared.isRecording else {
      state.status = .failed("Finish dictation before starting Always-On")
      return
    }

    state.begin(sources: sources)
    state.suppressEcho = settings.suppressEcho
    autoTrigger.reset()
    if settings.isProviderConfigured {
      OpenAICompatibleClient.shared.warmUp(config: settings.providerConfig)
    }
    let transcriber = LiveTranscriber()
    self.transcriber = transcriber

    updatesTask = Task { [state, autoTrigger] in
      for await update in transcriber.updates {
        let accepted = state.apply(update)
        autoTrigger.handle(update, accepted: accepted)
      }
    }

    let needsDownload = !FluidAudioModelManager.shared.isVersionDownloaded(.v2English)
    state.preparingMessage = needsDownload
      ? "Downloading the English speech model (about 500 MB)…"
      : "Starting live transcription…"

    sessionTask = Task {
      do {
        try await transcriber.prepare(asr: loadASRManager())
        try Task.checkCancellation()
        try await startCapture(sources: sources, into: transcriber)
        state.status = .running
        state.startedAt = Date()
        startLevelPolling(transcriber)
        logger.info("Always-On running with sources: \(sources.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)")
      } catch is CancellationError {
        return
      } catch {
        fail(error)
      }
    }
  }

  func stop() {
    AssistantService.shared.stop()
    autoTrigger.reset()
    teardown()
    state.end()
    panel.hide()
    logger.info("Always-On stopped")
  }

  func restart() {
    teardown()
    state.end()
    start()
  }

  func askNow() {
    guard state.isActive else { return }
    autoTrigger.noteManualAsk()
    AssistantService.shared.ask(trigger: .manual)
  }

  /// Pausing releases the microphone and system-audio capture entirely.
  func togglePause() {
    guard state.status == .running, let transcriber else { return }
    if state.isPaused {
      state.isPaused = false
      sessionTask = Task {
        do {
          try await startCapture(sources: state.activeSources, into: transcriber)
        } catch {
          fail(error)
        }
      }
    } else {
      state.isPaused = true
      stopCapture()
      state.levels = [:]
      Task { await transcriber.flush() }
    }
  }

  /// Finalize in-progress speech immediately so a manual AI request sees it.
  func flushPendingSpeech() async {
    await transcriber?.flush()
  }

  // MARK: - Private

  /// Reuses dictation's Parakeet v2 manager when it's loaded (decoder state is per call,
  /// so sharing is safe); otherwise loads v2 separately without replacing dictation's model.
  private func loadASRManager() async throws -> AsrManager {
    if case .tdt(let manager)? = FluidAudioModelManager.shared.getLoadedModel(for: .v2English) {
      return manager
    }
    let models = try await AsrModels.downloadAndLoad(version: .v2)
    let manager = AsrManager()
    try await manager.loadModels(models)
    return manager
  }

  private func startCapture(sources: Set<AudioSource>, into transcriber: LiveTranscriber) async throws {
    for source in AudioSource.allCases where sources.contains(source) {
      await transcriber.startSource(source)

      // ~10s of headroom; oldest audio is dropped only if the pipeline stalls badly.
      let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(500))
      sampleContinuations.append(continuation)
      ingestTasks.append(Task.detached(priority: .userInitiated) {
        for await samples in stream {
          await transcriber.ingest(samples, from: source)
        }
      })

      let onSamples: @Sendable ([Float]) -> Void = { continuation.yield($0) }
      switch source {
      case .microphone:
        try await AudioCaptureManager.shared.startStreaming(onSamples: onSamples)
      case .systemAudio:
        try await SystemAudioCaptureManager.shared.startStreaming(onSamples: onSamples)
      }
    }
  }

  private func stopCapture() {
    AudioCaptureManager.shared.stopStreaming()
    SystemAudioCaptureManager.shared.stopStreaming()
    sampleContinuations.forEach { $0.finish() }
    sampleContinuations = []
    ingestTasks.forEach { $0.cancel() }
    ingestTasks = []
  }

  private func startLevelPolling(_ transcriber: LiveTranscriber) {
    levelTask?.cancel()
    levelTask = Task { [state] in
      while !Task.isCancelled {
        if !state.isPaused {
          for source in state.activeSources {
            state.levels[source] = await transcriber.level(for: source)
          }
        }
        try? await Task.sleep(for: .milliseconds(80))
      }
    }
  }

  private func fail(_ error: Error) {
    logger.error("Always-On failed: \(error.localizedDescription, privacy: .public)")
    teardown()
    state.end()
    state.status = .failed(error.localizedDescription)
  }

  private func teardown() {
    stopCapture()
    sessionTask?.cancel()
    sessionTask = nil
    levelTask?.cancel()
    levelTask = nil
    updatesTask = nil
    if let transcriber {
      Task { await transcriber.shutdown() }
    }
    transcriber = nil
  }
}

// MARK: - Global Shortcuts

@MainActor
enum AlwaysOnShortcuts {

  private static var observer: NSObjectProtocol?

  static func install() {
    register()
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(
      forName: .alwaysOnShortcutsChanged, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { register() }
    }
  }

  private static func register() {
    let settings = AssistantSettings.shared
    var shortcuts: [HotkeyManager.RegisteredShortcut] = []
    if let toggle = settings.toggleShortcut {
      shortcuts.append(.init(shortcut: toggle) {
        AlwaysOnController.shared.toggle()
        return true
      })
    }
    if let ask = settings.askShortcut {
      shortcuts.append(.init(shortcut: ask) {
        guard AlwaysOnController.shared.isActive else { return false }
        AlwaysOnController.shared.askNow()
        return true
      })
    }
    HotkeyManager.shared.shortcuts = shortcuts
  }
}
