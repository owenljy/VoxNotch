//
//  DictationStateMachine.swift
//  VoxNotch
//
//  Owns the dictation state, session lifecycle, timer management, and
//  pipeline orchestration (record → transcribe → LLM → output → history).
//  The controller wires events here and translates callbacks into UI side effects.
//

import AppKit
import Foundation
import GRDB
import NaturalLanguage
import os.log

// MARK: - Output Result

/// Describes how text output was delivered to the user.
enum OutputResult: Equatable {
    /// Text was successfully inserted into the focused field.
    case inserted
    /// No focused text field was detected — text copied to clipboard only.
    case clipboard
    /// App switched mid-output — partial text typed, full text on clipboard.
    case clipboardAborted
}

// MARK: - Delegate

/// Notified on every state transition so the controller can sync AppState / UI.
@MainActor protocol DictationStateMachineDelegate: AnyObject {
    func stateMachine(
        _ stateMachine: DictationStateMachine,
        didTransitionFrom oldState: DictationState,
        to newState: DictationState
    )
}

// MARK: - State Machine

@MainActor
final class DictationStateMachine {

    private let logger = Logger(subsystem: "com.voxnotch", category: "DictationStateMachine")

    // MARK: - State Properties

    /// Current dictation state.
    private(set) var state: DictationState = .idle

    /// Session ID — incremented on cancel so in-flight async tasks know to discard.
    private(set) var currentSessionID = UUID()

    /// Recording start time.
    var recordingStartTime: Date?

    /// Timestamp of last cancel — used for cooldown between rapid presses.
    var lastCancelTime: Date?

    /// Minimum recording duration to avoid accidental taps and phantom words.
    let minimumRecordingDuration: TimeInterval = 0.5

    /// Delegate receives every state transition.
    weak var delegate: DictationStateMachineDelegate?

    // MARK: - Dependencies

    private let micAudioManager: AudioRecording
    private let systemAudioManager: AudioRecording
    /// The audio manager driving the current recording session.
    /// Set at `beginRecording(audioSource:)` time and used through stop/cancel/cleanup.
    private var audioManager: AudioRecording
    private let transcriptionEngine: TranscriptionEngine
    private let llmProcessor: LLMProcessing
    private let textOutputManager: TextOutputting
    private let settings: SettingsManager
    private let databaseManager: DatabaseManager
    private let toneRegistry: ToneRegistry
    private let clock: AppClock

    // MARK: - Timers

    private var pipelineTask: Task<Void, Never>?

    private var watchdogTimer: ClockTimer?
    private var durationTimer: ClockTimer?

    // MARK: - Callbacks

    /// Fired every second while recording, providing elapsed time.
    var onRecordingDurationTick: ((TimeInterval) -> Void)?

    /// Fired when the watchdog triggers (stuck recording).
    var onWatchdogFired: (() -> Void)?

    /// Fired after successful text output with the delivery method.
    var onPipelineOutputSuccess: ((_ result: OutputResult) -> Void)?

    /// Fired when the pipeline is cancelled (too short, etc.) so the controller can hide UI.
    var onPipelineCancelled: (() -> Void)?

    /// Fired when LLM fails but transcription succeeded (non-blocking warning).
    var onLLMWarning: ((_ message: String) -> Void)?

    /// Fired before .error transition when audio is preserved for retry.
    var onPipelineErrorWithAudio: ((_ audioURL: URL) -> Void)?

    // MARK: - Initialization

    init(
        audioManager: AudioRecording = AudioCaptureManager.shared,
        systemAudioManager: AudioRecording = SystemAudioCaptureManager.shared,
        transcriptionEngine: TranscriptionEngine = TranscriptionService.shared,
        llmProcessor: LLMProcessing = LLMService.shared,
        textOutputManager: TextOutputting = TextOutputManager.shared,
        settings: SettingsManager = .shared,
        databaseManager: DatabaseManager = .shared,
        toneRegistry: ToneRegistry = .shared,
        clock: AppClock? = nil
    ) {
        self.micAudioManager = audioManager
        self.systemAudioManager = systemAudioManager
        self.audioManager = audioManager
        self.transcriptionEngine = transcriptionEngine
        self.llmProcessor = llmProcessor
        self.textOutputManager = textOutputManager
        self.settings = settings
        self.databaseManager = databaseManager
        self.toneRegistry = toneRegistry
        self.clock = clock ?? SystemClock()
    }

    // MARK: - State Transitions

    /// Transition to a new state. Manages timers and notifies the delegate.
    func transition(to newState: DictationState) {
        let oldState = state
        assert(
            Self.isValidTransition(from: oldState, to: newState),
            "Invalid state transition: \(oldState) → \(newState)"
        )
        state = newState

        // Duration timer: only runs during .recording
        if case .recording = newState {} else {
            stopDurationTimer()
        }

        // Watchdog timer: start on recording, stop on anything else
        stopWatchdog()
        if case .recording = newState {
            startWatchdog()
        }

        delegate?.stateMachine(self, didTransitionFrom: oldState, to: newState)
    }

    /// Valid transitions per the dictation flow graph.
    ///
    ///     idle → idle | recording | modelSelecting | toneSelecting | warmingUp
    ///     recording → warmingUp | transcribing | idle | error
    ///     warmingUp → transcribing | idle | error
    ///     transcribing → processingLLM | outputting | idle | error
    ///     processingLLM → outputting | idle
    ///     outputting → idle | error
    ///     modelSelecting → idle | toneSelecting
    ///     toneSelecting → idle | modelSelecting
    ///     error → idle | warmingUp
    ///
    private static func isValidTransition(from oldState: DictationState, to newState: DictationState) -> Bool {
        switch oldState {
        case .idle:
            switch newState {
            case .idle, .recording, .modelSelecting, .toneSelecting, .warmingUp:
                return true
            default:
                return false
            }
        case .recording:
            switch newState {
            case .warmingUp, .transcribing, .idle, .error:
                return true
            default:
                return false
            }
        case .warmingUp:
            switch newState {
            case .transcribing, .idle, .error:
                return true
            default:
                return false
            }
        case .transcribing:
            switch newState {
            case .processingLLM, .outputting, .idle, .error:
                return true
            default:
                return false
            }
        case .processingLLM:
            switch newState {
            case .outputting, .idle:
                return true
            default:
                return false
            }
        case .outputting:
            switch newState {
            case .idle, .error:
                return true
            default:
                return false
            }
        case .modelSelecting:
            switch newState {
            case .idle, .toneSelecting:
                return true
            default:
                return false
            }
        case .toneSelecting:
            switch newState {
            case .idle, .modelSelecting:
                return true
            default:
                return false
            }
        case .error:
            switch newState {
            case .idle, .warmingUp:
                return true
            default:
                return false
            }
        }
    }

    /// Invalidate the current session (cancel in-flight work).
    @discardableResult
    func invalidateSession() -> UUID {
        pipelineTask?.cancel()
        pipelineTask = nil
        transcriptionEngine.cancelStreaming()
        audioManager.onResampledAudioSamples = nil
        let newID = UUID()
        currentSessionID = newID
        return newID
    }

    /// Check whether a captured session ID still matches the current session.
    func isSessionValid(_ sessionID: UUID) -> Bool {
        return sessionID == currentSessionID && !Task.isCancelled
    }

    // MARK: - Pipeline: Begin Recording

    /// Begin audio capture from the chosen source. Called by the controller
    /// after pre-flight checks (permission, model availability) pass.
    /// The selected manager is retained for the duration of the session so that
    /// stop/cancel/cleanup all target the same source.
    func beginRecording(audioSource: AudioSource = .microphone) async throws {
        invalidateSession()
        let manager: AudioRecording = (audioSource == .systemAudio) ? systemAudioManager : micAudioManager
        audioManager = manager
        textOutputManager.captureTarget()

        transition(to: .recording)
        recordingStartTime = clock.now()
        startDurationTimer()

        let sink = transcriptionEngine.beginStreaming()
        manager.onResampledAudioSamples = sink
        manager.accumulateBuffers = true
        do {
            try await manager.startRecording()
        } catch {
            transcriptionEngine.cancelStreaming()
            manager.onResampledAudioSamples = nil
            throw error
        }
        transcriptionEngine.preloadModel()
    }

    // MARK: - Pipeline: Stop Recording & Transcribe

    /// Stop recording and run the full pipeline: transcribe → LLM → output → history.
    func stopRecordingAndTranscribe(savedFrontmostApp: NSRunningApplication?) {
        guard case .recording = state else { return }

        // Check minimum duration
        let duration = recordingStartTime.map { clock.now().timeIntervalSince($0) } ?? 0
        if duration < minimumRecordingDuration {
            cancelPipeline()
            onPipelineCancelled?()
            return
        }

        // Stop audio capture
        let captureResult: AudioCaptureManager.CaptureResult
        do {
            captureResult = try audioManager.stopRecording()
        } catch {
            transcriptionEngine.cancelStreaming()
            audioManager.onResampledAudioSamples = nil
            audioManager.cancelRecording()
            transition(to: .error(error))
            return
        }

        let capturedSessionID = currentSessionID

        let recordingManager = audioManager
        recordingManager.onResampledAudioSamples = nil
        pipelineTask = Task {
            var shouldCleanupAudio = true
            defer {
                if shouldCleanupAudio {
                    recordingManager.cleanupFile(at: captureResult.fileURL)
                }
            }

            do {
                // Check model ready → warmingUp or transcribing
                let isReady = await transcriptionEngine.isReady
                guard isSessionValid(capturedSessionID) else { return }
                await MainActor.run {
                    transition(to: isReady ? .transcribing : .warmingUp)
                }

                try await transcriptionEngine.ensureModelReady()
                guard isSessionValid(capturedSessionID) else { return }

                if !isReady {
                    await MainActor.run { transition(to: .transcribing) }
                }

                // Transcribe
                let result = try await transcriptionEngine.finishStreaming(audioURL: captureResult.fileURL, language: nil)
                guard isSessionValid(capturedSessionID) else { return }

                // Post-process text
                let text: String = {
                    let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let filtered = settings.removeFillerWords ? FillerWordFilter.clean(raw) : raw
                    return settings.applyITN ? NemoTextProcessing.normalizeSentence(filtered) : filtered
                }()

                // Empty rejection
                if text.isEmpty {
                    await MainActor.run { transition(to: .idle) }
                    return
                }

                // Low-confidence rejection
                if let confidence = result.confidence, confidence < 0.45 {
                    await MainActor.run { transition(to: .idle) }
                    return
                }

                // LLM processing
                await MainActor.run { transition(to: .processingLLM) }
                guard isSessionValid(capturedSessionID) else { return }

                let finalText: String
                if llmProcessor.isEnabled {
                    let effectiveLanguage: String? = {
                        if settings.transcriptionLanguage != "auto" {
                            return settings.transcriptionLanguage
                        }
                        if let lang = result.language { return lang }
                        // Fallback: detect language from the transcribed text
                        return Self.detectLanguage(of: text)
                    }()
                    let llmResult = await llmProcessor.processWithResult(text: text, language: effectiveLanguage)
                    guard isSessionValid(capturedSessionID) else { return }
                    finalText = llmResult.text
                    if case .fallback(_, let error) = llmResult {
                        await MainActor.run { onLLMWarning?(error.localizedDescription) }
                    }
                } else {
                    finalText = text
                }

                guard isSessionValid(capturedSessionID) else { return }

                // History save (non-blocking)
                saveToHistory(
                    rawText: text,
                    finalText: finalText,
                    captureResult: captureResult,
                    transcriptionResult: result,
                    savedFrontmostApp: savedFrontmostApp
                )

                // Output text
                await outputText(finalText, savedFrontmostApp: savedFrontmostApp, sessionID: capturedSessionID)

            } catch {
                guard isSessionValid(capturedSessionID) else { return }
                transcriptionEngine.cancelStreaming()
                shouldCleanupAudio = false
                await MainActor.run {
                    onPipelineErrorWithAudio?(captureResult.fileURL)
                    transition(to: .error(error))
                }
            }
        }
    }

    // MARK: - Pipeline: Retry Transcription

    /// Retry transcription using a previously saved audio file. Skips LLM.
    func retryTranscription(audioURL: URL, savedFrontmostApp: NSRunningApplication?) {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }

        let capturedSessionID = currentSessionID

        pipelineTask = Task {
            do {
                guard isSessionValid(capturedSessionID) else { return }
                await MainActor.run { transition(to: .warmingUp) }
                try await transcriptionEngine.ensureModelReady()
                guard isSessionValid(capturedSessionID) else { return }

                await MainActor.run { transition(to: .transcribing) }
                let result = try await transcriptionEngine.transcribe(audioURL: audioURL, language: nil)
                guard isSessionValid(capturedSessionID) else { return }

                let text = result.text
                guard !text.isEmpty else {
                    await MainActor.run { transition(to: .error(TranscriptionError.noSpeechDetected)) }
                    return
                }

                audioManager.cleanupFile(at: audioURL)
                await outputText(text, savedFrontmostApp: savedFrontmostApp, sessionID: capturedSessionID)

            } catch {
                guard isSessionValid(capturedSessionID) else { return }
                await MainActor.run { transition(to: .error(error)) }
            }
        }
    }

    // MARK: - Pipeline: Output Text

    private func outputText(_ text: String, savedFrontmostApp: NSRunningApplication?, sessionID: UUID) async {
        guard isSessionValid(sessionID) else { return }
        // Never redirect a completed recording into a different application.
        if !textOutputManager.isTargetCurrent(savedFrontmostApp) {
            transition(to: .outputting)
            textOutputManager.copyToClipboardOnly(text)
            onPipelineOutputSuccess?(.clipboardAborted)
            transition(to: .idle)
            return
        }
        let effectiveApp = savedFrontmostApp

        let hasFocusedInput = textOutputManager.hasFocusedTextInput(for: effectiveApp)

        await MainActor.run { transition(to: .outputting) }

        guard isSessionValid(sessionID) else { return }
        if !textOutputManager.isTargetCurrent(savedFrontmostApp) {
            textOutputManager.copyToClipboardOnly(text)
            onPipelineOutputSuccess?(.clipboardAborted)
            transition(to: .idle)
            return
        }
        if hasFocusedInput {
            do {
                try await textOutputManager.output(text)
                guard isSessionValid(sessionID) else { return }
                await MainActor.run {
                    onPipelineOutputSuccess?(.inserted)
                    transition(to: .idle)
                }
            } catch is CancellationError {
                return
            } catch let error as TextOutputManager.TextOutputError where error == .targetAppChanged {
                guard isSessionValid(sessionID) else { return }
                // App switched mid-keystroke — fall back to clipboard gracefully.
                textOutputManager.copyToClipboardOnly(text)
                await MainActor.run {
                    onPipelineOutputSuccess?(.clipboardAborted)
                    transition(to: .idle)
                }
            } catch {
                guard isSessionValid(sessionID) else { return }
                await MainActor.run { transition(to: .error(error)) }
            }
        } else {
            textOutputManager.copyToClipboardOnly(text)
            await MainActor.run {
                onPipelineOutputSuccess?(.clipboard)
                transition(to: .idle)
            }
        }
    }

    // MARK: - Language Detection

    /// Detect the dominant language of a text string using NLLanguageRecognizer.
    /// Returns an ISO 639 code (e.g. "zh", "ja") or nil if undetermined.
    private static func detectLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return nil }
        let code = lang.rawValue
        // Only return non-English languages; English is the default behavior
        return code == "en" ? nil : code
    }

    // MARK: - Pipeline: History Save

    private func saveToHistory(
        rawText: String,
        finalText: String,
        captureResult: AudioCaptureManager.CaptureResult,
        transcriptionResult: TranscriptionResult,
        savedFrontmostApp: NSRunningApplication?
    ) {
        guard settings.historyEnabled else { return }

        var audioPath: String? = nil
        if settings.saveAudioRecordings {
            let audioDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("VoxNotch/audio", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
                let dest = audioDir.appendingPathComponent("\(UUID().uuidString).wav")
                try FileManager.default.copyItem(at: captureResult.fileURL, to: dest)
                audioPath = dest.path
            } catch {
                logger.error("Failed to save audio recording: \(error.localizedDescription)")
            }
        }

        let toneID = settings.activeToneID
        let toneName = toneRegistry.tone(forID: toneID)?.displayName ?? toneID
        let hasFocusedInput = textOutputManager.hasFocusedTextInput(for: savedFrontmostApp)
        let metadataDict: [String: String] = [
            "tone": toneName,
            "outputMethod": hasFocusedInput ? "paste" : "clipboard",
        ]
        let metadataJSON: String?
        do {
            let data = try JSONEncoder().encode(metadataDict)
            metadataJSON = String(data: data, encoding: .utf8)
        } catch {
            logger.error("Failed to encode history metadata: \(error.localizedDescription)")
            metadataJSON = nil
        }

        let processedText = (finalText != rawText) ? finalText : nil
        var record = TranscriptionRecord(
            rawText: rawText,
            processedText: processedText,
            model: settings.speechModel,
            duration: captureResult.duration,
            confidence: transcriptionResult.confidence.map(Double.init),
            audioPath: audioPath,
            metadata: metadataJSON
        )
        Task {
            do {
                _ = try await databaseManager.write { db in
                    try record.insert(db)
                }
            } catch {
                logger.error("Failed to save history: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Session Management

    /// Cancel audio without hiding the notch. Used for model/tone selection during recording.
    func stopRecordingQuietly() {
        invalidateSession()
        audioManager.cancelRecording()
        stopDurationTimer()
        transition(to: .idle)
    }

    /// Cancel any active pipeline. Invalidates session, stops audio, transitions to idle.
    func cancelPipeline() {
        lastCancelTime = clock.now()
        invalidateSession()
        audioManager.cancelRecording()
        transition(to: .idle)
    }

    /// Passthrough to reconfigure the transcription engine (e.g., after model switch).
    func reconfigureTranscription() {
        transcriptionEngine.reconfigure()
    }

    // MARK: - Duration Timer

    /// Start the duration timer.
    func startDurationTimer() {
        stopDurationTimer()
        durationTimer = clock.scheduleTimer(interval: 1.0, repeats: true) { [weak self] in
            guard let self, let start = self.recordingStartTime else { return }
            self.onRecordingDurationTick?(self.clock.now().timeIntervalSince(start))
        }
    }

    /// Stop the duration timer.
    func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer = clock.scheduleTimer(interval: 180.0, repeats: false) { [weak self] in
            self?.onWatchdogFired?()
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }
}
