import 'package:equatable/equatable.dart';

/// Video source options for streaming
enum VideoSource {
  glasses,      // Meta Ray-Ban glasses
  backCamera,   // Phone back camera
  frontCamera,  // Phone front camera
  screenShare,  // Jitsi screen share
}

/// Connection state for Meta glasses
enum GlassesConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

/// Permission status for glasses features
enum GlassesPermissionStatus {
  notDetermined,
  denied,
  granted,
  unknown,
}

/// Represents the current state of Meta glasses connection
class GlassesState extends Equatable {
  final GlassesConnectionState connection;
  final GlassesPermissionStatus cameraPermission;
  final String? errorMessage;
  final bool isConfigured;
  final VideoSource videoSource;

  const GlassesState({
    this.connection = GlassesConnectionState.disconnected,
    this.cameraPermission = GlassesPermissionStatus.notDetermined,
    this.errorMessage,
    this.isConfigured = false,
    this.videoSource = VideoSource.glasses,
  });

  bool get isConnected => connection == GlassesConnectionState.connected;
  bool get hasPermission => cameraPermission == GlassesPermissionStatus.granted;

  /// Check if ready to stream based on video source
  bool get isReady {
    switch (videoSource) {
      case VideoSource.glasses:
        return isConnected && hasPermission && isConfigured;
      case VideoSource.backCamera:
      case VideoSource.frontCamera:
      case VideoSource.screenShare:
        // Phone cameras/screen share don't need glasses connection
        return true;
    }
  }

  /// Whether current source requires glasses connection
  bool get requiresGlasses => videoSource == VideoSource.glasses;

  GlassesState copyWith({
    GlassesConnectionState? connection,
    GlassesPermissionStatus? cameraPermission,
    String? errorMessage,
    bool? isConfigured,
    VideoSource? videoSource,
  }) {
    return GlassesState(
      connection: connection ?? this.connection,
      cameraPermission: cameraPermission ?? this.cameraPermission,
      errorMessage: errorMessage ?? this.errorMessage,
      isConfigured: isConfigured ?? this.isConfigured,
      videoSource: videoSource ?? this.videoSource,
    );
  }

  @override
  List<Object?> get props => [connection, cameraPermission, errorMessage, isConfigured, videoSource];
}
