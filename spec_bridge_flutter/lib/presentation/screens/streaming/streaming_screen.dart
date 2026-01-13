import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../data/models/glasses_state.dart';
import '../../../data/models/meeting_config.dart';
import '../../../data/models/stream_status.dart';
import '../../../services/background_streaming_service.dart';
import '../../../services/glasses_service.dart';
import '../../../services/lib_jitsi_service.dart';
import '../../../services/platform_channels/meta_dat_channel.dart';
import '../../../services/settings_service.dart';
import '../../../services/stream_service.dart';
import 'widgets/control_buttons.dart';
import 'widgets/lib_jitsi_webview.dart';
import 'widgets/stats_overlay.dart';

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
    // Configure StreamService with lib-jitsi-meet service
    final streamService = context.read<StreamService>();
    final libJitsiService = context.read<LibJitsiService>();
    streamService.setLibJitsiService(libJitsiService);

    setState(() {}); // Trigger rebuild to show WebView

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
        body: SafeArea(
          child: Column(
            children: [
              // Top bar with status
              Consumer<StreamService>(
                builder: (context, streamService, _) {
                  return _buildTopBar(streamService.currentState);
                },
              ),

              // Video preview - WebView with overlay states
              Expanded(
                child: Stack(
                  children: [
                    // WebView showing the actual video being sent
                    LibJitsiWebView(
                      service: context.read<LibJitsiService>(),
                    ),

                    // Overlay for loading/error/special states
                    Consumer<GlassesService>(
                      builder: (context, glassesService, _) {
                        return _buildVideoOverlay(glassesService.videoSource);
                      },
                    ),

                    // Stats overlay
                    Consumer<SettingsService>(
                      builder: (context, settingsService, _) => StatsOverlay(
                        service: context.read<LibJitsiService>(),
                        nativeChannel: context.read<MetaDATChannel>(),
                        isVisible: settingsService.settings.showPipelineStats,
                      ),
                    ),
                  ],
                ),
              ),

              // Controls
              Consumer2<LibJitsiService, GlassesService>(
                builder: (context, libJitsiService, glassesService, _) {
                  final state = libJitsiService.currentState;
                  return _buildControls(
                    isAudioMuted: state.isAudioMuted,
                    isVideoMuted: state.isVideoMuted,
                    videoSource: glassesService.videoSource,
                  );
                },
              ),
            ],
          ),
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

          // Background mode toggle (Android only - iOS doesn't support background camera)
          if (Platform.isAndroid)
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

          // E2EE status indicator
          Consumer<LibJitsiService>(
            builder: (context, libJitsiService, _) {
              final isE2EE = libJitsiService.currentState.isE2EEEnabled;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Tooltip(
                  message: isE2EE ? 'E2EE Active' : 'E2EE Inactive',
                  child: Icon(
                    isE2EE ? Icons.lock : Icons.lock_open,
                    color: isE2EE ? Colors.green : Colors.grey,
                    size: 20,
                  ),
                ),
              );
            },
          ),

          // Stats toggle button
          Consumer<SettingsService>(
            builder: (context, settingsService, _) {
              final showStats = settingsService.settings.showPipelineStats;
              return IconButton(
                icon: Icon(
                  showStats ? Icons.analytics : Icons.analytics_outlined,
                  color: showStats ? Colors.green : Colors.white,
                ),
                onPressed: () => settingsService.setShowPipelineStats(!showStats),
                tooltip: 'Toggle Stats',
              );
            },
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

  Widget _buildVideoOverlay(VideoSource videoSource) {
    // Loading state - show spinner over video
    if (_isStarting) {
      return Container(
        color: Colors.black87,
        child: const Center(
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
        ),
      );
    }

    // Error state - show error message
    if (_errorMessage != null) {
      return Container(
        color: Colors.black87,
        child: Center(
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
        ),
      );
    }

    // Screen share mode - show status message
    if (videoSource == VideoSource.screenShare) {
      return Container(
        color: Colors.black87,
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.screen_share, color: Colors.grey, size: 64),
              SizedBox(height: 16),
              Text(
                'Screen share not yet implemented for lib-jitsi-meet',
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    // Normal streaming - WebView shows the video, no overlay needed
    return const SizedBox.shrink();
  }

  Widget _buildControls({
    required bool isAudioMuted,
    required bool isVideoMuted,
    required VideoSource videoSource,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.black54,
      child: ControlButtons(
        isAudioMuted: isAudioMuted,
        isVideoMuted: isVideoMuted,
        isScreenSharing: false,
        isScreenShareMode: videoSource == VideoSource.screenShare,
        onToggleAudio: () async {
          final streamService = context.read<StreamService>();
          await streamService.toggleAudio();
        },
        onToggleVideo: () async {
          final streamService = context.read<StreamService>();
          await streamService.toggleVideo();
        },
        onToggleScreenShare: () {
          // Screen share not implemented for lib-jitsi-meet yet
          debugPrint('Screen share not implemented for lib-jitsi-meet');
        },
        onEndCall: _stopStreaming,
      ),
    );
  }
}
