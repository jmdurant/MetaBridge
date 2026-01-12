//
//  JitsiManager.swift
//  SpecBridge
//
//  Manages Jitsi Meet SDK integration for video conferencing
//
//  SETUP REQUIRED:
//  1. Add JitsiMeetSDK via CocoaPods: pod 'JitsiMeetSDK'
//  2. Add App Group capability to both app and extension
//  3. Configure Info.plist with RTCAppGroupIdentifier and RTCScreenSharingExtension
//

import Foundation
import SwiftUI

// MARK: - Jitsi Meeting Configuration

struct JitsiMeetingConfig {
    /// The Jitsi server URL (use meet.jit.si for public server)
    var serverURL: String = "https://meet.jit.si"

    /// The room/meeting name
    var roomName: String = ""

    /// Display name for the participant
    var displayName: String = "SpecBridge User"

    /// Email (optional)
    var email: String = ""

    /// Start with audio muted
    var startWithAudioMuted: Bool = false

    /// Start with video muted (we'll use screen share for glasses video)
    var startWithVideoMuted: Bool = true

    /// Subject/title of the meeting
    var subject: String = ""
}

// MARK: - Jitsi Manager

@MainActor
class JitsiManager: ObservableObject {
    @Published var isInMeeting = false
    @Published var meetingStatus = "Not in meeting"
    @Published var currentRoom: String = ""

    /// Reference to the frame injector for sending glasses video
    var frameInjector: JitsiFrameInjector?

    // The JitsiMeetView will be created when SDK is available
    // private var jitsiMeetView: JitsiMeetView?

    init() {
        print("[JitsiManager] Initialized")
    }

    // MARK: - Public Methods

    /// Join a Jitsi meeting
    func joinMeeting(config: JitsiMeetingConfig) {
        guard !config.roomName.isEmpty else {
            meetingStatus = "Error: Room name required"
            return
        }

        meetingStatus = "Joining \(config.roomName)..."
        currentRoom = config.roomName

        // Start the frame injector to prepare for screen sharing
        frameInjector?.start()

        /*
        // === UNCOMMENT WHEN JitsiMeetSDK IS ADDED ===

        let options = JitsiMeetConferenceOptions.fromBuilder { builder in
            builder.serverURL = URL(string: config.serverURL)
            builder.room = config.roomName
            builder.userInfo = JitsiMeetUserInfo(
                displayName: config.displayName,
                andEmail: config.email,
                andAvatar: nil
            )
            builder.setSubject(config.subject)
            builder.setAudioMuted(config.startWithAudioMuted)
            builder.setVideoMuted(config.startWithVideoMuted)

            // Enable screen sharing feature
            builder.setFeatureFlag("ios.screensharing.enabled", withBoolean: true)
        }

        jitsiMeetView = JitsiMeetView()
        jitsiMeetView?.delegate = self
        jitsiMeetView?.join(options)
        */

        // Simulated join for now
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isInMeeting = true
            self?.meetingStatus = "In meeting: \(config.roomName)"
        }

        print("[JitsiManager] Joining meeting: \(config.roomName)")
    }

    /// Leave the current meeting
    func leaveMeeting() {
        meetingStatus = "Leaving meeting..."

        // Stop the frame injector
        frameInjector?.stop()

        /*
        // === UNCOMMENT WHEN JitsiMeetSDK IS ADDED ===
        jitsiMeetView?.hangUp()
        */

        isInMeeting = false
        meetingStatus = "Not in meeting"
        currentRoom = ""

        print("[JitsiManager] Left meeting")
    }

    /// Toggle screen share (which will show glasses video)
    func toggleScreenShare() {
        /*
        // === UNCOMMENT WHEN JitsiMeetSDK IS ADDED ===
        jitsiMeetView?.toggleScreenShare()
        */

        print("[JitsiManager] Toggle screen share")
    }

    /// Mute/unmute audio
    func setAudioMuted(_ muted: Bool) {
        /*
        // === UNCOMMENT WHEN JitsiMeetSDK IS ADDED ===
        jitsiMeetView?.setAudioMuted(muted)
        */

        print("[JitsiManager] Audio muted: \(muted)")
    }

    /// Get the Jitsi Meet URL for this meeting
    func getMeetingURL(for config: JitsiMeetingConfig) -> URL? {
        guard !config.roomName.isEmpty else { return nil }
        return URL(string: "\(config.serverURL)/\(config.roomName)")
    }
}

/*
// === UNCOMMENT WHEN JitsiMeetSDK IS ADDED ===

// MARK: - JitsiMeetViewDelegate

extension JitsiManager: JitsiMeetViewDelegate {
    func conferenceWillJoin(_ data: [AnyHashable: Any]!) {
        DispatchQueue.main.async { [weak self] in
            self?.meetingStatus = "Connecting..."
        }
        print("[JitsiManager] Conference will join: \(String(describing: data))")
    }

    func conferenceJoined(_ data: [AnyHashable: Any]!) {
        DispatchQueue.main.async { [weak self] in
            self?.isInMeeting = true
            self?.meetingStatus = "In meeting"
        }
        print("[JitsiManager] Conference joined: \(String(describing: data))")

        // Auto-start screen share to share glasses video
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.toggleScreenShare()
        }
    }

    func conferenceTerminated(_ data: [AnyHashable: Any]!) {
        DispatchQueue.main.async { [weak self] in
            self?.isInMeeting = false
            self?.meetingStatus = "Meeting ended"
            self?.frameInjector?.stop()
        }
        print("[JitsiManager] Conference terminated: \(String(describing: data))")
    }

    func participantJoined(_ data: [AnyHashable: Any]!) {
        print("[JitsiManager] Participant joined: \(String(describing: data))")
    }

    func participantLeft(_ data: [AnyHashable: Any]!) {
        print("[JitsiManager] Participant left: \(String(describing: data))")
    }

    func audioMutedChanged(_ data: [AnyHashable: Any]!) {
        print("[JitsiManager] Audio muted changed: \(String(describing: data))")
    }

    func videoMutedChanged(_ data: [AnyHashable: Any]!) {
        print("[JitsiManager] Video muted changed: \(String(describing: data))")
    }

    func screenShareToggled(_ data: [AnyHashable: Any]!) {
        print("[JitsiManager] Screen share toggled: \(String(describing: data))")
    }

    func enterPictureInPicture(_ data: [AnyHashable: Any]!) {
        print("[JitsiManager] Enter PiP: \(String(describing: data))")
    }
}
*/

// MARK: - Preview Helper
#if DEBUG
extension JitsiManager {
    static var preview: JitsiManager {
        let manager = JitsiManager()
        manager.isInMeeting = true
        manager.meetingStatus = "In meeting: test-room"
        manager.currentRoom = "test-room"
        return manager
    }
}
#endif
