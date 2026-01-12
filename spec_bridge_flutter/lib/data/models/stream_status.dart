import 'package:equatable/equatable.dart';

/// Status of the video stream
enum StreamStatus {
  idle,
  starting,
  streaming,
  stopping,
  stopped,
  error,
}

/// Represents the current streaming state
class StreamState extends Equatable {
  final StreamStatus status;
  final bool isInMeeting;
  final int framesSent;
  final String? errorMessage;

  const StreamState({
    this.status = StreamStatus.idle,
    this.isInMeeting = false,
    this.framesSent = 0,
    this.errorMessage,
  });

  bool get isStreaming => status == StreamStatus.streaming;
  bool get isActive => status == StreamStatus.streaming || status == StreamStatus.starting;

  StreamState copyWith({
    StreamStatus? status,
    bool? isInMeeting,
    int? framesSent,
    String? errorMessage,
  }) {
    return StreamState(
      status: status ?? this.status,
      isInMeeting: isInMeeting ?? this.isInMeeting,
      framesSent: framesSent ?? this.framesSent,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  List<Object?> get props => [status, isInMeeting, framesSent, errorMessage];
}

/// Event emitted from native platform channel
sealed class MetaDATEvent {}

class ConnectionStateEvent extends MetaDATEvent {
  final GlassesConnectionState state;
  final String? errorMessage;

  ConnectionStateEvent({
    required this.state,
    this.errorMessage,
  });
}

class StreamStatusEvent extends MetaDATEvent {
  final StreamStatus status;

  StreamStatusEvent({required this.status});
}

class FramePreviewEvent extends MetaDATEvent {
  final List<int> jpegData;

  FramePreviewEvent({required this.jpegData});
}

// Re-export for convenience
enum GlassesConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}
