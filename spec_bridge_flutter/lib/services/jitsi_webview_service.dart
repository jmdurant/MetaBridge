import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../data/models/meeting_config.dart';

/// Jitsi meeting state for WebView mode
class JitsiWebViewState {
  final bool isInMeeting;
  final String? roomName;
  final String? serverUrl;

  const JitsiWebViewState({
    this.isInMeeting = false,
    this.roomName,
    this.serverUrl,
  });

  JitsiWebViewState copyWith({
    bool? isInMeeting,
    String? roomName,
    String? serverUrl,
  }) {
    return JitsiWebViewState(
      isInMeeting: isInMeeting ?? this.isInMeeting,
      roomName: roomName ?? this.roomName,
      serverUrl: serverUrl ?? this.serverUrl,
    );
  }
}

/// WebView-based Jitsi service as fallback when SDK has conflicts
class JitsiWebViewService extends ChangeNotifier {
  JitsiWebViewState _currentState = const JitsiWebViewState();
  MeetingConfig? _pendingConfig;

  JitsiWebViewState get currentState => _currentState;
  MeetingConfig? get pendingConfig => _pendingConfig;

  /// Prepare to join a meeting (actual WebView is shown by the UI)
  void prepareMeeting(MeetingConfig config) {
    _pendingConfig = config;
    notifyListeners();
  }

  /// Called when WebView has loaded the meeting
  void onMeetingJoined() {
    if (_pendingConfig != null) {
      _currentState = JitsiWebViewState(
        isInMeeting: true,
        roomName: _pendingConfig!.roomName,
        serverUrl: _pendingConfig!.serverUrl,
      );
      notifyListeners();
    }
  }

  /// Called when leaving the meeting
  void onMeetingLeft() {
    _currentState = const JitsiWebViewState(isInMeeting: false);
    _pendingConfig = null;
    notifyListeners();
  }

  /// Build the Jitsi meeting URL with config options
  String buildMeetingUrl(MeetingConfig config) {
    final server = config.serverUrl ?? 'https://meet.jit.si';
    final room = Uri.encodeComponent(config.roomName);

    // Build URL with config parameters
    final params = <String, String>{};

    if (config.displayName != null && config.displayName!.isNotEmpty) {
      params['userInfo.displayName'] = config.displayName!;
    }

    // Start with audio/video muted by default (user will share screen)
    params['config.startWithAudioMuted'] = 'true';
    params['config.startWithVideoMuted'] = 'true';

    // Enable screen sharing
    params['config.disableScreensharingVirtualBackground'] = 'false';

    final queryString = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');

    final url = '$server/$room${queryString.isNotEmpty ? '#$queryString' : ''}';
    return url;
  }

  /// Get WebView settings optimized for Jitsi
  InAppWebViewSettings get webViewSettings => InAppWebViewSettings(
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,
    javaScriptEnabled: true,
    domStorageEnabled: true,
    databaseEnabled: true,
    useWideViewPort: true,
    loadWithOverviewMode: true,
    supportZoom: false,
    // Permissions for camera, mic, screen share
    allowFileAccessFromFileURLs: true,
    allowUniversalAccessFromFileURLs: true,
  );

  void dispose() {
    super.dispose();
  }
}
