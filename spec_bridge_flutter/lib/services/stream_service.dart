import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/app_settings.dart';
import '../data/models/meeting_config.dart';
import '../data/models/stream_status.dart';
import 'bluetooth_audio_service.dart';
import 'glasses_service.dart';
import 'lib_jitsi_service.dart';
import 'platform_channels/meta_dat_channel.dart';

/// Service that orchestrates glasses video streaming to Jitsi meetings
class StreamService extends ChangeNotifier {
  final GlassesService _glassesService;
  final BluetoothAudioService _bluetoothAudioService;
  LibJitsiService? _libJitsiService;

  StreamState _currentState = const StreamState();

  int _frameCount = 0;
  StreamSubscription? _libJitsiFrameSubscription;
  VoidCallback? _libJitsiListener;
  Timer? _statsLogTimer;
  MetaDATChannel? _nativeChannel;

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

  /// Set native channel for stats logging
  void setNativeChannel(MetaDATChannel channel) {
    _nativeChannel = channel;
  }

  /// Start periodic stats logging (every 5 seconds)
  void _startStatsLogging() {
    _statsLogTimer?.cancel();
    _statsLogTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await _logPipelineStats();
    });
  }

  /// Stop stats logging
  void _stopStatsLogging() {
    _statsLogTimer?.cancel();
    _statsLogTimer = null;
  }

  /// Log comprehensive pipeline stats
  Future<void> _logPipelineStats() async {
    if (_libJitsiService == null) return;

    try {
      // Get stats from all sources
      final webViewStats = await _libJitsiService!.getStats();
      final flutterStats = _libJitsiService!.getFlutterStats();
      Map<String, dynamic> nativeStats = {};
      if (_nativeChannel != null) {
        nativeStats = await _nativeChannel!.getStreamStats();
      }

      // Build log string
      final buffer = StringBuffer();
      buffer.writeln('========== PIPELINE STATS ==========');

      // Native capture stats
      final nativeRecv = nativeStats['framesReceived'] ?? 0;
      final nativeProc = nativeStats['framesProcessed'] ?? 0;
      final nativeSent = nativeStats['nativeFramesSent'] ?? 0;
      final nativeDropped = nativeStats['nativeFramesDropped'] ?? 0;
      final nativeBackpressure = nativeStats['nativeBackpressure'] ?? 0;
      final encodeMs = nativeStats['lastEncodeTimeMs'] ?? 0;
      final sdkIntervalMs = nativeStats['avgFrameIntervalMs'] ?? 0;
      buffer.writeln('Native: recv=$nativeRecv proc=$nativeProc sent=$nativeSent drop=$nativeDropped backpressure=$nativeBackpressure encodeMs=$encodeMs sdkIntervalMs=$sdkIntervalMs');

      // Flutter stats (if not using native path)
      final flutterSent = flutterStats['framesSent'] ?? 0;
      final flutterDropped = flutterStats['framesDropped'] ?? 0;
      final flutterSlowSends = flutterStats['wsSlowSends'] ?? 0;
      buffer.writeln('Flutter: sent=$flutterSent dropped=$flutterDropped slowSends=$flutterSlowSends');

      // WebView stats
      buffer.writeln('WebView: recv=${webViewStats.totalFrames} drawn=${webViewStats.framesDrawn} dropQ=${webViewStats.framesDroppedJs} dropStale=${webViewStats.framesDroppedStale}');
      buffer.writeln('Latency: last=${webViewStats.lastLatencyMs}ms avg=${webViewStats.avgLatencyMs}ms max=${webViewStats.maxLatencyMs}ms');
      buffer.writeln('Timing: arrivalMs=${webViewStats.avgArrivalMs} decodeMs=${webViewStats.avgDecodeMs} fps=${webViewStats.fps}');

      // WebRTC encoder stats (shows where backup may occur in encoder/network)
      buffer.writeln('WebRTC: enc=${webViewStats.rtcFramesEncoded} sent=${webViewStats.rtcFramesSent} pending=${webViewStats.rtcFramesPending} limit=${webViewStats.rtcQualityLimitation}');
      buffer.writeln('Encoder: ${webViewStats.rtcEncoderImpl} ${webViewStats.rtcEncodeWidth}x${webViewStats.rtcEncodeHeight}@${webViewStats.rtcEncodeFps}fps retrans=${webViewStats.rtcRetransmits}');
      buffer.writeln('=====================================');

      debugPrint(buffer.toString());
    } catch (e) {
      debugPrint('StreamService: Stats logging error: $e');
    }
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
  AudioOutput _currentAudioOutput = AudioOutput.speakerphone;
  AudioOutput get currentAudioOutput => _currentAudioOutput;

  /// Start streaming video to a Jitsi meeting
  Future<void> startStreaming(
    MeetingConfig config, {
    AudioOutput audioOutput = AudioOutput.speakerphone,
    VideoQuality videoQuality = VideoQuality.medium,
    int frameRate = 15, // Default to 15fps for stable Bluetooth
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
      debugPrint('StreamService: audioOutput=$audioOutput, videoQuality=$videoQuality, frameRate=$frameRate');

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

      // Set video source mode in WebView BEFORE joining (camera mode only)
      // This must happen before startVideoTrack() which is called in onConnectionEstablished
      if (!isGlassesMode) {
        // Camera mode: Use getUserMedia directly in WebView (much more efficient!)
        // No native capture needed - WebView handles camera access via WebRTC
        debugPrint('StreamService: Using direct camera mode (getUserMedia in WebView)');

        // Notify native side of video source for stats tracking
        await _glassesService.notifyVideoSourceToNative(videoSource);

        // Tell WebView to use camera mode - this acquires camera via getUserMedia
        final cameraReady = await _libJitsiService!.setVideoSource(videoSource.name);
        if (!cameraReady) {
          throw Exception('Failed to access camera in WebView');
        }
        debugPrint('StreamService: Camera ready in WebView, now joining meeting...');
      } else {
        // Glasses mode: Wait for WebSocket to be connected before joining
        // This ensures the frame pipeline is ready before creating the video track
        debugPrint('StreamService: Using glasses mode - waiting for WebSocket connection...');
        final wsConnected = await _libJitsiService!.waitForWebSocketConnected();
        if (!wsConnected) {
          throw Exception('WebSocket connection failed - cannot stream glasses video');
        }
        debugPrint('StreamService: WebSocket connected, ready to join meeting');
      }

      // Join meeting - this triggers startVideoTrack() in onConnectionEstablished
      // For camera: will use the getUserMedia stream we just acquired
      // For glasses: will use canvas captureStream with WebSocket ready for frames
      // usePhoneMic: force phone mic when NOT using glasses audio to preserve BT bandwidth for glasses video
      final usePhoneMic = audioOutput != AudioOutput.glasses;

      // Force phone speaker/mic mode BEFORE creating audio track in WebRTC
      // This prevents Bluetooth SCO from activating and competing with glasses video
      if (usePhoneMic && isGlassesMode) {
        debugPrint('StreamService: Forcing phone speaker/mic to preserve BT bandwidth for glasses');
        await _bluetoothAudioService.forcePhoneMic();
      }

      debugPrint('StreamService: [${ isGlassesMode ? "Glasses" : "Camera"}] Joining meeting (usePhoneMic=$usePhoneMic)...');
      await _libJitsiService!.joinMeeting(config, usePhoneMic: usePhoneMic);

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
          frameRate: frameRate,
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

      // Start periodic stats logging
      _startStatsLogging();

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

    // Stop stats logging
    _stopStatsLogging();

    try {
      // Cancel frame subscription
      await _libJitsiFrameSubscription?.cancel();
      _libJitsiFrameSubscription = null;

      // Stop glasses streaming
      await _glassesService.stopStreaming();

      // Reset native frame server client state for clean session transition
      await _glassesService.resetFrameServer();
      debugPrint('StreamService: Native frame server reset for clean session transition');

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
  /// - speakerphone/earpiece: Maximize video quality (24fps/high) since BT is free for video
  /// - glasses: Reduce video quality (2fps/low) to share BT bandwidth with audio
  Future<bool> setAudioOutput(AudioOutput output) async {
    if (output == _currentAudioOutput) return true;

    final success = await _bluetoothAudioService.setAudioOutput(output);
    debugPrint('StreamService: Switched audio to ${output.name}: $success');

    if (success) {
      // Adjust video quality based on whether glasses audio is using BT bandwidth
      await _adjustVideoForAudioOutput(output);
      _currentAudioOutput = output;
      _updateState(_currentState.copyWith(isGlassesAudioActive: output == AudioOutput.glasses));
    }

    return success;
  }

  /// Adjust video quality/fps based on audio output to manage Bluetooth bandwidth
  Future<void> _adjustVideoForAudioOutput(AudioOutput output) async {
    final isGlassesMode = _glassesService.videoSource.toString().contains('glasses');
    if (!isGlassesMode) return; // Only applies to glasses streaming

    if (output == AudioOutput.glasses) {
      // Glasses audio uses BT bandwidth → reduce video to 2fps, low quality
      debugPrint('StreamService: Reducing video to 2fps/low for glasses audio');
      await _glassesService.restartStreaming(
        videoQuality: 'low',
        frameRate: 2,
      );
    } else {
      // Speakerphone or earpiece → maximize video to 24fps, high quality (BT free for video)
      debugPrint('StreamService: Maximizing video to 24fps/high for ${output.name}');
      await _glassesService.restartStreaming(
        videoQuality: 'high',
        frameRate: 24,
      );
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
