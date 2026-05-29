# Changelog

All notable changes to this project will be documented in this file.

## [1.3.0] - 2026-05-29 - Meta Wearables SDK 0.7.0 Upgrade (Android)

### Changed
- **Meta Wearables DAT SDK 0.3.0 → 0.7.0** (`mwdat-core`, `mwdat-camera`).
- **New session/stream API:** migrated from the removed `Wearables.startStreamSession(...)` to the
  `Wearables.createSession() → session.addStream(StreamConfiguration) → stream.start()` lifecycle.
- `RegistrationState` updated for its sealed-class → enum change; `activeDevice(devices)` → `activeDeviceFlow()`;
  registration/unregistration now take an Activity.

### Added
- **Compressed HEVC streaming (experimental, opt-in, default OFF):** `StreamConfiguration.compressVideo`
  delivers the glasses' native HEVC bitstream (skips on-phone decode), plumbed through native →
  `StreamConfig` → a "Compressed Video (HEVC)" toggle in Settings. The WebRTC receive side is not yet
  wired for HEVC, so raw I420 remains the working default. Wiring HEVC end-to-end is the next step and
  is where the ~2–5s latency win is expected.
- **Multi-glasses-version support:** monitors `DeviceCompatibility` per device and surfaces a
  "firmware/app update required" banner with an Update action (`Wearables.openFirmwareUpdate`) — needed
  for older Ray-Ban Meta (Gen 1) glasses on stale firmware. Uses a permissive device selector so all
  camera-capable glasses are eligible.

### Removed
- The phone-side / glasses-side **ABR reflection hacks** in `StreamSessionManager` — they targeted SDK
  internals that no longer exist in 0.7.0, and 0.4.0 fixed the "stream latency degrading over time" bug
  they were working around.

### Notes
- Raw-I420 frame output is byte-for-byte unchanged, so the existing native-server/WebView pipeline is
  unaffected. iOS parity (`VideoCodec.hvc1`) is still pending.

## [1.2.0] - 2026-01-13 - Glasses Streaming POC

### Added
- **Meta Glasses Video Streaming:** Successfully streaming video from Meta Ray-Ban glasses to Jitsi meetings via lib-jitsi-meet WebView approach.
- **Glasses Camera Permission:** Proper permission request flow using `Wearables.RequestPermissionContract()`.
- **Auto Camera Permission:** Automatically requests glasses camera access when device connects.
- **Disconnect Button:** UI to disconnect from paired glasses.
- **E2EE State Tracking:** End-to-end encryption state management in LibJitsiService.
- **Background Mode Support:** Option to keep WebView active when app backgrounds.

### Changed
- **Stream Order (Glasses):** Start glasses capture FIRST, then join Jitsi meeting to avoid race condition with WebView audio setup.
- **Video Track Type:** Use 'desktop' instead of 'camera' to prevent Jitsi from acquiring real camera on unmute.
- **Frame Processing:** Simplified to single JPEG encode (I420 → NV21 → JPEG @ 50%) for better performance.
- **MainActivity:** Switched to FlutterFragmentActivity for ActivityResult support.
- **VideoQuality:** Using MEDIUM (504×896) @ 24fps matching official Meta sample.
- **Build Updates:** Gradle 8.13, AGP 8.8.0, Kotlin 2.1.0.

### Known Limitations (POC)
- ~2-5 second video delay due to double-encoding pipeline (glasses → JPEG → WebRTC).
- WebSocket can disconnect on network issues (no auto-reconnect yet).
- Memory pressure from JPEG encoding per frame.

### Architecture Notes
Current pipeline: `Glasses (HEVC) → SDK decode → I420 → JPEG → Base64 → WebView Canvas → captureStream() → WebRTC encode → Network`

For production, native WebRTC integration would bypass the WebView for significantly lower latency.

## [Unreleased] - 2026-01-04

### Added
- **720p Vertical Video Support:** Updated stream configuration to request High resolution (1280x720) from the Meta Wearables SDK.
- **VideoCodecSettings:** Explicitly enforced H.264 High Profile and 9:16 aspect ratio in HaishinKit to prevent default landscape handling.

### Fixed
- **1x1 Aspect Ratio Bug:** Solved a race condition where the RTMP stream would initialize with 0x0 or 1x1 dimensions.
- **Encoder Priming:** Removed the broadcasting guard to allow video buffers to "prime" the encoder immediately upon app launch, ensuring correct metadata is sent during the handshake.

### Changed
- Updated dependency compatibility to HaishinKit 2.2.3.