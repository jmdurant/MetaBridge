//
//  SampleUploader.swift
//  SpecBridge
//
//  Converts CMSampleBuffer frames to JPEG and sends via socket to Jitsi
//

import Foundation
import CoreMedia
import CoreImage
import UIKit
import ReplayKit

class SampleUploader {
    private static let imageContext = CIContext()

    @Atomic private var isReady = false
    private var connection: SocketConnection

    private var dataToSend: Data?
    private var byteIndex = 0

    private let serialQueue: DispatchQueue

    init(connection: SocketConnection) {
        self.connection = connection
        self.serialQueue = DispatchQueue(label: "com.specbridge.sampleuploader")

        setupConnection()
    }

    @discardableResult
    func send(sample: CMSampleBuffer) -> Bool {
        guard isReady else {
            return false
        }

        isReady = false

        dataToSend = prepare(sample: sample)
        byteIndex = 0

        serialQueue.async { [weak self] in
            self?.sendDataChunk()
        }

        return true
    }

    // Overload for sending raw pixel buffer with orientation
    @discardableResult
    func send(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) -> Bool {
        guard isReady else {
            return false
        }

        isReady = false

        dataToSend = prepare(pixelBuffer: pixelBuffer, orientation: orientation)
        byteIndex = 0

        serialQueue.async { [weak self] in
            self?.sendDataChunk()
        }

        return true
    }
}

// MARK: - Private Methods
private extension SampleUploader {
    func setupConnection() {
        connection.didOpen = { [weak self] in
            self?.isReady = true
            print("[SampleUploader] Connection opened, ready to send frames")
        }

        connection.didClose = { [weak self] error in
            self?.isReady = false
            print("[SampleUploader] Connection closed: \(String(describing: error))")
        }

        connection.streamHasSpaceAvailable = { [weak self] in
            self?.serialQueue.async {
                self?.sendDataChunk()
            }
        }
    }

    func sendDataChunk() {
        guard let dataToSend = dataToSend else {
            return
        }

        var bytesLeft = dataToSend.count - byteIndex
        var length = bytesLeft > 10240 ? 10240 : bytesLeft

        length = dataToSend[byteIndex..<(byteIndex + length)].withUnsafeBytes {
            guard let ptr = $0.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return connection.writeToStream(buffer: ptr, maxLength: length)
        }

        if length > 0 {
            byteIndex += length
            bytesLeft -= length

            if bytesLeft == 0 {
                self.dataToSend = nil
                byteIndex = 0
                isReady = true
            }
        }
    }

    func prepare(sample: CMSampleBuffer) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            print("[SampleUploader] Failed to get pixel buffer from sample")
            return nil
        }

        // Get orientation from sample buffer
        var orientation = CGImagePropertyOrientation.up
        if let orientationAttachment = CMGetAttachment(
            sample,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber {
            orientation = CGImagePropertyOrientation(rawValue: orientationAttachment.uint32Value) ?? .up
        }

        return prepare(pixelBuffer: pixelBuffer, orientation: orientation)
    }

    func prepare(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> Data? {
        // Scale down for bandwidth (0.5 = half resolution)
        guard let jpegData = jpegData(from: pixelBuffer, scale: 0.5) else {
            print("[SampleUploader] Failed to create JPEG data")
            return nil
        }

        // Wrap in HTTP message format (what react-native-webrtc expects)
        guard let message = CFHTTPMessageCreateResponse(
            kCFAllocatorDefault,
            200,
            nil,
            kCFHTTPVersion1_1
        ).takeRetainedValue() as CFHTTPMessage? else {
            print("[SampleUploader] Failed to create HTTP message")
            return nil
        }

        CFHTTPMessageSetHeaderFieldValue(
            message,
            "Content-Length" as CFString,
            "\(jpegData.count)" as CFString
        )

        CFHTTPMessageSetHeaderFieldValue(
            message,
            "Buffer-Orientation" as CFString,
            "\(orientation.rawValue)" as CFString
        )

        CFHTTPMessageSetBody(message, jpegData as CFData)

        guard let serializedMessage = CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data? else {
            print("[SampleUploader] Failed to serialize HTTP message")
            return nil
        }

        return serializedMessage
    }

    func jpegData(from pixelBuffer: CVPixelBuffer, scale: CGFloat) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = Self.imageContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        let uiImage = UIImage(cgImage: cgImage)

        // Use high quality JPEG compression
        return uiImage.jpegData(compressionQuality: 0.8)
    }
}
