import Flutter
import Foundation
import MWDATCore
import MWDATCamera

/// Flutter plugin for Meta Wearables DAT SDK integration
class MetaDATPlugin: NSObject {
    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private let frameChannel: FlutterEventChannel

    private var eventSink: FlutterEventSink?
    private var frameSink: FlutterEventSink?

    private var wearablesManager: MetaWearablesManager?
    private var streamManager: StreamSessionManager?
    private var jitsiBridge: JitsiFrameBridge?

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

        methodChannel.setMethodCallHandler(handleMethodCall)
        eventChannel.setStreamHandler(self)
        frameChannel.setStreamHandler(FrameStreamHandler(plugin: self))
    }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "configure":
            configure(result: result)

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
            checkCameraPermission(result: result)

        case "requestCameraPermission":
            requestCameraPermission(result: result)

        case "startStreaming":
            if let args = call.arguments as? [String: Any] {
                let width = args["width"] as? Int ?? 1280
                let height = args["height"] as? Int ?? 720
                let frameRate = args["frameRate"] as? Int ?? 24
                startStreaming(width: width, height: height, frameRate: frameRate, result: result)
            } else {
                startStreaming(width: 1280, height: 720, frameRate: 24, result: result)
            }

        case "stopStreaming":
            stopStreaming(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Method Implementations

    private func configure(result: @escaping FlutterResult) {
        wearablesManager = MetaWearablesManager()
        wearablesManager?.delegate = self

        wearablesManager?.configure { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    result(true)
                } else {
                    result(FlutterError(
                        code: "CONFIG_FAILED",
                        message: error?.localizedDescription ?? "Failed to configure SDK",
                        details: nil
                    ))
                }
            }
        }
    }

    private func startRegistration(result: @escaping FlutterResult) {
        guard let manager = wearablesManager else {
            result(FlutterError(code: "NOT_CONFIGURED", message: "Call configure first", details: nil))
            return
        }

        manager.startRegistration { success, error in
            DispatchQueue.main.async {
                if success {
                    result(true)
                } else {
                    result(FlutterError(
                        code: "REGISTRATION_FAILED",
                        message: error?.localizedDescription ?? "Failed to start registration",
                        details: nil
                    ))
                }
            }
        }
    }

    private func handleURL(_ url: URL, result: @escaping FlutterResult) {
        guard let manager = wearablesManager else {
            result(FlutterError(code: "NOT_CONFIGURED", message: "Call configure first", details: nil))
            return
        }

        manager.handleCallback(url: url) { success, error in
            DispatchQueue.main.async {
                if success {
                    self.sendEvent(["type": "connectionState", "state": "connected"])
                    result(true)
                } else {
                    self.sendEvent([
                        "type": "connectionState",
                        "state": "error",
                        "error": error?.localizedDescription ?? "Unknown error"
                    ])
                    result(false)
                }
            }
        }
    }

    private func checkCameraPermission(result: @escaping FlutterResult) {
        guard let manager = wearablesManager else {
            result("unknown")
            return
        }

        manager.checkCameraPermission { status in
            DispatchQueue.main.async {
                result(status.rawValue)
            }
        }
    }

    private func requestCameraPermission(result: @escaping FlutterResult) {
        guard let manager = wearablesManager else {
            result(FlutterError(code: "NOT_CONFIGURED", message: "Call configure first", details: nil))
            return
        }

        manager.requestCameraPermission { status in
            DispatchQueue.main.async {
                result(status.rawValue)
            }
        }
    }

    private func startStreaming(width: Int, height: Int, frameRate: Int, result: @escaping FlutterResult) {
        guard let manager = wearablesManager else {
            result(FlutterError(code: "NOT_CONFIGURED", message: "Call configure first", details: nil))
            return
        }

        // Initialize Jitsi frame bridge for socket injection
        jitsiBridge = JitsiFrameBridge()
        jitsiBridge?.connect()

        // Initialize stream session manager
        streamManager = StreamSessionManager(wearablesManager: manager)
        streamManager?.delegate = self

        let config = StreamConfig(width: width, height: height, frameRate: frameRate)
        streamManager?.startStreaming(config: config) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.sendEvent(["type": "streamStatus", "status": "streaming"])
                    result(true)
                } else {
                    self?.sendEvent([
                        "type": "streamStatus",
                        "status": "error",
                        "error": error?.localizedDescription ?? "Unknown error"
                    ])
                    result(FlutterError(
                        code: "STREAM_FAILED",
                        message: error?.localizedDescription ?? "Failed to start streaming",
                        details: nil
                    ))
                }
            }
        }
    }

    private func stopStreaming(result: @escaping FlutterResult) {
        streamManager?.stopStreaming()
        streamManager = nil

        jitsiBridge?.disconnect()
        jitsiBridge = nil

        sendEvent(["type": "streamStatus", "status": "stopped"])
        result(nil)
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
        DispatchQueue.main.async {
            self.eventSink?(data)
        }
    }

    fileprivate func sendFrame(_ data: Data) {
        DispatchQueue.main.async {
            self.frameSink?(FlutterStandardTypedData(bytes: data))
        }
    }
}

// MARK: - FlutterStreamHandler

extension MetaDATPlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
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
        plugin?.frameSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.frameSink = nil
        return nil
    }
}

// MARK: - MetaWearablesManagerDelegate

extension MetaDATPlugin: MetaWearablesManagerDelegate {
    func wearablesManager(_ manager: MetaWearablesManager, didChangeConnectionState state: ConnectionState) {
        let stateString: String
        switch state {
        case .disconnected: stateString = "disconnected"
        case .connecting: stateString = "connecting"
        case .connected: stateString = "connected"
        case .error: stateString = "error"
        }
        sendEvent(["type": "connectionState", "state": stateString])
    }

    func wearablesManager(_ manager: MetaWearablesManager, didReceiveError error: Error) {
        sendEvent([
            "type": "connectionState",
            "state": "error",
            "error": error.localizedDescription
        ])
    }
}

// MARK: - StreamSessionManagerDelegate

extension MetaDATPlugin: StreamSessionManagerDelegate {
    func streamManager(_ manager: StreamSessionManager, didReceiveFrame frameData: Data) {
        // Send to Jitsi via socket injection (every frame)
        jitsiBridge?.sendFrame(frameData)

        // Send to Flutter for preview (every 3rd frame to reduce bandwidth)
        if manager.frameCount % 3 == 0 {
            sendFrame(frameData)
        }
    }

    func streamManager(_ manager: StreamSessionManager, didChangeStatus status: StreamSessionStatus) {
        let statusString: String
        switch status {
        case .idle: statusString = "stopped"
        case .starting: statusString = "starting"
        case .streaming: statusString = "streaming"
        case .stopping: statusString = "stopping"
        case .error: statusString = "error"
        }
        sendEvent(["type": "streamStatus", "status": statusString])
    }

    func streamManager(_ manager: StreamSessionManager, didReceiveError error: Error) {
        sendEvent([
            "type": "streamStatus",
            "status": "error",
            "error": error.localizedDescription
        ])
    }
}

// MARK: - Supporting Types

enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case error
}

enum StreamSessionStatus {
    case idle
    case starting
    case streaming
    case stopping
    case error
}

struct StreamConfig {
    let width: Int
    let height: Int
    let frameRate: Int
}
