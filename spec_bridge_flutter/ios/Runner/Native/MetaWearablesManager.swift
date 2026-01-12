import Foundation
import MWDATCore
import MWDATCamera

/// Delegate protocol for wearables manager events
protocol MetaWearablesManagerDelegate: AnyObject {
    func wearablesManager(_ manager: MetaWearablesManager, didChangeConnectionState state: ConnectionState)
    func wearablesManager(_ manager: MetaWearablesManager, didReceiveError error: Error)
}

/// Permission status for glasses camera
enum GlassesCameraPermission: String {
    case unknown
    case notDetermined = "notDetermined"
    case granted
    case denied
}

/// Manager for Meta Wearables DAT SDK interactions
class MetaWearablesManager {
    weak var delegate: MetaWearablesManagerDelegate?

    private var datCore: MWDATCoreProtocol?
    private var datCamera: MWDATCameraProtocol?

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var isConfigured = false

    // MARK: - Configuration

    func configure(completion: @escaping (Bool, Error?) -> Void) {
        // Initialize DAT Core
        MWDATCore.shared.configure { [weak self] result in
            switch result {
            case .success:
                self?.datCore = MWDATCore.shared
                self?.isConfigured = true
                completion(true, nil)
            case .failure(let error):
                completion(false, error)
            }
        }
    }

    // MARK: - Registration

    func startRegistration(completion: @escaping (Bool, Error?) -> Void) {
        guard let core = datCore else {
            completion(false, NSError(domain: "MetaWearables", code: -1,
                                     userInfo: [NSLocalizedDescriptionKey: "SDK not configured"]))
            return
        }

        connectionState = .connecting
        delegate?.wearablesManager(self, didChangeConnectionState: .connecting)

        // Open Meta View app for registration
        core.startRegistration { [weak self] result in
            switch result {
            case .success:
                completion(true, nil)
            case .failure(let error):
                self?.connectionState = .error
                self?.delegate?.wearablesManager(self!, didChangeConnectionState: .error)
                completion(false, error)
            }
        }
    }

    func handleCallback(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        guard let core = datCore else {
            completion(false, NSError(domain: "MetaWearables", code: -1,
                                     userInfo: [NSLocalizedDescriptionKey: "SDK not configured"]))
            return
        }

        core.handleCallback(url: url) { [weak self] result in
            switch result {
            case .success:
                self?.connectionState = .connected
                self?.delegate?.wearablesManager(self!, didChangeConnectionState: .connected)
                self?.initializeCamera()
                completion(true, nil)
            case .failure(let error):
                self?.connectionState = .error
                self?.delegate?.wearablesManager(self!, didChangeConnectionState: .error)
                completion(false, error)
            }
        }
    }

    // MARK: - Camera

    private func initializeCamera() {
        datCamera = MWDATCamera.shared
    }

    func checkCameraPermission(completion: @escaping (GlassesCameraPermission) -> Void) {
        guard let camera = datCamera else {
            completion(.unknown)
            return
        }

        camera.checkCameraPermission { status in
            let permission: GlassesCameraPermission
            switch status {
            case .notDetermined: permission = .notDetermined
            case .authorized: permission = .granted
            case .denied: permission = .denied
            default: permission = .unknown
            }
            completion(permission)
        }
    }

    func requestCameraPermission(completion: @escaping (GlassesCameraPermission) -> Void) {
        guard let camera = datCamera else {
            completion(.unknown)
            return
        }

        camera.requestCameraPermission { status in
            let permission: GlassesCameraPermission
            switch status {
            case .authorized: permission = .granted
            case .denied: permission = .denied
            default: permission = .unknown
            }
            completion(permission)
        }
    }

    // MARK: - Streaming

    func createStreamSession() -> MWDATStreamSessionProtocol? {
        return datCamera?.createStreamSession()
    }

    // MARK: - Cleanup

    func disconnect() {
        connectionState = .disconnected
        delegate?.wearablesManager(self, didChangeConnectionState: .disconnected)
    }
}
