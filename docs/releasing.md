# CI and releases

## Validation

Pull requests and pushes to `main` run the shared `VoxNotch` scheme on the
[`macos-26` ARM64 runner](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) using Xcode 26.6. Tests also gate tag releases.
Swift packages must match the checked-in `Package.resolved`; automatic dependency
updates are disabled. Test result bundles and logs are kept for seven days.

The recording-time inference test skips when no Metal device is available.
The real Qwen recording benchmark requires `TEST_RUNNER_VOXNOTCH_ASR_MANIFEST`
and stays opt-in: hosted CI does not download large model weights. Run it on an
Apple Silicon Mac before releasing ASR changes; see `asr-evaluation.md`.

## Versioning

Update both Debug and Release `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
in `VoxNotch.xcodeproj/project.pbxproj`, then update `CHANGELOG.md`.
Current version: **0.4.1 (6)**.

After committing and pushing the reviewed changes, push the corresponding
`v0.4.1` tag to publish. The workflow checks the tag against the project version
and then against the archived app's `CFBundleShortVersionString`.
Only stable `vMAJOR.MINOR.PATCH` tags are accepted.

A successful run publishes `VoxNotch.dmg` and `VoxNotch.dmg.sha256`.
The release uses ad-hoc signing to seal the app bundle but remains unnotarized.
Developer ID signing and notarization require Apple distribution credentials
and are not configured by these workflows.
