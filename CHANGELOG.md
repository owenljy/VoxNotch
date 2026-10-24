# Changelog

## 0.5.2

- Add a QR-paired Phone View on the same Wi-Fi, with live transcripts and answers, independent answer history, adjustable panes, and iPad layouts. Enabling it hides the Mac panes while keeping the pairing window available.
- Add a horizontal answer history rail with hover previews, click-to-lock, and double-click-to-return.
- Retry once when no answer text arrives within 1.5 seconds, with a configurable timeout and optional fallback model in AI Provider settings.
- Preload downloaded Always-On transcription models at launch and reuse prepared models across sessions.
- Validate microphone input before capture and report missing or invalid devices with actionable guidance.
- Check permissions before starting capture or asking the AI, with explicit setup controls to resolve missing permissions before a session.
- Harden window capture requests across windows, popovers, resizing, and lifecycle changes. Add a best-effort CGS redaction fallback, including refresh handling for live toggles and resized surfaces. Capture compatibility depends on the recorder; the fallback can appear as a grey rectangle.
- Improve the Coding Interview template with Python-only, plain-spoken answers, and add configurable reasoning effort.
- Sign releases with a stable certificate to preserve the app identity across future updates. **This is the first release using that certificate: upgrading from an earlier ad-hoc-signed version may require granting macOS permissions again once.**

Build number: 9.

## 0.5.1

- Add editable Always-On prompt templates, vocabulary hints, answer navigation shortcuts, and microphone/output device controls.
- Save and search local Always-On session history with transcripts and AI answers.
- Fix recording startup, pause/resume, device-switching and restart races; prevent old transcription and answer tasks from affecting new sessions.
- Preserve short utterances, the last sentence on stop/quit, and the chronological order of overlapping audio sources.
- Prevent deleted history and discarded speculative answers from reappearing; preserve session metadata when saving is enabled mid-session.
- Avoid duplicate automatic answers after a manual request and stop pending automatic triggers when disabled or paused.
- Fix held shortcut events reaching the front app, Markdown code fences being altered, and stale history search results.
- Include the Swift optimizer crash workaround missing from the failed 0.5.0 release; verify arm64 archives and the signed app inside the completed DMG before publishing.

Build number: 8.

## 0.5.0

- Add Always-On mode: continuous on-device transcription of the microphone (Me) and system audio (Them) with Parakeet v2, shown live in a translucent two-pane panel under the notch.
- Answer from the live transcript with any OpenAI-compatible provider (base URL, Keychain-stored API key, model list, latency test), streamed as Markdown with paging and copy.
- Answer automatically when the other person pauses after a question or goes quiet, cancelling speculative answers if they keep talking; ask manually with ⌃⌘↩ and toggle Always-On with ⌃⌘A.
- Low-latency streaming pipeline: complete text about 350 ms after speech ends, live partial updates, and microphone echo suppression.
- Draggable, dockable, resizable and minimizable panel with configurable prompt, colors, background tint and text size.
- Exclude notch panels from screen sharing and recordings when "Hide from screen recording" is on.

Build number: 7.

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
