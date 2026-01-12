import 'package:equatable/equatable.dart';

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

  const GlassesState({
    this.connection = GlassesConnectionState.disconnected,
    this.cameraPermission = GlassesPermissionStatus.notDetermined,
    this.errorMessage,
    this.isConfigured = false,
  });

  bool get isConnected => connection == GlassesConnectionState.connected;
  bool get hasPermission => cameraPermission == GlassesPermissionStatus.granted;
  bool get isReady => isConnected && hasPermission && isConfigured;

  GlassesState copyWith({
    GlassesConnectionState? connection,
    GlassesPermissionStatus? cameraPermission,
    String? errorMessage,
    bool? isConfigured,
  }) {
    return GlassesState(
      connection: connection ?? this.connection,
      cameraPermission: cameraPermission ?? this.cameraPermission,
      errorMessage: errorMessage ?? this.errorMessage,
      isConfigured: isConfigured ?? this.isConfigured,
    );
  }

  @override
  List<Object?> get props => [connection, cameraPermission, errorMessage, isConfigured];
}
