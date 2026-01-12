import AVFoundation
import Foundation

/// Bridge for injecting video frames into Jitsi screen share
/// Uses Unix domain socket to communicate with Jitsi SDK's broadcast upload mechanism
class JitsiFrameBridge {
    private var socketConnection: SocketConnection?
    private var sampleUploader: SampleUploader?

    private(set) var isConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    // Socket path for Jitsi screen share
    // This matches the path Jitsi SDK expects for broadcast upload extension
    private let socketPath: String

    init() {
        // Use App Group container for socket path
        // This allows communication between main app and broadcast extension
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.specbridge.app"
        ) {
            socketPath = containerURL.appendingPathComponent("rtc_SSFD").path
        } else {
            // Fallback to temp directory
            socketPath = NSTemporaryDirectory() + "rtc_SSFD"
        }
    }

    // MARK: - Connection

    func connect() {
        guard !isConnected else { return }

        socketConnection = SocketConnection(socketPath: socketPath)
        socketConnection?.delegate = self

        sampleUploader = SampleUploader(connection: socketConnection!)

        socketConnection?.connect()
    }

    func disconnect() {
        isConnected = false
        reconnectAttempts = 0

        socketConnection?.disconnect()
        socketConnection = nil

        sampleUploader = nil
    }

    // MARK: - Frame Injection

    /// Send JPEG frame data to Jitsi screen share
    func sendFrame(_ jpegData: Data) {
        guard isConnected else {
            // Try to reconnect if disconnected
            if reconnectAttempts < maxReconnectAttempts {
                reconnectAttempts += 1
                connect()
            }
            return
        }

        sampleUploader?.uploadFrame(jpegData)
    }

    /// Send CMSampleBuffer to Jitsi screen share
    func sendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isConnected else { return }
        sampleUploader?.uploadSampleBuffer(sampleBuffer)
    }
}

// MARK: - SocketConnectionDelegate

extension JitsiFrameBridge: SocketConnectionDelegate {
    func socketDidConnect(_ socket: SocketConnection) {
        isConnected = true
        reconnectAttempts = 0
        print("[JitsiFrameBridge] Socket connected")
    }

    func socketDidDisconnect(_ socket: SocketConnection) {
        isConnected = false
        print("[JitsiFrameBridge] Socket disconnected")

        // Attempt reconnection
        if reconnectAttempts < maxReconnectAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.reconnectAttempts += 1
                self?.connect()
            }
        }
    }

    func socket(_ socket: SocketConnection, didReceiveError error: Error) {
        print("[JitsiFrameBridge] Socket error: \(error.localizedDescription)")
        isConnected = false
    }
}
