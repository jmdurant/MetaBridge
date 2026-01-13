import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/meeting_config.dart';
import '../data/models/stream_status.dart';
import 'bluetooth_audio_service.dart';
import 'glasses_service.dart';
import 'lib_jitsi_service.dart';

/// Service that orchestrates glasses video streaming to Jitsi meetings
class StreamService extends ChangeNotifier {
  final GlassesService _glassesService;
  final BluetoothAudioService _bluetoothAudioService;
  LibJitsiService? _libJitsiService;

  StreamState _currentState = const StreamState();

  int _frameCount = 0;
  StreamSubscription? _libJitsiFrameSubscription;
  VoidCallback? _libJitsiListener;

  StreamService(
    this._glassesService,
    this._bluetoothAudioService,
  ) {
    // No initial setup needed - lib-jitsi-meet service is set later
  }

  /// Set the lib-jitsi-meet service (called when available)
  void setLibJitsiService(LibJitsiService service) {
    _libJitsiService = service;
    _setupLibJitsiListener();
  }

  void _setupLibJitsiListener() {
    _libJitsiListener = () {
      final state = _libJitsiService!.currentState;
      _updateState(_currentState.copyWith(
        isInMeeting: state.isInMeeting,
      ));
    };
    _libJitsiService!.addListener(_libJitsiListener!);
  }

  /// Current stream state
  StreamState get currentState => _currentState;

  /// Stream of preview frames
  Stream<Uint8List> get previewFrameStream => _glassesService.previewFrameStream;

  void _updateState(StreamState newState) {
    _currentState = newState;
    notifyListeners();
  }

  /// Start streaming video to a Jitsi meeting
  Future<void> startStreaming(MeetingConfig config) async {
    try {
      if (_libJitsiService == null) {
        throw Exception('LibJitsiService not available');
      }

      _updateState(_currentState.copyWith(status: StreamStatus.starting));
      _frameCount = 0;

      final videoSource = _glassesService.videoSource;
      debugPrint('StreamService: Starting lib-jitsi-meet mode, videoSource=$videoSource');

      // 1. Route audio to glasses if available
      final audioRouted = await _bluetoothAudioService.autoRouteToGlasses();
      if (audioRouted) {
        debugPrint('StreamService: Audio routed to glasses');
      }

      // 2. Start video capture (glasses or camera)
      final captureStarted = await _glassesService.startStreaming();
      if (!captureStarted) {
        throw Exception('Failed to start video capture');
      }

      // 3. Join meeting via lib-jitsi-meet
      await _libJitsiService!.joinMeeting(config);

      // 4. Send frames to lib-jitsi-meet WebView
      _libJitsiFrameSubscription = _glassesService.previewFrameStream.listen((frameData) {
        _frameCount++;
        // Send every frame to lib-jitsi-meet (it handles throttling)
        _libJitsiService!.sendFrame(frameData);

        // Update UI every 30 frames
        if (_frameCount % 30 == 0) {
          _updateState(_currentState.copyWith(framesSent: _frameCount));
        }
      });

      _updateState(_currentState.copyWith(
        status: StreamStatus.streaming,
        isInMeeting: true,
        isGlassesAudioActive: audioRouted,
      ));

      debugPrint('StreamService: lib-jitsi-meet streaming started');
    } catch (e) {
      _updateState(_currentState.copyWith(
        status: StreamStatus.error,
        errorMessage: e.toString(),
      ));
      rethrow;
    }
  }

  /// Stop streaming and leave meeting
  Future<void> stopStreaming() async {
    _updateState(_currentState.copyWith(status: StreamStatus.stopping));

    try {
      // Cancel frame subscription
      await _libJitsiFrameSubscription?.cancel();
      _libJitsiFrameSubscription = null;

      // Stop glasses streaming
      await _glassesService.stopStreaming();

      // Leave meeting
      if (_libJitsiService != null) {
        await _libJitsiService!.leaveMeeting();
      }

      // Clear audio routing
      await _bluetoothAudioService.clearAudioDevice();

      _updateState(const StreamState(
        status: StreamStatus.stopped,
        isInMeeting: false,
        framesSent: 0,
        isGlassesAudioActive: false,
      ));
    } catch (e) {
      _updateState(_currentState.copyWith(
        status: StreamStatus.error,
        errorMessage: e.toString(),
      ));
    }
  }

  /// Toggle audio in meeting
  Future<void> toggleAudio() async {
    if (_libJitsiService != null) {
      await _libJitsiService!.toggleAudio();
    }
  }

  /// Toggle video in meeting
  Future<void> toggleVideo() async {
    if (_libJitsiService != null) {
      await _libJitsiService!.toggleVideo();
    }
  }

  @override
  void dispose() {
    _libJitsiFrameSubscription?.cancel();
    if (_libJitsiListener != null && _libJitsiService != null) {
      _libJitsiService!.removeListener(_libJitsiListener!);
    }
    super.dispose();
  }
}
