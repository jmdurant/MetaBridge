import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:jitsi_meet_flutter_sdk/jitsi_meet_flutter_sdk.dart';

import '../data/models/meeting_config.dart';

/// Meeting state for UI
class JitsiMeetingState {
  final bool isInMeeting;
  final bool isAudioMuted;
  final bool isVideoMuted;
  final bool isScreenSharing;
  final String? errorMessage;

  const JitsiMeetingState({
    this.isInMeeting = false,
    this.isAudioMuted = false,
    this.isVideoMuted = true,
    this.isScreenSharing = false,
    this.errorMessage,
  });

  JitsiMeetingState copyWith({
    bool? isInMeeting,
    bool? isAudioMuted,
    bool? isVideoMuted,
    bool? isScreenSharing,
    String? errorMessage,
  }) {
    return JitsiMeetingState(
      isInMeeting: isInMeeting ?? this.isInMeeting,
      isAudioMuted: isAudioMuted ?? this.isAudioMuted,
      isVideoMuted: isVideoMuted ?? this.isVideoMuted,
      isScreenSharing: isScreenSharing ?? this.isScreenSharing,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// Service for managing Jitsi meetings
class JitsiService extends ChangeNotifier {
  final JitsiMeet _jitsiMeet = JitsiMeet();

  JitsiMeetingState _currentState = const JitsiMeetingState();

  // Track mute states locally (SDK doesn't provide getters)
  bool _isAudioMuted = false;
  bool _isVideoMuted = true;

  JitsiService() {
    _setupEventListeners();
  }

  /// Current meeting state
  JitsiMeetingState get currentState => _currentState;

  /// Whether currently in a meeting
  bool get isInMeeting => _currentState.isInMeeting;

  void _setupEventListeners() {
    // Note: JitsiMeet SDK event listeners are set up per-join call
    // The SDK uses a different event model than addListener
  }

  void _updateState(JitsiMeetingState newState) {
    _currentState = newState;
    notifyListeners();
  }

  /// Join a Jitsi meeting
  Future<void> joinMeeting(MeetingConfig config) async {
    if (!config.isValid) {
      throw ArgumentError('Invalid meeting configuration');
    }

    final options = JitsiMeetConferenceOptions(
      serverURL: config.serverUrl,
      room: config.roomName,
      userInfo: JitsiMeetUserInfo(
        displayName: config.displayName,
      ),
      configOverrides: {
        'startWithAudioMuted': config.startWithAudioMuted,
        'startWithVideoMuted': config.startWithVideoMuted,
        'prejoinPageEnabled': false,
      },
      featureFlags: {
        'ios.screensharing.enabled': true,
        'recording.enabled': false,
        'live-streaming.enabled': false,
        'meeting-password.enabled': false,
        'invite.enabled': false,
        'close-captions.enabled': false,
      },
    );

    _isAudioMuted = config.startWithAudioMuted;
    _isVideoMuted = config.startWithVideoMuted;

    final listener = JitsiMeetEventListener(
      conferenceJoined: (url) {
        _updateState(_currentState.copyWith(isInMeeting: true));
      },
      conferenceTerminated: (url, error) {
        _updateState(_currentState.copyWith(
          isInMeeting: false,
          isScreenSharing: false,
          errorMessage: error?.toString(),
        ));
      },
      conferenceWillJoin: (url) {
        // Conference joining
      },
      participantJoined: (email, name, role, participantId) {
        // Participant joined
      },
      participantLeft: (participantId) {
        // Participant left
      },
      audioMutedChanged: (muted) {
        _isAudioMuted = muted;
        _updateState(_currentState.copyWith(isAudioMuted: muted));
      },
      videoMutedChanged: (muted) {
        _isVideoMuted = muted;
        _updateState(_currentState.copyWith(isVideoMuted: muted));
      },
      screenShareToggled: (participantId, sharing) {
        _updateState(_currentState.copyWith(isScreenSharing: sharing));
      },
    );

    await _jitsiMeet.join(options, listener);
  }

  /// Leave the current meeting
  Future<void> leaveMeeting() async {
    await _jitsiMeet.hangUp();
  }

  /// Toggle audio mute
  Future<bool> toggleAudio() async {
    await _jitsiMeet.setAudioMuted(!_isAudioMuted);
    _isAudioMuted = !_isAudioMuted;
    _updateState(_currentState.copyWith(isAudioMuted: _isAudioMuted));
    return _isAudioMuted;
  }

  /// Toggle video mute
  Future<bool> toggleVideo() async {
    await _jitsiMeet.setVideoMuted(!_isVideoMuted);
    _isVideoMuted = !_isVideoMuted;
    _updateState(_currentState.copyWith(isVideoMuted: _isVideoMuted));
    return _isVideoMuted;
  }

  /// Toggle screen share
  Future<void> toggleScreenShare() async {
    await _jitsiMeet.toggleScreenShare(!_currentState.isScreenSharing);
  }

  /// Set audio muted state
  Future<void> setAudioMuted(bool muted) async {
    await _jitsiMeet.setAudioMuted(muted);
    _isAudioMuted = muted;
    _updateState(_currentState.copyWith(isAudioMuted: muted));
  }

  /// Set video muted state
  Future<void> setVideoMuted(bool muted) async {
    await _jitsiMeet.setVideoMuted(muted);
    _isVideoMuted = muted;
    _updateState(_currentState.copyWith(isVideoMuted: muted));
  }
}
