//
//  QuickDictationController.swift
//  VoxNotch
//
//  Thin wiring layer: hotkey events → DictationStateMachine,
//  state changes → AppState / NotchManager side effects.
//

import AppKit
import Foundation
import os.log
import SwiftUI

/// Controller for Quick Dictation mode (hold-to-record, release to transcribe)
@MainActor
final class QuickDictationController {

    private let logger = Logger(subsystem: "com.voxnotch", category: "QuickDictationController")

    // MARK: - Types

    /// Callback for state changes
    typealias StateCallback = (DictationState) -> Void

    // MARK: - Properties

    static let shared = QuickDictationController()

    /// The state machine that owns the dictation state, session ID, timers, and pipeline.
    let stateMachine: DictationStateMachine

    /// Callback for state changes
    var onStateChange: StateCallback?

    /// Whether dictation is currently active
    var isActive: Bool { stateMachine.state.isActive }

    /// Current dictation state (read-only, delegates to state machine)
    var state: DictationState { stateMachine.state }

    // Dependencies
    private let hotkeyManager: HotkeyManager
    private let audioManager: AudioRecording
    private let systemAudioManager: AudioRecording
    private let appState: AppState
    private let notchPresenter: NotchPresenting
    private let soundManager: SoundManager
    private let settings: SettingsManager
    private let errorRouter: ErrorRouter

    /// The frontmost application when the user pressed the hotkey.
    /// Captured before the notch panel appears so AX queries target the correct app.
    private var savedFrontmostApp: NSRunningApplication?

    /// Audio source for the current/next recording. Set by hotkey handlers
    /// before calling `startRecording()` and read by the state machine.
    private var pendingAudioSource: AudioSource = .microphone

    /// Cooldown after a cancel before accepting a new recording (prevents frame drops on rapid presses)
    private let cancelCooldown: TimeInterval = 0.3

    // MARK: - Initialization

    init(
        hotkeyManager: HotkeyManager = .shared,
        audioManager: AudioRecording = AudioCaptureManager.shared,
        systemAudioManager: AudioRecording = SystemAudioCaptureManager.shared,
        textOutputManager: TextOutputting = TextOutputManager.shared,
        transcriptionEngine: TranscriptionEngine = TranscriptionService.shared,
        llmProcessor: LLMProcessing = LLMService.shared,
        appState: AppState = .shared,
        notchPresenter: NotchPresenting = NotchManager.shared,
        soundManager: SoundManager = .shared,
        settings: SettingsManager = .shared,
        errorRouter: ErrorRouter? = nil
    ) {
        self.hotkeyManager = hotkeyManager
        self.audioManager = audioManager
        self.systemAudioManager = systemAudioManager
        self.appState = appState
        self.notchPresenter = notchPresenter
        self.soundManager = soundManager
        self.settings = settings
        self.errorRouter = errorRouter ?? ErrorRouter()

        // State machine owns the pipeline dependencies
        self.stateMachine = DictationStateMachine(
            audioManager: audioManager,
            systemAudioManager: systemAudioManager,
            transcriptionEngine: transcriptionEngine,
            llmProcessor: llmProcessor,
            textOutputManager: textOutputManager,
            settings: settings
        )

        stateMachine.delegate = self

        // Wire state machine callbacks
        stateMachine.onRecordingDurationTick = { [weak self] elapsed in
            self?.appState.recordingDuration = elapsed
        }
        stateMachine.onWatchdogFired = { [weak self] in
            self?.logger.warning("Watchdog triggered - force resetting stuck recording state")
            self?.cancelCurrentSession()
        }
        stateMachine.onPipelineOutputSuccess = { [weak self] result in
            self?.appState.error.lastAudioURL = nil
            self?.appState.lastOutputResult = result
            self?.notchPresenter.showOutputResult(result)
            self?.soundManager.playSuccessSound()
        }
        stateMachine.onPipelineCancelled = { [weak self] in
            self?.notchPresenter.hide()
        }
        stateMachine.onLLMWarning = { [weak self] message in
            self?.errorRouter.reportWarning(message)
        }
        stateMachine.onPipelineErrorWithAudio = { [weak self] audioURL in
            self?.appState.error.lastAudioURL = audioURL
        }

        setupHotkeyHandler()
        setupModelSwitchHandler()
        setupToneSwitchHandler()
        setupSilenceDetection()
        setupEscapeHandler()
    }

    // MARK: - Setup

    private func setupHotkeyHandler() {
        hotkeyManager.onHotkeyEvent = { [weak self] event in
            self?.logger.debug("Received hotkey event: \(String(describing: event))")
            switch event {
            case .keyDown:
                self?.pendingAudioSource = .microphone
                self?.startRecording()
            case .keyUp:
                if case .modelSelecting = self?.stateMachine.state {
                    self?.confirmModelSelection()
                } else if case .toneSelecting = self?.stateMachine.state {
                    self?.confirmToneSelection()
                } else {
                    self?.stateMachine.stopRecordingAndTranscribe(savedFrontmostApp: self?.savedFrontmostApp)
                }
            }
        }

        hotkeyManager.onSecondaryHotkeyEvent = { [weak self] event in
            self?.logger.debug("Received system-audio hotkey event: \(String(describing: event))")
            switch event {
            case .keyDown:
                self?.pendingAudioSource = .systemAudio
                self?.startRecording()
            case .keyUp:
                self?.stateMachine.stopRecordingAndTranscribe(savedFrontmostApp: self?.savedFrontmostApp)
            }
        }
    }

    private func setupModelSwitchHandler() {
        hotkeyManager.onModelSwitchKey = { [weak self] direction in
            self?.handleModelSwitchRequest(direction: direction)
        }
    }

    private func setupToneSwitchHandler() {
        hotkeyManager.onToneSwitchKey = { [weak self] direction in
            self?.handleToneSwitchRequest(direction: direction)
        }
    }

    private func setupEscapeHandler() {
        hotkeyManager.onEscapeKey = { [weak self] in
            guard let self else { return }
            guard self.isActive else { return }
            self.cancelCurrentSession()
        }
    }

    private func setupSilenceDetection() {
        let onWarning: () -> Void = { [weak self] in
            guard let self = self,
                  case .recording = self.stateMachine.state
            else { return }
            self.appState.silenceWarningActive = true
        }
        let onThreshold: () -> Void = { [weak self] in
            guard let self = self,
                  case .recording = self.stateMachine.state
            else { return }
            self.appState.silenceWarningActive = false
            self.stateMachine.stopRecordingAndTranscribe(savedFrontmostApp: self.savedFrontmostApp)
        }

        audioManager.onSilenceWarning = onWarning
        audioManager.onSilenceThresholdReached = onThreshold
        systemAudioManager.onSilenceWarning = onWarning
        systemAudioManager.onSilenceThresholdReached = onThreshold
    }

    /// Timer for retrying hotkey listener after permission is granted
    private var permissionCheckTimer: Timer?

    /// Start the Quick Dictation controller
    func start() {
        if !AudioCaptureManager.shared.hasMicrophonePermission {
            AudioCaptureManager.shared.requestMicrophonePermission { _ in }
        }
        if hotkeyManager.startListening() {
            logger.info("Hotkey listener started")
        } else {
            logger.info("Waiting for accessibility permission...")
        }
        startPermissionCheck()
    }

    private func startPermissionCheck() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            if self.hotkeyManager.hasAccessibilityPermission {
                if !self.hotkeyManager.isListening && self.hotkeyManager.startListening() {
                    self.logger.info("Hotkey listener started after permission granted")
                }
            } else {
                self.hotkeyManager.stopListening()
            }
        }
    }

    /// Stop the Quick Dictation controller
    func stop() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        hotkeyManager.stopListening()
        stateMachine.cancelPipeline()
    }

    // MARK: - Click-to-Dictate

    func toggleDictation() {
        switch stateMachine.state {
        case .idle, .error, .modelSelecting, .toneSelecting:
            startRecording()
        case .recording:
            stateMachine.stopRecordingAndTranscribe(savedFrontmostApp: savedFrontmostApp)
        case .warmingUp, .transcribing, .processingLLM, .outputting:
            break
        }
    }

    // MARK: - Recording Flow (Pre-flight Checks Only)

    private func startRecording() {
        logger.debug("startRecording called, state: \(String(describing: self.stateMachine.state))")

        if case .recording = stateMachine.state { return }

        // Cooldown after a recent cancel
        if let lastCancel = stateMachine.lastCancelTime,
           Date().timeIntervalSince(lastCancel) < cancelCooldown {
            logger.debug("Ignoring startRecording during cooldown")
            return
        }

        // Retry redirect
        if appState.error.canRetryTranscription {
            retryTranscription()
            return
        }

        // Clear stale transient flags
        errorRouter.clear()
        appState.error.clearLLMWarning()
        appState.error.lastAudioURL = nil
        appState.modelDownload.modelsNeeded = false
        notchPresenter.clearTransient()

        // Cancel if busy
        if case .warmingUp = stateMachine.state {
            cancelCurrentSession()
        } else if case .transcribing = stateMachine.state {
            cancelCurrentSession()
        } else if case .processingLLM = stateMachine.state {
            cancelCurrentSession()
        } else if case .outputting = stateMachine.state {
            cancelCurrentSession()
        } else if case .error = stateMachine.state {
            cancelCurrentSession()
        }

        stateMachine.transition(to: .idle)

        // Model download pre-check
        let speechModelID = settings.speechModel
        let (builtinModel, customModel) = SpeechModel.resolve(speechModelID)
        let isModelDownloaded: Bool
        let modelDisplayName: String
        if let builtin = builtinModel {
            isModelDownloaded = builtin.isDownloaded
            modelDisplayName = builtin.displayName
        } else if let custom = customModel {
            isModelDownloaded = MLXAudioModelManager.shared.isCustomModelOnDisk(custom)
            modelDisplayName = custom.displayName
        } else {
            isModelDownloaded = false
            modelDisplayName = "Unknown"
        }
        if !isModelDownloaded {
            logger.info("Model not downloaded, directing to Settings")
            let message: String
            if settings.onboardingModelState == .skipped {
                message = "Download a speech model in Settings to start dictating"
            } else {
                message = "Not downloaded: \(modelDisplayName)"
            }
            withAnimation(.smooth(duration: 0.4)) {
                appState.modelDownload.modelsNeeded = true
                appState.modelDownload.modelsNeededMessage = message
            }
            notchPresenter.showModelsNeeded(appState.modelDownload.modelsNeededMessage)
            return
        }

        // Permission pre-check varies by audio source.
        switch pendingAudioSource {
        case .microphone:
            guard AudioCaptureManager.shared.hasMicrophonePermission else {
                logger.info("No mic permission, requesting...")
                AudioCaptureManager.shared.requestMicrophonePermission { [weak self] granted in
                    self?.logger.info("Mic permission result: \(granted)")
                    if granted { self?.startRecording() }
                }
                return
            }
        case .systemAudio:
            guard SystemAudioCaptureManager.shared.hasScreenRecordingPermission else {
                logger.info("No screen recording permission, prompting and opening System Settings")
                // First call shows the OS prompt; subsequent calls (after denial)
                // silently return false. Either way, also open System Settings so
                // the user has a clear path to grant permission later.
                _ = SystemAudioCaptureManager.shared.requestScreenRecordingPermission()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
                errorRouter.reportWarning("Enable Screen Recording for VoxNotch in System Settings, then press the hotkey again.")
                return
            }
        }

        logger.debug("Starting audio capture from \(String(describing: self.pendingAudioSource))...")

        savedFrontmostApp = NSWorkspace.shared.frontmostApplication
        appState.recordingDuration = 0

        let source = pendingAudioSource
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.stateMachine.beginRecording(audioSource: source)
                self.logger.debug("Audio capture started")
            } catch {
                self.logger.error("Failed to start audio capture: \(error.localizedDescription)")
                self.stateMachine.transition(to: .error(error))
            }
        }
    }

    // MARK: - Retry

    func retryTranscription() {
        guard let audioURL = appState.error.lastAudioURL else { return }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            appState.error.lastAudioURL = nil
            return
        }
        appState.error.reset()
        stateMachine.retryTranscription(audioURL: audioURL, savedFrontmostApp: savedFrontmostApp)
    }

    // MARK: - Session Management

    private func stopRecordingQuietly() {
        savedFrontmostApp = nil
        appState.recordingDuration = 0
        stateMachine.stopRecordingQuietly()
    }

    private func cancelCurrentSession() {
        logger.debug("Cancelling current session")
        savedFrontmostApp = nil
        stateMachine.cancelPipeline()
        notchPresenter.hide()
    }

    // MARK: - Tone Selection

    private func handleToneSwitchRequest(direction: Int) {
        if case .modelSelecting = stateMachine.state { return }
        if case .recording = stateMachine.state {
            stopRecordingQuietly()
        }
        if case .error = stateMachine.state {
            stateMachine.transition(to: .idle)
        }
        guard case .idle = stateMachine.state else {
            if case .toneSelecting = stateMachine.state {
                cycleToneSelection(direction: direction)
            }
            return
        }
        enterToneSelectionMode(direction: direction)
    }

    private func getPinnedTones() -> [ToneTemplate] {
        let ids = settings.pinnedToneIDs.isEmpty
            ? ["formal", "fixGrammar"]
            : settings.pinnedToneIDs
        let pinned = ids.compactMap { ToneRegistry.shared.tone(forID: $0) }
        if let noneTone = ToneRegistry.shared.tone(forID: "none") {
            return [noneTone] + pinned
        }
        return pinned
    }

    private func enterToneSelectionMode(direction: Int) {
        let candidates = getPinnedTones()
        appState.toneSelection.candidates = candidates
        appState.toneSelection.index = 0
        stateMachine.transition(to: .toneSelecting)
    }

    private func cycleToneSelection(direction: Int) {
        let total = appState.toneSelection.candidates.count + 1
        let current = appState.toneSelection.index
        appState.toneSelection.index = ((current + direction) + total) % total
    }

    private func confirmToneSelection() {
        appState.modelDownload.modelsNeeded = false
        notchPresenter.clearTransient()

        let index = appState.toneSelection.index
        let candidates = appState.toneSelection.candidates

        if index >= candidates.count {
            appState.navigateToSettingsPanel = SettingsPanel.ai.rawValue
            SettingsWindowController.shared.showNavigatingToAIEnhancement()
            stateMachine.transition(to: .idle)
            notchPresenter.hide()
        } else {
            let selected = candidates[index]
            settings.activeToneID = selected.id
            logger.info("Tone switched to \(selected.displayName)")
            notchPresenter.showConfirmation(selected.displayName)
            stateMachine.transition(to: .idle)
        }
    }

    // MARK: - Model Selection

    private func handleModelSwitchRequest(direction: Int) {
        if case .toneSelecting = stateMachine.state { return }
        if case .recording = stateMachine.state {
            stopRecordingQuietly()
        }
        if case .error = stateMachine.state {
            stateMachine.transition(to: .idle)
        }
        guard case .idle = stateMachine.state else {
            if case .modelSelecting = stateMachine.state {
                cycleModelSelection(direction: direction)
            }
            return
        }
        enterModelSelectionMode(direction: direction)
    }

    private func getPinnedModels() -> [AnyModel] {
        let ids = settings.pinnedModelIDs.isEmpty
            ? Array(SpeechModel.allCases.prefix(3)).map(\.rawValue)
            : settings.pinnedModelIDs
        return ids.compactMap { id -> AnyModel? in
            if let builtin = SpeechModel(rawValue: id) { return .builtin(builtin) }
            if let custom = CustomModelRegistry.shared.model(withID: id) { return .custom(custom) }
            return nil
        }
    }

    private func enterModelSelectionMode(direction: Int) {
        let candidates = getPinnedModels()
        appState.modelSelection.candidates = candidates
        appState.modelSelection.index = 0
        stateMachine.transition(to: .modelSelecting)
    }

    private func cycleModelSelection(direction: Int) {
        let total = appState.modelSelection.candidates.count + 1
        let current = appState.modelSelection.index
        appState.modelSelection.index = ((current + direction) + total) % total
    }

    private func confirmModelSelection() {
        appState.modelDownload.modelsNeeded = false
        notchPresenter.clearTransient()

        let index = appState.modelSelection.index
        let candidates = appState.modelSelection.candidates

        if index >= candidates.count {
            appState.navigateToSettingsPanel = SettingsPanel.speechModel.rawValue
            SettingsWindowController.shared.showNavigatingToSpeechModel()
            stateMachine.transition(to: .idle)
            notchPresenter.hide()
        } else {
            let selected = candidates[index]
            settings.speechModel = selected.settingsID
            stateMachine.reconfigureTranscription()
            logger.info("Model switched to \(selected.displayName)")

            if selected.isDownloaded {
                notchPresenter.showConfirmation(selected.displayName)
            } else {
                withAnimation(.smooth(duration: 0.4)) {
                    appState.modelDownload.modelsNeeded = true
                    appState.modelDownload.modelsNeededMessage = "Not downloaded: \(selected.displayName)"
                }
                notchPresenter.showModelsNeeded(appState.modelDownload.modelsNeededMessage)
            }
            stateMachine.transition(to: .idle)
        }
    }
}

// MARK: - DictationStateMachineDelegate

extension QuickDictationController: DictationStateMachineDelegate {

    func stateMachine(
        _ stateMachine: DictationStateMachine,
        didTransitionFrom oldState: DictationState,
        to newState: DictationState
    ) {
        // Reset recording duration when leaving recording
        if case .recording = newState {} else {
            appState.recordingDuration = 0
        }

        // Update app state — wrapped in withAnimation so dictationPhase
        // transitions in the notch get smooth crossfade.
        withAnimation(.smooth(duration: 0.4)) {
            appState.dictationPhase = newState
            appState.silenceWarningActive = false

            if case .error(let error) = newState {
                errorRouter.report(error)
            }
        }

        // NotchManager calls outside withAnimation (they do their own async work)
        switch newState {
        case .recording:      notchPresenter.showRecording()
        case .warmingUp:      notchPresenter.showTranscribing()
        case .transcribing:   notchPresenter.showTranscribing()
        case .processingLLM:  notchPresenter.showProcessingLLM()
        case .modelSelecting: notchPresenter.showModelSelector()
        case .toneSelecting:  notchPresenter.showToneSelector()
        case .error(let e):   notchPresenter.showError(e.localizedDescription)
        default: break
        }

        onStateChange?(newState)
    }
}
