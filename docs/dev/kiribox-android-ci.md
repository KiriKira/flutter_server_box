# KiriBox Android builds

`.github/workflows/android-kiribox.yml` builds ARM64 and x86-64 release APKs by
manual dispatch. Tests are disabled unless `run_adb_tests` is selected. The display name and artifact name are
KiriBox. Both the Android application ID and native namespace are
`tech.kirikira.kiribox`, allowing installation alongside the original ServerBox.
Shared Flutter platform-channel names remain compatible across platforms.

Select `publish_release` to publish both signed APKs, checksums, and certificate
fingerprint after successful builds. Publication runs only from `main`, verifies
both APK signatures, and refuses an existing version tag. Update the app version
to the latest upstream stable release before dispatching. The legacy upstream
multi-platform tag workflow does not publish automatically in this fork.
For a corrected build of the same app version, `release_revision` adds a suffix
to the release tag without moving a published tag. CI reads the compiled APK
manifest and requires the actual install ID `tech.kirikira.kiribox` and the
expected version before signing and again before publishing.

## Persistent signing

The release identity is generated once and stored outside the git checkout.
The public SHA-256 certificate pin is `android/kiribox-signing-sha256.txt`.
Every signed CI artifact must match this pin; CI never makes a replacement key
or substitutes a disposable debug signature for a release.

With a GitHub credential allowed to manage this repository's Actions secrets:

```sh
python3 scripts/release/setup-kiribox-signing.py \
  --directory /private/backups/kiribox-signing \
  --repository KiriKira/flutter_server_box --upload
```

Use the original private directory or restore its backup on subsequent runs.
Do not generate a second identity when a signing backup already exists. The
script uploads these four repository secrets through stdin:

| Secret | Value from the private signing backup |
| --- | --- |
| `KIRIBOX_KEYSTORE_BASE64` | Base64 of `kiribox-release.p12` |
| `KIRIBOX_KEYSTORE_PASSWORD` | `store_password` in `signing.json` |
| `KIRIBOX_KEY_ALIAS` | `alias` in `signing.json` |
| `KIRIBOX_KEY_PASSWORD` | `key_password` in `signing.json` |

Retain an offline backup of the private directory. Never upload it as an Actions
artifact or commit it. The signing script restores the key only into a private
temporary directory and deletes that copy on exit. APKs ship with a certificate
fingerprint and file checksums. Missing secrets fail before any expensive build;
the workflow never publishes a debug-signed substitute for a release.

Forks may need Actions enabled at the repository's Actions page before the first
run. The current connected GitHub integration can push repository contents but
receives HTTP 403 from the Actions secrets public-key API. An account credential
with Secrets write permission, or an administrator using Settings → Secrets and
variables → Actions, must perform the upload.

## Android verification

The KVM job runs an Android 35 Google APIs emulator. A Flutter integration test
starts the app's foreground pairing service, while the runner opens the actual
Android Wireless debugging pairing-code dialog. The app pairs using the native
ADB client and then exercises TLS connection, shell v2 exit codes and stderr,
status, interactive PTY, binary ADB sync, screenshots, APK installation and
verification, uninstall, and command cancellation. Pairing codes are exchanged
only through the debuggable app's private files and are not logged or uploaded.
The disposable fixture's signing key is unrelated to the release identity.

Evidence is uploaded as `kiribox-adb-emulator-evidence`; a green static test run
alone is not proof of device pairing. The runner also probes TCP 22 at the
user-supplied SSH address, without attempting authentication.

To regenerate the fork's generated BuildData without changing the build number:

```sh
dart --packages=.dart_tool/package_config.json scripts/release/update_kiribox_build_data.dart
```
