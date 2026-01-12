//
//  DarwinNotificationCenter.swift
//  SpecBridge
//
//  Darwin notifications for cross-process communication
//

import Foundation

enum DarwinNotification: String {
    case broadcastStarted = "com.specbridge.broadcast.started"
    case broadcastStopped = "com.specbridge.broadcast.stopped"
}

class DarwinNotificationCenter {
    static let shared = DarwinNotificationCenter()

    private let notificationCenter: CFNotificationCenter

    private init() {
        notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    }

    func postNotification(_ notification: DarwinNotification) {
        CFNotificationCenterPostNotification(
            notificationCenter,
            CFNotificationName(notification.rawValue as CFString),
            nil,
            nil,
            true
        )
    }

    func addObserver(for notification: DarwinNotification, callback: @escaping () -> Void) {
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())

        CFNotificationCenterAddObserver(
            notificationCenter,
            observer,
            { _, observer, name, _, _ in
                // Note: In a real implementation, you'd need to map this back to the callback
                print("Darwin notification received: \(String(describing: name))")
            },
            notification.rawValue as CFString,
            nil,
            .deliverImmediately
        )
    }

    func removeObserver(for notification: DarwinNotification) {
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())

        CFNotificationCenterRemoveObserver(
            notificationCenter,
            observer,
            CFNotificationName(notification.rawValue as CFString),
            nil
        )
    }
}
