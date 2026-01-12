import AVFoundation
import Foundation
import MWDATCamera

/// Delegate protocol for stream session events
protocol StreamSessionManagerDelegate: AnyObject {
    func streamManager(_ manager: StreamSessionManager, didReceiveFrame frameData: Data)
    func streamManager(_ manager: StreamSessionManager, didChangeStatus status: StreamSessionStatus)
    func streamManager(_ manager: StreamSessionManager, didReceiveError error: Error)
}

/// Manages video streaming session from Meta glasses
class StreamSessionManager {
    weak var delegate: StreamSessionManagerDelegate?

    private let wearablesManager: MetaWearablesManager
    private var streamSession: MWDATStreamSessionProtocol?

    private(set) var status: StreamSessionStatus = .idle
    private(set) var frameCount: Int = 0

    private let jpegQuality: CGFloat = 0.7
    private var lastFrameTime: CFTimeInterval = 0
    private let targetFrameInterval: CFTimeInterval // 1/frameRate

    init(wearablesManager: MetaWearablesManager, targetFrameRate: Int = 24) {
        self.wearablesManager = wearablesManager
        self.targetFrameInterval = 1.0 / Double(targetFrameRate)
    }

    // MARK: - Streaming Control

    func startStreaming(config: StreamConfig, completion: @escaping (Bool, Error?) -> Void) {
        guard status == .idle else {
            completion(false, NSError(domain: "StreamSession", code: -1,
                                     userInfo: [NSLocalizedDescriptionKey: "Already streaming"]))
            return
        }

        status = .starting
        delegate?.streamManager(self, didChangeStatus: .starting)
        frameCount = 0

        // Create stream session from DAT SDK
        guard let session = wearablesManager.createStreamSession() else {
            let error = NSError(domain: "StreamSession", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "Failed to create stream session"])
            status = .error
            delegate?.streamManager(self, didChangeStatus: .error)
            delegate?.streamManager(self, didReceiveError: error)
            completion(false, error)
            return
        }

        streamSession = session

        // Configure stream parameters
        let streamConfig = MWDATStreamSessionConfig(
            resolution: CGSize(width: CGFloat(config.width), height: CGFloat(config.height)),
            frameRate: config.frameRate
        )

        session.configure(with: streamConfig) { [weak self] result in
            switch result {
            case .success:
                self?.subscribeToFrames()
                self?.status = .streaming
                self?.delegate?.streamManager(self!, didChangeStatus: .streaming)
                completion(true, nil)
            case .failure(let error):
                self?.status = .error
                self?.delegate?.streamManager(self!, didChangeStatus: .error)
                self?.delegate?.streamManager(self!, didReceiveError: error)
                completion(false, error)
            }
        }
    }

    func stopStreaming() {
        guard status == .streaming else { return }

        status = .stopping
        delegate?.streamManager(self, didChangeStatus: .stopping)

        streamSession?.stop()
        streamSession = nil

        status = .idle
        delegate?.streamManager(self, didChangeStatus: .idle)
    }

    // MARK: - Frame Processing

    private func subscribeToFrames() {
        streamSession?.videoFramePublisher.sink { [weak self] sampleBuffer in
            self?.processFrame(sampleBuffer)
        }
    }

    private func processFrame(_ sampleBuffer: CMSampleBuffer) {
        // Rate limiting
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastFrameTime >= targetFrameInterval else { return }
        lastFrameTime = currentTime

        frameCount += 1

        // Convert CMSampleBuffer to JPEG data
        guard let jpegData = convertToJPEG(sampleBuffer) else { return }

        // Send to delegate
        delegate?.streamManager(self, didReceiveFrame: jpegData)
    }

    private func convertToJPEG(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: jpegQuality)
    }
}

// MARK: - MWDATStreamSessionConfig (if not provided by SDK)

/// Configuration for stream session (may need adjustment based on actual SDK API)
struct MWDATStreamSessionConfig {
    let resolution: CGSize
    let frameRate: Int
}

// MARK: - Protocol Stubs (for compilation - actual implementations from SDK)

/// Protocol representing DAT stream session (actual implementation from MWDATCamera)
protocol MWDATStreamSessionProtocol {
    var videoFramePublisher: VideoFramePublisher { get }
    func configure(with config: MWDATStreamSessionConfig, completion: @escaping (Result<Void, Error>) -> Void)
    func stop()
}

/// Simple publisher wrapper for video frames
class VideoFramePublisher {
    private var subscriber: ((CMSampleBuffer) -> Void)?

    func sink(_ handler: @escaping (CMSampleBuffer) -> Void) {
        subscriber = handler
    }

    func send(_ sampleBuffer: CMSampleBuffer) {
        subscriber?(sampleBuffer)
    }
}
