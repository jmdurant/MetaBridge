import Foundation

/// Delegate protocol for socket connection events
protocol SocketConnectionDelegate: AnyObject {
    func socketDidConnect(_ socket: SocketConnection)
    func socketDidDisconnect(_ socket: SocketConnection)
    func socket(_ socket: SocketConnection, didReceiveError error: Error)
}

/// Unix domain socket connection for Jitsi screen share frame injection
class SocketConnection: NSObject {
    weak var delegate: SocketConnectionDelegate?

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var isConnected = false

    private let socketPath: String
    private let queue = DispatchQueue(label: "com.specbridge.socket", qos: .userInteractive)

    init(socketPath: String) {
        self.socketPath = socketPath
        super.init()
    }

    // MARK: - Connection

    func connect() {
        queue.async { [weak self] in
            self?.connectInternal()
        }
    }

    private func connectInternal() {
        // Clean up existing connection
        disconnectInternal()

        // Create Unix domain socket streams
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocketToHost(
            kCFAllocatorDefault,
            socketPath as CFString,
            0, // Port not used for Unix sockets
            &readStream,
            &writeStream
        )

        // For Unix domain sockets, we need to use a different approach
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            let error = NSError(domain: "SocketConnection", code: Int(errno),
                               userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
            delegate?.socket(self, didReceiveError: error)
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dest in
                _ = strcpy(dest, ptr)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            close(socketFD)
            let error = NSError(domain: "SocketConnection", code: Int(errno),
                               userInfo: [NSLocalizedDescriptionKey: "Failed to connect: \(String(cString: strerror(errno)))"])
            delegate?.socket(self, didReceiveError: error)
            return
        }

        // Create streams from socket file descriptor
        CFStreamCreatePairWithSocket(
            kCFAllocatorDefault,
            socketFD,
            &readStream,
            &writeStream
        )

        guard let input = readStream?.takeRetainedValue(),
              let output = writeStream?.takeRetainedValue() else {
            close(socketFD)
            let error = NSError(domain: "SocketConnection", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "Failed to create streams"])
            delegate?.socket(self, didReceiveError: error)
            return
        }

        // Configure streams to close socket when done
        CFReadStreamSetProperty(input, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)
        CFWriteStreamSetProperty(output, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)

        inputStream = input as InputStream
        outputStream = output as OutputStream

        inputStream?.delegate = self
        outputStream?.delegate = self

        inputStream?.schedule(in: .main, forMode: .common)
        outputStream?.schedule(in: .main, forMode: .common)

        inputStream?.open()
        outputStream?.open()

        isConnected = true
        DispatchQueue.main.async {
            self.delegate?.socketDidConnect(self)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.disconnectInternal()
        }
    }

    private func disconnectInternal() {
        inputStream?.close()
        outputStream?.close()

        inputStream?.remove(from: .main, forMode: .common)
        outputStream?.remove(from: .main, forMode: .common)

        inputStream = nil
        outputStream = nil

        if isConnected {
            isConnected = false
            DispatchQueue.main.async {
                self.delegate?.socketDidDisconnect(self)
            }
        }
    }

    // MARK: - Data Transfer

    func write(_ data: Data) -> Bool {
        guard isConnected, let output = outputStream, output.hasSpaceAvailable else {
            return false
        }

        return data.withUnsafeBytes { bufferPtr -> Bool in
            guard let baseAddress = bufferPtr.baseAddress else { return false }
            let bytesWritten = output.write(baseAddress.assumingMemoryBound(to: UInt8.self), maxLength: data.count)
            return bytesWritten == data.count
        }
    }

    func writeAsync(_ data: Data, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let success = self?.write(data) ?? false
            if let completion = completion {
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        }
    }
}

// MARK: - StreamDelegate

extension SocketConnection: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            break
        case .hasBytesAvailable:
            // Read incoming data if needed
            break
        case .hasSpaceAvailable:
            break
        case .errorOccurred:
            let error = aStream.streamError ?? NSError(domain: "SocketConnection", code: -1,
                                                       userInfo: [NSLocalizedDescriptionKey: "Stream error"])
            delegate?.socket(self, didReceiveError: error)
            disconnectInternal()
        case .endEncountered:
            delegate?.socketDidDisconnect(self)
            disconnectInternal()
        default:
            break
        }
    }
}
