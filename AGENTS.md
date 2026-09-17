# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What is VoxNotch

A macOS menu bar dictation app that uses the MacBook's notch as its recording UI. Audio is transcribed locally on Apple Silicon using FluidAudio or MLX ASR models — nothing leaves the device. Hold ⌃⌥ to record, release to transcribe and output text to the frontmost app.

## Build & Test

```bash
# Build
xcodebuild -project VoxNotch.xcodeproj -scheme VoxNotch -configuration Debug build

# Run all tests
xcodebuild -project VoxNotch.xcodeproj -scheme VoxNotch -configuration Debug test

# Run a single test class
xcodebuild -project VoxNotch.xcodeproj -scheme VoxNotch -configuration Debug \
  test -only-testing:VoxNotchTests/DictationStateMachineTests

# Run a single test method
xcodebuild -project VoxNotch.xcodeproj -scheme VoxNotch -configuration Debug \
  test -only-testing:VoxNotchTests/DictationStateMachineTests/testStartRecording
```

- **Xcode 16+** required. Swift 6.0 strict concurrency for main target, Swift 5.0 for tests.
- SPM dependencies are resolved automatically on first build.
- No linter is configured.

## Architecture

### Dictation Pipeline

```
Hotkey (HotkeyManager) → QuickDictationController → DictationStateMachine
  → AudioCaptureManager (mic → 16kHz mono WAV)
  → VadGate (Silero VAD, optional)
  → TranscriptionService → FluidAudioProvider | MLXAudioProvider
  → NemoTextProcessing (ITN) + FillerWordFilter
  → LLMService (Apple Intelligence / Ollama, optional)
  → TextOutputManager (CGEvent keystrokes or clipboard paste)
  → DatabaseManager (SQLite + FTS5 history)
```

### Core Design: Ports & Adapters with State Machine

**DictationStateMachine** (`StateMachine/`) is the central orchestrator. It manages state transitions through `idle → recording → warmingUp → transcribing → [processingLLM] → outputting → idle`, with `modelSelecting`, `toneSelecting`, and `error` as side states. Uses session IDs to cancel stale async tasks.

**QuickDictationController** (`Controllers/`) wires hotkey events to the state machine and routes state-change callbacks to the UI.

**Protocol abstractions** (`Protocols/`) decouple the state machine from implementations:
- `AudioRecording` — mic capture
- `TranscriptionEngine` — ASR providers
- `TextOutputting` — text delivery
- `LLMProcessing` — post-processing
- `NotchPresenting` — notch UI
- `AppClock` — timers (enables deterministic test clock)

**ServiceContainer** (`App/ServiceContainer.swift`) is the DI root. Production uses singletons; tests inject mocks.

### Concurrency Model

- `@MainActor` on all UI state: `AppState`, `SettingsManager`, `NotchManager`, all ViewModels.
- `@unchecked Sendable` singletons protected by `NSLock` for audio buffer access (`AudioCaptureManager.audioLock`) and model loading (`FluidAudioModelManager.lock`).
- Session ID pattern: the state machine increments a session ID on each recording; async continuations check their captured ID against the current one and bail if stale.

### Notch UI

`NotchManager` owns a persistent `NotchPanel` (NSPanel subclass). The panel hosts SwiftUI content (`NotchContentView`) and uses `panelOpacity` to fade before calling `orderOut`. The waveform (`ScrollingWaveformView`) reads from `AudioVisualizationState` which is updated at ~60fps from the audio tap.

### Text Output Targeting

`TextOutputManager` captures `savedFrontmostApp` at hotkey-press time (not at output time). It checks `AXFocusedUIElement` + `AXRole` to decide between CGEvent keystroke simulation and clipboard paste. A hardcoded whitelist covers apps with unreliable AX trees (Chrome, VS Code, Slack, Discord).

### Testing

Tests live in `VoxNotchTests/`. Each protocol has a corresponding mock in `VoxNotchTests/Mocks/`. `TestClock` replaces `SystemClock` for deterministic timer behavior. `AppState(forTesting:)` creates non-singleton instances for test isolation.

### Key Managers

| Manager | Responsibility |
|---|---|
| `SettingsManager` | UserDefaults persistence, observable |
| `ModelDownloadManager` | HuggingFace model downloads with progress |
| `ModelMemoryManager` | Unloads models after 5 min idle |
| `SoundManager` | Start/stop/error audio cues |
| `DatabaseManager` | GRDB SQLite + FTS5 for transcription history |
| `ErrorRouter` | Centralized error → UI mapping |

### Two ASR Engines

`SpeechModel` enum unifies FluidAudio (Parakeet v2/v3, English-focused) and MLX Audio (GLM, Qwen3, multilingual). `TranscriptionService` selects the provider based on the model's `.engine` property. Each engine has its own model manager for lifecycle/memory.
