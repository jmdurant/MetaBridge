//
//  SocketConnection.swift
//  SpecBridge
//
//  Unix domain socket connection for communicating with Jitsi's react-native-webrtc
//

import Foundation

class SocketConnection: NSObject {
    var didOpen: (() -> Void)?
    var didClose: ((Error?) -> Void)?
    var streamHasSpaceAvailable: (() -> Void)?

    private let filePath: String
    private var socketHandle: Int32 = -1
    private var address: sockaddr_un?

    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    private var networkQueue: DispatchQueue?
    private var shouldKeepRunning = false

    init?(filePath path: String) {
        filePath = path
        socketHandle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)

        guard socketHandle != -1 else {
            print("[SocketConnection] Failed to create socket")
            return nil
        }

        super.init()
    }

    deinit {
        close()
    }

    func open() -> Bool {
        print("[SocketConnection] Opening socket connection to: \(filePath)")

        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[SocketConnection] Socket file does not exist at: \(filePath)")
            return false
        }

        guard setupAddress() else {
            print("[SocketConnection] Failed to setup address")
            return false
        }

        guard connectSocket() else {
            print("[SocketConnection] Failed to connect socket")
            return false
        }

        setupStreams()

        inputStream?.open()
        outputStream?.open()

        print("[SocketConnection] Socket connection opened successfully")
        return true
    }

    func close() {
        print("[SocketConnection] Closing socket connection")

        unscheduleStreams()

        inputStream?.delegate = nil
        outputStream?.delegate = nil

        inputStream?.close()
        outputStream?.close()

        inputStream = nil
        outputStream = nil

        if socketHandle != -1 {
            Darwin.close(socketHandle)
            socketHandle = -1
        }
    }

    func writeToStream(buffer: UnsafePointer<UInt8>, maxLength length: Int) -> Int {
        guard let outputStream = outputStream else {
            print("[SocketConnection] Output stream not available")
            return -1
        }
        return outputStream.write(buffer, maxLength: length)
    }
}

// MARK: - StreamDelegate
extension SocketConnection: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            print("[SocketConnection] Stream open completed")
            if aStream == outputStream {
                didOpen?()
            }

        case .hasBytesAvailable:
            if aStream == inputStream {
                var buffer: UInt8 = 0
                let numberOfBytesRead = inputStream?.read(&buffer, maxLength: 1)
                if numberOfBytesRead == 0 && aStream.streamStatus == .atEnd {
                    print("[SocketConnection] Server closed connection")
                    close()
                    notifyDidClose(error: nil)
                }
            }

        case .hasSpaceAvailable:
            if aStream == outputStream {
                streamHasSpaceAvailable?()
            }

        case .errorOccurred:
            print("[SocketConnection] Stream error: \(String(describing: aStream.streamError))")
            close()
            notifyDidClose(error: aStream.streamError)

        case .endEncountered:
            print("[SocketConnection] Stream end encountered")
            close()
            notifyDidClose(error: nil)

        default:
            break
        }
    }
}

// MARK: - Private Methods
private extension SocketConnection {
    func setupAddress() -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        guard filePath.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            print("[SocketConnection] File path is too long")
            return false
        }

        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            filePath.withCString {
                strncpy(ptr, $0, filePath.count)
            }
        }

        address = addr
        return true
    }

    func connectSocket() -> Bool {
        guard var addr = address else {
            return false
        }

        let status = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard status == noErr else {
            print("[SocketConnection] Connect failed with status: \(status), errno: \(errno)")
            return false
        }

        return true
    }

    func setupStreams() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketHandle, &readStream, &writeStream)

        inputStream = readStream?.takeRetainedValue()
        inputStream?.delegate = self
        inputStream?.setProperty(
            kCFBooleanTrue,
            forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String)
        )

        outputStream = writeStream?.takeRetainedValue()
        outputStream?.delegate = self
        outputStream?.setProperty(
            kCFBooleanTrue,
            forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String)
        )

        scheduleStreams()
    }

    func scheduleStreams() {
        shouldKeepRunning = true

        networkQueue = DispatchQueue.global(qos: .userInitiated)
        networkQueue?.async { [weak self] in
            guard let self = self else { return }

            self.inputStream?.schedule(in: .current, forMode: .common)
            self.outputStream?.schedule(in: .current, forMode: .common)

            var isRunning = false
            repeat {
                isRunning = self.shouldKeepRunning && RunLoop.current.run(mode: .default, before: .distantFuture)
            } while isRunning
        }
    }

    func unscheduleStreams() {
        shouldKeepRunning = false

        networkQueue?.sync { [weak self] in
            self?.inputStream?.remove(from: .current, forMode: .common)
            self?.outputStream?.remove(from: .current, forMode: .common)
        }
    }

    func notifyDidClose(error: Error?) {
        didClose?(error)
    }
}
