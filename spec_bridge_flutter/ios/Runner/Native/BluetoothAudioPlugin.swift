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
        case "forcePhoneMic":
            forcePhoneMic(result: result)
        case "setPhoneAudioMode":
            if let args = call.arguments as? [String: Any],
               let mode = args["mode"] as? String {
                setPhoneAudioMode(mode: mode, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "mode is required", details: nil))
            }
        case "routeToGlassesBle":
            routeToGlassesBle(result: result)
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

    /// Force audio to phone's built-in speaker/mic.
    /// This prevents Bluetooth from competing with glasses video stream.
    private func forcePhoneMic(result: @escaping FlutterResult) {
        do {
            // Override to speaker forces audio to built-in speaker
            try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker])
            try audioSession.overrideOutputAudioPort(.speaker)
            try audioSession.setActive(true)
            print("BluetoothAudioPlugin: Forced audio to phone speaker")
            result(true)
        } catch {
            print("BluetoothAudioPlugin: Failed to force phone mic - \(error)")
            result(FlutterError(code: "FORCE_PHONE_MIC_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    /// Set phone audio mode to speakerphone or earpiece.
    private func setPhoneAudioMode(mode: String, result: @escaping FlutterResult) {
        do {
            switch mode {
            case "speakerphone":
                try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker])
                try audioSession.overrideOutputAudioPort(.speaker)
                print("BluetoothAudioPlugin: Set audio to speakerphone")
            case "earpiece":
                try audioSession.setCategory(.playAndRecord, options: [])
                try audioSession.overrideOutputAudioPort(.none)
                print("BluetoothAudioPlugin: Set audio to earpiece")
            default:
                result(FlutterError(code: "INVALID_MODE", message: "Mode must be 'speakerphone' or 'earpiece'", details: nil))
                return
            }
            try audioSession.setActive(true)
            result(true)
        } catch {
            print("BluetoothAudioPlugin: Failed to set phone audio mode - \(error)")
            result(FlutterError(code: "SET_PHONE_AUDIO_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    /// Route audio to glasses, preferring BLE Audio over HFP.
    /// BLE Audio uses Bluetooth LE which doesn't compete with Classic used by glasses video.
    private func routeToGlassesBle(result: @escaping FlutterResult) {
        do {
            try audioSession.setCategory(.playAndRecord, options: [.allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setMode(.voiceChat)
            try audioSession.setActive(true)

            guard let availableInputs = audioSession.availableInputs else {
                result([
                    "success": false,
                    "type": "none",
                    "deviceName": NSNull()
                ])
                return
            }

            print("BluetoothAudioPlugin: Looking for glasses BLE audio...")
            print("BluetoothAudioPlugin: Available inputs: \(availableInputs.map { "\($0.portName) (\($0.portType.rawValue))" })")

            // Prefer BLE over HFP
            let bleDevice = availableInputs.first { $0.portType == .bluetoothLE }
            let hfpDevice = availableInputs.first { $0.portType == .bluetoothHFP }

            let targetDevice = bleDevice ?? hfpDevice
            let deviceType: String
            if bleDevice != nil {
                deviceType = "ble"
            } else if hfpDevice != nil {
                deviceType = "sco" // HFP is similar to SCO
            } else {
                deviceType = "none"
            }

            if let device = targetDevice {
                try audioSession.setPreferredInput(device)
                print("BluetoothAudioPlugin: Routed to \(deviceType) device: \(device.portName)")
                result([
                    "success": true,
                    "type": deviceType,
                    "deviceName": device.portName
                ])
            } else {
                print("BluetoothAudioPlugin: No BLE or HFP device found")
                result([
                    "success": false,
                    "type": "none",
                    "deviceName": NSNull()
                ])
            }
        } catch {
            print("BluetoothAudioPlugin: Failed to route to glasses BLE - \(error)")
            result(FlutterError(code: "ROUTE_GLASSES_BLE_ERROR", message: error.localizedDescription, details: nil))
        }
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
