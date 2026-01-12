import Foundation
import SwiftUI
import Combine
import UIKit
import AVFoundation
import MWDATCore
import MWDATCamera

/// Output mode for the glasses video stream
enum StreamOutputMode {
    case twitch
    case jitsi
    case both
}

@MainActor
class StreamManager: ObservableObject {
    @Published var currentFrame: UIImage?
    @Published var status = "Ready to Stream"
    @Published var isStreaming = false

    private var streamSession: StreamSession?
    private var token: AnyListenerToken?

    /// Current output mode
    var outputMode: StreamOutputMode = .twitch

    // Reference to Twitch Manager
    var twitchManager: TwitchManager?

    // Reference to Jitsi Frame Injector
    var jitsiFrameInjector: JitsiFrameInjector?
    
    private func configureAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Sets iOS to allow Bluetooth audio (prevents "Video Paused" error)
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            print("Audio session configured successfully")
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    func startStreaming() async {
        status = "Checking permissions..."
        
        let currentStatus = try? await Wearables.shared.checkPermissionStatus(.camera)
        if currentStatus != .granted {
            status = "Requesting permission..."
            let requestResult = try? await Wearables.shared.requestPermission(.camera)
            if requestResult != .granted {
                status = "Permission denied. Check Meta AI app."
                return
            }
        }
        
        status = "Configuring Audio..."
        configureAudio()
        
        status = "Configuring session..."
        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        
        // Use High resolution for 720p 9:16 vertical video
        let config = StreamSessionConfig(
            videoCodec: .raw,
            resolution: .high,
            frameRate: 24
        )
        
        let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)
        self.streamSession = session
        
        // --- VIDEO HANDLING ---
        token = session.videoFramePublisher.listen { [weak self] frame in
            // 1. Create the visual image for the iPhone screen
            if let image = frame.makeUIImage() {
                Task { @MainActor in
                    self?.currentFrame = image
                    self?.status = "Streaming Live"
                    self?.isStreaming = true
                }
            }

            // 2. Extract the RAW buffer
            let buffer = frame.sampleBuffer

            // 3. Route to output destinations based on mode
            Task { @MainActor in
                guard let self = self else { return }

                switch self.outputMode {
                case .twitch:
                    self.twitchManager?.processVideoFrame(buffer)

                case .jitsi:
                    self.jitsiFrameInjector?.injectFrame(buffer)

                case .both:
                    self.twitchManager?.processVideoFrame(buffer)
                    self.jitsiFrameInjector?.injectFrame(buffer)
                }
            }
        }
        
        status = "Starting stream..."
        await session.start()
    }
    
    func stopStreaming() async {
        status = "Stopping..."
        await streamSession?.stop()

        // Stop outputs based on mode
        switch outputMode {
        case .twitch:
            await twitchManager?.stopBroadcast()

        case .jitsi:
            jitsiFrameInjector?.stop()

        case .both:
            await twitchManager?.stopBroadcast()
            jitsiFrameInjector?.stop()
        }

        status = "Ready to Stream"
        isStreaming = false
        currentFrame = nil
    }
}
