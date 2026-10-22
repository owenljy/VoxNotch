# CI and releases

## Validation

Pull requests and pushes to `main` run the shared `VoxNotch` scheme on the
[`macos-26` ARM64 runner](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) using Xcode 26.6. Tests also gate tag releases.
Swift packages must match the checked-in `Package.resolved`; automatic dependency
updates are disabled. Test result bundles and logs are kept for seven days.
Tests and release archives explicitly build `arm64`, including dependencies.

The recording-time inference test skips when no Metal device is available.
The real Qwen recording benchmark requires `TEST_RUNNER_VOXNOTCH_ASR_MANIFEST`
and stays opt-in: hosted CI does not download large model weights. Run it on an
Apple Silicon Mac before releasing ASR changes; see `asr-evaluation.md`.

## Versioning

Update both Debug and Release `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
in `VoxNotch.xcodeproj/project.pbxproj`, then update `CHANGELOG.md`.
Current version: **0.5.0 (7)**.

After committing and pushing the reviewed changes, push the corresponding
`v0.5.0` tag to publish. The workflow checks the tag against the project version
and then against the archived app's `CFBundleShortVersionString`.
Only stable `vMAJOR.MINOR.PATCH` tags are accepted.

A successful run publishes `VoxNotch.dmg` and `VoxNotch.dmg.sha256`.
Before publishing, the workflow checks the archived app's version, build number,
architecture, and resource signature, then mounts the completed DMG read-only and
repeats those checks on the packaged app. Archive result bundles and full logs
are retained for seven days, including on failure.
The release uses ad-hoc signing to seal the app bundle but remains unnotarized.
Developer ID signing and notarization require Apple distribution credentials
and are not configured by these workflows.

## Previous release failure

The [v0.5.0 release run](https://github.com/owenljy/VoxNotch/actions/runs/39738945485)
passed tests but failed during the Release archive with exit code 65. The full
`archive-log` artifact records an Apple Swift 6.3.3 compiler crash in
`EarlyPerfInliner` while optimizing `FirstMouseHostingView.deinit`. The ordinary
Actions console log was truncated before this backtrace; use the saved archive
diagnostics when investigating compiler failures.

Commit `eeac80a` replaces the generic `NSHostingView<Content>` subclass with a
non-generic `NSHostingView<AnyView>` subclass. Keep that workaround until a
tested toolchain no longer needs it. The v0.5.0 tag predates that fix; new releases
must include it rather than rerunning the unchanged old tag.
