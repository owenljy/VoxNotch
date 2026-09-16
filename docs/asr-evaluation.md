# Local ASR evaluation

The built-in Qwen variants share the existing Swift loader. The 0.6B and 1.7B
4-bit downloads are approximately 713 MB and 1.61 GB respectively, based on
Hugging Face file metadata checked on 2026-09-15. They have independent IDs and
caches; the original `mlx-qwen3-asr` setting still selects 1.7B BF16.

## Run recordings through Qwen

Prepare a local JSON manifest. Audio paths may be absolute or relative to the
manifest. Use mono 16 kHz recordings, each between 0 and 60 seconds long.
Include Mandarin, English, mixed-language technical terms, numbers, and noisy
speech, with manually checked reference transcripts.

```json
{
  "models": [
    "mlx-community/Qwen3-ASR-0.6B-4bit",
    "mlx-community/Qwen3-ASR-1.7B-4bit",
    "mlx-community/Qwen3-ASR-1.7B-bf16"
  ],
  "samples": [
    {
      "id": "mixed-01",
      "audioPath": "mixed-01.wav",
      "reference": "请把这个 pull request 合并到 main 分支。"
    }
  ]
}
```

From the repository root:

```sh
TEST_RUNNER_VOXNOTCH_ASR_MANIFEST=/absolute/path/manifest.json \
xcodebuild -project VoxNotch.xcodeproj -scheme VoxNotch \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:VoxNotchTests/SpeechModelTests/testQwenRecordingBenchmark \
  -resultBundlePath /tmp/voxnotch-asr-benchmark.xcresult \
  CODE_SIGNING_ALLOWED=NO test
```

Use a fresh result-bundle path for each run. The test downloads selected models
on first use and skips automatically when the environment variable is absent.
It validates the audio before downloading, warms up each model like the app,
and attaches `qwen-recording-benchmark.json` to the test result. The report
contains references, actual transcripts, audio duration, inference time, and
load time (including download time if uncached). It also prints the JSON in the
test log. Record the Mac model, memory, and power mode alongside each run.

This measures model inference, not the complete hotkey-to-output latency. It
does not measure peak memory or automatically score accuracy. Compare the
transcripts against references, especially names, numbers, and code identifiers,
before changing defaults. A two-sample synthetic speech smoke test passed on an Apple M4 with 24 GB RAM: Chinese (4.31 s audio) took 0.42 s inference, English (2.78 s audio) took 0.26 s inference, and both transcripts matched the references. See `asr-smoke-results.json`. This does not replace a real-recording accuracy evaluation.

## FireRedASR2 integration prerequisite

The currently resolved MLX Audio commit `b76c81f` only includes GLM-ASR, Qwen3-ASR,
Voxtral Realtime, and Parakeet. Upstream now provides `FireRedASR2Model` with
`mlx-community/FireRedASR2-AED-mlx` (approximately 4.57 GB).

Upgrading directly to the current upstream requires resolving a dependency
conflict: its `mlx-swift-lm` requirement starts at 3.31.3, while the pinned
AnyLanguageModel 0.7.1 package requires the 2.x major version. A coordinated SDK
upgrade and regression check of ASR and LLM providers is needed before adding
FireRed to the built-in list or running it through this app. The current change
keeps the existing dependency lock and default model.

Sources:

- [Qwen Swift loader examples](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Qwen3ASR/README.md)
- [FireRed Swift integration](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/FireRedASR2/README.md)
- [Current upstream package requirements](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Package.swift)
