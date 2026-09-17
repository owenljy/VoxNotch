# Local diagnostics and real-recording benchmark

Open Settings → Diagnostics to inspect the most recent 50 dictations. The
summary reports median and nearest-rank P95 of release-to-output latency.
Individual records split post-release time into model preparation, ASR, text
cleanup, optional LLM, and output. Streaming models can run inference before
release, so their ASR figure is **post-release work**, not total inference cost.
The app retains at most 500 diagnostic rows and never puts audio or transcript
content in this table. Clear diagnostics from this page; history has separate
retention and deletion controls.

## Real microphone evaluation

The existing benchmark runner is documented in [asr-evaluation.md](asr-evaluation.md).
For a useful comparison, prepare 20–30 consented, manually transcribed mono
16 kHz WAV clips. Include quiet and noisy rooms, the actual microphone types,
English and Mandarin, code-switching, names, numbers, and long uninterrupted
speech. Keep the same fixture files and references for every model; do not
commit private recordings to the repository.

Record Mac model, available memory, power mode, model cache state, and the
chosen post-processing settings with each run. Compare raw ASR text to a
manually verified reference. Use word error rate for English and character
error rate for Chinese; inspect mixed-language terms, punctuation, and proper
names manually. Model inference benchmarks do not test the global hotkey,
microphone capture, or insertion into other apps.

Separately test end-to-end delivery in Notes, browser text fields, an IDE,
and apps with unusual Accessibility behavior. For each app, verify successful
insertion, changing focus during recording, and clipboard fallback. Review the
corresponding Diagnostics row for actual delivery outcome and latency.
