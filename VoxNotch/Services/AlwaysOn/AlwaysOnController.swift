//
//  AlwaysOnController.swift
//  VoxNotch
//
//  Starts/stops Always-On mode: owns the LiveTranscriber, routes microphone and
//  system-audio streams into it, publishes transcript updates and input levels
//  to AlwaysOnState, and shows the overlay panel.
//

import CoreAudio
import FluidAudio
import Foundation
import os

@MainActor
final class AlwaysOnController {

  static let shared = AlwaysOnController()

  private let state = AlwaysOnState.shared
  private let panel = AlwaysOnPanelController.shared
  private let settings = AssistantSettings.shared
  private let historyStore = AlwaysOnHistoryStore.shared
  private lazy var autoTrigger = AutoTriggerCoordinator(assistant: .shared, settings: settings)
  private let logger = Logger(subsystem: "com.voxnotch", category: "AlwaysOnController")

  private var transcriber: LiveTranscriber?
  private var sessionTask: Task<Void, Never>?
  private var updatesTask: Task<Void, Never>?
  private var levelTask: Task<Void, Never>?
  private var ingestTasks: [AudioSource: Task<Void, Never>] = [:]
  private var sampleContinuations: [AudioSource: AsyncStream<[Float]>.Continuation] = [:]
  private var isEndingSession = false
  private var finalizationTask: Task<Void, Never>?
  private lazy var captureCoordinator = AlwaysOnCaptureCoordinator { [weak self] source in
    self?.stopCapture(source)
  }

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
    AudioDeviceMonitor.shared.start()
    state.suppressEcho = settings.suppressEcho
    autoTrigger.reset()
    let sessionID = state.sessionID
    historyStore.startSession(id: sessionID, sources: sources, startedAt: Date())
    if settings.isProviderConfigured {
      OpenAICompatibleClient.shared.warmUp(config: settings.providerConfig)
    }
    let transcriber = LiveTranscriber()
    self.transcriber = transcriber

    // History keeps its own transcript while a stopped session drains. A new
    // session can begin immediately without accepting the old session's finals.
    let historyTranscript = AlwaysOnState()
    historyTranscript.begin(sources: sources)
    historyTranscript.suppressEcho = settings.suppressEcho
    updatesTask = Task { [state, autoTrigger, historyStore, sessionID] in
      for await update in transcriber.updates {
        if state.sessionID == sessionID, state.isActive {
          for source in AudioSource.allCases {
            historyTranscript.setSource(source, active: state.activeSources.contains(source))
          }
          let accepted = state.apply(update)
          autoTrigger.handle(update, accepted: accepted)
        }
        if historyTranscript.apply(update), update.isFinal, let segment = historyTranscript.lastFinalSegment {
          historyStore.recordSegment(segment, sessionID: sessionID)
        }
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
        try await startCapture(sources: sources, into: transcriber, sessionID: sessionID)
        try checkSession(sessionID)
        state.status = .running
        state.startedAt = Date()
        startLevelPolling(transcriber)
        logger.info("Always-On running with sources: \(sources.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)")
      } catch is CancellationError {
        return
      } catch {
        guard state.sessionID == sessionID, state.isActive else { return }
        fail(error)
      }
    }
  }

  func stop() {
    guard state.isActive || transcriber != nil else {
      panel.hide()
      return
    }
    let sessionID = state.sessionID
    AssistantService.shared.stop()
    autoTrigger.reset()
    teardown()
    historyStore.endSession(id: sessionID, endedAt: Date(), cleanly: true)
    state.end()
    panel.hide()
    logger.info("Always-On stopped")
  }

  /// Used on normal app termination so the last transcript and close marker
  /// reach SQLite before the process exits.
  func stopAndWait() async {
    stop()
    await finalizationTask?.value
    await historyStore.flush()
  }

  func restart() {
    stop()
    start()
  }

  func askNow() {
    guard state.isActive else { return }
    guard settings.isProviderConfigured else {
      SettingsWindowController.shared.show(panel: .aiProvider)
      return
    }
    autoTrigger.noteManualAsk()
    AssistantService.shared.ask(trigger: .manual)
  }

  func clearTranscript() {
    AssistantService.shared.stop()
    autoTrigger.reset()
    state.clearTranscript()
  }

  /// Pausing releases the microphone and system-audio capture entirely.
  func togglePause() {
    guard state.status == .running, let transcriber else { return }
    if state.isPaused {
      state.isPaused = false
      for source in state.activeSources {
        observeCapture(beginCapture(source, into: transcriber, sessionID: state.sessionID), source: source)
      }
    } else {
      state.isPaused = true
      autoTrigger.reset()
      captureCoordinator.stopAll()
      state.levels = [:]
      Task { await transcriber.flush() }
    }
  }

  // MARK: - Devices & Sources (session-only; Settings hold the defaults)

  /// Switch microphones mid-session. Capture is stopped before the device changes,
  /// because swapping the device under a running tap leaves a stale format converter.
  func selectMicrophone(_ deviceID: AudioDeviceID?) {
    guard state.status == .running else { return }
    let isCapturing = state.status == .running && !state.isPaused && state.activeSources.contains(.microphone)
    if isCapturing { captureCoordinator.stop(.microphone) }
    AudioCaptureManager.shared.selectInputDevice(deviceID)
    AudioDeviceMonitor.shared.refresh()
    guard isCapturing, let transcriber else { return }
    observeCapture(beginCapture(.microphone, into: transcriber, sessionID: state.sessionID), source: .microphone)
  }

  /// Turn one source on or off for the current session.
  func setSource(_ source: AudioSource, enabled: Bool) {
    guard state.status == .running, let transcriber else { return }
    guard state.activeSources.contains(source) != enabled else { return }
    state.setSource(source, active: enabled)
    guard !state.isPaused else { return }

    if enabled {
      observeCapture(beginCapture(source, into: transcriber, sessionID: state.sessionID), source: source)
    } else {
      captureCoordinator.stop(source)
      Task { await transcriber.flush(source: source) }
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

  private func checkSession(_ sessionID: String) throws {
    try Task.checkCancellation()
    guard state.sessionID == sessionID, state.isActive else { throw CancellationError() }
  }

  private func startCapture(sources: Set<AudioSource>, into transcriber: LiveTranscriber, sessionID: String) async throws {
    for source in AudioSource.allCases where sources.contains(source) {
      try checkSession(sessionID)
      try await beginCapture(source, into: transcriber, sessionID: sessionID).value
    }
  }

  private func beginCapture(_ source: AudioSource, into transcriber: LiveTranscriber, sessionID: String) -> Task<Void, Error> {
    captureCoordinator.start(source) {
      try self.checkSession(sessionID)
      guard !self.state.isPaused, self.state.activeSources.contains(source) else { throw CancellationError() }
      await transcriber.startSource(source)
      try self.checkSession(sessionID)

      // ~10s of headroom; oldest audio is dropped only if the pipeline stalls badly.
      let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(500))
      self.sampleContinuations[source] = continuation
      self.ingestTasks[source] = Task.detached(priority: .userInitiated) {
        for await samples in stream {
          await transcriber.ingest(samples, from: source)
        }
      }

      let onSamples: @Sendable ([Float]) -> Void = { continuation.yield($0) }
      switch source {
      case .microphone:
        try await AudioCaptureManager.shared.startStreaming(onSamples: onSamples)
      case .systemAudio:
        try await SystemAudioCaptureManager.shared.startStreaming(onSamples: onSamples)
      }
    }
  }

  private func observeCapture(_ task: Task<Void, Error>, source: AudioSource) {
    let sessionID = state.sessionID
    let generation = captureCoordinator.generations[source]
    Task {
      do {
        try await task.value
      } catch is CancellationError {
        return
      } catch {
        guard state.sessionID == sessionID, state.isActive,
              captureCoordinator.generations[source] == generation else { return }
        logger.error("Could not start \(source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        state.setSource(source, active: false)
      }
    }
  }

  private func stopCapture(_ source: AudioSource) {
    switch source {
    case .microphone: AudioCaptureManager.shared.stopStreaming()
    case .systemAudio: SystemAudioCaptureManager.shared.stopStreaming()
    }
    sampleContinuations.removeValue(forKey: source)?.finish()
    let ingest = ingestTasks.removeValue(forKey: source)
    if !isEndingSession { ingest?.cancel() }
    state.levels[source] = nil
  }

  private func startLevelPolling(_ transcriber: LiveTranscriber) {
    levelTask?.cancel()
    let sessionID = state.sessionID
    levelTask = Task { [state] in
      while !Task.isCancelled {
        if !state.isPaused {
          for source in state.activeSources {
            let level = await transcriber.level(for: source)
            guard !Task.isCancelled, state.sessionID == sessionID else { return }
            if !state.isPaused, state.activeSources.contains(source) { state.levels[source] = level }
          }
        }
        try? await Task.sleep(for: .milliseconds(80))
      }
    }
  }

  private func fail(_ error: Error) {
    let sessionID = state.sessionID
    logger.error("Always-On failed: \(error.localizedDescription, privacy: .public)")
    AssistantService.shared.stop()
    autoTrigger.reset()
    teardown()
    historyStore.endSession(id: sessionID, endedAt: Date(), cleanly: false)
    state.end()
    state.status = .failed(error.localizedDescription)
  }

  private func teardown() {
    let pendingIngest = Array(ingestTasks.values)
    isEndingSession = true
    captureCoordinator.stopAll()
    isEndingSession = false
    sessionTask?.cancel()
    sessionTask = nil
    levelTask?.cancel()
    levelTask = nil
    // Its captured transcript is session-specific; let it persist the tail finals.
    let pendingUpdates = updatesTask
    updatesTask = nil
    if let transcriber {
      let previous = finalizationTask
      finalizationTask = Task {
        await previous?.value
        for ingest in pendingIngest { await ingest.value }
        await transcriber.finish()
        await pendingUpdates?.value
      }
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
    if let previous = settings.previousAnswerShortcut {
      shortcuts.append(.init(shortcut: previous) {
        guard AlwaysOnController.shared.isActive else { return false }
        AlwaysOnState.shared.showAnswer(offset: -1)
        return true
      })
    }
    if let next = settings.nextAnswerShortcut {
      shortcuts.append(.init(shortcut: next) {
        guard AlwaysOnController.shared.isActive else { return false }
        AlwaysOnState.shared.showAnswer(offset: 1)
        return true
      })
    }
    HotkeyManager.shared.shortcuts = shortcuts
  }
}
