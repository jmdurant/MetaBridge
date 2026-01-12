import AVFoundation
import Foundation

/// Uploads video frames to Jitsi via socket connection
/// Formats frames as HTTP-style messages that Jitsi's screen share expects
class SampleUploader {
    private let connection: SocketConnection
    private let queue = DispatchQueue(label: "com.specbridge.uploader", qos: .userInteractive)

    private var frameIndex: UInt64 = 0
    private let boundary = "frame-boundary"

    init(connection: SocketConnection) {
        self.connection = connection
    }

    // MARK: - Frame Upload

    /// Upload JPEG frame data to Jitsi
    func uploadFrame(_ jpegData: Data) {
        queue.async { [weak self] in
            self?.uploadFrameInternal(jpegData)
        }
    }

    private func uploadFrameInternal(_ jpegData: Data) {
        frameIndex += 1

        // Format as HTTP multipart message (Jitsi screen share protocol)
        let message = buildFrameMessage(jpegData)

        connection.write(message)
    }

    /// Upload CMSampleBuffer directly
    func uploadSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let jpegData = convertToJPEG(sampleBuffer) else { return }
        uploadFrame(jpegData)
    }

    // MARK: - Message Building

    private func buildFrameMessage(_ jpegData: Data) -> Data {
        // Build HTTP-style multipart message
        // This format is what Jitsi's Broadcast Upload Extension expects

        var message = Data()

        // Content headers
        let headers = """
        --\(boundary)\r
        Content-Type: image/jpeg\r
        Content-Length: \(jpegData.count)\r
        X-Frame-Index: \(frameIndex)\r
        X-Timestamp: \(Date().timeIntervalSince1970)\r
        \r

        """

        if let headerData = headers.data(using: .utf8) {
            message.append(headerData)
        }

        // JPEG data
        message.append(jpegData)

        // Boundary terminator
        if let terminator = "\r\n".data(using: .utf8) {
            message.append(terminator)
        }

        return message
    }

    // MARK: - JPEG Conversion

    private func convertToJPEG(_ sampleBuffer: CMSampleBuffer, quality: CGFloat = 0.7) -> Data? {
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
        return uiImage.jpegData(compressionQuality: quality)
    }

    // MARK: - Reset

    func reset() {
        frameIndex = 0
    }
}
