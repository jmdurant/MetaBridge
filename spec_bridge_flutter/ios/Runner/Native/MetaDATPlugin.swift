import Flutter
import Foundation
import MWDATCore
import MWDATCamera
import AVFoundation

/// Flutter plugin for Meta Wearables DAT SDK integration
/// Uses REAL SDK APIs from MWDATCore/MWDATCamera
@MainActor
class MetaDATPlugin: NSObject {
    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private let frameChannel: FlutterEventChannel

    private var eventSink: FlutterEventSink?
    private var frameSink: FlutterEventSink?

    // Real SDK objects
    private var streamSession: StreamSession?
    private var videoFrameToken: AnyListenerToken?
    private var stateToken: AnyListenerToken?
    private var jitsiFrameInjector: JitsiFrameInjector?

    private var frameCount: Int = 0
    private var pendingURL: URL?

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: "com.specbridge/meta_dat",
            binaryMessenger: messenger
        )
        eventChannel = FlutterEventChannel(
            name: "com.specbridge/meta_dat_events",
            binaryMessenger: messenger
        )
        frameChannel = FlutterEventChannel(
            name: "com.specbridge/meta_dat_frames",
            binaryMessenger: messenger
        )

        super.init()

        methodChannel.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in
                self?.handleMethodCall(call, result: result)
            }
        }
        eventChannel.setStreamHandler(self)
        frameChannel.setStreamHandler(FrameStreamHandler(plugin: self))
    }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "configure":
            // SDK auto-initializes, no configuration needed
            result(true)

        case "startRegistration":
            startRegistration(result: result)

        case "handleUrl":
            if let args = call.arguments as? [String: Any],
               let urlString = args["url"] as? String,
               let url = URL(string: urlString) {
                handleURL(url, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "URL required", details: nil))
            }

        case "checkCameraPermission":
            Task {
                await checkCameraPermission(result: result)
            }

        case "requestCameraPermission":
            Task {
                await requestCameraPermission(result: result)
            }

        case "startStreaming":
            let args = call.arguments as? [String: Any]
            let videoSource = args?["videoSource"] as? String ?? "glasses"
            let videoQuality = args?["videoQuality"] as? String ?? "medium"
            let frameRate = args?["frameRate"] as? Int ?? 24
            Task {
                await startStreaming(videoSource: videoSource, videoQuality: videoQuality, frameRate: frameRate, result: result)
            }

        case "stopStreaming":
            Task {
                await stopStreaming(result: result)
            }

        case "disconnect":
            Task {
                await disconnect(result: result)
            }

        case "setVideoSource":
            if let args = call.arguments as? [String: Any],
               let source = args["source"] as? String {
                setVideoSource(source: source, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "source required", details: nil))
            }

        case "getStreamStats":
            getStreamStats(result: result)

        case "setNativeServerEnabled":
            // No-op on iOS - we use Unix socket instead of WebSocket server
            result(true)

        case "resetFrameServer":
            resetFrameServer(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Registration

    private func startRegistration(result: @escaping FlutterResult) {
        sendEvent(["type": "connectionState", "state": "connecting"])

        do {
            try Wearables.shared.startRegistration()
            result(true)
        } catch {
            sendEvent([
                "type": "connectionState",
                "state": "error",
                "error": error.localizedDescription
            ])
            result(FlutterError(
                code: "REGISTRATION_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    private func handleURL(_ url: URL, result: @escaping FlutterResult) {
        // The URL is handled automatically by the SDK when the app returns from Meta View
        // We just need to notify Flutter about the connection state
        sendEvent(["type": "connectionState", "state": "connected"])
        result(true)
    }

    // MARK: - Permissions (Real async APIs)

    private func checkCameraPermission(result: @escaping FlutterResult) async {
        do {
            let status = try await Wearables.shared.checkPermissionStatus(.camera)
            let statusString = permissionStatusToString(status)
            result(statusString)
        } catch {
            result("unknown")
        }
    }

    private func requestCameraPermission(result: @escaping FlutterResult) async {
        do {
            let status = try await Wearables.shared.requestPermission(.camera)
            let statusString = permissionStatusToString(status)
            result(statusString)
        } catch {
            result(FlutterError(
                code: "PERMISSION_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    private func permissionStatusToString(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    // Camera capture manager for phone cameras
    private var cameraCaptureManager: CameraCaptureManager?
    private var currentVideoSource: String = "glasses"
    private var currentVideoQuality: String = "medium"
    private var currentFrameRate: Int = 24

    // Stats tracking
    private var framesReceived: Int = 0
    private var framesProcessed: Int = 0
    private var streamStartTime: Date?

    // MARK: - Streaming

    private func startStreaming(videoSource: String, videoQuality: String, frameRate: Int, result: @escaping FlutterResult) async {
        currentVideoSource = videoSource
        currentVideoQuality = videoQuality
        currentFrameRate = frameRate
        sendEvent(["type": "streamStatus", "status": "starting"])
        frameCount = 0
        framesReceived = 0
        framesProcessed = 0
        streamStartTime = Date()

        // Configure audio session for Bluetooth
        configureAudio()

        // Initialize Jitsi frame injector for socket injection
        jitsiFrameInjector = JitsiFrameInjector()
        jitsiFrameInjector?.start()

        print("[MetaDATPlugin] Starting stream: source=\(videoSource), quality=\(videoQuality), fps=\(frameRate)")

        switch videoSource {
        case "glasses":
            await startGlassesStreaming(videoQuality: videoQuality, frameRate: frameRate, result: result)
        case "backCamera":
            startCameraStreaming(useFrontCamera: false, result: result)
        case "frontCamera":
            startCameraStreaming(useFrontCamera: true, result: result)
        case "screenRecord":
            result(FlutterError(code: "NOT_IMPLEMENTED", message: "Screen recording not yet implemented", details: nil))
        default:
            result(FlutterError(code: "INVALID_SOURCE", message: "Unknown video source: \(videoSource)", details: nil))
        }
    }

    private func startGlassesStreaming(videoQuality: String, frameRate: Int, result: @escaping FlutterResult) async {
        // Create device selector (auto-selects available device)
        let selector = AutoDeviceSelector(wearables: Wearables.shared)

        // Map video quality string to SDK resolution
        let resolution: StreamSessionConfig.Resolution
        switch videoQuality.lowercased() {
        case "low":
            resolution = .low
        case "high":
            resolution = .high
        default:
            resolution = .medium
        }

        // Coerce frame rate to valid SDK values: 30, 24, 15, 7, 2
        let validFpsValues = [30, 24, 15, 7, 2]
        let fps = validFpsValues.min(by: { abs($0 - frameRate) < abs($1 - frameRate) }) ?? 24

        print("[MetaDATPlugin] Using resolution: \(resolution), fps: \(fps) (requested: \(frameRate))")

        // Configure stream with parameters
        let config = StreamSessionConfig(
            videoCodec: .raw,
            resolution: resolution,
            frameRate: fps
        )

        // Create stream session
        let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)
        self.streamSession = session

        // Subscribe to session state changes
        stateToken = session.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                self?.handleSessionState(state)
            }
        }

        // Subscribe to video frames
        videoFrameToken = session.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in
                self?.handleVideoFrame(frame)
            }
        }

        // Start the stream
        await session.start()
        result(true)
    }

    private func startCameraStreaming(useFrontCamera: Bool, result: @escaping FlutterResult) {
        cameraCaptureManager = CameraCaptureManager()
        cameraCaptureManager?.onFrameCaptured = { [weak self] sampleBuffer, jpegData in
            guard let self = self else { return }
            self.frameCount += 1

            // Send to Jitsi via socket injection
            self.jitsiFrameInjector?.injectFrame(sampleBuffer)

            // Send preview to Flutter (every 3rd frame)
            if self.frameCount % 3 == 0 {
                self.sendFrame(jpegData)
            }
        }

        let success = cameraCaptureManager?.startCapture(useFrontCamera: useFrontCamera) ?? false
        if success {
            sendEvent(["type": "streamStatus", "status": "streaming"])
        }
        result(success)
    }

    private func stopStreaming(result: @escaping FlutterResult) async {
        sendEvent(["type": "streamStatus", "status": "stopping"])

        // Stop glasses stream session
        await streamSession?.stop()
        videoFrameToken = nil
        stateToken = nil
        streamSession = nil

        // Stop camera capture
        cameraCaptureManager?.stopCapture()
        cameraCaptureManager = nil

        // Stop Jitsi injector
        jitsiFrameInjector?.stop()
        jitsiFrameInjector = nil

        sendEvent(["type": "streamStatus", "status": "stopped"])
        result(nil)
    }

    private func disconnect(result: @escaping FlutterResult) async {
        print("[MetaDATPlugin] Disconnecting from glasses...")

        // Stop any active streaming
        await streamSession?.stop()
        videoFrameToken = nil
        stateToken = nil
        streamSession = nil

        cameraCaptureManager?.stopCapture()
        cameraCaptureManager = nil

        jitsiFrameInjector?.stop()
        jitsiFrameInjector = nil

        sendEvent(["type": "connectionState", "state": "disconnected"])
        result(nil)
    }

    private func setVideoSource(source: String, result: @escaping FlutterResult) {
        currentVideoSource = source
        print("[MetaDATPlugin] Video source set to: \(source)")
        result(true)
    }

    private func getStreamStats(result: @escaping FlutterResult) {
        let stats: [String: Any] = [
            "framesReceived": framesReceived,
            "framesProcessed": framesProcessed,
            "framesSent": jitsiFrameInjector?.framesSent ?? 0,
            "videoSource": currentVideoSource,
            "videoQuality": currentVideoQuality,
            "frameRate": currentFrameRate,
            "isConnected": jitsiFrameInjector?.isConnected ?? false,
            "streamDurationMs": streamStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        ]
        result(stats)
    }

    private func resetFrameServer(result: @escaping FlutterResult) {
        print("[MetaDATPlugin] Resetting frame server...")

        // Reset the Jitsi frame injector for clean session transition
        jitsiFrameInjector?.stop()
        jitsiFrameInjector = nil

        // Reset counters
        frameCount = 0
        framesReceived = 0
        framesProcessed = 0

        result(true)
    }

    private func handleSessionState(_ state: StreamSessionState) {
        let statusString: String
        switch state {
        case .stopped: statusString = "stopped"
        case .waitingForDevice: statusString = "waiting"
        case .starting: statusString = "starting"
        case .streaming: statusString = "streaming"
        case .paused: statusString = "paused"
        case .stopping: statusString = "stopping"
        @unknown default: statusString = "unknown"
        }
        sendEvent(["type": "streamStatus", "status": statusString])
    }

    private func handleVideoFrame(_ frame: VideoFrame) {
        frameCount += 1
        framesReceived += 1

        // Send to Jitsi via socket injection (uses CMSampleBuffer)
        jitsiFrameInjector?.injectFrame(frame.sampleBuffer)
        framesProcessed += 1

        // Send preview to Flutter (every 3rd frame to reduce bandwidth)
        if frameCount % 3 == 0 {
            if let image = frame.makeUIImage(),
               let jpegData = image.jpegData(compressionQuality: 0.7) {
                sendFrame(jpegData)
            }
        }

        // Log stats periodically
        if frameCount % 100 == 0 {
            print("[MetaDATPlugin] Frames: received=\(framesReceived), processed=\(framesProcessed), sent=\(jitsiFrameInjector?.framesSent ?? 0)")
        }
    }

    private func configureAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
            print("[MetaDATPlugin] Audio session configured for Bluetooth")
        } catch {
            print("[MetaDATPlugin] Failed to configure audio session: \(error)")
        }
    }

    // MARK: - URL Handling

    func handleIncomingURL(_ url: URL) {
        pendingURL = url
        sendEvent([
            "type": "incomingUrl",
            "url": url.absoluteString
        ])
    }

    // MARK: - Event Helpers

    private func sendEvent(_ data: [String: Any]) {
        eventSink?(data)
    }

    fileprivate func sendFrame(_ data: Data) {
        frameSink?(FlutterStandardTypedData(bytes: data))
    }
}

// MARK: - FlutterStreamHandler

extension MetaDATPlugin: FlutterStreamHandler {
    nonisolated func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        Task { @MainActor in
            self.eventSink = events
        }
        return nil
    }

    nonisolated func onCancel(withArguments arguments: Any?) -> FlutterError? {
        Task { @MainActor in
            self.eventSink = nil
        }
        return nil
    }
}

// MARK: - Frame Stream Handler

private class FrameStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: MetaDATPlugin?

    init(plugin: MetaDATPlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        Task { @MainActor in
            self.plugin?.frameSink = events
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        Task { @MainActor in
            self.plugin?.frameSink = nil
        }
        return nil
    }
}
