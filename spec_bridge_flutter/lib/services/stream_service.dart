import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/models/glasses_state.dart';
import '../data/models/meeting_config.dart';
import '../data/models/stream_status.dart';
import 'bluetooth_audio_service.dart';
import 'floating_preview_service.dart';
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
  bool _pendingScreenShare = false; // Track if we need to auto-start screen share
  bool _useOverlayMode = false; // Track if using overlay (glasses/camera) vs native screen share

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
      final wasInMeeting = _currentState.isInMeeting;

      _updateState(_currentState.copyWith(
        isInMeeting: meetingState.isInMeeting,
      ));

      // Auto-trigger screen share when conference is joined
      if (!wasInMeeting && meetingState.isInMeeting && _pendingScreenShare) {
        _pendingScreenShare = false;
        debugPrint('StreamService: Auto-triggering screen share after conference joined');
        // Small delay to ensure meeting is fully ready
        Future.delayed(const Duration(milliseconds: 500), () {
          _triggerScreenShare();
        });
      }
    };
    _jitsiService.addListener(_jitsiListener!);
  }

  /// Trigger screen share
  /// Note: PiP doesn't work during screen share (Jitsi limitation)
  /// User must use touch pass-through or notification to interact with Jitsi
  Future<void> _triggerScreenShare() async {
    debugPrint('StreamService: Triggering screen share, useOverlayMode=$_useOverlayMode');
    await _jitsiService.toggleScreenShare();
  }

  void _updateState(StreamState newState) {
    _currentState = newState;
    notifyListeners();
  }

  /// Start streaming video to a Jitsi meeting
  Future<void> startStreaming(MeetingConfig config) async {
    try {
      _updateState(_currentState.copyWith(status: StreamStatus.starting));
      _frameCount = 0;

      final videoSource = _glassesService.videoSource;
      final isScreenShare = videoSource == VideoSource.screenShare;
      debugPrint('StreamService: videoSource=$videoSource, isScreenShare=$isScreenShare');

      // 1. Route audio to glasses if available (best effort, skip for screen share)
      bool audioRouted = false;
      if (!isScreenShare) {
        audioRouted = await _bluetoothAudioService.autoRouteToGlasses();
        if (audioRouted) {
          debugPrint('StreamService: Audio routed to glasses');
        } else {
          debugPrint('StreamService: Using default audio device');
        }
      }

      // 2. Start video capture (skip for screen share - Jitsi handles it)
      if (!isScreenShare) {
        // On Android, start the floating overlay for MediaProjection capture
        if (Platform.isAndroid) {
          final hasPermission = await FloatingPreviewService.checkOverlayPermission();
          if (hasPermission) {
            await FloatingPreviewService.startOverlay();
            debugPrint('StreamService: Floating overlay started');
          } else {
            debugPrint('StreamService: No overlay permission, requesting...');
            await FloatingPreviewService.requestOverlayPermission();
          }
        }

        final captureStarted = await _glassesService.startStreaming();
        if (!captureStarted) {
          throw Exception('Failed to start video capture');
        }
      }

      // 3. Join Jitsi meeting
      await _jitsiService.joinMeeting(config);

      // 4. Start counting frames for status display (skip for screen share)
      if (!isScreenShare) {
        _glassesEventSubscription = _glassesService.previewFrameStream.listen((_) {
          _frameCount++;
          if (_frameCount % 30 == 0) {
            _updateState(_currentState.copyWith(framesSent: _frameCount));
          }
        });
      }

      _updateState(_currentState.copyWith(
        status: StreamStatus.streaming,
        isInMeeting: true,
        isGlassesAudioActive: audioRouted,
      ));

      // 5. Auto-trigger screen share for ALL modes
      // - Screen share mode: native screen capture (no overlay, no PiP)
      // - Glasses/Camera modes: capture overlay with PiP for meeting visibility
      _pendingScreenShare = true;
      _useOverlayMode = !isScreenShare; // Use overlay+PiP for glasses/camera modes
      debugPrint('StreamService: Screen share pending for $videoSource, useOverlayMode=$_useOverlayMode');
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
    _pendingScreenShare = false;
    _useOverlayMode = false;

    try {
      // Cancel frame subscription
      await _glassesEventSubscription?.cancel();
      _glassesEventSubscription = null;

      // Stop glasses streaming
      await _glassesService.stopStreaming();

      // Stop floating overlay on Android
      if (Platform.isAndroid) {
        await FloatingPreviewService.stopOverlay();
        debugPrint('StreamService: Floating overlay stopped');
      }

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

  /// Toggle video in meeting
  Future<void> toggleVideo() async {
    await _jitsiService.toggleVideo();
  }

  /// Toggle screen share in meeting
  Future<void> toggleScreenShare() async {
    debugPrint('StreamService: toggleScreenShare called');
    await _jitsiService.toggleScreenShare();
    debugPrint('StreamService: toggleScreenShare completed');
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
