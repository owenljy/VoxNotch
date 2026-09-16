//
//  SystemAudioCaptureManager.swift
//  VoxNotch
//
//  System audio capture using ScreenCaptureKit for transcription
//

import Foundation
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import Accelerate
import os.log

/// Manages system audio capture via ScreenCaptureKit (SCStream)
final class SystemAudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {

    private let logger = Logger(subsystem: "com.voxnotch", category: "SystemAudioCaptureManager")

    // MARK: - Types

    enum SystemAudioCaptureError: LocalizedError {
        case screenRecordingPermissionDenied
        case streamStartFailed(Error)
        case noAudioRecorded
        case fileWriteFailed(Error)
        case noDisplayFound

        var errorDescription: String? {
            switch self {
            case .screenRecordingPermissionDenied:
                return "Screen Recording permission is required for system audio capture. Enable it in System Settings > Privacy & Security > Screen Recording."
            case .streamStartFailed(let error):
                return "Failed to start system audio capture: \(error.localizedDescription)"
            case .noAudioRecorded:
                return "No system audio was recorded"
            case .fileWriteFailed(let error):
                return "Failed to write audio file: \(error.localizedDescription)"
            case .noDisplayFound:
                return "No display found for audio capture"
            }
        }
    }

    // MARK: - Properties

    static let shared = SystemAudioCaptureManager()

    private var stream: SCStream?

    /// Buffer to accumulate recorded audio
    private var recordedBuffers: [AVAudioPCMBuffer] = []

    /// Whether we're currently recording
    private(set) var isRecording: Bool = false

    /// Always accumulates internally; the setter is a no-op kept for `AudioRecording` conformance.
    var accumulateBuffers: Bool = true

    /// Whether Screen Recording permission is currently granted.
    /// `CGPreflightScreenCaptureAccess` returns the status without prompting.
    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Trigger the macOS Screen Recording permission prompt. The system shows the prompt
    /// the first time; subsequent calls just return the current status.
    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Recording start time
    private var recordingStartTime: Date?

    /// Target sample rate for ASR pipeline
    private let targetSampleRate: Double = 16000

    /// Output format for resampled audio (16kHz mono Float32)
    private let resampledFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Resampling converter for producing 16kHz mono from SCStream output
    private var resamplingConverter: AVAudioConverter?

    /// Reusable output buffer for the resampling converter.
    private var reusableOutputBuffer: AVAudioPCMBuffer?

    /// Serial queue for audio buffer processing
    private let audioQueue = DispatchQueue(label: "com.voxnotch.systemaudio", qos: .userInteractive)

    // MARK: - Silence Detection

    private var silenceStartTime: Date?
    private var silenceWarningTriggered = false
    private var silenceWarningRatio: Double { 0.75 }

    /// Callback when silence warning threshold (75%) is reached
    var onSilenceWarning: (() -> Void)?

    /// Callback when silence duration threshold is exceeded (auto-stop)
    var onSilenceThresholdReached: (() -> Void)?

    // MARK: - Real-time Audio Streaming

    /// Callback for real-time audio samples at 16kHz
    var onAudioSamples: (([Float]) -> Void)?

    /// Callback for resampled 16kHz audio samples
    private let samplesCallbackLock = NSLock()
    private var samplesCallback: (@Sendable ([Float]) -> Void)?
    var onResampledAudioSamples: (@Sendable ([Float]) -> Void)? {
        get {
            samplesCallbackLock.lock()
            defer { samplesCallbackLock.unlock() }
            return samplesCallback
        }
        set {
            samplesCallbackLock.lock()
            samplesCallback = newValue
            samplesCallbackLock.unlock()
        }
    }

    // MARK: - Audio Level Visualization

    private var previousBands = [Float](repeating: 0, count: 6)
    private var lastAudioLevelUpdate = Date.distantPast

    /// FFT setup for frequency analysis
    private let fftLog2N: vDSP_Length = 10 // 2^10 = 1024
    private let fftSize = 1024
    private var fftSetup: FFTSetup?

    // Pre-allocated FFT working arrays
    private var fftInput = [Float](repeating: 0, count: 1024)
    private var fftWindow: [Float] = {
        var w = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&w, vDSP_Length(1024), Int32(vDSP_HANN_NORM))
        return w
    }()
    private var fftReal = [Float](repeating: 0, count: 512)
    private var fftImag = [Float](repeating: 0, count: 512)
    private var fftMagnitudes = [Float](repeating: 0, count: 512)

    // MARK: - Initialization

    private override init() {
        super.init()
    }

    // MARK: - Recording

    /// Start capturing system audio
    /// - Throws: SystemAudioCaptureError if capture cannot start
    func startRecording() async throws {
        if isRecording {
            logger.debug("Already recording, stopping previous stream")
            cancelRecording()
        }

        // Clear previous buffers — synchronize on audioQueue to drain any pending callbacks
        audioQueue.sync {
            self.recordedBuffers.removeAll()
            self.previousBands = [Float](repeating: 0, count: 6)
            self.silenceStartTime = nil
            self.silenceWarningTriggered = false
            self.resamplingConverter = nil
        }

        // Get shareable content (triggers permission prompt on first use)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            logger.error("Screen recording permission denied: \(error.localizedDescription)")
            throw SystemAudioCaptureError.screenRecordingPermissionDenied
        }

        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayFound
        }

        // Exclude VoxNotch from capture to prevent feedback
        let selfApp = content.applications.first {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let excludedApps = selfApp.map { [$0] } ?? []

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = 48000
        // Skip video frames — audio only
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: CMTimeValue(Int32.max), timescale: 1)

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        do {
            try await newStream.startCapture()
        } catch {
            logger.error("Failed to start capture: \(error.localizedDescription)")
            throw SystemAudioCaptureError.streamStartFailed(error)
        }

        stream = newStream
        isRecording = true
        recordingStartTime = Date()
        logger.info("Started recording system audio")
    }

    /// Stop recording and save to file
    /// - Returns: CaptureResult with file URL and metadata
    /// - Throws: SystemAudioCaptureError if recording cannot be saved
    func stopRecording() throws -> AudioCaptureManager.CaptureResult {
        guard isRecording else {
            throw SystemAudioCaptureError.noAudioRecorded
        }

        // Mark as not recording and drain audioQueue so no more callbacks touch recordedBuffers
        let capturedStream = stream
        stream = nil
        audioQueue.sync {
            self.isRecording = false
            self.resamplingConverter = nil
            self.reusableOutputBuffer = nil
        }

        // Fire-and-forget stream cleanup (safe — we already drained the queue above)
        Task {
            try? await capturedStream?.stopCapture()
        }

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        logger.info("Stopped recording, duration: \(duration)s")

        guard !recordedBuffers.isEmpty else {
            throw SystemAudioCaptureError.noAudioRecorded
        }

        let fileURL = try saveBuffersToFile()

        DispatchQueue.main.async {
            AudioVisualizationState.shared.audioLevel = 0
            AudioVisualizationState.shared.audioFrequencyBands = [Float](repeating: 0, count: 6)
        }
        previousBands = [Float](repeating: 0, count: 6)

        return AudioCaptureManager.CaptureResult(
            fileURL: fileURL,
            duration: duration,
            sampleRate: targetSampleRate
        )
    }

    /// Cancel recording without saving
    func cancelRecording() {
        guard isRecording else { return }

        let capturedStream = stream
        stream = nil

        // Drain audioQueue and clear state so no more callbacks touch shared state
        audioQueue.sync {
            self.isRecording = false
            self.recordedBuffers.removeAll()
            self.resamplingConverter = nil
            self.reusableOutputBuffer = nil
            self.previousBands = [Float](repeating: 0, count: 6)
            self.silenceStartTime = nil
            self.silenceWarningTriggered = false
        }

        Task {
            try? await capturedStream?.stopCapture()
        }

        DispatchQueue.main.async {
            AudioVisualizationState.shared.audioLevel = 0
            AudioVisualizationState.shared.audioFrequencyBands = [Float](repeating: 0, count: 6)
        }

        logger.info("Recording cancelled")
    }

    /// Clean up a recorded audio file
    func cleanupFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.warning("Failed to clean up file at \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRecording else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let pcmBuffer = sampleBuffer.asPCMBuffer(format: asbd.pointee) else { return }

        // Resample to 16kHz mono
        if resamplingConverter == nil {
            resamplingConverter = AVAudioConverter(from: pcmBuffer.format, to: resampledFormat)
        }

        guard let converter = resamplingConverter else { return }

        let ratio = targetSampleRate / pcmBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 1

        // Lazily create or grow the reusable output buffer
        if reusableOutputBuffer == nil || reusableOutputBuffer!.frameCapacity < outputFrameCapacity {
            reusableOutputBuffer = AVAudioPCMBuffer(pcmFormat: resampledFormat, frameCapacity: outputFrameCapacity)
        }
        guard let outputBuffer = reusableOutputBuffer else { return }
        outputBuffer.frameLength = 0

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard error == nil, frameCount > 0, let outputChannelData = outputBuffer.floatChannelData else { return }

        // Create resampledBuffer and copy directly from outputBuffer (skip Array intermediate)
        guard let resampledBuffer = AVAudioPCMBuffer(pcmFormat: resampledFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        resampledBuffer.frameLength = AVAudioFrameCount(frameCount)
        if let destChannelData = resampledBuffer.floatChannelData {
            destChannelData[0].update(from: outputChannelData[0], count: frameCount)
        }

        recordedBuffers.append(resampledBuffer)

        if let sink = self.onResampledAudioSamples {
            sink(Array(UnsafeBufferPointer(start: outputChannelData[0], count: frameCount)))
        }

        // Update audio level for visualization
        updateAudioLevel(buffer: resampledBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error: \(error.localizedDescription)")
        if isRecording {
            isRecording = false
            DispatchQueue.main.async {
                AudioVisualizationState.shared.audioLevel = 0
                AudioVisualizationState.shared.audioFrequencyBands = [Float](repeating: 0, count: 6)
            }
        }
    }

    // MARK: - File Writing

    private func saveBuffersToFile() throws -> URL {
        guard let firstBuffer = recordedBuffers.first else {
            throw SystemAudioCaptureError.noAudioRecorded
        }

        let inputFormat = firstBuffer.format
        let totalFrames = recordedBuffers.reduce(0) { $0 + Int($1.frameLength) }

        guard let combinedBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(totalFrames)
        ) else {
            throw SystemAudioCaptureError.noAudioRecorded
        }

        var offset: AVAudioFrameCount = 0
        for buffer in recordedBuffers {
            let frameCount = buffer.frameLength
            guard let srcData = buffer.floatChannelData,
                  let dstData = combinedBuffer.floatChannelData else { continue }

            for channel in 0..<Int(inputFormat.channelCount) {
                let src = srcData[channel]
                let dst = dstData[channel].advanced(by: Int(offset))
                dst.update(from: src, count: Int(frameCount))
            }
            offset += frameCount
        }
        combinedBuffer.frameLength = offset

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "voxnotch_sysaudio_\(UUID().uuidString).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            let audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: targetSampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            )
            try audioFile.write(from: combinedBuffer)
            logger.debug("Saved audio to \(fileURL.path)")
            return fileURL
        } catch {
            throw SystemAudioCaptureError.fileWriteFailed(error)
        }
    }

    // MARK: - Audio Level & Frequency Analysis

    private func updateAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(
            from: 0,
            to: Int(buffer.frameLength),
            by: buffer.stride
        ).map { channelDataValue[$0] }

        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
        let normalizedLevel = min(rms * 3, 1.0)

        let now = Date()
        if now.timeIntervalSince(lastAudioLevelUpdate) >= 1.0 / 60.0 {
            lastAudioLevelUpdate = now
            let sampleRate = buffer.format.sampleRate
            let bands = computeFrequencyBands(from: channelDataValueArray, sampleRate: sampleRate)
            DispatchQueue.main.async {
                AudioVisualizationState.shared.audioLevel = normalizedLevel
                AudioVisualizationState.shared.audioFrequencyBands = bands
            }
        }

        // Silence detection
        let settings = SettingsManager.shared

        guard settings.enableAutoStopOnSilence else {
            silenceStartTime = nil
            silenceWarningTriggered = false
            return
        }

        let rmsDB: Double
        if rms > 0 {
            rmsDB = 20.0 * log10(Double(rms))
        } else {
            rmsDB = -100.0
        }

        let isSilent = rmsDB < settings.silenceThresholdDB

        if isSilent {
            if silenceStartTime == nil {
                silenceStartTime = Date()
                silenceWarningTriggered = false
            }

            if let startTime = silenceStartTime {
                let silenceDuration = Date().timeIntervalSince(startTime)
                let thresholdDuration = settings.silenceDurationSeconds

                if !silenceWarningTriggered && silenceDuration >= thresholdDuration * silenceWarningRatio {
                    silenceWarningTriggered = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onSilenceWarning?()
                    }
                }

                if silenceDuration >= thresholdDuration {
                    DispatchQueue.main.async { [weak self] in
                        self?.onSilenceThresholdReached?()
                    }
                    silenceStartTime = nil
                    silenceWarningTriggered = false
                }
            }
        } else {
            silenceStartTime = nil
            silenceWarningTriggered = false
        }
    }

    private func computeFrequencyBands(from samples: [Float], sampleRate: Double) -> [Float] {
        if fftSetup == nil {
            fftSetup = vDSP_create_fftsetup(fftLog2N, FFTRadix(kFFTRadix2))
        }
        guard let setup = fftSetup else { return [Float](repeating: 0, count: 6) }

        // Zero-fill and copy samples into pre-allocated input buffer
        vDSP_vclr(&fftInput, 1, vDSP_Length(fftSize))
        let copyCount = min(samples.count, fftSize)
        fftInput[0..<copyCount] = samples[0..<copyCount]

        // Apply pre-computed Hann window
        vDSP_vmul(fftInput, 1, fftWindow, 1, &fftInput, 1, vDSP_Length(fftSize))

        // Zero-fill split complex arrays
        vDSP_vclr(&fftReal, 1, vDSP_Length(fftSize / 2))
        vDSP_vclr(&fftImag, 1, vDSP_Length(fftSize / 2))

        fftReal.withUnsafeMutableBufferPointer { realBuf in
            fftImag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

                fftInput.withUnsafeBytes { rawPtr in
                    rawPtr.withMemoryRebound(to: DSPComplex.self) { complexPtr in
                        vDSP_ctoz(complexPtr.baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, fftLog2N, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &fftMagnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        var scale = Float(1.0) / Float(fftSize)
        vDSP_vsmul(fftMagnitudes, 1, &scale, &fftMagnitudes, 1, vDSP_Length(fftSize / 2))

        let boundaries: [Double] = [100, 300, 600, 1000, 2000, 3500, 6000]
        let binWidth = sampleRate / Double(fftSize)
        let sensitivities: [Float] = [1.5, 2.0, 2.5, 3.5, 8.0, 15.0]
        let dbFloor: Float = -45.0

        var bands = [Float](repeating: 0, count: 6)
        fftMagnitudes.withUnsafeBufferPointer { magBuf in
            for i in 0..<6 {
                let lowBin = max(1, Int(boundaries[i] / binWidth))
                let highBin = min(fftSize / 2 - 1, Int(boundaries[i + 1] / binWidth))
                guard lowBin < highBin else { continue }

                var rms: Float = 0
                vDSP_rmsqv(magBuf.baseAddress!.advanced(by: lowBin), 1, &rms, vDSP_Length(highBin - lowBin))

                let db = 20.0 * log10(max(rms, 1e-10))
                let normalized = max(0, min(1, (db - dbFloor) / (-dbFloor))) * sensitivities[i]
                let target = min(1, normalized)

                let previous = previousBands[i]
                if target > previous {
                    bands[i] = previous + (target - previous) * 0.95
                } else {
                    bands[i] = previous + (target - previous) * 0.25
                }
            }
        }

        previousBands = bands
        return bands
    }
}

// MARK: - AudioRecording Conformance

extension SystemAudioCaptureManager: AudioRecording {}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer Extension

private extension CMSampleBuffer {
    func asPCMBuffer(format asbd: AudioStreamBasicDescription) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0 else { return nil }

        guard let avFormat = AVAudioFormat(streamDescription: withUnsafePointer(to: asbd) { $0 }) else { return nil }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        var lengthAtOffset: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let srcData = dataPointer else { return nil }

        // Copy audio data into the PCM buffer
        if let floatData = pcmBuffer.floatChannelData {
            let bytesPerFrame = Int(asbd.mBytesPerFrame)
            let channelCount = Int(asbd.mChannelsPerFrame)

            if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                // Non-interleaved: each channel's data is in a separate buffer
                let framesBytes = frameCount * bytesPerFrame
                for ch in 0..<channelCount {
                    memcpy(floatData[ch], srcData.advanced(by: ch * framesBytes), framesBytes)
                }
            } else {
                // Interleaved: single buffer with all channels interleaved
                memcpy(floatData[0], srcData, frameCount * bytesPerFrame)
            }
        } else if let int16Data = pcmBuffer.int16ChannelData {
            memcpy(int16Data[0], srcData, frameCount * Int(asbd.mBytesPerFrame))
        }

        return pcmBuffer
    }
}
