# Changelog

## 0.4.1

- Seal and verify the complete App bundle before creating the DMG; fix the invalid resource signature in the 0.4.0 installer.

Build number: 6.

## 0.4.0

- Add Parakeet Unified English 0.6B (INT8 offline) and Parakeet EOU 120M (320 ms streaming).
- Flush EOU right context on release so trailing words are not cut off.
- Isolate model caches and decoder lifecycles; reset EOU between recordings and serialize cancellation with ongoing inference.
- Pin FluidAudio to a tested revision and use its bundled text-normalization library.
- Recover disabled hotkey event taps and clarify Accessibility permissions for multiple app copies.
- Add private, on-device dictation diagnostics with per-stage timings, delivery outcomes, failure categories, and a Settings view.
- Add local benchmark guidance for real microphone recordings and cross-app delivery checks.

Build number: 5.

## 0.3.0

- Add Qwen3-ASR 0.6B and 1.7B 4-bit models while preserving the original BF16 selection.
- Improve language detection, cancellation, recording-time segment processing, and idle model unloading.
- Validate and repair model downloads and protect clipboard contents and output focus.
- Remove the Hugging Face import entry point; preserve management of existing imports.
- Correct custom model availability and shared-cache deletion behavior.
- Unify typography, section spacing, and multiline text layout across settings and history.
- Improve launch-at-login settings with system approval guidance and status refresh.
- Add pull-request tests, a shared Xcode scheme, release version checks, and DMG checksums.

Build number: 4.
