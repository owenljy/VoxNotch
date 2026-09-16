# Dictation pipeline improvements

## Implemented

- **Qwen language handling:** map ISO language selections to Qwen language names.
  Auto uses an open assistant prompt, allowing the model to generate
  `language …<asr_text>…`; metadata is parsed out of the delivered transcript.
  The application uses the SDK's public forward pass and checks cancellation
  between generated tokens. Audio is chunked into at most roughly 30-second
  windows using the SDK's low-energy boundary search.
- **Cancellation:** retain and cancel pipeline tasks, assign a new session ID for
  each recording, reject late results after LLM processing, and remove temporary
  audio through the recording source that created it. Cancelled queued Metal
  work does not start. A running GPU operation is not forcibly interrupted.
- **Output target:** capture the original application, Accessibility window and
  focused element. A changed target receives no simulated input; the transcript
  is copied with a clipboard notice. Where Accessibility cannot expose a window
  or element, the application identity remains the available check. Recheck
  while typing and before pasting. Avoid retrying whole-text output after a
  partial insertion.
- **Clipboard:** snapshot all items and data types, restore only if the change
  count still belongs to the application, and remove the unconditional copy
  after successful insertion. Allow 300 ms for paste consumption; this is a
  compatibility delay, not an acknowledgement from the receiving application.
- **Downloads:** inspect safetensors headers, contiguous data offsets and file
  lengths, plus the shard index. Reject config-only or truncated caches and
  download into temporary files and validate size and available LFS SHA-256 before
  replacing incomplete assets. The application uses HTTPS snapshots pinned to a
  repository commit and repairs the old downloader's `filename/filename` layout
  before the SDK's loader can read the cache.
  Share concurrent loads of the same model; custom models resolve architecture
  before loading instead of trying GLM first. Unknown architectures report an
  explicit error. Structural validation is not a cryptographic integrity check.
- **Memory:** replace the legacy simulated Whisper memory manager with an idle
  timer and memory-pressure observer controlling the real ASR service. Drop both
  provider and manager references after five minutes idle or idle pressure.
  Active inference/loading and recording leases prevent eviction. Outstanding
  synchronous SDK calls retain their own references until they finish.
- **VAD:** apply the existing opt-in Silero speech gate to MLX file transcription
  and Voxtral recording-time finalization as well as FluidAudio. This is speech
  rejection, not a new silence-trimming implementation.
- **Voxtral recording-time processing:** wire mono 16 kHz microphone and system
  audio callbacks into a bounded, ordered input queue. Prefer boundaries after
  three seconds plus 400 ms of quiet; force a boundary at twelve seconds. Decode
  completed segments while recording, flush the tail after stop, and only insert
  the final result. Retain the WAV for whole-recording fallback on streaming
  failure. Queue overflow fails rather than silently dropping samples.

## Streaming limits

The pinned Voxtral SDK does not expose a continuous audio-input decoder session.
The implementation therefore performs **independent speech-segment inference**,
not cached token-level streaming. An uninterrupted utterance may lose context at
forced segment boundaries. Silence boundaries use an energy heuristic, so noisy
rooms may cause more forced boundaries. No partial transcript is inserted into
another application. Cancellation of Voxtral/GLM waits for the current
synchronous inference call; Qwen checks cancellation between tokens.

## Validation

Final verification on 2026-09-15: the full Xcode test run passed all 110 tests, including the synthetic recording smoke test (no skips).

Automated tests cover language prompts and parsed metadata, cancellation after a
suspended LLM response, changed targets, clipboard ownership/rich formats,
truncated/missing-shard downloads, segment sample preservation, decoding before
stop, cancelled streaming results, and active-inference memory protection.

Use `docs/asr-evaluation.md` for local recording comparisons. The Qwen 0.6B 4-bit Auto-language smoke test matched both Chinese and English
references on Apple M4; results are saved in `asr-smoke-results.json`. Synthetic speech
smoke tests are only a loader/inference check, not evidence of accuracy on real
microphones, accents, noisy speech, or long recordings. Hardware microphone and
system-audio capture and receiving-app behavior still require interactive QA.

Qwen prompt behavior is based on the upstream implementation:
https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py
