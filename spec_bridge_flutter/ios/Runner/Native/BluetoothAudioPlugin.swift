import Flutter
import AVFoundation
import UIKit

/// Flutter plugin for managing Bluetooth audio routing on iOS.
/// Supports routing audio to Meta glasses via Bluetooth HFP.
class BluetoothAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?

    private let audioSession = AVAudioSession.sharedInstance()

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: "com.specbridge/bluetooth_audio",
            binaryMessenger: messenger
        )
        eventChannel = FlutterEventChannel(
            name: "com.specbridge/bluetooth_audio_events",
            binaryMessenger: messenger
        )

        super.init()

        methodChannel.setMethodCallHandler(handle)
        eventChannel.setStreamHandler(self)

        setupNotifications()
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        // Not using standard registration - initialized manually in AppDelegate
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getAvailableDevices":
            getAvailableDevices(result: result)
        case "setAudioDevice":
            if let args = call.arguments as? [String: Any],
               let deviceId = args["deviceId"] as? String {
                setAudioDevice(deviceId: deviceId, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "deviceId is required", details: nil))
            }
        case "clearAudioDevice":
            clearAudioDevice(result: result)
        case "isBluetoothAudioActive":
            isBluetoothAudioActive(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func getAvailableDevices(result: @escaping FlutterResult) {
        do {
            // Ensure audio session is configured for Bluetooth
            try audioSession.setCategory(.playAndRecord, options: [.allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setActive(true)

            var devices: [[String: Any]] = []

            guard let availableInputs = audioSession.availableInputs else {
                result(devices)
                return
            }

            for input in availableInputs {
                if isBluetoothPort(input.portType) {
                    devices.append([
                        "id": input.uid,
                        "name": input.portName,
                        "type": getBluetoothType(input.portType),
                        "isConnected": true
                    ])
                }
            }

            result(devices)
        } catch {
            result(FlutterError(code: "GET_DEVICES_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func setAudioDevice(deviceId: String, result: @escaping FlutterResult) {
        do {
            // Ensure audio session is configured for Bluetooth
            try audioSession.setCategory(.playAndRecord, options: [.allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setMode(.videoChat)
            try audioSession.setActive(true)

            guard let availableInputs = audioSession.availableInputs else {
                result(false)
                return
            }

            // Find the device with matching UID
            guard let targetInput = availableInputs.first(where: { $0.uid == deviceId }) else {
                result(false)
                return
            }

            try audioSession.setPreferredInput(targetInput)
            print("BluetoothAudioPlugin: Set preferred input to \(targetInput.portName)")
            result(true)
        } catch {
            print("BluetoothAudioPlugin: Failed to set audio device - \(error)")
            result(FlutterError(code: "SET_DEVICE_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func clearAudioDevice(result: @escaping FlutterResult) {
        do {
            try audioSession.setPreferredInput(nil)
            result(nil)
        } catch {
            result(FlutterError(code: "CLEAR_DEVICE_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func isBluetoothAudioActive(result: @escaping FlutterResult) {
        let currentRoute = audioSession.currentRoute

        // Check if any input is Bluetooth
        let hasBluetoothInput = currentRoute.inputs.contains { input in
            isBluetoothPort(input.portType)
        }

        // Check if any output is Bluetooth
        let hasBluetoothOutput = currentRoute.outputs.contains { output in
            isBluetoothPort(output.portType)
        }

        result(hasBluetoothInput || hasBluetoothOutput)
    }

    private func isBluetoothPort(_ portType: AVAudioSession.Port) -> Bool {
        return portType == .bluetoothHFP ||
               portType == .bluetoothA2DP ||
               portType == .bluetoothLE
    }

    private func getBluetoothType(_ portType: AVAudioSession.Port) -> String {
        switch portType {
        case .bluetoothHFP:
            return "hfp"
        case .bluetoothA2DP:
            return "a2dp"
        case .bluetoothLE:
            return "ble"
        default:
            return "unknown"
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .newDeviceAvailable:
            // New device connected
            if let eventSink = eventSink {
                let currentRoute = audioSession.currentRoute
                for input in currentRoute.inputs {
                    if isBluetoothPort(input.portType) {
                        eventSink([
                            "type": "connected",
                            "device": [
                                "id": input.uid,
                                "name": input.portName,
                                "type": getBluetoothType(input.portType),
                                "isConnected": true
                            ]
                        ])
                    }
                }
            }

        case .oldDeviceUnavailable:
            // Device disconnected
            if let eventSink = eventSink,
               let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
                for input in previousRoute.inputs {
                    if isBluetoothPort(input.portType) {
                        eventSink([
                            "type": "disconnected",
                            "deviceId": input.uid
                        ])
                    }
                }
            }

        default:
            // Route changed for other reasons
            if let eventSink = eventSink {
                let currentRoute = audioSession.currentRoute
                let activeBluetoothInput = currentRoute.inputs.first { isBluetoothPort($0.portType) }
                eventSink([
                    "type": "routeChanged",
                    "activeDeviceId": activeBluetoothInput?.uid as Any
                ])
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
