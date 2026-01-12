import Foundation

/// Wrapper for Darwin notification center for IPC between app and broadcast extension
class DarwinNotificationCenter {
    static let shared = DarwinNotificationCenter()

    private let notificationCenter: CFNotificationCenter

    // Notification names for broadcast extension communication
    static let startedNotification = "com.specbridge.broadcast.started"
    static let stoppedNotification = "com.specbridge.broadcast.stopped"
    static let frameRequestNotification = "com.specbridge.broadcast.frameRequest"

    private init() {
        notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    }

    // MARK: - Posting

    func postNotification(name: String) {
        CFNotificationCenterPostNotification(
            notificationCenter,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Observing

    func addObserver(name: String, callback: @escaping () -> Void) {
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())

        CFNotificationCenterAddObserver(
            notificationCenter,
            observer,
            { _, _, name, _, _ in
                // Note: callback handling would need to use a registry pattern
                // for proper callback invocation in production code
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    func removeObserver(name: String) {
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())

        CFNotificationCenterRemoveObserver(
            notificationCenter,
            observer,
            CFNotificationName(name as CFString),
            nil
        )
    }

    func removeAllObservers() {
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())

        CFNotificationCenterRemoveEveryObserver(
            notificationCenter,
            observer
        )
    }
}
