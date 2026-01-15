import 'package:equatable/equatable.dart';

enum JitsiMode {
  libJitsiMeet, // lib-jitsi-meet in WebView with direct frame injection
}

/// Audio output destination
enum AudioOutput {
  speakerphone, // Loud hands-free mode - no Bluetooth bandwidth usage
  earpiece,     // Quiet hold-to-ear mode - no Bluetooth bandwidth usage
  glasses,      // Route to glasses via Bluetooth (reduces video to 2fps)
}

/// Video quality for glasses streaming
enum VideoQuality {
  low,    // Lower bandwidth, better for unstable connections
  medium, // Default - matches Meta sample app
  high,   // Higher quality, may affect performance
}

/// Target frame rate for glasses streaming
/// Valid SDK values: 30, 24, 15, 7, 2
/// Lower values are more stable over Bluetooth (limited bandwidth)
enum TargetFrameRate {
  fps30(30), // Highest - requires WiFi Direct (not available for 3rd party apps)
  fps24(24), // High - may drop on congested Bluetooth
  fps15(15), // Recommended - stable on Bluetooth Classic
  fps7(7),   // Low - guaranteed stable, fallback rate
  ;

  final int value;
  const TargetFrameRate(this.value);
}

class AppSettings extends Equatable {
  final JitsiMode jitsiMode;
  final String defaultServer;
  final String defaultRoomName;
  final String? displayName;
  final bool showPipelineStats;
  final AudioOutput defaultAudioOutput;
  final VideoQuality defaultVideoQuality;
  final TargetFrameRate defaultFrameRate;
  final bool useNativeFrameServer; // Bypass Flutter UI thread for frames

  const AppSettings({
    this.jitsiMode = JitsiMode.libJitsiMeet,
    this.defaultServer = 'https://meet.ffmuc.net',
    this.defaultRoomName = 'SpecBridgeRoom',
    this.displayName,
    this.showPipelineStats = true,
    this.defaultAudioOutput = AudioOutput.speakerphone,
    this.defaultVideoQuality = VideoQuality.low, // LOW quality for better BT bandwidth
    this.defaultFrameRate = TargetFrameRate.fps15, // 15fps stable on Bluetooth
    this.useNativeFrameServer = true, // Default enabled for better performance
  });

  AppSettings copyWith({
    JitsiMode? jitsiMode,
    String? defaultServer,
    String? defaultRoomName,
    String? displayName,
    bool? showPipelineStats,
    AudioOutput? defaultAudioOutput,
    VideoQuality? defaultVideoQuality,
    TargetFrameRate? defaultFrameRate,
    bool? useNativeFrameServer,
  }) {
    return AppSettings(
      jitsiMode: jitsiMode ?? this.jitsiMode,
      defaultServer: defaultServer ?? this.defaultServer,
      defaultRoomName: defaultRoomName ?? this.defaultRoomName,
      displayName: displayName ?? this.displayName,
      showPipelineStats: showPipelineStats ?? this.showPipelineStats,
      defaultAudioOutput: defaultAudioOutput ?? this.defaultAudioOutput,
      defaultVideoQuality: defaultVideoQuality ?? this.defaultVideoQuality,
      defaultFrameRate: defaultFrameRate ?? this.defaultFrameRate,
      useNativeFrameServer: useNativeFrameServer ?? this.useNativeFrameServer,
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
        defaultFrameRate,
        useNativeFrameServer,
      ];
}
