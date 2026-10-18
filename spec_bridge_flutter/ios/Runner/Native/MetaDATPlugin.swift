import Flutter
import Foundation
import MWDATCore
import MWDATCamera

/// DAT 1.x integration for the Flutter WebView meeting pipeline.
@MainActor
final class MetaDATPlugin: NSObject {
    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private let frameChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?
    fileprivate var frameSink: FlutterEventSink?
    private var configured = false
    private var registrationTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var startupTimeout: Task<Void, Never>?
    private var deviceSession: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private var stream: MWDATCamera.Stream?
    private var frameToken: AnyListenerToken?
    private var frameTask: Task<Void, Never>?
    private var frameContinuation: AsyncStream<VideoFrame>.Continuation?
    private var stateToken: AnyListenerToken?
    private var errorToken: AnyListenerToken?
    private var sessionErrorToken: AnyListenerToken?
    private var cameraCaptureManager: CameraCaptureManager?
    private var currentVideoSource = "glasses"
    private var currentVideoQuality = "medium"
    private var currentFrameRate = 15
    private var streamWasActive = false
    private var framesReceived = 0
    private var framesProcessed = 0

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(name: "com.specbridge/meta_dat", binaryMessenger: messenger)
        eventChannel = FlutterEventChannel(name: "com.specbridge/meta_dat_events", binaryMessenger: messenger)
        frameChannel = FlutterEventChannel(name: "com.specbridge/meta_dat_frames", binaryMessenger: messenger)
        super.init()
        methodChannel.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in
                guard let self else { return }
                await self.handle(call, result: result)
            }
        }
        eventChannel.setStreamHandler(self)
        frameChannel.setStreamHandler(FrameStreamHandler(plugin: self))
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let args = call.arguments as? [String: Any] ?? [:]
        do {
            switch call.method {
            case "configure":
                if !configured {
                    try Wearables.configure()
                    configured = true
                    registrationTask = Task { [weak self] in
                        for await state in Wearables.shared.registrationStateStream() {
                            guard let self, !Task.isCancelled else { return }
                            self.publishRegistration(state)
                        }
                    }
                }
                publishRegistration(Wearables.shared.registrationState)
                result(true)
            case "startRegistration":
                try await Wearables.shared.startRegistration()
                result(true)
            case "handleUrl":
                guard let text = args["url"] as? String, let url = URL(string: text) else {
                    result(FlutterError(code: "INVALID_ARGS", message: "URL required", details: nil))
                    return
                }
                result(try await Wearables.shared.handleUrl(url))
                publishRegistration(Wearables.shared.registrationState)
            case "checkCameraPermission":
                result(try await Wearables.shared.checkPermissionStatus(.camera) == .granted ? "granted" : "denied")
            case "requestCameraPermission":
                result(try await Wearables.shared.requestPermission(.camera) == .granted ? "granted" : "denied")
            case "startStreaming":
                try startStreaming(args)
                result(true)
            case "stopStreaming":
                await stopStreaming()
                result(nil)
            case "disconnect":
                await stopStreaming()
                try await Wearables.shared.startUnregistration()
                result(nil)
            case "setVideoSource":
                currentVideoSource = args["source"] as? String ?? "glasses"
                result(true)
            case "setNativeServerEnabled", "isNativeServerEnabled":
                // iOS feeds the Dart loopback WebSocket through the frame channel.
                result(false)
            case "resetFrameServer":
                framesReceived = 0
                framesProcessed = 0
                result(true)
            case "getStreamStats":
                result([
                    "framesReceived": framesReceived, "framesProcessed": framesProcessed,
                    "videoSource": currentVideoSource, "videoQuality": currentVideoQuality,
                    "frameRate": currentFrameRate, "isConnected": stream?.state == .streaming
                ])
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch {
            result(FlutterError(code: "META_DAT_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func publishRegistration(_ state: RegistrationState) {
        let value: String
        switch state {
        case .registered: value = "connected"
        case .registering: value = "connecting"
        default: value = "disconnected"
        }
        eventSink?(["type": "connectionState", "state": value])
    }

    private func publishStatus(_ status: String, error: String? = nil) {
        var event: [String: Any] = ["type": "streamStatus", "status": status]
        if let error { event["error"] = error }
        eventSink?(event)
    }

    private func startStreaming(_ args: [String: Any]) throws {
        guard deviceSession == nil, cameraCaptureManager == nil else {
            throw NSError(domain: "SpecBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Already streaming"])
        }
        currentVideoSource = args["videoSource"] as? String ?? "glasses"
        currentVideoQuality = args["videoQuality"] as? String ?? "medium"
        let requestedFPS = args["frameRate"] as? Int ?? 15
        currentFrameRate = [2, 7, 15, 24, 30].min(by: { abs($0 - requestedFPS) < abs($1 - requestedFPS) }) ?? 15
        framesReceived = 0
        framesProcessed = 0
        publishStatus("starting")
        if currentVideoSource == "backCamera" || currentVideoSource == "frontCamera" {
            let capture = CameraCaptureManager()
            cameraCaptureManager = capture
            capture.onFrameCaptured = { [weak self] _, jpeg in
                self?.sendFrame(jpeg)
            }
            guard capture.startCapture(useFrontCamera: currentVideoSource == "frontCamera") else {
                cameraCaptureManager = nil
                throw NSError(domain: "SpecBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Camera unavailable"])
            }
            publishStatus("streaming")
            return
        }
        guard currentVideoSource == "glasses" else {
            throw NSError(domain: "SpecBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported video source"])
        }
        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        let session = try Wearables.shared.createSession(deviceSelector: selector)
        deviceSession = session
        sessionErrorToken = session.errorPublisher.listen { error in
            // Device state determines termination; compatibility warnings are nonfatal.
            NSLog("Meta device session: %@", error.localizedDescription)
        }
        sessionTask = Task { [weak self] in
            for await state in session.stateStream() {
                guard let self, !Task.isCancelled, self.deviceSession === session else { return }
                switch state {
                case .started:
                    if self.camera == nil {
                        do { try self.attachCamera(to: session) }
                        catch {
                            self.publishStatus("error", error: error.localizedDescription)
                            session.stop()
                        }
                    }
                case .paused: self.publishStatus("paused")
                case .stopped:
                    self.releaseSession()
                    self.publishStatus("stopped")
                    return
                case .stopping: self.publishStatus("stopping")
                default: break
                }
            }
        }
        do { try session.start() }
        catch {
            releaseSession()
            throw error
        }
        startupTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.deviceSession === session, self.stream?.state != .streaming else { return }
            self.publishStatus("error", error: "Timed out starting glasses camera")
            session.stop()
        }
    }

    private func attachCamera(to session: DeviceSession) throws {
        let resolution: StreamingResolution = currentVideoQuality == "high" ? .high : currentVideoQuality == "low" ? .low : .medium
        let config = StreamConfiguration(videoCodec: .raw, resolution: resolution, frameRate: UInt(currentFrameRate))
        guard let camera = try session.addCamera(config: config) else {
            throw NSError(domain: "SpecBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: "Camera could not be attached"])
        }
        self.camera = camera
        let stream = camera.stream
        self.stream = stream
        streamWasActive = false
        stateToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self, self.stream === stream else { return }
                if state != .stopped { self.streamWasActive = true }
                if state == .streaming { self.startupTimeout?.cancel() }
                switch state {
                case .streaming: self.publishStatus("streaming")
                case .paused: self.publishStatus("paused")
                case .starting, .waitingForDevice: self.publishStatus("starting")
                case .stopping: self.publishStatus("stopping")
                case .stopped:
                    if self.streamWasActive { session.stop() }
                }
            }
        }
        errorToken = stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.publishStatus("error", error: error.localizedDescription) }
        }
        let frames = AsyncStream<VideoFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frameContinuation = frames.continuation
        frameToken = stream.videoFramePublisher.listen { frame in
            frames.continuation.yield(frame)
        }
        frameTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await frame in frames.stream {
                guard !Task.isCancelled else { return }
                let jpeg = autoreleasepool { frame.makeUIImage()?.jpegData(compressionQuality: 0.7) }
                if let jpeg { await self?.deliverFrame(jpeg, from: stream) }
            }
        }
        stream.start()
    }

    private func sendFrame(_ data: Data) {
        framesReceived += 1
        if let frameSink {
            frameSink(FlutterStandardTypedData(bytes: data))
            framesProcessed += 1
        }
    }

    private func deliverFrame(_ data: Data, from source: MWDATCamera.Stream) {
        guard stream === source else { return }
        sendFrame(data)
    }

    private func stopStreaming() async {
        startupTimeout?.cancel()
        cameraCaptureManager?.stopCapture()
        cameraCaptureManager = nil
        if let session = deviceSession {
            publishStatus("stopping")
            session.stop()
            for await state in session.stateStream() {
                if state == .stopped { break }
            }
        }
        releaseSession()
        publishStatus("stopped")
    }

    private func releaseSession() {
        startupTimeout?.cancel()
        startupTimeout = nil
        sessionTask?.cancel()
        sessionTask = nil
        frameToken = nil
        frameContinuation?.finish()
        frameContinuation = nil
        frameTask?.cancel()
        frameTask = nil
        stateToken = nil
        errorToken = nil
        sessionErrorToken = nil
        stream = nil
        camera = nil
        deviceSession = nil
    }
}

extension MetaDATPlugin: FlutterStreamHandler {
    nonisolated func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        Task { @MainActor in
            self.eventSink = events
            if self.configured { self.publishRegistration(Wearables.shared.registrationState) }
        }
        return nil
    }
    nonisolated func onCancel(withArguments arguments: Any?) -> FlutterError? {
        Task { @MainActor in self.eventSink = nil }
        return nil
    }
}

private final class FrameStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: MetaDATPlugin?
    init(plugin: MetaDATPlugin) { self.plugin = plugin }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        Task { @MainActor in self.plugin?.frameSink = events }
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        Task { @MainActor in self.plugin?.frameSink = nil }
        return nil
    }
}
