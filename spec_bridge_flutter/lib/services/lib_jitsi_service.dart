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
  final int lastLatencyMs; // Last frame E2E latency (native capture → JS receive)
  final int avgLatencyMs; // Average E2E latency
  final int maxLatencyMs; // Max E2E latency seen
  final int totalBytes;
  final bool isJoined;
  final bool hasAudioTrack;
  final bool hasVideoTrack;
  final bool wsConnected;
  final bool isE2EEEnabled;
  final String videoSourceMode; // 'canvas' or 'camera'
  final bool hasCameraStream; // true if using getUserMedia
  // WebRTC encoder stats (shows where backup may occur in encoder/network)
  final int rtcFramesEncoded;
  final int rtcFramesSent;
  final int rtcFramesPending; // Frames in encoder queue
  final String rtcQualityLimitation;
  final String rtcEncoderImpl;
  final int rtcEncodeWidth;
  final int rtcEncodeHeight;
  final int rtcEncodeFps;
  final int rtcBytesSent;
  final int rtcRetransmits;

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
    this.lastLatencyMs = 0,
    this.avgLatencyMs = 0,
    this.maxLatencyMs = 0,
    this.totalBytes = 0,
    this.isJoined = false,
    this.hasAudioTrack = false,
    this.hasVideoTrack = false,
    this.wsConnected = false,
    this.isE2EEEnabled = false,
    this.videoSourceMode = 'canvas',
    this.hasCameraStream = false,
    this.rtcFramesEncoded = 0,
    this.rtcFramesSent = 0,
    this.rtcFramesPending = 0,
    this.rtcQualityLimitation = 'none',
    this.rtcEncoderImpl = 'unknown',
    this.rtcEncodeWidth = 0,
    this.rtcEncodeHeight = 0,
    this.rtcEncodeFps = 0,
    this.rtcBytesSent = 0,
    this.rtcRetransmits = 0,
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
      lastLatencyMs: json['lastLatencyMs'] as int? ?? 0,
      avgLatencyMs: json['avgLatencyMs'] as int? ?? 0,
      maxLatencyMs: json['maxLatencyMs'] as int? ?? 0,
      totalBytes: json['totalBytes'] as int? ?? 0,
      isJoined: json['isJoined'] as bool? ?? false,
      hasAudioTrack: json['hasAudioTrack'] as bool? ?? false,
      hasVideoTrack: json['hasVideoTrack'] as bool? ?? false,
      wsConnected: json['wsConnected'] as bool? ?? false,
      isE2EEEnabled: json['isE2EEEnabled'] as bool? ?? false,
      videoSourceMode: json['videoSourceMode'] as String? ?? 'canvas',
      hasCameraStream: json['hasCameraStream'] as bool? ?? false,
      rtcFramesEncoded: json['rtcFramesEncoded'] as int? ?? 0,
      rtcFramesSent: json['rtcFramesSent'] as int? ?? 0,
      rtcFramesPending: json['rtcFramesPending'] as int? ?? 0,
      rtcQualityLimitation: json['rtcQualityLimitation'] as String? ?? 'none',
      rtcEncoderImpl: json['rtcEncoderImpl'] as String? ?? 'unknown',
      rtcEncodeWidth: json['rtcEncodeWidth'] as int? ?? 0,
      rtcEncodeHeight: json['rtcEncodeHeight'] as int? ?? 0,
      rtcEncodeFps: json['rtcEncodeFps'] as int? ?? 0,
      rtcBytesSent: json['rtcBytesSent'] as int? ?? 0,
      rtcRetransmits: json['rtcRetransmits'] as int? ?? 0,
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
    this.isVideoMuted = false,
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

  // Completer for waiting on camera to be ready (getUserMedia complete)
  Completer<bool>? _cameraReadyCompleter;

  // Completer for waiting on WebSocket to be connected (for glasses frame pipeline)
  Completer<bool>? _wsConnectedCompleter;

  // Completer for waiting on full disconnection (XMPP session closed)
  Completer<bool>? _disconnectedCompleter;

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
          _joinWithConfig(_pendingConfig!, usePhoneMic: _pendingUsePhoneMic);
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

      case 'disconnected':
        // XMPP connection fully closed - safe to reconnect now
        debugPrint('LibJitsiService: Disconnected event received');
        _disconnectedCompleter?.complete(true);
        _disconnectedCompleter = null;
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

      case 'cameraReady':
        // Camera acquired via getUserMedia - complete the waiting Future
        debugPrint('LibJitsiService: Camera ready event received');
        _cameraReadyCompleter?.complete(true);
        _cameraReadyCompleter = null;
        break;

      case 'wsConnected':
        // WebSocket connected - frame pipeline is ready
        debugPrint('LibJitsiService: WebSocket connected event received');
        _wsConnectedCompleter?.complete(true);
        _wsConnectedCompleter = null;
        break;

      case 'wsDisconnected':
        debugPrint('LibJitsiService: WebSocket disconnected');
        break;
    }
  }

  void _updateState(LibJitsiState newState) {
    _currentState = newState;
    notifyListeners();
  }

  /// Wait for WebSocket to be connected (for glasses frame pipeline)
  /// Call this before joining a meeting in glasses mode to ensure frames can flow
  Future<bool> waitForWebSocketConnected({Duration timeout = const Duration(seconds: 10)}) async {
    if (_controller == null) return false;

    // First check if already connected by querying JS
    try {
      final result = await _controller?.evaluateJavascript(
        source: 'typeof frameSocket !== "undefined" && frameSocket && frameSocket.readyState === WebSocket.OPEN',
      );
      if (result == true || result == 'true') {
        debugPrint('LibJitsiService: WebSocket already connected');
        return true;
      }
    } catch (e) {
      debugPrint('LibJitsiService: Error checking WebSocket status: $e');
    }

    // Not connected yet, wait for wsConnected event
    _wsConnectedCompleter = Completer<bool>();
    debugPrint('LibJitsiService: Waiting for WebSocket to connect...');

    try {
      final connected = await _wsConnectedCompleter!.future.timeout(
        timeout,
        onTimeout: () {
          debugPrint('LibJitsiService: WebSocket connection timeout!');
          return false;
        },
      );
      debugPrint('LibJitsiService: WebSocket connected: $connected');
      return connected;
    } catch (e) {
      debugPrint('LibJitsiService: WebSocket wait error: $e');
      _wsConnectedCompleter = null;
      return false;
    }
  }

  /// Prepare and join a meeting
  /// usePhoneMic: when true (default), forces phone mic instead of Bluetooth
  ///              to preserve Bluetooth bandwidth for glasses video streaming
  Future<void> joinMeeting(MeetingConfig config, {bool usePhoneMic = true}) async {
    _pendingConfig = config;
    _pendingUsePhoneMic = usePhoneMic;
    notifyListeners();

    // Start WebSocket server for frame transfer
    if (!_wsServer.isRunning) {
      await _wsServer.start();
    }

    if (_currentState.isInitialized && _controller != null) {
      await _joinWithConfig(config, usePhoneMic: usePhoneMic);
    }
    // Otherwise, will join when initialized callback fires
  }

  bool _pendingUsePhoneMic = true;

  Future<void> _joinWithConfig(MeetingConfig config, {bool usePhoneMic = true}) async {
    final server = config.serverUrl;
    final room = config.roomName;
    final displayName = config.displayName;
    final enableE2EE = config.enableE2EE;
    final e2eePassphrase = config.e2eePassphrase ?? '';

    debugPrint('LibJitsiService: Joining $room on $server as $displayName (E2EE: $enableE2EE, usePhoneMic: $usePhoneMic)');

    await _controller?.evaluateJavascript(
      source: 'joinRoom("$server", "$room", "$displayName", $enableE2EE, "$e2eePassphrase", $usePhoneMic)',
    );
  }

  /// Leave the current meeting
  Future<void> leaveMeeting() async {
    debugPrint('LibJitsiService: Leaving meeting...');

    // Set up completer to wait for actual disconnection event
    _disconnectedCompleter = Completer<bool>();

    // Call JS leaveRoom
    try {
      await _controller?.evaluateJavascript(source: 'leaveRoom()');

      // Wait for actual disconnected event from JS (server-side cleanup complete)
      // This is critical - reconnecting before server cleanup causes JVB session failures
      debugPrint('LibJitsiService: Waiting for disconnected event...');
      final disconnected = await _disconnectedCompleter!.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('LibJitsiService: Disconnect timeout - proceeding anyway');
          return false;
        },
      );
      debugPrint('LibJitsiService: Disconnected: $disconnected');
    } catch (e) {
      debugPrint('LibJitsiService: Error during leave: $e');
    }

    // Clear the completer
    _disconnectedCompleter = null;

    await _wsServer.stop();

    // Reset all pending state
    _pendingConfig = null;
    _pendingVideoSource = null;
    _cameraReadyCompleter = null;
    _wsConnectedCompleter = null;

    // Reset state to clean slate
    _updateState(const LibJitsiState());

    // Reload WebView to get fresh lib-jitsi-meet instance
    // This clears any stale internal state from the previous session
    await reloadWebView();

    debugPrint('LibJitsiService: Left meeting, state reset');
  }

  /// Reload the WebView to get a fresh lib-jitsi-meet instance
  /// Call this before starting a new session to clear any stale state
  Future<void> reloadWebView() async {
    debugPrint('LibJitsiService: Reloading WebView for fresh state...');

    // Reset initialized state - we'll wait for 'initialized' event again
    _updateState(_currentState.copyWith(isInitialized: false));

    // Reload the HTML file
    await _controller?.loadFile(assetFilePath: 'assets/jitsi_bridge.html');

    debugPrint('LibJitsiService: WebView reload initiated');
  }

  // Frame counter for debug logging
  int _frameSentCount = 0;
  // Track frames dropped due to not being in meeting, paused, or no client
  int _framesDropped = 0;

  /// Get Flutter-side frame stats
  Map<String, dynamic> getFlutterStats() {
    final wsStats = _wsServer.getStats();
    final dropRate = (_frameSentCount + _framesDropped) > 0
        ? (_framesDropped * 100 / (_frameSentCount + _framesDropped)).round()
        : 0;
    return {
      'framesSent': _frameSentCount,
      'framesDropped': _framesDropped,
      'dropRate': dropRate,
      'wsSlowSends': wsStats['framesWithSlowSend'] ?? 0,
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
      _framesDropped++;
      return;
    }
    if (_isPaused) {
      if (_frameSentCount == 0) debugPrint('LibJitsiService.sendFrame: WebView is paused');
      _framesDropped++;
      return;
    }
    if (!_wsServer.hasClient) {
      if (_frameSentCount == 0) debugPrint('LibJitsiService.sendFrame: WebSocket client not connected');
      _framesDropped++;
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
  /// For camera modes, waits for the 'cameraReady' event from JS
  Future<bool> _setVideoSourceInternal(String source) async {
    if (_controller == null) return false;

    final isCameraMode = source == 'frontCamera' || source == 'backCamera';

    try {
      // For camera mode, set up completer to wait for cameraReady event
      if (isCameraMode) {
        _cameraReadyCompleter = Completer<bool>();
        debugPrint('LibJitsiService: Waiting for camera to be ready...');
      }

      // Call JS setVideoSource - this returns immediately (Promise not awaited by evaluateJavascript)
      await _controller?.evaluateJavascript(
        source: 'setVideoSource("$source")',
      );

      // For camera mode, wait for the actual cameraReady event from JS
      if (isCameraMode && _cameraReadyCompleter != null) {
        // Wait with timeout in case something goes wrong
        final ready = await _cameraReadyCompleter!.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('LibJitsiService: Camera ready timeout!');
            return false;
          },
        );
        debugPrint('LibJitsiService: Camera ready: $ready');
        return ready;
      }

      // For glasses/canvas mode, no need to wait
      debugPrint('LibJitsiService: setVideoSource($source) - canvas mode, no wait needed');
      return true;
    } catch (e) {
      debugPrint('LibJitsiService: setVideoSource error: $e');
      _cameraReadyCompleter = null;
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
    debugPrint('LibJitsiService: toggleAudio called');
    final result = await _controller?.evaluateJavascript(
      source: 'toggleAudio()',
    );
    debugPrint('LibJitsiService: toggleAudio result: $result');
    return result == true || result == 'true';
  }

  /// Toggle video mute
  Future<bool> toggleVideo() async {
    debugPrint('LibJitsiService: toggleVideo called');
    final result = await _controller?.evaluateJavascript(
      source: 'toggleVideo()',
    );
    debugPrint('LibJitsiService: toggleVideo result: $result');
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

  /// Restart video track after source switch
  Future<void> restartVideoTrack() async {
    debugPrint('LibJitsiService: Restarting video track');
    await _controller?.evaluateJavascript(
      source: 'startVideoTrack()',
    );
    debugPrint('LibJitsiService: Video track restart initiated');
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
