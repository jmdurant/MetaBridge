# SpecBridge Flutter

Stream video from Meta Ray-Ban smart glasses to Jitsi video meetings.

## What It Does

SpecBridge captures the camera feed from Meta Ray-Ban glasses and streams it to a Jitsi meeting as a screen share. Remote participants see exactly what the glasses wearer sees in real-time.

## Requirements

- Meta Ray-Ban smart glasses (paired with Meta View or Meta AI app)
- Android device (API 26+) or iOS device
- GitHub account (for Meta SDK access)

## Quick Start

### 1. Get Meta SDK Access

Create a GitHub Personal Access Token with `read:packages` scope:
https://github.com/settings/tokens/new

```bash
export GITHUB_TOKEN=ghp_your_token_here
```

### 2. Build & Run

```bash
cd spec_bridge_flutter
flutter pub get
flutter run
```

### 3. Connect Glasses

1. Open the app
2. Grant camera/microphone permissions
3. Tap "Connect Glasses"
4. Complete pairing in Meta View/AI app
5. Enter room name and tap "Start Streaming"

## Deep Links

Join meetings directly via URL:

```
specbridge://join?room=MyRoom
specbridge://join?room=Team&server=https://custom.jitsi.com&name=John
```

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed documentation.

```
Meta Glasses → Meta SDK → StreamSessionManager → JitsiFrameBridge → Jitsi Screen Share
                                    ↓
                            Flutter Preview (8fps)
```

## Project Structure

```
lib/
├── services/           # Business logic
│   ├── glasses_service.dart
│   ├── jitsi_service.dart
│   └── stream_service.dart
├── presentation/       # UI screens
│   └── screens/
│       ├── setup/
│       └── streaming/
└── main.dart           # Entry point

android/.../kotlin/
├── MetaWearablesPlugin.kt    # Platform channel
├── MetaWearablesManager.kt   # SDK wrapper
├── StreamSessionManager.kt   # Video capture
└── JitsiFrameBridge.kt       # Socket injection
```

## Tech Stack

| Component | Technology |
|-----------|------------|
| Framework | Flutter 3.16+ |
| State | Provider |
| Navigation | GoRouter |
| Video | Meta Wearables SDK |
| Meetings | Jitsi Meet Flutter SDK |
| Deep Links | app_links |

## Configuration

### Video Quality

Default: 720p @ 24fps

Configurable in `StreamSessionManager.kt`:
- HIGH: 720x1280
- MEDIUM: 504x896
- LOW: 360x640

### Jitsi Server

Default: `meet.jit.si`

Custom servers supported via deep link or setup screen.

## Building

```bash
# Debug
flutter build apk --debug

# Release
flutter build apk --release

# iOS
flutter build ios
```

## License

MIT
