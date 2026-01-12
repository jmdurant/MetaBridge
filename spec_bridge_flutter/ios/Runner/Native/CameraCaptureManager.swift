import AVFoundation
import CoreMedia
import UIKit

/// Manages camera capture from phone cameras (front/back) for streaming
/// Uses AVCaptureSession for frame capture
class CameraCaptureManager: NSObject {

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let sessionQueue = DispatchQueue(label: "com.specbridge.camera.session")
    private let processingQueue = DispatchQueue(label: "com.specbridge.camera.processing")

    // Callback for captured frames
    var onFrameCaptured: ((CMSampleBuffer, Data) -> Void)?

    private var frameCount: Int = 0

    // Match iOS glasses streaming: 0.5x scaling, 0.8 JPEG quality
    private let scaleFactor: CGFloat = 0.5
    private let jpegQuality: CGFloat = 0.8

    private var useFrontCamera = false

    // MARK: - Public Methods

    func startCapture(useFrontCamera: Bool) -> Bool {
        self.useFrontCamera = useFrontCamera
        frameCount = 0

        // Check camera permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            var authorized = false
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { granted in
                authorized = granted
                semaphore.signal()
            }
            semaphore.wait()
            if !authorized { return false }
        default:
            return false
        }

        return setupCaptureSession()
    }

    func stopCapture() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil
            self?.videoOutput = nil
        }
    }

    // MARK: - Capture Session Setup

    private func setupCaptureSession() -> Bool {
        let session = AVCaptureSession()
        session.sessionPreset = .hd1280x720

        // Get camera device
        guard let camera = getCamera() else {
            print("[CameraCaptureManager] No camera available")
            return false
        }

        // Add input
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                print("[CameraCaptureManager] Cannot add camera input")
                return false
            }
        } catch {
            print("[CameraCaptureManager] Error creating camera input: \(error)")
            return false
        }

        // Add video output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: processingQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            print("[CameraCaptureManager] Cannot add video output")
            return false
        }

        // Configure connection
        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            // Mirror front camera
            if useFrontCamera && connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }

        captureSession = session
        videoOutput = output

        // Start capture
        sessionQueue.async {
            session.startRunning()
            print("[CameraCaptureManager] Capture session started")
        }

        return true
    }

    private func getCamera() -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = useFrontCamera ? .front : .back

        // Try to get wide angle camera first
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return device
        }

        // Fallback to any available camera
        return AVCaptureDevice.default(for: .video)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1

        // Convert to JPEG for Flutter preview
        guard let jpegData = convertToJpeg(sampleBuffer: sampleBuffer) else {
            return
        }

        // Call the callback with both sample buffer (for Jitsi) and JPEG (for Flutter)
        DispatchQueue.main.async { [weak self] in
            self?.onFrameCaptured?(sampleBuffer, jpegData)
        }
    }

    private func convertToJpeg(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Scale to 0.5x for bandwidth optimization
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: jpegQuality)
    }
}
