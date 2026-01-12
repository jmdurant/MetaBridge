import 'package:equatable/equatable.dart';

/// Configuration for a Jitsi meeting
class MeetingConfig extends Equatable {
  final String roomName;
  final String serverUrl;
  final String displayName;
  final bool startWithVideoMuted;
  final bool startWithAudioMuted;

  const MeetingConfig({
    required this.roomName,
    this.serverUrl = 'https://meet.jit.si',
    this.displayName = 'SpecBridge User',
    this.startWithVideoMuted = true,
    this.startWithAudioMuted = false,
  });

  /// Creates a meeting URL for sharing
  String get meetingUrl => '$serverUrl/$roomName';

  /// Check if configuration is valid for joining
  bool get isValid => roomName.isNotEmpty && serverUrl.isNotEmpty;

  MeetingConfig copyWith({
    String? roomName,
    String? serverUrl,
    String? displayName,
    bool? startWithVideoMuted,
    bool? startWithAudioMuted,
  }) {
    return MeetingConfig(
      roomName: roomName ?? this.roomName,
      serverUrl: serverUrl ?? this.serverUrl,
      displayName: displayName ?? this.displayName,
      startWithVideoMuted: startWithVideoMuted ?? this.startWithVideoMuted,
      startWithAudioMuted: startWithAudioMuted ?? this.startWithAudioMuted,
    );
  }

  /// Create from deep link parameters
  factory MeetingConfig.fromDeepLink({
    required String roomName,
    String? serverUrl,
    String? displayName,
  }) {
    return MeetingConfig(
      roomName: roomName,
      serverUrl: serverUrl ?? 'https://meet.jit.si',
      displayName: displayName ?? 'SpecBridge User',
    );
  }

  @override
  List<Object?> get props => [
        roomName,
        serverUrl,
        displayName,
        startWithVideoMuted,
        startWithAudioMuted,
      ];
}
