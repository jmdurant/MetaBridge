import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../data/models/glasses_state.dart';

/// Stream configuration for video capture
class StreamConfig {
  final int width;
  final int height;
  final int frameRate;
  final VideoSource videoSource;
  final String videoQuality; // low, medium, high

  const StreamConfig({
    this.width = 1280,
    this.height = 720,
    this.frameRate = 24,
    this.videoSource = VideoSource.glasses,
    this.videoQuality = 'medium',
  });

  Map<String, dynamic> toMap() => {
        'width': width,
        'height': height,
        'frameRate': frameRate,
        'videoSource': videoSource.name,
        'videoQuality': videoQuality,
      };
}

/// Events from the Meta DAT SDK
sealed class MetaDATEvent {}

class ConnectionStateEvent extends MetaDATEvent {
  final GlassesConnectionState state;
  final String? errorMessage;
  ConnectionStateEvent(this.state, {this.errorMessage});
}

class StreamStatusEvent extends MetaDATEvent {
  final String status;
  final String? errorMessage;
  StreamStatusEvent(this.status, {this.errorMessage});
}

class FramePreviewEvent extends MetaDATEvent {
  final Uint8List frameData;
  FramePreviewEvent(this.frameData);
}

/// Abstract interface for Meta DAT platform channel
abstract class MetaDATChannel {
  /// Configure the SDK
  Future<bool> configure();

  /// Start registration with Meta View app
  Future<bool> startRegistration();

  /// Handle URL callback from Meta View
  Future<bool> handleUrl(String url);

  /// Check camera permission status
  Future<GlassesPermissionStatus> checkCameraPermission();

  /// Request camera permission
  Future<GlassesPermissionStatus> requestCameraPermission();

  /// Start video streaming
  Future<bool> startStreaming(StreamConfig config);

  /// Stop video streaming
  Future<void> stopStreaming();

  /// Disconnect from glasses
  Future<void> disconnect();

  /// Get streaming stats from native side
  Future<Map<String, dynamic>> getStreamStats();

  /// Enable/disable native WebSocket frame server (bypasses Flutter UI thread)
  Future<bool> setNativeServerEnabled(bool enabled);

  /// Check if native frame server is enabled
  Future<bool> isNativeServerEnabled();

  /// Event stream for connection/status updates
  Stream<MetaDATEvent> get eventStream;

  /// Stream of preview frames (JPEG data)
  Stream<Uint8List> get previewFrameStream;

  /// Dispose resources
  void dispose();
}

/// Implementation of MetaDATChannel using platform channels
class MetaDATChannelImpl implements MetaDATChannel {
  static const _methodChannel = MethodChannel('com.specbridge/meta_dat');
  static const _eventChannel = EventChannel('com.specbridge/meta_dat_events');
  static const _frameChannel = EventChannel('com.specbridge/meta_dat_frames');

  final _eventController = StreamController<MetaDATEvent>.broadcast();
  final _frameController = StreamController<Uint8List>.broadcast();

  StreamSubscription? _eventSubscription;
  StreamSubscription? _frameSubscription;

  // Frame reception tracking
  int _framesReceivedFromNative = 0;
  DateTime? _firstFrameTime;

  /// Stats about frames received from native side
  Map<String, dynamic> get frameReceptionStats {
    final now = DateTime.now();
    final elapsed = _firstFrameTime != null
        ? now.difference(_firstFrameTime!).inMilliseconds
        : 0;
    final avgFps = elapsed > 0
        ? (_framesReceivedFromNative * 1000 / elapsed).round()
        : 0;
    return {
      'framesReceivedFromNative': _framesReceivedFromNative,
      'avgFps': avgFps,
      'elapsedMs': elapsed,
    };
  }

  MetaDATChannelImpl() {
    _setupEventListeners();
  }

  void _setupEventListeners() {
    _eventSubscription = _eventChannel
        .receiveBroadcastStream()
        .listen(_handleEvent, onError: _handleError);

    _frameSubscription = _frameChannel
        .receiveBroadcastStream()
        .listen(_handleFrame, onError: _handleError);
  }

  void _handleEvent(dynamic event) {
    if (event is! Map) return;

    final type = event['type'] as String?;
    switch (type) {
      case 'connectionState':
        final stateStr = event['state'] as String?;
        final state = _parseConnectionState(stateStr);
        final error = event['error'] as String?;
        _eventController.add(ConnectionStateEvent(state, errorMessage: error));
        break;
      case 'streamStatus':
        final status = event['status'] as String? ?? 'unknown';
        final error = event['error'] as String?;
        _eventController.add(StreamStatusEvent(status, errorMessage: error));
        break;
      case 'incomingUrl':
        // URL events are handled separately via deep links
        break;
    }
  }

  void _handleFrame(dynamic data) {
    if (data is Uint8List) {
      _framesReceivedFromNative++;
      _firstFrameTime ??= DateTime.now();

      // Log first frame and every 100 frames
      if (_framesReceivedFromNative == 1) {
        debugPrint('MetaDATChannel: First frame received from native (${data.length} bytes)');
      }
      if (_framesReceivedFromNative % 100 == 0) {
        final stats = frameReceptionStats;
        debugPrint('MetaDATChannel: Frames received=$_framesReceivedFromNative, avgFps=${stats['avgFps']}');
      }

      _frameController.add(data);
      _eventController.add(FramePreviewEvent(data));
    }
  }

  void _handleError(dynamic error) {
    _eventController.add(
      ConnectionStateEvent(GlassesConnectionState.error,
          errorMessage: error.toString()),
    );
  }

  GlassesConnectionState _parseConnectionState(String? state) {
    switch (state) {
      case 'disconnected':
        return GlassesConnectionState.disconnected;
      case 'connecting':
        return GlassesConnectionState.connecting;
      case 'connected':
        return GlassesConnectionState.connected;
      case 'error':
        return GlassesConnectionState.error;
      default:
        return GlassesConnectionState.disconnected;
    }
  }

  GlassesPermissionStatus _parsePermissionStatus(String? status) {
    switch (status) {
      case 'granted':
        return GlassesPermissionStatus.granted;
      case 'denied':
        return GlassesPermissionStatus.denied;
      case 'notDetermined':
        return GlassesPermissionStatus.notDetermined;
      default:
        return GlassesPermissionStatus.unknown;
    }
  }

  @override
  Future<bool> configure() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('configure');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> startRegistration() async {
    try {
      final result =
          await _methodChannel.invokeMethod<bool>('startRegistration');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> handleUrl(String url) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'handleUrl',
        {'url': url},
      );
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<GlassesPermissionStatus> checkCameraPermission() async {
    try {
      final result =
          await _methodChannel.invokeMethod<String>('checkCameraPermission');
      return _parsePermissionStatus(result);
    } on PlatformException {
      return GlassesPermissionStatus.unknown;
    }
  }

  @override
  Future<GlassesPermissionStatus> requestCameraPermission() async {
    try {
      final result =
          await _methodChannel.invokeMethod<String>('requestCameraPermission');
      return _parsePermissionStatus(result);
    } on PlatformException {
      return GlassesPermissionStatus.unknown;
    }
  }

  @override
  Future<bool> startStreaming(StreamConfig config) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'startStreaming',
        config.toMap(),
      );
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> stopStreaming() async {
    try {
      await _methodChannel.invokeMethod<void>('stopStreaming');
    } on PlatformException {
      // Ignore errors on stop
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _methodChannel.invokeMethod<void>('disconnect');
    } on PlatformException {
      // Ignore errors on disconnect
    }
  }

  @override
  Future<Map<String, dynamic>> getStreamStats() async {
    try {
      final result =
          await _methodChannel.invokeMethod<Map<Object?, Object?>>('getStreamStats');
      if (result != null) {
        return result.map((k, v) => MapEntry(k.toString(), v));
      }
      return {};
    } on PlatformException {
      return {};
    }
  }

  @override
  Future<bool> setNativeServerEnabled(bool enabled) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'setNativeServerEnabled',
        {'enabled': enabled},
      );
      debugPrint('MetaDATChannel: Native server ${enabled ? "enabled" : "disabled"}');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('MetaDATChannel: setNativeServerEnabled error: $e');
      return false;
    }
  }

  @override
  Future<bool> isNativeServerEnabled() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('isNativeServerEnabled');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Stream<MetaDATEvent> get eventStream => _eventController.stream;

  @override
  Stream<Uint8List> get previewFrameStream => _frameController.stream;

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _frameSubscription?.cancel();
    _eventController.close();
    _frameController.close();
  }
}
