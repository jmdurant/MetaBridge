import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/models/app_settings.dart';
import '../data/models/glasses_state.dart';
import '../data/models/meeting_config.dart';
import '../data/models/stream_status.dart';
import 'bluetooth_audio_service.dart';
import 'floating_preview_service.dart';
import 'glasses_service.dart';
import 'jitsi_service.dart';
import 'lib_jitsi_service.dart';

/// Service that orchestrates glasses video streaming to Jitsi meetings
class StreamService extends ChangeNotifier {
  final GlassesService _glassesService;
  final JitsiService _jitsiService;
  final BluetoothAudioService _bluetoothAudioService;
  LibJitsiService? _libJitsiService;
  JitsiMode _jitsiMode = JitsiMode.sdk;

  StreamState _currentState = const StreamState();

  int _frameCount = 0;
  StreamSubscription? _glassesEventSubscription;
  StreamSubscription? _libJitsiFrameSubscription;
  VoidCallback? _jitsiListener;
  VoidCallback? _libJitsiListener;
  bool _pendingScreenShare = false; // Track if we need to auto-start screen share
  bool _useOverlayMode = false; // Track if using overlay (glasses/camera) vs native screen share

  StreamService(
    this._glassesService,
    this._jitsiService,
    this._bluetoothAudioService,
  ) {
    _listenToServices();
  }

  /// Set the lib-jitsi-meet service (called when available)
  void setLibJitsiService(LibJitsiService service) {
    _libJitsiService = service;
    _setupLibJitsiListener();
  }

  /// Set the Jitsi mode to use
  void setJitsiMode(JitsiMode mode) {
    _jitsiMode = mode;
    debugPrint('StreamService: Jitsi mode set to $mode');
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
    // Use lib-jitsi-meet mode if configured
    if (_jitsiMode == JitsiMode.libJitsiMeet) {
      await _startStreamingLibJitsi(config);
      return;
    }

    // SDK mode (with overlay + screen capture)
    await _startStreamingSdk(config);
  }

  /// Start streaming using lib-jitsi-meet (direct frame injection)
  Future<void> _startStreamingLibJitsi(MeetingConfig config) async {
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

  /// Start streaming using SDK mode (overlay + screen capture)
  Future<void> _startStreamingSdk(MeetingConfig config) async {
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
      // Cancel frame subscriptions
      await _glassesEventSubscription?.cancel();
      _glassesEventSubscription = null;
      await _libJitsiFrameSubscription?.cancel();
      _libJitsiFrameSubscription = null;

      // Stop glasses streaming
      await _glassesService.stopStreaming();

      // Stop floating overlay on Android (SDK mode only)
      if (_jitsiMode == JitsiMode.sdk && Platform.isAndroid) {
        await FloatingPreviewService.stopOverlay();
        debugPrint('StreamService: Floating overlay stopped');
      }

      // Leave meeting (based on mode)
      if (_jitsiMode == JitsiMode.libJitsiMeet && _libJitsiService != null) {
        await _libJitsiService!.leaveMeeting();
      } else {
        await _jitsiService.leaveMeeting();
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
    if (_jitsiMode == JitsiMode.libJitsiMeet && _libJitsiService != null) {
      await _libJitsiService!.toggleAudio();
    } else {
      await _jitsiService.toggleAudio();
    }
  }

  /// Toggle video in meeting
  Future<void> toggleVideo() async {
    if (_jitsiMode == JitsiMode.libJitsiMeet && _libJitsiService != null) {
      await _libJitsiService!.toggleVideo();
    } else {
      await _jitsiService.toggleVideo();
    }
  }

  /// Toggle screen share in meeting (SDK mode only)
  Future<void> toggleScreenShare() async {
    if (_jitsiMode == JitsiMode.libJitsiMeet) {
      debugPrint('StreamService: Screen share not applicable in lib-jitsi-meet mode');
      return;
    }
    debugPrint('StreamService: toggleScreenShare called');
    await _jitsiService.toggleScreenShare();
    debugPrint('StreamService: toggleScreenShare completed');
  }

  @override
  void dispose() {
    _glassesEventSubscription?.cancel();
    _libJitsiFrameSubscription?.cancel();
    if (_jitsiListener != null) {
      _jitsiService.removeListener(_jitsiListener!);
    }
    if (_libJitsiListener != null && _libJitsiService != null) {
      _libJitsiService!.removeListener(_libJitsiListener!);
    }
    super.dispose();
  }
}
