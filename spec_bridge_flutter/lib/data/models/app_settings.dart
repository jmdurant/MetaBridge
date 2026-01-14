import 'package:equatable/equatable.dart';

enum JitsiMode {
  libJitsiMeet, // lib-jitsi-meet in WebView with direct frame injection
}

/// Audio output destination
enum AudioOutput {
  phoneSpeaker, // Default - no Bluetooth bandwidth usage
  glasses,      // Route to glasses via Bluetooth (may impact video frame rate)
}

/// Video quality for glasses streaming
enum VideoQuality {
  low,    // Lower bandwidth, better for unstable connections
  medium, // Default - matches Meta sample app
  high,   // Higher quality, may affect performance
}

class AppSettings extends Equatable {
  final JitsiMode jitsiMode;
  final String defaultServer;
  final String defaultRoomName;
  final String? displayName;
  final bool showPipelineStats;
  final AudioOutput defaultAudioOutput;
  final VideoQuality defaultVideoQuality;

  const AppSettings({
    this.jitsiMode = JitsiMode.libJitsiMeet,
    this.defaultServer = 'https://meet.ffmuc.net',
    this.defaultRoomName = 'SpecBridgeRoom',
    this.displayName,
    this.showPipelineStats = true,
    this.defaultAudioOutput = AudioOutput.phoneSpeaker,
    this.defaultVideoQuality = VideoQuality.medium,
  });

  AppSettings copyWith({
    JitsiMode? jitsiMode,
    String? defaultServer,
    String? defaultRoomName,
    String? displayName,
    bool? showPipelineStats,
    AudioOutput? defaultAudioOutput,
    VideoQuality? defaultVideoQuality,
  }) {
    return AppSettings(
      jitsiMode: jitsiMode ?? this.jitsiMode,
      defaultServer: defaultServer ?? this.defaultServer,
      defaultRoomName: defaultRoomName ?? this.defaultRoomName,
      displayName: displayName ?? this.displayName,
      showPipelineStats: showPipelineStats ?? this.showPipelineStats,
      defaultAudioOutput: defaultAudioOutput ?? this.defaultAudioOutput,
      defaultVideoQuality: defaultVideoQuality ?? this.defaultVideoQuality,
    );
  }

  @override
  List<Object?> get props => [
        jitsiMode,
        defaultServer,
        defaultRoomName,
        displayName,
        showPipelineStats,
        defaultAudioOutput,
        defaultVideoQuality,
      ];
}
