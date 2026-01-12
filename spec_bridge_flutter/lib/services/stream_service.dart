import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/meeting_config.dart';
import '../data/models/stream_status.dart';
import 'bluetooth_audio_service.dart';
import 'glasses_service.dart';
import 'jitsi_service.dart';

/// Service that orchestrates glasses video streaming to Jitsi meetings
class StreamService extends ChangeNotifier {
  final GlassesService _glassesService;
  final JitsiService _jitsiService;
  final BluetoothAudioService _bluetoothAudioService;

  StreamState _currentState = const StreamState();

  int _frameCount = 0;
  StreamSubscription? _glassesEventSubscription;
  VoidCallback? _jitsiListener;

  StreamService(
    this._glassesService,
    this._jitsiService,
    this._bluetoothAudioService,
  ) {
    _listenToServices();
  }

  /// Current stream state
  StreamState get currentState => _currentState;

  /// Stream of preview frames
  Stream<Uint8List> get previewFrameStream => _glassesService.previewFrameStream;

  void _listenToServices() {
    // Listen to Jitsi meeting state
    _jitsiListener = () {
      final meetingState = _jitsiService.currentState;
      _updateState(_currentState.copyWith(
        isInMeeting: meetingState.isInMeeting,
      ));
    };
    _jitsiService.addListener(_jitsiListener!);
  }

  void _updateState(StreamState newState) {
    _currentState = newState;
    notifyListeners();
  }

  /// Start streaming glasses video to a Jitsi meeting
  Future<void> startStreaming(MeetingConfig config) async {
    try {
      _updateState(_currentState.copyWith(status: StreamStatus.starting));
      _frameCount = 0;

      // 1. Route audio to glasses if available (best effort)
      final audioRouted = await _bluetoothAudioService.autoRouteToGlasses();
      if (audioRouted) {
        debugPrint('StreamService: Audio routed to glasses');
      } else {
        debugPrint('StreamService: Using default audio device');
      }

      // 2. Start glasses video capture
      final glassesStarted = await _glassesService.startStreaming();
      if (!glassesStarted) {
        throw Exception('Failed to start glasses video capture');
      }

      // 3. Join Jitsi meeting
      await _jitsiService.joinMeeting(config);

      // 4. Start counting frames for status display
      _glassesEventSubscription = _glassesService.previewFrameStream.listen((_) {
        _frameCount++;
        if (_frameCount % 30 == 0) {
          _updateState(_currentState.copyWith(framesSent: _frameCount));
        }
      });

      // 5. Enable screen share after a short delay (to let meeting establish)
      await Future.delayed(const Duration(seconds: 2));
      await _jitsiService.toggleScreenShare();

      _updateState(_currentState.copyWith(
        status: StreamStatus.streaming,
        isInMeeting: true,
        isGlassesAudioActive: audioRouted,
      ));
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
      await _glassesEventSubscription?.cancel();
      _glassesEventSubscription = null;

      // Stop glasses streaming
      await _glassesService.stopStreaming();

      // Leave Jitsi meeting
      await _jitsiService.leaveMeeting();

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
    await _jitsiService.toggleAudio();
  }

  /// Toggle screen share
  Future<void> toggleScreenShare() async {
    await _jitsiService.toggleScreenShare();
  }

  @override
  void dispose() {
    _glassesEventSubscription?.cancel();
    if (_jitsiListener != null) {
      _jitsiService.removeListener(_jitsiListener!);
    }
    super.dispose();
  }
}
