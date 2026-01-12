//
//  JitsiFrameInjector.swift
//  SpecBridge
//
//  Bridges Meta glasses video frames to Jitsi meetings via socket injection
//  This allows glasses video to appear as "screen share" in Jitsi
//

import Foundation
import CoreMedia
import UIKit

/// Configuration for the Jitsi frame injector
struct JitsiFrameInjectorConfig {
    /// App Group identifier shared with the Jitsi SDK / Broadcast Extension
    let appGroupIdentifier: String

    /// Socket file name within the app group container
    let socketFileName: String

    /// Frame rate limiting (send every Nth frame)
    let frameSkipCount: Int

    static let `default` = JitsiFrameInjectorConfig(
        appGroupIdentifier: "group.com.specbridge.app",
        socketFileName: "rtc_SSFD",
        frameSkipCount: 3  // Send every 3rd frame (8fps from 24fps source)
    )
}

@MainActor
class JitsiFrameInjector: ObservableObject {
    @Published var isConnected = false
    @Published var status = "Not Connected"
    @Published var framesSent: Int = 0

    private let config: JitsiFrameInjectorConfig
    private var socketConnection: SocketConnection?
    private var uploader: SampleUploader?
    private var frameCount: Int = 0

    /// Path to the socket file in the shared App Group container
    var socketFilePath: String {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: config.appGroupIdentifier
        ) else {
            print("[JitsiFrameInjector] Failed to get App Group container URL")
            return ""
        }
        return containerURL.appendingPathComponent(config.socketFileName).path
    }

    init(config: JitsiFrameInjectorConfig = .default) {
        self.config = config
    }

    // MARK: - Public Methods

    /// Start the frame injection system
    /// Call this when user wants to join a Jitsi meeting with glasses video
    func start() {
        status = "Initializing..."
        frameCount = 0
        framesSent = 0

        // Post notification that broadcast is starting
        // This tells react-native-webrtc to start listening on the socket
        DarwinNotificationCenter.shared.postNotification(.broadcastStarted)

        // Small delay to let the socket server start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.connectToSocket()
        }
    }

    /// Stop the frame injection system
    func stop() {
        status = "Stopping..."

        DarwinNotificationCenter.shared.postNotification(.broadcastStopped)

        socketConnection?.close()
        socketConnection = nil
        uploader = nil

        isConnected = false
        status = "Disconnected"
        frameCount = 0

        print("[JitsiFrameInjector] Stopped, total frames sent: \(framesSent)")
    }

    /// Inject a video frame from the Meta glasses
    /// Call this from StreamManager's video frame callback
    func injectFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isConnected else { return }

        frameCount += 1

        // Frame rate limiting - only send every Nth frame
        guard frameCount % config.frameSkipCount == 0 else { return }

        if uploader?.send(sample: sampleBuffer) == true {
            framesSent += 1

            // Update status periodically
            if framesSent % 30 == 0 {
                status = "Streaming (\(framesSent) frames)"
            }
        }
    }

    /// Alternative: inject from CVPixelBuffer directly
    func injectFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isConnected else { return }

        frameCount += 1
        guard frameCount % config.frameSkipCount == 0 else { return }

        if uploader?.send(pixelBuffer: pixelBuffer) == true {
            framesSent += 1

            if framesSent % 30 == 0 {
                status = "Streaming (\(framesSent) frames)"
            }
        }
    }

    // MARK: - Private Methods

    private func connectToSocket() {
        status = "Connecting to socket..."

        print("[JitsiFrameInjector] Socket path: \(socketFilePath)")

        // Check if socket file exists
        if !FileManager.default.fileExists(atPath: socketFilePath) {
            status = "Waiting for Jitsi..."
            print("[JitsiFrameInjector] Socket file not found, retrying in 1 second...")

            // Retry after delay - the socket is created by react-native-webrtc
            // when screen share is initiated
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.connectToSocket()
            }
            return
        }

        guard let connection = SocketConnection(filePath: socketFilePath) else {
            status = "Socket creation failed"
            print("[JitsiFrameInjector] Failed to create socket connection")
            return
        }

        socketConnection = connection
        uploader = SampleUploader(connection: connection)

        // Set up connection callbacks
        connection.didOpen = { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = true
                self?.status = "Connected - Ready"
                print("[JitsiFrameInjector] Socket connected!")
            }
        }

        connection.didClose = { [weak self] error in
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.status = "Disconnected"
                if let error = error {
                    print("[JitsiFrameInjector] Socket closed with error: \(error)")
                } else {
                    print("[JitsiFrameInjector] Socket closed")
                }
            }
        }

        // Open the connection
        if connection.open() {
            print("[JitsiFrameInjector] Socket connection initiated")
        } else {
            status = "Connection failed"
            print("[JitsiFrameInjector] Failed to open socket connection")

            // Retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.connectToSocket()
            }
        }
    }
}

// MARK: - Preview Helper
#if DEBUG
extension JitsiFrameInjector {
    static var preview: JitsiFrameInjector {
        let injector = JitsiFrameInjector()
        injector.isConnected = true
        injector.status = "Connected - Ready"
        injector.framesSent = 42
        return injector
    }
}
#endif
