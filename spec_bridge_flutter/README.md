# SpecBridge Flutter

SpecBridge sends video from Meta glasses to Jitsi meetings. This directory is the active Flutter application; the repository root's `SpecBridge.xcodeproj` is a separate Swift/Twitch prototype.

Flutter owns setup, deep links, settings and call controls. Kotlin and Swift plugins capture glasses video using Meta DAT. A bundled `lib-jitsi-meet` runs inside a WebView and publishes the video. Phone camera mode uses the WebView's `getUserMedia()` directly.

## Requirements

- Flutter 3.44+ and Dart 3.12+ (validated with Flutter 3.47.7 / Dart 3.13.5).
- Android 12+ device; Android SDK 37 to compile, target SDK 36, Java 21.
- For iOS: Xcode with Swift 6 support, iOS 16+ device, a signing team for device installation.
- Compatible Meta glasses paired in the Meta AI companion app. Configure Developer Mode or a release channel for your app.

Meta DAT 1.0.1 is pinned on both platforms. Android now downloads from Maven Central; **no GitHub token is required**. iOS uses the official Swift Package, pinned in `ios/Runner.xcodeproj`. See [Meta Android setup](https://github.com/facebook/meta-wearables-dat-android#including-the-sdk-in-your-project) and [Meta iOS setup](https://github.com/facebook/meta-wearables-dat-ios#including-the-sdk-in-your-project).

## Build and test

Run from this directory:

```sh
flutter pub get
flutter test
flutter analyze
node --test test/js/*.test.cjs
flutter build apk --debug
flutter build ios --simulator --debug --no-codesign
```

To exercise the bundled Jitsi library and synthetic frame rendering in a desktop browser, run `python3 -m http.server 8800 --bind 127.0.0.1`, open `http://127.0.0.1:8800/test/browser/jitsi_bridge_smoke.html`, and click **Run smoke test**. This does not request camera/microphone access or join a meeting.

For a physical device, use `flutter run`. On iOS, select your development team in `ios/Runner.xcworkspace`. Configure the app identifiers and release-channel values in `android/app/src/main/res/values/strings.xml` and `ios/Runner/Info.plist` for your Meta developer application. The existing iOS Meta application ID is retained; use the appropriate Developer Mode configuration for local testing.

The Android release build still uses debug signing. Supply a release keystore configuration before distributing a release.

## Use

1. Grant phone microphone, camera and Bluetooth permissions.
2. Connect/register the glasses through Meta AI and grant their camera permission.
3. Choose the server and room, then start streaming.
4. Wait for both the Jitsi join event and the glasses streaming state. A glasses pause is shown separately from a live stream.

Fresh settings use low video quality at 15 fps and the phone speaker/microphone. Glasses audio shares Bluetooth bandwidth with video; test it independently. Settings currently default to `https://meet.ffmuc.net` and `SpecBridgeRoom`; choose your own server and room for real calls.

## Deep links

```text
specbridge://join?room=MyRoom
openemr-telehealth://join?room=MyRoom&server=https%3A%2F%2Fjitsi.example.org&name=Alex&jwt=TOKEN
```

URL-encode values. JWTs stay in the join flow and are not included in native deep-link logs. Server-specific XMPP configuration still needs validation; an arbitrary Jitsi deployment is not guaranteed to work with the default domain assumptions.

## Dependencies

| Component | Version |
| --- | --- |
| Meta DAT Android and iOS | 1.0.1 |
| lib-jitsi-meet | v2228.0.0+572f49c8, bundled locally |
| flutter_inappwebview | 6.2.0-beta.3, explicitly pinned prerelease |
| go_router | 18.1.0 |
| app_links | 7.2.2 |
| permission_handler | 13.0.2 |
| provider | 6.1.5+1 |
| shared_preferences | 2.5.6 |
| equatable / cupertino_icons | 3.0.0 / 2.0.0 |

Commit `pubspec.lock`, `ios/Podfile.lock` and the Swift package resolution. Jitsi's upstream license, release URL and file checksums are in `assets/vendor/jitsi/`. To update it, take the UMD bundle, E2EE worker and license notices from an official [Jitsi release](https://github.com/jitsi/lib-jitsi-meet/releases), update `version.json`, run the bridge tests and test a call on both phones.

## Validation and next steps

The October 2026 review and upgrade are documented in [ARCHITECTURE.md](ARCHITECTURE.md), including remaining issues, performance priorities and physical-device checks. Build success and mocked bridge tests do not establish glasses connectivity, audio routing, end-to-end encryption interoperability or sustained background streaming.

## Android session diagnostics

Starting a stream records a diagnostic session, including failed starts. Open the document icon on the streaming screen, or **Settings → Developer Options → Latest session report**, then choose **Copy report**. The latest report is saved locally and remains available after stopping or reopening the app. Starting another stream replaces it, so copy any report you want to retain first.

The report samples about every five seconds and retains the first sample, the latest 180 samples (roughly 15 minutes), and the latest 100 application events. It also includes up to 32 recent typed SDK events per capture. Discard counts identify trimmed application history. A report that was not finalized may reflect an interrupted app session; background sampling is subject to Android scheduling.

- **SDK delivery:** requested quality/FPS, actual incoming dimensions, rolling FPS, resolution changes, current/longest delivery gap, and gaps of at least one second. Gaps use a monotonic clock, include an ongoing stall, and exclude SDK-reported pauses. FPS is unknown until one second of active streaming. These are delivery measurements on the phone, not Bluetooth packet counters.
- **Device:** phone/app/SDK versions and available glasses firmware, battery, thermal, link, worn and hinge state. Missing SDK metadata stays unknown. Device state is sampled rather than continuously recorded.
- **Audio:** route requests and their return values, plus the communication device Android reports. A mismatch with a requested phone route is recorded. This observation does not prove which microphone WebRTC is capturing and does not change audio routing.
- **Pipeline:** native socket, Flutter forwarding, WebView rendering and Jitsi encoder counters. Capture restarts have a new `captureSequence`; compare counters within the same capture. The latest native capture snapshot survives stop for the final report.
- **Phone-local delay:** Android SDK frame receipt to WebView processing. This excludes camera exposure, the glasses-to-phone Bluetooth link, the internet and remote playback. It is unavailable for JPEG/iOS or phone-camera paths.

Reports contain selected diagnostic metadata, with no media, meeting names, server URLs, JWTs, encryption keys or device identifiers. Reports are copied only when you tap the button. Saving failures are shown in the viewer so you can copy the in-memory report.

Run the hardware-independent timing tests with JDK 21: from `android`, run `./gradlew :app:testDebugUnitTest`. Flutter tests cover persistence, failed starts, teardown, bounded history, metadata filtering and report UI. A real-glasses call is still needed to validate actual SDK metadata, microphone routing and stream behavior.

## License

Application code: MIT, see the repository's `LICENSE`. Bundled Jitsi code retains its upstream licenses under `assets/vendor/jitsi/`.
