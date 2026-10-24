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
Current version: **0.5.4 (11)**.

After committing and pushing the reviewed changes, push the corresponding
`v0.5.4` tag to publish. The workflow checks the tag against the project version
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


The [v0.5.2 attempt](https://github.com/owenljy/VoxNotch/actions/runs/40092999811)
failed the test gate before archiving. Four assertions expected `.readOnly` after
clearing `.none`, but AppKit can keep returning `.none` even after the setter is
called. A standalone NSWindow probe on macOS 27 reproduced this without any app
privacy manager. The unit fixture now records the requested setter value while
still forwarding it to the real NSWindow; the separate opt-in capture pixel suite
continues to assert that disabling protection restores actual visible content.
AI streaming tests also inject their Keychain reader so a locally saved key's
approval state cannot interfere with mocked providers. A regression test verifies
that approval failures still prevent requests and never use interactive reads.
No v0.5.2 installer was published; the fixes are included in v0.5.4, and the failed
tag remains intact.

Local validation for the retry: 297 tests, zero failures, five conditional skips.
The additional capture check skipped because the newly built test host did not
have Screen Recording permission. The earlier authorized build passed two rounds
of the AppKit/SwiftUI capture matrix (32 tests, zero skips); production capture
code is unchanged by this CI fix.

The [v0.5.3 attempt](https://github.com/owenljy/VoxNotch/actions/runs/40094714041)
passed all 297 tests but Swift 6.3.3 crashed in `EarlyPerfInliner` while optimizing
`PreparedModelCache`'s generic deallocator (`PreparedModelCacheCfD`). The complete
`archive-log` artifact contains the backtrace; the Actions console is truncated.
An explicit `@_optimize(none) deinit {}` marks both destroying and deallocating
destructors `[Onone]` in optimized SIL. Other cache methods remain optimized.
The shared CI workflow compiles this file with `-O` and checks that exact
deallocator before spending time building dependencies or the release archive. Keep this narrow compiler
workaround until the pinned toolchain is verified to no longer need it. No
v0.5.3 installer was published; v0.5.4 retries with the workaround.

## Signing preflight and retrying an unpublished tag

The first v0.5.4 run passed tests and the cloud Release archive, but `codesign`
reported `no identity found`. The imported temporary keychain was absent from the
user search list, and the self-signed certificate had no code-signing trust on the
hosted runner. The workflow now adds the keychain to that list, grants the pinned
public certificate code-signing trust on the ephemeral runner, checks a valid
identity, and signs and verifies a small real executable before building. Cleanup
deletes the private keychain first, then removes temporary trust and the public
certificate. Each system cleanup command has a 20-second timeout because trust
removal can hang on a hosted runner; any failure is reported as a warning before
the ephemeral runner is discarded. This does not
change trust settings on a developer or user's Mac.

To validate signing without a full build:

```sh
gh workflow run release.yml --ref main -f release_tag=v0.5.4 -F preflight_only=true
```

To retry the existing unpublished tag with the updated workflow:

```sh
gh workflow run release.yml --ref main -f release_tag=v0.5.4
```

Optionally pass `-f verified_ci_run=40096813538` to reuse that successful CI run
for v0.5.4. The workflow resolves annotated tags to their commit and verifies that
the run belongs to this repository, is a successful push of `ci.yml`, and tests
that exact commit before accepting it as the test gate. Without this input, it
runs tests normally. The retry always checks out the specified tag for the build;
it never moves the tag and refuses to replace an existing GitHub Release.
