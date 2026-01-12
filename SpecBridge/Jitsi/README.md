# Jitsi Integration for SpecBridge

This folder contains the components needed to stream Meta glasses video to Jitsi meetings.

## Architecture

```
Meta Glasses → StreamManager → JitsiFrameInjector → Unix Socket → react-native-webrtc → Jitsi Meeting
                                     ↓
                              SampleUploader
                              (JPEG encode + HTTP wrap)
                                     ↓
                              SocketConnection
                              (Unix domain socket)
```

## Files

| File | Purpose |
|------|---------|
| `Atomic.swift` | Thread-safe property wrapper |
| `DarwinNotificationCenter.swift` | Cross-process notifications |
| `SocketConnection.swift` | Unix socket communication |
| `SampleUploader.swift` | CMSampleBuffer → JPEG → HTTP message |
| `JitsiFrameInjector.swift` | Bridges StreamManager to socket |
| `JitsiManager.swift` | Jitsi SDK wrapper (requires SDK) |

## Setup Required

### 1. Add JitsiMeetSDK

The Jitsi SDK is distributed via CocoaPods. You'll need to:

1. Create a `Podfile` in the project root:
```ruby
platform :ios, '15.1'

target 'SpecBridge' do
  use_frameworks!
  pod 'JitsiMeetSDK', '~> 9.0'
end
```

2. Run `pod install`
3. Open `SpecBridge.xcworkspace` instead of `.xcodeproj`

### 2. Configure App Groups

1. In Xcode, select the SpecBridge target
2. Go to **Signing & Capabilities**
3. Click **+ Capability** → **App Groups**
4. Add: `group.com.dukes.SpecBridge`

### 3. Create Broadcast Upload Extension (Optional)

If you need full screen sharing support:

1. **File → New → Target → Broadcast Upload Extension**
2. Name it `BroadcastExtension`
3. Add it to the same App Group
4. Copy `SampleHandler.swift` from Jitsi samples

### 4. Uncomment JitsiMeetSDK Code

In `JitsiManager.swift`, uncomment the sections marked:
```swift
// === UNCOMMENT WHEN JitsiMeetSDK IS ADDED ===
```

## How It Works

1. **User selects Jitsi mode** in the app
2. **StreamManager** captures frames from Meta glasses
3. **JitsiFrameInjector** receives frames and:
   - JPEG encodes them (scaled down for bandwidth)
   - Wraps in HTTP message format
   - Sends via Unix socket
4. **react-native-webrtc** (in Jitsi SDK) receives frames
5. Frames appear as **"screen share"** in the meeting

## Limitations

- Video appears as "screen share" not "camera" in Jitsi
- Requires JitsiMeetSDK which adds ~100MB to app size
- Socket connection requires the Jitsi SDK to be listening

## Alternative: Direct WebRTC

For more control, you could bypass the Jitsi SDK entirely:

1. Use `JitsiWebRTC` pod directly
2. Create custom `RTCVideoCapturer` for glasses frames
3. Implement Jitsi signaling protocol

This is more work but gives you camera-style video instead of screen share.
