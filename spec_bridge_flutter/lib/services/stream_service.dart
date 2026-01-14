import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/app_settings.dart';
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

  // Current audio output setting (can be changed during call)
  AudioOutput _currentAudioOutput = AudioOutput.phoneSpeaker;
  AudioOutput get currentAudioOutput => _currentAudioOutput;

  /// Start streaming video to a Jitsi meeting
  Future<void> startStreaming(
    MeetingConfig config, {
    AudioOutput audioOutput = AudioOutput.phoneSpeaker,
    VideoQuality videoQuality = VideoQuality.medium,
    bool useNativeFrameServer = true,
  }) async {
    try {
      if (_libJitsiService == null) {
        throw Exception('LibJitsiService not available');
      }

      _updateState(_currentState.copyWith(status: StreamStatus.starting));
      _frameCount = 0;
      _currentAudioOutput = audioOutput;

      // Enable/disable native frame server based on setting
      await _glassesService.setNativeServerEnabled(useNativeFrameServer);
      debugPrint('StreamService: Native frame server ${useNativeFrameServer ? "enabled" : "disabled"}');

      final videoSource = _glassesService.videoSource;
      final isGlassesMode = videoSource.toString().contains('glasses');
      debugPrint('StreamService: Starting lib-jitsi-meet mode, videoSource=$videoSource, isGlassesMode=$isGlassesMode');
      debugPrint('StreamService: audioOutput=$audioOutput, videoQuality=$videoQuality');

      // 1. Route audio based on setting
      // For glasses mode, only route to glasses if explicitly requested (to preserve BT bandwidth for video)
      bool audioRouted = false;
      if (audioOutput == AudioOutput.glasses) {
        audioRouted = await _bluetoothAudioService.autoRouteToGlasses();
        if (audioRouted) {
          debugPrint('StreamService: Audio routed to glasses');
        } else {
          debugPrint('StreamService: Failed to route audio to glasses, using phone speaker');
        }
      } else {
        debugPrint('StreamService: Using phone speaker for audio (preserves BT bandwidth for video)');
      }

      // For camera mode, we need to set up getUserMedia BEFORE joining
      // because startVideoTrack() is called inside onConnectionEstablished
      if (!isGlassesMode) {
        // Camera mode: Use getUserMedia directly in WebView (much more efficient!)
        // No native capture needed - WebView handles camera access via WebRTC
        debugPrint('StreamService: Using direct camera mode (getUserMedia in WebView)');

        // Notify native side of video source for stats tracking
        await _glassesService.notifyVideoSourceToNative(videoSource);

        // Tell WebView to use camera mode BEFORE joining - this acquires camera via getUserMedia
        // This must happen before startVideoTrack() which is called in onConnectionEstablished
        final cameraReady = await _libJitsiService!.setVideoSource(videoSource.name);
        if (!cameraReady) {
          throw Exception('Failed to access camera in WebView');
        }
        debugPrint('StreamService: Camera ready in WebView, now joining meeting...');
      }

      // Join meeting - this triggers startVideoTrack() in onConnectionEstablished
      // For camera: will use the getUserMedia stream we just acquired
      // For glasses: will use canvas mode (default)
      debugPrint('StreamService: [${ isGlassesMode ? "Glasses" : "Camera"}] Joining meeting...');
      await _libJitsiService!.joinMeeting(config);

      // Wait for XMPP signaling to complete - the 'joined' event sets isInMeeting=true
      // This is critical: frames are blocked until isInMeeting is true
      await Future.delayed(const Duration(milliseconds: 1500));
      debugPrint('StreamService: Meeting join initiated, isInMeeting=${_libJitsiService!.isInMeeting}');

      // For glasses mode, start native streaming after joining
      if (isGlassesMode) {
        debugPrint('StreamService: Starting glasses video capture...');

        // Start native streaming
        final captureStarted = await _glassesService.startStreaming(
          videoQuality: videoQuality.name,
        );
        if (!captureStarted) {
          throw Exception('Failed to start video capture');
        }
        debugPrint('StreamService: Glasses video capture started');

        // Set up frame forwarding to lib-jitsi-meet WebView
        _libJitsiFrameSubscription = _glassesService.previewFrameStream.listen((frameData) {
          _frameCount++;

          if (_frameCount == 1) {
            debugPrint('StreamService: First frame received (${frameData.length} bytes)');
          }

          // Send every frame to lib-jitsi-meet (it handles throttling)
          _libJitsiService!.sendFrame(frameData);

          // Update UI every 30 frames
          if (_frameCount % 30 == 0) {
            debugPrint('StreamService: Sent $_frameCount frames');
            _updateState(_currentState.copyWith(framesSent: _frameCount));
          }
        });
      }

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

  /// Switch audio output during a call
  Future<bool> setAudioOutput(AudioOutput output) async {
    if (output == _currentAudioOutput) return true;

    bool success = false;
    if (output == AudioOutput.glasses) {
      success = await _bluetoothAudioService.autoRouteToGlasses();
      if (success) {
        debugPrint('StreamService: Switched audio to glasses');
      }
    } else {
      await _bluetoothAudioService.clearAudioDevice();
      success = true;
      debugPrint('StreamService: Switched audio to phone speaker');
    }

    if (success) {
      _currentAudioOutput = output;
      _updateState(_currentState.copyWith(isGlassesAudioActive: output == AudioOutput.glasses));
    }

    return success;
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
