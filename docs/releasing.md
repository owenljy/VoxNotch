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
Current version: **0.5.1 (8)**.

After committing and pushing the reviewed changes, push the corresponding
`v0.5.1` tag to publish. The workflow checks the tag against the project version
and then against the archived app's `CFBundleShortVersionString`.
Only stable `vMAJOR.MINOR.PATCH` tags are accepted.

A successful run publishes `VoxNotch.dmg` and `VoxNotch.dmg.sha256`.
Before publishing, the workflow checks the archived app's version, build number,
architecture, and resource signature, then mounts the completed DMG read-only and
repeats those checks on the packaged app. Archive result bundles and full logs
are retained for seven days, including on failure.
DMG creation uses `create-dmg --skip-jenkins` to avoid Finder AppleScript timeouts
in unattended environments. The Applications link remains available; custom
icon placement is skipped.
## Signing

Releases are signed with a stable self-signed certificate ("VoxNotch Release
Signing", SHA-1 `A722522038615D41E96104CBE6110D94EAD809B4`, valid until 2046).
macOS ties permission grants (Microphone, Screen & System Audio Recording,
Accessibility) and Keychain access to the app's designated requirement, which is
`identifier "com.jingyuanliang.VoxNotch" and certificate root = H"<sha1>"`. With
ad-hoc signing that requirement is a per-build cdhash, so every update looked like
a new app and re-prompted for everything; with a fixed certificate grants survive
updates.

- The `.p12` and its password live in the `MACOS_SIGNING_CERT_P12` (base64) and
  `MACOS_SIGNING_CERT_PASSWORD` repository secrets. The workflow imports them into
  a temporary keychain, signs nested code and then the app, and fails unless the
  designated requirement is pinned to `SIGNING_CERT_SHA1`.
- Never replace the certificate: a new one changes the designated requirement and
  every user loses their permissions again. Keep the backup `.p12` and password
  (created in `~/VoxNotch-signing/`) in a password manager.
- The app remains unnotarized. Developer ID signing and notarization require Apple
  distribution credentials and are not configured.

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
