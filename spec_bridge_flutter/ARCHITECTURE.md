# Flutter Jitsi and Meta glasses architecture

Reviewed 18 October 2026. The active app is `spec_bridge_flutter`; the separate root Swift/Twitch prototype is outside this upgrade. Both Flutter platform integrations now use Meta DAT 1.0.1 and explicit device/camera/stream lifecycles.

## Current video paths

```text
Android glasses
  Meta DAT decoded I420
    → Kotlin frame envelope (12-byte header + I420)
    → native loopback WebSocket :8766
    → WebView WebGL canvas → captureStream() → Jitsi WebRTC

Android fallback
  Same frame envelope → Flutter EventChannel → Dart loopback WebSocket :8765
    → the same WebView renderer

iOS glasses
  Meta DAT raw video → latest-frame buffer → background JPEG conversion
    → Flutter EventChannel → Dart loopback WebSocket :8765
    → WebView JPEG renderer → canvas → captureStream() → Jitsi WebRTC

Phone camera
  WebView getUserMedia() → Jitsi WebRTC
```

The Android glasses path already uses raw I420; the old JPEG/Base64 architecture description was obsolete. The 12-byte little-endian header contains width, height and the low 32 bits of capture time in epoch milliseconds. Each frame owns its data. The renderer handles timestamp rollover and drops stale frames.

Jitsi wraps both the glasses canvas and phone video as camera tracks. The old Unix-socket injection helpers remain as historical files but are not the active Flutter meeting transport. Restored iOS project membership excludes these unused helpers.

Both WebSocket listeners bind to `127.0.0.1`. Android drops frames when the socket has buffered output. Dart permits one frame in flight and waits for the JavaScript `frameReceived` receipt. JavaScript keeps only the latest pending frame, so a slow decoder does not accumulate an application-level playback queue. iOS also buffers only the latest SDK frame before JPEG conversion.

## Changes in this upgrade

| Previous issue | Current behavior |
| --- | --- |
| Android DAT 0.3.0 and obsolete streaming factory | DAT 1.0.1 from Maven Central; `DeviceSession → Camera → Stream`; no package credentials |
| Flutter iOS had no Xcode project and referenced nonexistent Meta CocoaPods integration | Restored Flutter iOS project and resources, exact Meta Swift Package 1.0.1 |
| iOS skipped SDK configuration and inferred registration from a callback URL | Calls `Wearables.configure()` and `handleUrl()`; observes actual registration state |
| iOS tried to send full-rate frames to an unused Jitsi SDK socket | Sends glasses frames into the active WebView pipeline |
| Jitsi loaded mutable JavaScript from meet.jit.si at every launch | Bundled official v2228.0.0+572f49c8 release, worker, licenses and checksums |
| No Dart lockfile; dependency floors described Flutter 3.16 | Updated direct packages, added lockfile, Flutter 3.44 / Dart 3.12 minimum |
| Gradle 8.13 rejected by installed Flutter | Gradle 8.14.4 with distribution checksum; compile SDK 37 for permission_handler |
| Deep-link values interpolated directly into executable JavaScript | Arguments serialized with JSON; quotes/newlines remain data |
| Full deep-link URLs logged natively | Logs omit URLs and their JWT query values |
| Frame servers exposed camera bytes to LAN clients | Loopback-only listeners; bounded application queues |
| Old native socket callbacks could reset a healthy fallback connection | Callbacks verify socket identity before changing state |
| Reused frame buffers could change during asynchronous delivery | Independent frame ownership and safe queued sends |
| Audio setup read an undefined `usePhoneMic` variable | Explicitly passes microphone preference to the connection callback |
| E2EE failures were ignored and a requested setting was reported as success | Checks support, imports HKDF key material, configures before media, aborts on setup failure |
| A fixed delay and “start accepted” were treated as live | Waits for conference-joined and SDK-streaming events; propagates paused/error states |
| WebView automatically granted every resource permission | Navigation limited to the bridge asset; grants only local camera/microphone requests |
| Tests consisted of `expect(true, isTrue)` | Regression tests cover bridge arguments, readiness/failure, registration, queues, reconnects, timestamps and navigation |

## Remaining priorities

1. **Validate a real call on each phone before release.** The migration crosses multiple DAT API changes and pins a new Jitsi client. Registration, glasses firmware compatibility, WebView media permission origins and hardware encoders require physical devices. Desktop Chrome smoke tests passed, but no live call or physical-device result is claimed.
2. **Make meeting policy explicit.** Settings default to a public community server and a shared `SpecBridgeRoom`. Choose a controlled deployment, unique room identifiers and an authentication policy for the intended application. `joinRoom()` still derives `conference.<host>` and `focus.<host>`; deployments with different XMPP domains, tenants or URL prefixes need explicit configuration. JWT presence alone does not prove a compatible server configuration.
3. **Finish initial mute handling.** `MeetingConfig.startWithVideoMuted` and `startWithAudioMuted` are not passed to the JavaScript join API. The default video-muted field therefore does not describe actual behavior. Decide the intended startup behavior and cover it with a media-track test before treating those flags as an enforceable policy.
4. **Authenticate local frame consumers.** Loopback removes LAN exposure, but a per-session random token is still needed to prevent another local process or browser context from subscribing to a fixed port or replacing the client.
5. **Measure and simplify the frame pipeline.** `processI420FrameInternal()` currently forces GPU completion with `gl.finish()` for timing on every frame. Make this optional diagnostic behavior. iOS additionally converts JPEG back through CPU RGBA/YUV processing. Benchmark raw frames on iOS, request-driven canvas capture and a native WebRTC capture integration against the existing path before committing to a rewrite.
6. **Validate E2EE interoperability.** The shared-passphrase mode uses Jitsi's externally managed HKDF key path. Peers must use the same key protocol; this is not automatically compatible with the stock Jitsi UI's managed-key mode. Capability checks and mocked success/failure tests do not verify encrypted media between devices, worker loading, rekeying or behavior after reconnect.
7. **Test background and recovery behavior.** iOS raw video may pause in the background, and an Android foreground service does not by itself guarantee continued WebView rendering. HEVC background capture is a separate transport/decoder project. Test app backgrounding, folding/removing glasses, network handoffs and repeated start/stop without assuming automatic recovery.
8. **Finish release infrastructure.** Android release signing still uses the debug configuration. Configure real signing and Meta application/release-channel values. AGP 8.13.2 and Kotlin 2.3.0 still build, but current Flutter warns about their future support; upgrade them together with Gradle as a separate toolchain change. Generated machine-specific Flutter config files were already tracked in the repository and should be removed from source control in a cleanup.

For scale: tightly packed 504×896 I420 at 24 fps moves about 16.3 MB/s through local frame delivery before WebRTC compression. This is a calculation from dimensions and frame rate, not measured network bandwidth. Default 360×640 at 15 fps is about 5.2 MB/s. Reducing copies and unnecessary synchronization is likely more useful than increasing requested resolution first.

## Verification

Run from `spec_bridge_flutter`:

```sh
flutter test
flutter analyze
node --test test/js/*.test.cjs
flutter build apk --debug
flutter build ios --simulator --debug --no-codesign
```

The automated suite includes Flutter and JavaScript regression tests and native JVM tests for frame-delivery timing. Tests use a recording WebView, real local Dart WebSockets, a controllable monotonic clock and mocked Jitsi/browser APIs; they do not substitute for device media tests. Flutter analysis, Android debug and iOS simulator compilation passed during the SDK upgrade.

Android diagnostics now retain a bounded session report through failed starts and teardown, with SDK delivery, sampled device state, actual communication-device selection and downstream pipeline counters. See [Android session diagnostics](README.md#android-session-diagnostics) for collection boundaries and how to copy the report. The phone-local delay measurement begins at native SDK receipt; it does not measure the glasses-to-phone link or remote playback.

The browser smoke test at `test/browser/jitsi_bridge_smoke.html` additionally passed six checks in desktop Chrome using the actual bundled Jitsi library: initialization, WebGL availability, synthetic I420 and JPEG pixel rendering, canvas video-track creation, and capture cleanup on disposal. It makes no camera/microphone request and does not join a meeting. No release upload, signing change for distribution or physical-glasses test was performed.

Device acceptance checks:

- Register, cancel registration, unregister and re-register. Confirm the UI follows SDK state.
- Deny and subsequently grant glasses camera permission, including revocation in Meta AI.
- Join with quotes/unicode in participant names and a real JWT-enabled deployment.
- Verify phone and glasses microphone routing with a remote participant.
- Stream low/15, medium/24 and high/24; measure remote latency, dropped frames, memory and thermal behavior over at least 15 minutes.
- Fold/remove glasses, pause/resume, background/foreground and switch Wi-Fi/cellular. Confirm state and cleanup after stop-during-start and repeated joins.
- Validate E2EE success with compatible peers and failure on unsupported WebViews, including mismatched keys and reconnects.

## Upstream references

- [Meta Android installation](https://github.com/facebook/meta-wearables-dat-android#including-the-sdk-in-your-project)
- [Meta Android release changes](https://github.com/facebook/meta-wearables-dat-android/blob/main/CHANGELOG.md)
- [Meta iOS installation](https://github.com/facebook/meta-wearables-dat-ios#including-the-sdk-in-your-project)
- [Meta iOS release changes](https://github.com/facebook/meta-wearables-dat-ios/blob/main/CHANGELOG.md)
- [Pinned Jitsi release](https://github.com/jitsi/lib-jitsi-meet/releases/tag/v2228.0.0%2B572f49c8)
- [Jitsi low-level API](https://jitsi.github.io/handbook/docs/dev-guide/dev-guide-ljm-api/)
