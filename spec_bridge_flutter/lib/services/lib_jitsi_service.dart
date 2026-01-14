import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../data/models/meeting_config.dart';
import 'frame_websocket_server.dart';

/// Stats from the lib-jitsi-meet WebView
class LibJitsiStats {
  final String resolution;
  final int width;
  final int height;
  final int fps;
  final int bitrate; // kbps
  final int totalFrames;
  final int framesDrawn;
  final int framesDroppedJs;
  final int framesDroppedStale; // Frames dropped due to being too old
  final int jsDropRate;
  final int lastDecodeMs;
  final int avgDecodeMs;
  final int avgArrivalMs; // Average frame arrival interval
  final int totalBytes;
  final bool isJoined;
  final bool hasAudioTrack;
  final bool hasVideoTrack;
  final bool wsConnected;
  final bool isE2EEEnabled;
  final String videoSourceMode; // 'canvas' or 'camera'
  final bool hasCameraStream; // true if using getUserMedia

  const LibJitsiStats({
    this.resolution = '0x0',
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.bitrate = 0,
    this.totalFrames = 0,
    this.framesDrawn = 0,
    this.framesDroppedJs = 0,
    this.framesDroppedStale = 0,
    this.jsDropRate = 0,
    this.lastDecodeMs = 0,
    this.avgDecodeMs = 0,
    this.avgArrivalMs = 0,
    this.totalBytes = 0,
    this.isJoined = false,
    this.hasAudioTrack = false,
    this.hasVideoTrack = false,
    this.wsConnected = false,
    this.isE2EEEnabled = false,
    this.videoSourceMode = 'canvas',
    this.hasCameraStream = false,
  });

  factory LibJitsiStats.fromJson(Map<String, dynamic> json) {
    return LibJitsiStats(
      resolution: json['resolution'] as String? ?? '0x0',
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      fps: json['fps'] as int? ?? 0,
      bitrate: json['bitrate'] as int? ?? 0,
      totalFrames: json['totalFrames'] as int? ?? 0,
      framesDrawn: json['framesDrawn'] as int? ?? 0,
      framesDroppedJs: json['framesDroppedJs'] as int? ?? 0,
      framesDroppedStale: json['framesDroppedStale'] as int? ?? 0,
      jsDropRate: json['jsDropRate'] as int? ?? 0,
      lastDecodeMs: json['lastDecodeMs'] as int? ?? 0,
      avgDecodeMs: json['avgDecodeMs'] as int? ?? 0,
      avgArrivalMs: json['avgArrivalMs'] as int? ?? 0,
      totalBytes: json['totalBytes'] as int? ?? 0,
      isJoined: json['isJoined'] as bool? ?? false,
      hasAudioTrack: json['hasAudioTrack'] as bool? ?? false,
      hasVideoTrack: json['hasVideoTrack'] as bool? ?? false,
      wsConnected: json['wsConnected'] as bool? ?? false,
      isE2EEEnabled: json['isE2EEEnabled'] as bool? ?? false,
      videoSourceMode: json['videoSourceMode'] as String? ?? 'canvas',
      hasCameraStream: json['hasCameraStream'] as bool? ?? false,
    );
  }

  String get bitrateFormatted {
    if (bitrate >= 1000) {
      return '${(bitrate / 1000).toStringAsFixed(1)} Mbps';
    }
    return '$bitrate kbps';
  }
}

/// State for lib-jitsi-meet WebView mode
class LibJitsiState {
  final bool isInitialized;
  final bool isInMeeting;
  final bool isAudioMuted;
  final bool isVideoMuted;
  final bool isE2EEEnabled;
  final String? roomName;
  final String? errorMessage;
  final int participantCount;

  const LibJitsiState({
    this.isInitialized = false,
    this.isInMeeting = false,
    this.isAudioMuted = false,
    this.isVideoMuted = true,
    this.isE2EEEnabled = false,
    this.roomName,
    this.errorMessage,
    this.participantCount = 0,
  });

  LibJitsiState copyWith({
    bool? isInitialized,
    bool? isInMeeting,
    bool? isAudioMuted,
    bool? isVideoMuted,
    bool? isE2EEEnabled,
    String? roomName,
    String? errorMessage,
    int? participantCount,
  }) {
    return LibJitsiState(
      isInitialized: isInitialized ?? this.isInitialized,
      isInMeeting: isInMeeting ?? this.isInMeeting,
      isAudioMuted: isAudioMuted ?? this.isAudioMuted,
      isVideoMuted: isVideoMuted ?? this.isVideoMuted,
      isE2EEEnabled: isE2EEEnabled ?? this.isE2EEEnabled,
      roomName: roomName ?? this.roomName,
      errorMessage: errorMessage,
      participantCount: participantCount ?? this.participantCount,
    );
  }
}

/// Service for managing lib-jitsi-meet in a WebView
///
/// This service loads a local HTML page that uses lib-jitsi-meet.js
/// to connect to Jitsi servers. Video frames are drawn to a canvas
/// and captured via captureStream() for WebRTC transmission.
class LibJitsiService extends ChangeNotifier {
  InAppWebViewController? _controller;
  LibJitsiState _currentState = const LibJitsiState();
  MeetingConfig? _pendingConfig;
  String? _pendingVideoSource; // Queued video source to set after initialization

  // WebSocket server for fast binary frame transfer
  final FrameWebSocketServer _wsServer = FrameWebSocketServer();

  // No throttle - let JavaScript handle frame dropping with "latest frame wins"

  // Pause state - don't send frames when WebView is paused
  bool _isPaused = false;

  // Background mode - when enabled, don't pause WebView when app backgrounds
  bool _backgroundModeEnabled = false;

  LibJitsiState get currentState => _currentState;
  MeetingConfig? get pendingConfig => _pendingConfig;
  bool get isInMeeting => _currentState.isInMeeting;
  bool get backgroundModeEnabled => _backgroundModeEnabled;
  FrameWebSocketServer get wsServer => _wsServer;

  /// Enable or disable background mode
  /// When enabled, the WebView won't be paused when the app goes to background
  void setBackgroundMode(bool enabled) {
    _backgroundModeEnabled = enabled;
    debugPrint('LibJitsiService: Background mode ${enabled ? "enabled" : "disabled"}');
  }

  /// Set the WebView controller (called from widget)
  void setController(InAppWebViewController controller) {
    _controller = controller;
    // Reset initialized state - new WebView means new JS context
    _updateState(_currentState.copyWith(isInitialized: false));
    _setupJavaScriptHandlers(controller);

    // Start WebSocket server early so JS can connect when it initializes
    if (!_wsServer.isRunning) {
      _wsServer.start().then((success) {
        debugPrint('LibJitsiService: WebSocket server started: $success');
      });
    }
  }

  void _setupJavaScriptHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'jitsiEvent',
      callback: (args) {
        if (args.length >= 2) {
          final event = args[0] as String;
          final dataJson = args[1] as String;
          _handleJitsiEvent(event, dataJson);
        }
        return null;
      },
    );
  }

  Future<void> _handleJitsiEvent(String event, String dataJson) async {
    debugPrint('LibJitsiService: event=$event, data=$dataJson');

    Map<String, dynamic> data = {};
    try {
      data = json.decode(dataJson) as Map<String, dynamic>;
    } catch (_) {}

    switch (event) {
      case 'initialized':
        // Handle pending operations FIRST, before setting isInitialized
        // This prevents a race where joinMeeting() sees isInitialized=true
        // but camera acquisition is still in progress
        if (_pendingVideoSource != null) {
          await _setVideoSourceInternal(_pendingVideoSource!);
          _pendingVideoSource = null;
        }
        // NOW set initialized (after camera is ready)
        _updateState(_currentState.copyWith(isInitialized: true));
        // If we have a pending config, join now
        if (_pendingConfig != null) {
          _joinWithConfig(_pendingConfig!);
        }
        break;

      case 'joined':
        _updateState(_currentState.copyWith(
          isInMeeting: true,
          roomName: data['room'] as String?,
        ));
        break;

      case 'left':
        _updateState(_currentState.copyWith(
          isInMeeting: false,
          roomName: null,
          participantCount: 0,
        ));
        _pendingConfig = null;
        break;

      case 'connectionFailed':
      case 'conferenceFailed':
      case 'error':
        _updateState(_currentState.copyWith(
          errorMessage: data['error'] as String? ?? data['message'] as String?,
        ));
        break;

      case 'audioMutedChanged':
        _updateState(_currentState.copyWith(
          isAudioMuted: data['muted'] as bool? ?? false,
        ));
        break;

      case 'videoMutedChanged':
        _updateState(_currentState.copyWith(
          isVideoMuted: data['muted'] as bool? ?? false,
        ));
        break;

      case 'participantJoined':
        _updateState(_currentState.copyWith(
          participantCount: _currentState.participantCount + 1,
        ));
        break;

      case 'participantLeft':
        _updateState(_currentState.copyWith(
          participantCount: (_currentState.participantCount - 1).clamp(0, 999),
        ));
        break;

      case 'e2eeEnabled':
        _updateState(_currentState.copyWith(isE2EEEnabled: true));
        break;

      case 'e2eeDisabled':
        _updateState(_currentState.copyWith(isE2EEEnabled: false));
        break;

      case 'e2eeError':
        debugPrint('LibJitsiService: E2EE error: ${data['message']}');
        break;
    }
  }

  void _updateState(LibJitsiState newState) {
    _currentState = newState;
    notifyListeners();
  }

  /// Prepare and join a meeting
  Future<void> joinMeeting(MeetingConfig config) async {
    _pendingConfig = config;
    notifyListeners();

    // Start WebSocket server for frame transfer
    if (!_wsServer.isRunning) {
      await _wsServer.start();
    }

    if (_currentState.isInitialized && _controller != null) {
      await _joinWithConfig(config);
    }
    // Otherwise, will join when initialized callback fires
  }

  Future<void> _joinWithConfig(MeetingConfig config) async {
    final server = config.serverUrl;
    final room = config.roomName;
    final displayName = config.displayName;
    final enableE2EE = config.enableE2EE;
    final e2eePassphrase = config.e2eePassphrase ?? '';

    debugPrint('LibJitsiService: Joining $room on $server as $displayName (E2EE: $enableE2EE)');

    await _controller?.evaluateJavascript(
      source: 'joinRoom("$server", "$room", "$displayName", $enableE2EE, "$e2eePassphrase")',
    );
  }

  /// Leave the current meeting
  Future<void> leaveMeeting() async {
    debugPrint('LibJitsiService: Leaving meeting...');

    // Call JS leaveRoom and wait a moment for async cleanup
    try {
      await _controller?.evaluateJavascript(source: 'leaveRoom()');
      // Give JS time to complete async cleanup (conference.leave() is async)
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      debugPrint('LibJitsiService: Error during leave: $e');
    }

    await _wsServer.stop();

    // Reset all pending state
    _pendingConfig = null;
    _pendingVideoSource = null;

    // Reset state to clean slate
    _updateState(const LibJitsiState());

    debugPrint('LibJitsiService: Left meeting, state reset');
  }

  // Frame counter for debug logging
  int _frameSentCount = 0;
  // Flutter side doesn't drop frames - WebSocket/JS layer handles frame pacing
  final int _framesDropped = 0;

  /// Get Flutter-side frame stats
  Map<String, dynamic> getFlutterStats() {
    final dropRate = (_frameSentCount + _framesDropped) > 0
        ? (_framesDropped * 100 / (_frameSentCount + _framesDropped)).round()
        : 0;
    return {
      'framesSent': _frameSentCount,
      'framesDropped': _framesDropped,
      'dropRate': dropRate,
    };
  }

  /// Send a video frame to the WebView via WebSocket
  ///
  /// Frames are sent as raw JPEG bytes over WebSocket - no base64 encoding!
  /// This is much faster than evaluateJavascript with base64 strings.
  void sendFrame(Uint8List jpegData) {
    // Don't send frames when paused
    if (!_currentState.isInMeeting) {
      if (_frameSentCount == 0) debugPrint('LibJitsiService.sendFrame: not in meeting yet');
      return;
    }
    if (_isPaused) {
      if (_frameSentCount == 0) debugPrint('LibJitsiService.sendFrame: WebView is paused');
      return;
    }
    if (!_wsServer.hasClient) {
      if (_frameSentCount == 0) debugPrint('LibJitsiService.sendFrame: WebSocket client not connected');
      return;
    }

    _frameSentCount++;

    if (_frameSentCount == 1) {
      debugPrint('LibJitsiService: Sending first frame via WebSocket (${jpegData.length} bytes)');
    }
    if (_frameSentCount % 100 == 0) {
      debugPrint('LibJitsiService: Sent $_frameSentCount frames, dropped $_framesDropped (${(_framesDropped * 100 / (_frameSentCount + _framesDropped)).toStringAsFixed(1)}% drop rate)');
    }

    // Send raw bytes via WebSocket - no base64!
    _wsServer.sendFrame(jpegData);
  }

  /// Set video resolution
  Future<void> setResolution(int width, int height) async {
    await _controller?.evaluateJavascript(
      source: 'setResolution($width, $height)',
    );
  }

  /// Set video source mode in WebView
  /// For camera modes ('frontCamera', 'backCamera'), uses getUserMedia directly
  /// For glasses mode, uses canvas captureStream
  Future<bool> setVideoSource(String source) async {
    if (_controller == null) return false;

    // If not initialized yet, queue the request
    if (!_currentState.isInitialized) {
      debugPrint('LibJitsiService: WebView not initialized, queuing setVideoSource($source)');
      _pendingVideoSource = source;
      return true; // Will be set when initialized
    }

    return await _setVideoSourceInternal(source);
  }

  /// Internal method to actually call JavaScript setVideoSource
  Future<bool> _setVideoSourceInternal(String source) async {
    if (_controller == null) return false;

    try {
      // Wrap in an async IIFE to ensure the Promise is awaited
      final result = await _controller?.evaluateJavascript(
        source: '''
          (async function() {
            try {
              const success = await setVideoSource("$source");
              return success;
            } catch (e) {
              console.error('[JitsiBridge] setVideoSource error:', e);
              return false;
            }
          })()
        ''',
      );
      debugPrint('LibJitsiService: setVideoSource($source) result: $result');
      return result == true || result == 'true';
    } catch (e) {
      debugPrint('LibJitsiService: setVideoSource error: $e');
      return false;
    }
  }

  /// Check if using direct camera mode (getUserMedia) vs canvas mode
  bool get isUsingDirectCamera {
    // This would need to query JS, but for now we track it locally
    return false; // TODO: implement proper tracking
  }

  /// Toggle audio mute
  Future<bool> toggleAudio() async {
    final result = await _controller?.evaluateJavascript(
      source: 'toggleAudio()',
    );
    return result == true || result == 'true';
  }

  /// Toggle video mute
  Future<bool> toggleVideo() async {
    final result = await _controller?.evaluateJavascript(
      source: 'toggleVideo()',
    );
    return result == true || result == 'true';
  }

  /// Set audio muted state
  Future<void> setAudioMuted(bool muted) async {
    await _controller?.evaluateJavascript(
      source: 'setAudioMuted($muted)',
    );
  }

  /// Set video muted state
  Future<void> setVideoMuted(bool muted) async {
    await _controller?.evaluateJavascript(
      source: 'setVideoMuted($muted)',
    );
  }

  /// Resume the WebView after app comes back to foreground
  ///
  /// Android pauses WebViews when app is backgrounded to save battery.
  /// This resumes JavaScript execution and triggers a canvas refresh.
  Future<void> resumeWebView() async {
    debugPrint('LibJitsiService: Resuming WebView');
    _isPaused = false;
    try {
      // Resume the WebView (unpauses JavaScript timers, etc.)
      await _controller?.resume();

      // Trigger a canvas refresh in case it was stale
      await _controller?.evaluateJavascript(
        source: '''
          if (typeof ctx !== 'undefined' && ctx) {
            // Force canvas to redraw by triggering a minor update
            ctx.fillStyle = ctx.fillStyle;
          }
        ''',
      );
    } catch (e) {
      debugPrint('LibJitsiService: Resume error: $e');
    }
  }

  /// Pause the WebView when app goes to background
  /// If background mode is enabled, this does nothing to keep streaming active
  Future<void> pauseWebView() async {
    if (_backgroundModeEnabled) {
      debugPrint('LibJitsiService: Background mode enabled, not pausing WebView');
      return;
    }

    debugPrint('LibJitsiService: Pausing WebView');
    _isPaused = true;
    try {
      await _controller?.pause();
    } catch (e) {
      debugPrint('LibJitsiService: Pause error: $e');
    }
  }

  /// Get the local asset path for the bridge HTML
  String get bridgeHtmlPath => 'assets/jitsi_bridge.html';

  /// Get current stats from the WebView
  Future<LibJitsiStats> getStats() async {
    if (_controller == null) {
      return const LibJitsiStats();
    }

    try {
      final result = await _controller?.evaluateJavascript(
        source: 'typeof getStats === "function" ? JSON.stringify(getStats()) : null',
      );

      if (result != null && result != 'null') {
        // Remove quotes if the result is a string
        String jsonStr = result;
        if (jsonStr.startsWith('"') && jsonStr.endsWith('"')) {
          jsonStr = jsonStr.substring(1, jsonStr.length - 1);
          // Unescape the JSON string
          jsonStr = jsonStr.replaceAll(r'\"', '"');
        }

        final data = json.decode(jsonStr) as Map<String, dynamic>;
        return LibJitsiStats.fromJson(data);
      }
    } catch (e) {
      debugPrint('LibJitsiService: Error getting stats: $e');
    }

    return const LibJitsiStats();
  }

  /// Get WebView settings optimized for lib-jitsi-meet
  InAppWebViewSettings get webViewSettings => InAppWebViewSettings(
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        useWideViewPort: true,
        loadWithOverviewMode: true,
        supportZoom: false,
        // Permissions for camera, mic
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        // Allow mixed content for local assets
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        // Hardware acceleration for WebGL
        hardwareAcceleration: true,
      );

  @override
  void dispose() {
    _wsServer.stop();
    _controller = null;
    super.dispose();
  }
}
