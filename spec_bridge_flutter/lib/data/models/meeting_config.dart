import 'package:equatable/equatable.dart';

/// Configuration for a Jitsi meeting
class MeetingConfig extends Equatable {
  final String roomName;
  final String serverUrl;
  final String displayName;
  final bool startWithVideoMuted;
  final bool startWithAudioMuted;
  final bool enableE2EE;
  final String? e2eePassphrase;

  const MeetingConfig({
    required this.roomName,
    this.serverUrl = 'https://meet.jit.si',
    this.displayName = 'SpecBridge User',
    this.startWithVideoMuted = true,
    this.startWithAudioMuted = false,
    this.enableE2EE = false,
    this.e2eePassphrase,
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
    bool? enableE2EE,
    String? e2eePassphrase,
  }) {
    return MeetingConfig(
      roomName: roomName ?? this.roomName,
      serverUrl: serverUrl ?? this.serverUrl,
      displayName: displayName ?? this.displayName,
      startWithVideoMuted: startWithVideoMuted ?? this.startWithVideoMuted,
      startWithAudioMuted: startWithAudioMuted ?? this.startWithAudioMuted,
      enableE2EE: enableE2EE ?? this.enableE2EE,
      e2eePassphrase: e2eePassphrase ?? this.e2eePassphrase,
    );
  }

  /// Create from deep link parameters
  factory MeetingConfig.fromDeepLink({
    required String roomName,
    String? serverUrl,
    String? displayName,
    bool? enableE2EE,
    String? e2eePassphrase,
  }) {
    return MeetingConfig(
      roomName: roomName,
      serverUrl: serverUrl ?? 'https://meet.jit.si',
      displayName: displayName ?? 'SpecBridge User',
      enableE2EE: enableE2EE ?? false,
      e2eePassphrase: e2eePassphrase,
    );
  }

  @override
  List<Object?> get props => [
        roomName,
        serverUrl,
        displayName,
        startWithVideoMuted,
        startWithAudioMuted,
        enableE2EE,
        e2eePassphrase,
      ];
}
