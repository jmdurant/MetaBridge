import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/glasses_state.dart';
import 'platform_channels/meta_dat_channel.dart';

/// Service for managing Meta glasses connection and video capture
class GlassesService extends ChangeNotifier {
  final MetaDATChannel _channel;

  GlassesState _currentState = const GlassesState();
  StreamSubscription? _eventSubscription;

  GlassesService(this._channel) {
    _listenToEvents();
  }

  /// Current glasses state
  GlassesState get currentState => _currentState;

  /// Stream of preview frames from glasses
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

  /// Start video streaming from glasses
  Future<bool> startStreaming({
    int width = 1280,
    int height = 720,
    int frameRate = 24,
  }) async {
    final config = StreamConfig(
      width: width,
      height: height,
      frameRate: frameRate,
    );
    return await _channel.startStreaming(config);
  }

  /// Stop video streaming
  Future<void> stopStreaming() async {
    await _channel.stopStreaming();
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _channel.dispose();
    super.dispose();
  }
}
