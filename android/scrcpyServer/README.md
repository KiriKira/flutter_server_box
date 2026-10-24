# Bundled scrcpy server

`third_party/scrcpy` is pinned to upstream 5.0.1,
commit `a60891aea193d92e7e5c3942700eca63f9d19a5f` (Apache-2.0).
This module compiles its Java, AIDL and manifest without modifying upstream.
The unsigned dex APK and license are copied into the app's generated assets by
`prepareScrcpyServer`, a dependency of every app asset merge. The server is run
through `app_process`, not installed. No runtime download is performed.

The native protocol reader, Rust launch command, this module's version and the
APK verifier must be upgraded together: scrcpy makes no cross-version protocol
compatibility promise. In particular, version 5 uses session-size packets rather
than width/height directly after the initial codec header.

Video reception and AVC decoding stay in Kotlin and use a Flutter SurfaceProducer.
Control messages use SDK touch/key injection, not UHID, so the target's software
keyboard remains usable. Clipboard autosync and audio are explicitly disabled.
The screen session never owns the underlying ADB connection.

Pure JVM wire-format tests: `ScrcpyProtocolTest`. Rust launch validation tests:
`cargo test -p sbm_parser --lib android::tests::scrcpy`.
Device acceptance remains manual: rotation, multi-touch, target IME typing,
background/resume, network interruption, and independent terminal/APK operations.
