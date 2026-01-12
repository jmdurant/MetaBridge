# SpecBridge Flutter - Architecture Documentation

## Overview

SpecBridge streams video from Meta Ray-Ban smart glasses to Jitsi video meetings. The glasses camera feed is injected into Jitsi as a screen share, allowing remote participants to see what the glasses wearer sees.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         FLUTTER (Dart)                               │
│                                                                      │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐             │
│  │GlassesService│    │ JitsiService│    │StreamService│             │
│  │   (state)    │    │   (state)   │    │   (state)   │             │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘             │
│         │                  │                  │                      │
│         ▼                  ▼                  │                      │
│  ┌─────────────┐    ┌─────────────┐          │                      │
│  │MetaDATChannel│    │jitsi_meet_  │          │                      │
│  │(MethodChannel)│   │flutter_sdk  │          │                      │
│  └──────┬──────┘    └─────────────┘          │                      │
└─────────┼────────────────────────────────────┼──────────────────────┘
          │                                    │
    ┌─────┴─────┐                              │
    ▼           ▼                              │
┌────────┐  ┌────────────────────────────────────────────────────────┐
│  iOS   │  │                    ANDROID (Kotlin)                     │
│(Swift) │  │                                                         │
│        │  │  ┌──────────────────┐    ┌────────────────────────┐    │
│        │  │  │MetaWearablesPlugin│───▶│  MetaWearablesManager  │    │
│        │  │  └────────┬─────────┘    └───────────┬────────────┘    │
│        │  │           │                          │                  │
│        │  │           ▼                          ▼                  │
│        │  │  ┌──────────────────┐    ┌────────────────────────┐    │
│        │  │  │StreamSessionManager│   │   Meta Wearables SDK   │    │
│        │  │  └────────┬─────────┘    │  (mwdat-core/camera)   │    │
│        │  │           │              └────────────────────────┘    │
│        │  │           ▼                                             │
│        │  │  ┌──────────────────┐                                   │
│        │  │  │ JitsiFrameBridge │──▶ Unix Socket ──▶ Jitsi Screen  │
│        │  │  └──────────────────┘                      Share        │
│        │  │                                                         │
└────────┘  └─────────────────────────────────────────────────────────┘
```

## Video Frame Flow

```
Meta Glasses Camera (720p @ 24fps)
         │
         ▼
┌─────────────────────────────┐
│  Meta Wearables SDK         │
│  StreamSession.videoStream  │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  StreamSessionManager       │
│  - Converts to JPEG         │
│  - 70% quality compression  │
└─────────────┬───────────────┘
              │
       ┌──────┴──────┐
       │             │
       ▼             ▼
┌─────────────┐ ┌─────────────────┐
│JitsiFrame   │ │ Flutter Preview │
│Bridge       │ │ (every 3rd     │
│(all frames) │ │  frame = 8fps) │
└──────┬──────┘ └─────────────────┘
       │
       ▼
┌─────────────────────────────┐
│  Unix Domain Socket         │
│  /data/.../rtc_SSFD         │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  Jitsi Screen Share         │
│  (appears as shared screen) │
└─────────────────────────────┘
```

## Project Structure

```
spec_bridge_flutter/
├── lib/
│   ├── main.dart                    # App entry, Provider setup
│   ├── app/
│   │   ├── app.dart                 # MaterialApp + GoRouter
│   │   ├── routes.dart              # Route definitions
│   │   └── theme.dart               # App theming
│   ├── data/
│   │   └── models/
│   │       ├── glasses_state.dart   # Glasses connection state
│   │       ├── meeting_config.dart  # Jitsi meeting config
│   │       └── stream_status.dart   # Streaming state
│   ├── services/
│   │   ├── glasses_service.dart     # Meta glasses abstraction
│   │   ├── jitsi_service.dart       # Jitsi meeting management
│   │   ├── stream_service.dart      # Orchestrates streaming
│   │   ├── permission_service.dart  # System permissions
│   │   ├── deep_link_service.dart   # URL handling
│   │   └── platform_channels/
│   │       └── meta_dat_channel.dart # Native bridge interface
│   └── presentation/
│       └── screens/
│           ├── splash/              # Initial loading
│           ├── setup/               # Glasses + meeting config
│           └── streaming/           # Active stream view
├── android/
│   └── app/src/main/kotlin/com/specbridge/app/
│       ├── MainActivity.kt          # Flutter activity
│       ├── MetaWearablesPlugin.kt   # Platform channel handler
│       ├── MetaWearablesManager.kt  # SDK wrapper
│       ├── StreamSessionManager.kt  # Video capture
│       └── JitsiFrameBridge.kt      # Socket injection
└── ios/
    └── Runner/Native/               # iOS Swift implementation
```

## State Management (Provider)

```dart
MultiProvider(
  providers: [
    // Platform channel (singleton)
    Provider<MetaDATChannel>.value(value: metaDATChannel),

    // Stateless utilities
    Provider<PermissionService>(create: (_) => PermissionService()),

    // Reactive services with ChangeNotifier
    ChangeNotifierProvider<DeepLinkService>.value(value: deepLinkService),

    ChangeNotifierProxyProvider<MetaDATChannel, GlassesService>(...),

    ChangeNotifierProvider<JitsiService>(create: (_) => JitsiService()),

    ChangeNotifierProxyProvider2<GlassesService, JitsiService, StreamService>(...),

    // Router
    Provider<GoRouter>(create: (_) => createRouter()),
  ],
)
```

## Key Components

### 1. GlassesService
Manages Meta glasses connection lifecycle:
- SDK initialization
- Pairing via Meta View/Meta AI app
- Camera permission handling
- Video stream access

### 2. JitsiService
Handles Jitsi meeting integration:
- Join/leave meetings
- Audio/video mute controls
- Screen share toggle
- Meeting event callbacks

### 3. StreamService
Orchestrates the streaming pipeline:
- Coordinates glasses + Jitsi
- Manages frame flow
- Handles errors and reconnection

### 4. MetaDATChannel
Flutter ↔ Native bridge:
- MethodChannel for commands
- EventChannel for state updates
- EventChannel for frame data

## Platform Channels

```
┌─────────────────────────────────────────────────────────────┐
│                     CHANNEL NAMES                            │
├─────────────────────────────────────────────────────────────┤
│ com.specbridge/meta_dat        │ MethodChannel (commands)   │
│ com.specbridge/meta_dat_events │ EventChannel (state)       │
│ com.specbridge/meta_dat_frames │ EventChannel (JPEG data)   │
└─────────────────────────────────────────────────────────────┘

METHODS:
- configure()           → Initialize SDK
- startRegistration()   → Begin pairing
- handleUrl(url)        → Process callback
- checkCameraPermission() → Query permission
- requestCameraPermission() → Request permission
- startStreaming(config) → Begin video capture
- stopStreaming()       → End video capture

EVENTS:
- connectionState: {state: "connected"|"disconnected"|...}
- streamStatus: {status: "streaming"|"stopped"|...}
- incomingUrl: {url: "specbridge://..."}

FRAMES:
- Raw Uint8List JPEG data (every 3rd frame for preview)
```

## Deep Link Scheme

```
specbridge://
├── /callback              # Meta View/AI app return
│   → Completes pairing flow
│
└── /join                  # Direct meeting join
    ?room=RoomName         # Required: room name
    &server=https://...    # Optional: Jitsi server (default: meet.jit.si)
    &name=DisplayName      # Optional: user display name

Examples:
  specbridge://callback
  specbridge://join?room=MyMeeting
  specbridge://join?room=Team&server=https://custom.jitsi.com&name=John
```

## Socket Injection (JitsiFrameBridge)

The glasses video is injected into Jitsi via Unix domain socket, appearing as screen share:

```kotlin
// Socket path
val socketPath = "${context.filesDir.absolutePath}/rtc_SSFD"

// Frame message format (HTTP multipart style)
"""
--frame-boundary
Content-Type: image/jpeg
Content-Length: ${jpegData.size}
X-Frame-Index: $frameIndex
X-Timestamp: ${System.currentTimeMillis() / 1000.0}

[JPEG binary data]
"""
```

## Video Quality Options

| Quality | Resolution | Use Case |
|---------|------------|----------|
| HIGH    | 720×1280   | Default, best quality |
| MEDIUM  | 504×896    | Lower bandwidth |
| LOW     | 360×640    | Minimal bandwidth |

Frame rates: 2, 7, 15, 24, or 30 FPS (default: 24)

## User Flow

```
┌─────────┐     ┌──────────┐     ┌───────────┐     ┌───────────┐
│ Splash  │────▶│  Setup   │────▶│ Streaming │────▶│   End     │
│ Screen  │     │  Screen  │     │  Screen   │     │           │
└─────────┘     └──────────┘     └───────────┘     └───────────┘
     │               │                 │
     │               │                 │
     ▼               ▼                 ▼
 Initialize      1. Grant           Live view:
 SDK + check        permissions     - Video preview
 permissions     2. Connect         - Frame counter
                    glasses         - Mute controls
                 3. Configure       - End stream
                    meeting
                 4. Start
```

## Error Handling

| Error | Cause | Recovery |
|-------|-------|----------|
| SDK init failed | Missing Meta app | Prompt to install Meta View |
| Pairing timeout | User cancelled | Retry pairing |
| Permission denied | User declined | Open settings |
| Socket connect failed | Jitsi not ready | Retry with backoff |
| Frame send failed | Socket closed | Reconnect socket |

## Dependencies

```yaml
# State Management
provider: ^6.1.5

# Navigation
go_router: ^17.0.1
app_links: ^7.0.0

# Jitsi
jitsi_meet_flutter_sdk: ^11.6.0

# Permissions
permission_handler: ^12.0.1

# Storage
shared_preferences: ^2.5.4
```

```kotlin
// Android (build.gradle.kts)
com.meta.wearable:mwdat-core:0.3.0
com.meta.wearable:mwdat-camera:0.3.0
org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0
androidx.lifecycle:lifecycle-runtime-ktx:2.8.7
```

## Build Requirements

### Android
- Gradle 9.2.1
- Android Gradle Plugin 8.13.0
- Kotlin 2.1.0
- Java 21
- compileSdk/targetSdk 36
- minSdk 26

### Meta SDK Access
```bash
# Set GitHub token with read:packages scope
export GITHUB_TOKEN=ghp_xxxxx
flutter build apk
```

## Testing

```bash
# Analysis
flutter analyze

# Build debug APK
flutter build apk --debug

# Build release APK
flutter build apk --release
```
