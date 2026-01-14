import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/glasses_state.dart';
import 'platform_channels/meta_dat_channel.dart';

/// Service for managing video capture from glasses or phone cameras
class GlassesService extends ChangeNotifier {
  final MetaDATChannel _channel;

  GlassesState _currentState = const GlassesState();
  StreamSubscription? _eventSubscription;

  GlassesService(this._channel) {
    _listenToEvents();
  }

  /// Current glasses/video state
  GlassesState get currentState => _currentState;

  /// Currently selected video source
  VideoSource get videoSource => _currentState.videoSource;

  /// Stream of preview frames from current video source
  Stream<Uint8List> get previewFrameStream => _channel.previewFrameStream;

  void _listenToEvents() {
    _eventSubscription = _channel.eventStream.listen((event) {
      switch (event) {
        case ConnectionStateEvent():
          _updateState(_currentState.copyWith(
            connection: event.state,
            errorMessage: event.errorMessage,
          ));
          break;
        case StreamStatusEvent():
          // Stream status is handled by StreamService
          break;
        case FramePreviewEvent():
          // Frames are handled via previewFrameStream
          break;
      }
    });
  }

  void _updateState(GlassesState newState) {
    _currentState = newState;
    notifyListeners();
  }

  /// Initialize the Meta Wearables SDK
  Future<bool> initialize() async {
    final result = await _channel.configure();
    if (result) {
      _updateState(_currentState.copyWith(isConfigured: true));
    }
    return result;
  }

  /// Start pairing flow with Meta View app
  Future<bool> startPairing() async {
    _updateState(_currentState.copyWith(
      connection: GlassesConnectionState.connecting,
    ));
    return await _channel.startRegistration();
  }

  /// Handle return URL from Meta View app
  Future<bool> handleMetaViewCallback(String url) async {
    final result = await _channel.handleUrl(url);
    if (result) {
      _updateState(_currentState.copyWith(
        connection: GlassesConnectionState.connected,
      ));
    }
    return result;
  }

  /// Check if camera permission is granted
  Future<GlassesPermissionStatus> checkCameraPermission() async {
    final status = await _channel.checkCameraPermission();
    _updateState(_currentState.copyWith(cameraPermission: status));
    return status;
  }

  /// Request camera permission from glasses
  Future<GlassesPermissionStatus> requestCameraPermission() async {
    final status = await _channel.requestCameraPermission();
    _updateState(_currentState.copyWith(cameraPermission: status));
    return status;
  }

  /// Set the video source for streaming
  void setVideoSource(VideoSource source) {
    _updateState(_currentState.copyWith(videoSource: source));
  }

  /// Notify native side of video source (for stats tracking)
  /// Used when camera mode uses WebView's getUserMedia directly
  Future<bool> notifyVideoSourceToNative(VideoSource source) async {
    return await _channel.setVideoSource(source);
  }

  /// Start video streaming from current video source
  Future<bool> startStreaming({
    int width = 1280,
    int height = 720,
    int frameRate = 24,
    String videoQuality = 'medium',
  }) async {
    final config = StreamConfig(
      width: width,
      height: height,
      frameRate: frameRate,
      videoSource: _currentState.videoSource,
      videoQuality: videoQuality,
    );
    return await _channel.startStreaming(config);
  }

  /// Stop video streaming
  Future<void> stopStreaming() async {
    await _channel.stopStreaming();
  }

  /// Enable/disable native frame server (bypasses Flutter UI thread)
  Future<bool> setNativeServerEnabled(bool enabled) async {
    return await _channel.setNativeServerEnabled(enabled);
  }

  /// Reset native frame server client state for clean session transitions
  Future<bool> resetFrameServer() async {
    return await _channel.resetFrameServer();
  }

  /// Disconnect from glasses
  Future<void> disconnect() async {
    await _channel.disconnect();
    _updateState(_currentState.copyWith(
      connection: GlassesConnectionState.disconnected,
      cameraPermission: GlassesPermissionStatus.notDetermined,
    ));
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _channel.dispose();
    super.dispose();
  }
}
