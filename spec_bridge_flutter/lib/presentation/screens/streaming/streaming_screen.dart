import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../data/models/app_settings.dart';
import '../../../data/models/glasses_state.dart';
import '../../../data/models/meeting_config.dart';
import '../../../data/models/stream_status.dart';
import '../../../services/background_streaming_service.dart';
import '../../../services/glasses_service.dart';
import '../../../services/jitsi_service.dart';
import '../../../services/lib_jitsi_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/stream_service.dart';
import 'widgets/control_buttons.dart';
import 'widgets/lib_jitsi_webview.dart';
import 'widgets/stats_overlay.dart';
import 'widgets/video_preview.dart';

/// Main streaming screen showing video preview and controls
class StreamingScreen extends StatefulWidget {
  final MeetingConfig config;

  const StreamingScreen({
    super.key,
    required this.config,
  });

  @override
  State<StreamingScreen> createState() => _StreamingScreenState();
}

class _StreamingScreenState extends State<StreamingScreen> with WidgetsBindingObserver {
  bool _isStarting = true;
  String? _errorMessage;
  Orientation? _lastOrientation;
  JitsiMode _jitsiMode = JitsiMode.sdk;
  bool _showStats = false;
  bool _backgroundMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Schedule after frame to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAndStart();
    });
  }

  void _initializeAndStart() {
    // Get the Jitsi mode from settings
    final settings = context.read<SettingsService>().settings;
    _jitsiMode = settings.jitsiMode;

    // Configure StreamService with the mode and services
    final streamService = context.read<StreamService>();
    streamService.setJitsiMode(_jitsiMode);

    if (_jitsiMode == JitsiMode.libJitsiMeet) {
      final libJitsiService = context.read<LibJitsiService>();
      streamService.setLibJitsiService(libJitsiService);
    }

    setState(() {}); // Trigger rebuild to show WebView if needed

    _startStreaming();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Initial orientation check
    _updateSystemUI();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Check orientation after metrics change
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateSystemUI();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('StreamingScreen: Lifecycle state changed to $state');

    if (_jitsiMode == JitsiMode.libJitsiMeet) {
      final libJitsiService = context.read<LibJitsiService>();

      if (state == AppLifecycleState.resumed) {
        // App came back to foreground - resume WebView
        debugPrint('StreamingScreen: Resuming lib-jitsi-meet WebView');
        libJitsiService.resumeWebView();
      } else if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.inactive) {
        // App going to background - pause to prevent frame queue buildup
        debugPrint('StreamingScreen: Pausing lib-jitsi-meet WebView');
        libJitsiService.pauseWebView();
      }
    }
  }

  void _updateSystemUI() {
    final orientation = MediaQuery.of(context).orientation;
    if (orientation != _lastOrientation) {
      _lastOrientation = orientation;
      if (orientation == Orientation.landscape) {
        // Hide status bar and navigation bar in landscape for immersive experience
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.immersiveSticky,
          overlays: [],
        );
      } else {
        // Show system UI in portrait
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.edgeToEdge,
          overlays: SystemUiOverlay.values,
        );
      }
    }
  }

  void _restoreSystemUI() {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
  }

  Future<void> _startStreaming() async {
    try {
      final streamService = context.read<StreamService>();
      await streamService.startStreaming(widget.config);
      if (mounted) {
        setState(() => _isStarting = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isStarting = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _stopStreaming() async {
    _restoreSystemUI();

    // Stop background service if running
    if (_backgroundMode) {
      await BackgroundStreamingService.stopService();
    }

    final streamService = context.read<StreamService>();
    await streamService.stopStreaming();
    if (mounted) {
      context.go('/setup');
    }
  }

  Future<void> _toggleBackgroundMode() async {
    if (_jitsiMode != JitsiMode.libJitsiMeet) return;

    final newMode = !_backgroundMode;
    final libJitsiService = context.read<LibJitsiService>();

    if (newMode) {
      // Enable background mode
      final started = await BackgroundStreamingService.startService();
      if (started) {
        libJitsiService.setBackgroundMode(true);
        setState(() => _backgroundMode = true);
        debugPrint('StreamingScreen: Background mode enabled');
      }
    } else {
      // Disable background mode
      await BackgroundStreamingService.stopService();
      libJitsiService.setBackgroundMode(false);
      setState(() => _backgroundMode = false);
      debugPrint('StreamingScreen: Background mode disabled');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _restoreSystemUI();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop Streaming?'),
        content: const Text(
          'This will end your stream and leave the meeting.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );

    if (result == true) {
      await _stopStreaming();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _onWillPop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Hidden WebView for lib-jitsi-meet mode
            if (_jitsiMode == JitsiMode.libJitsiMeet)
              Positioned(
                left: -10,
                top: -10,
                child: LibJitsiWebView(
                  service: context.read<LibJitsiService>(),
                ),
              ),

            // Stats overlay (lib-jitsi-meet mode only)
            if (_jitsiMode == JitsiMode.libJitsiMeet)
              StatsOverlay(
                service: context.read<LibJitsiService>(),
                isVisible: _showStats,
              ),

            // Main UI
            SafeArea(
              child: Column(
                children: [
                  // Top bar with status
                  Consumer<StreamService>(
                    builder: (context, streamService, _) {
                      return _buildTopBar(streamService.currentState);
                    },
                  ),

                  // Video preview
                  Expanded(
                    child: _jitsiMode == JitsiMode.libJitsiMeet
                        ? Consumer<GlassesService>(
                            builder: (context, glassesService, _) {
                              return _buildVideoArea(
                                glassesService.videoSource,
                                false, // No screen sharing in lib-jitsi-meet mode
                              );
                            },
                          )
                        : Consumer2<GlassesService, JitsiService>(
                            builder: (context, glassesService, jitsiService, _) {
                              return _buildVideoArea(
                                glassesService.videoSource,
                                jitsiService.currentState.isScreenSharing,
                              );
                            },
                          ),
                  ),

                  // Controls
                  _jitsiMode == JitsiMode.libJitsiMeet
                      ? Consumer2<LibJitsiService, GlassesService>(
                          builder: (context, libJitsiService, glassesService, _) {
                            final state = libJitsiService.currentState;
                            return _buildControls(
                              JitsiMeetingState(
                                isInMeeting: state.isInMeeting,
                                isAudioMuted: state.isAudioMuted,
                                isVideoMuted: state.isVideoMuted,
                              ),
                              glassesService.videoSource,
                            );
                          },
                        )
                      : Consumer2<JitsiService, GlassesService>(
                          builder: (context, jitsiService, glassesService, _) {
                            return _buildControls(
                              jitsiService.currentState,
                              glassesService.videoSource,
                            );
                          },
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(StreamState streamState) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.black54,
      child: Row(
        children: [
          // Back button
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => _onWillPop(),
          ),

          // Room name
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.config.roomName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _getStatusText(streamState.status),
                  style: TextStyle(
                    color: _getStatusColor(streamState.status),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          // Background mode toggle (only for lib-jitsi-meet mode on Android)
          // iOS doesn't support background camera streaming
          if (_jitsiMode == JitsiMode.libJitsiMeet && Platform.isAndroid)
            IconButton(
              icon: Icon(
                _backgroundMode
                    ? Icons.screen_lock_portrait
                    : Icons.screen_lock_portrait_outlined,
                color: _backgroundMode ? Colors.green : Colors.white,
              ),
              onPressed: _toggleBackgroundMode,
              tooltip: _backgroundMode ? 'Disable Background Mode' : 'Enable Background Mode',
            ),

          // Stats toggle button (only for lib-jitsi-meet mode)
          if (_jitsiMode == JitsiMode.libJitsiMeet)
            IconButton(
              icon: Icon(
                _showStats ? Icons.analytics : Icons.analytics_outlined,
                color: _showStats ? Colors.green : Colors.white,
              ),
              onPressed: () => setState(() => _showStats = !_showStats),
              tooltip: 'Toggle Stats',
            ),

          // Frame counter
          if (streamState.framesSent > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.fiber_manual_record,
                      color: Colors.green, size: 8),
                  const SizedBox(width: 4),
                  Text(
                    '${streamState.framesSent} frames',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _getStatusText(StreamStatus status) {
    switch (status) {
      case StreamStatus.idle:
        return 'Idle';
      case StreamStatus.stopped:
        return 'Stopped';
      case StreamStatus.starting:
        return 'Starting...';
      case StreamStatus.streaming:
        return 'Live';
      case StreamStatus.stopping:
        return 'Stopping...';
      case StreamStatus.error:
        return 'Error';
    }
  }

  Color _getStatusColor(StreamStatus status) {
    switch (status) {
      case StreamStatus.idle:
        return Colors.grey;
      case StreamStatus.stopped:
        return Colors.grey;
      case StreamStatus.starting:
        return Colors.orange;
      case StreamStatus.streaming:
        return Colors.green;
      case StreamStatus.stopping:
        return Colors.orange;
      case StreamStatus.error:
        return Colors.red;
    }
  }

  Widget _buildVideoArea(VideoSource videoSource, bool isScreenSharing) {
    if (_isStarting) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              'Connecting to meeting...',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 64),
              const SizedBox(height: 16),
              Text(
                'Failed to start streaming',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => context.go('/setup'),
                child: const Text('Back to Setup'),
              ),
            ],
          ),
        ),
      );
    }

    // Screen share mode - show status instead of preview
    if (videoSource == VideoSource.screenShare) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isScreenSharing ? Icons.screen_share : Icons.screen_share_outlined,
              color: isScreenSharing ? Colors.green : Colors.grey,
              size: 64,
            ),
            const SizedBox(height: 16),
            Text(
              isScreenSharing ? 'Screen sharing active' : 'Tap "Share Screen" to start',
              style: TextStyle(
                color: isScreenSharing ? Colors.green : Colors.grey,
                fontSize: 16,
              ),
            ),
            if (isScreenSharing) ...[
              const SizedBox(height: 8),
              const Text(
                'Your screen is being shared in the meeting',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ],
        ),
      );
    }

    // Camera/glasses mode - show video preview
    final streamService = context.read<StreamService>();
    final previewStream = streamService.previewFrameStream;

    return StreamBuilder<Uint8List>(
      stream: previewStream,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return VideoPreview(frameData: snapshot.data!);
        }
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam, color: Colors.grey, size: 64),
              SizedBox(height: 16),
              Text(
                'Waiting for video...',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildControls(JitsiMeetingState meetingState, VideoSource videoSource) {
    final isScreenShareMode = videoSource == VideoSource.screenShare;

    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.black54,
      child: ControlButtons(
        isAudioMuted: meetingState.isAudioMuted,
        isVideoMuted: meetingState.isVideoMuted,
        isScreenSharing: meetingState.isScreenSharing,
        isScreenShareMode: isScreenShareMode,
        onToggleAudio: () async {
          final streamService = context.read<StreamService>();
          await streamService.toggleAudio();
        },
        onToggleVideo: () async {
          final streamService = context.read<StreamService>();
          await streamService.toggleVideo();
        },
        onToggleScreenShare: () async {
          debugPrint('StreamingScreen: Screen share button pressed');
          final streamService = context.read<StreamService>();
          await streamService.toggleScreenShare();
        },
        onEndCall: _stopStreaming,
      ),
    );
  }
}
