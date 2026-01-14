import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../services/lib_jitsi_service.dart';
import '../../../../services/platform_channels/meta_dat_channel.dart';

/// Overlay that displays streaming stats (resolution, FPS, bitrate)
/// Now shows full pipeline: Native -> Flutter -> WebView
class StatsOverlay extends StatefulWidget {
  final LibJitsiService service;
  final MetaDATChannel? nativeChannel;
  final bool isVisible;

  const StatsOverlay({
    super.key,
    required this.service,
    this.nativeChannel,
    this.isVisible = true,
  });

  @override
  State<StatsOverlay> createState() => _StatsOverlayState();
}

class _StatsOverlayState extends State<StatsOverlay> {
  LibJitsiStats _webViewStats = const LibJitsiStats();
  Map<String, dynamic> _nativeStats = {};
  Map<String, dynamic> _flutterStats = {};
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    if (widget.isVisible) {
      _startRefreshing();
    }
  }

  @override
  void didUpdateWidget(StatsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible && !oldWidget.isVisible) {
      _startRefreshing();
    } else if (!widget.isVisible && oldWidget.isVisible) {
      _stopRefreshing();
    }
  }

  void _startRefreshing() {
    _refreshStats();
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshStats();
    });
  }

  void _stopRefreshing() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<void> _refreshStats() async {
    if (!mounted) return;

    // Get WebView stats
    final webViewStats = await widget.service.getStats();

    // Get Flutter-side stats
    final flutterStats = widget.service.getFlutterStats();

    // Get native stats (if available)
    Map<String, dynamic> nativeStats = {};
    if (widget.nativeChannel != null) {
      nativeStats = await widget.nativeChannel!.getStreamStats();

      // Add Flutter EventChannel reception stats
      if (widget.nativeChannel is MetaDATChannelImpl) {
        final impl = widget.nativeChannel as MetaDATChannelImpl;
        nativeStats.addAll(impl.frameReceptionStats);
      }
    }

    if (mounted) {
      setState(() {
        _webViewStats = webViewStats;
        _flutterStats = flutterStats;
        _nativeStats = nativeStats;
      });
    }
  }

  @override
  void dispose() {
    _stopRefreshing();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isVisible) return const SizedBox.shrink();

    // Video source type from native and JS
    // Native reports current source, WebView reports actual mode being used
    final nativeVideoSource = _nativeStats['videoSource'] ?? 'unknown';
    final webViewMode = _webViewStats.videoSourceMode; // 'camera' or 'canvas'
    final hasCameraStream = _webViewStats.hasCameraStream;

    // Determine actual video source - prefer WebView's info as source of truth
    // since it knows what's actually being used for WebRTC
    final isDirectCamera = webViewMode == 'camera' && hasCameraStream;

    // For display, use native source but validate against WebView mode
    String videoSource = nativeVideoSource;
    if (isDirectCamera && nativeVideoSource == 'glasses') {
      // WebView is using camera but native wasn't updated - this is a bug state
      // Show what WebView is actually using
      videoSource = 'camera (WebView)';
    }

    final isGlassesMode = !isDirectCamera && (nativeVideoSource == 'glasses' || webViewMode == 'canvas');
    final isCameraMode = nativeVideoSource == 'frontCamera' || nativeVideoSource == 'backCamera';

    // Native server stats
    final useNativeServer = _nativeStats['useNativeServer'] ?? false;
    final nativeServerRunning = _nativeStats['nativeServerRunning'] ?? false;
    final nativeServerHasClient = _nativeStats['nativeServerHasClient'] ?? false;
    final nativeFramesSent = _nativeStats['nativeFramesSent'] ?? 0;
    final nativeFramesDropped = _nativeStats['nativeFramesDropped'] ?? 0;

    // Extract native capture stats (glasses mode)
    final nativeReceived = _nativeStats['framesReceived'] ?? 0;
    final nativeProcessed = _nativeStats['framesProcessed'] ?? 0;
    final nativeSkipped = _nativeStats['framesSkipped'] ?? 0;
    final nativeSkipRate = _nativeStats['skipRate'] ?? 0;
    final encodeTimeMs = _nativeStats['lastEncodeTimeMs'] ?? 0;
    final avgEncodeMs = _nativeStats['avgEncodeTimeMs'] ?? 0;

    // Camera stats
    final cameraFrameCount = _nativeStats['cameraFrameCount'] ?? 0;

    // System stats
    final cpuUsage = _nativeStats['cpuUsage'] ?? -1;
    final memUsed = _nativeStats['memoryUsedMB'] ?? 0;
    final memMax = _nativeStats['memoryMaxMB'] ?? 0;

    // Extract EventChannel stats (frames received by Flutter from native)
    final flutterReceived = _nativeStats['framesReceivedFromNative'] ?? 0;
    final eventChannelFps = _nativeStats['avgFps'] ?? 0;

    // Extract Flutter stats
    final flutterSent = _flutterStats['framesSent'] ?? 0;
    final flutterDropped = _flutterStats['framesDropped'] ?? 0;
    final flutterDropRate = _flutterStats['dropRate'] ?? 0;

    // Calculate EventChannel loss (only relevant if not using native server)
    final eventChannelLoss = nativeProcessed > 0
        ? ((nativeProcessed - flutterReceived) * 100 / nativeProcessed).round()
        : 0;

    // Determine which path is active
    final usingNativePath = useNativeServer && nativeServerHasClient;

    return Positioned(
      top: 60,
      right: 8,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Pipeline header with source indicator
            _buildSectionHeader('PIPELINE STATS'),
            _buildStatRow('Source', _formatVideoSource(videoSource, isDirectCamera)),
            const SizedBox(height: 4),

            // Direct camera mode - minimal stats (no processing pipeline)
            if (isDirectCamera) ...[
              _buildSectionLabel('Direct WebRTC'),
              _buildStatRow(
                'Path',
                'getUserMedia → WebRTC',
                valueColor: Colors.greenAccent,
              ),
              _buildStatRow('Camera', hasCameraStream ? 'Active' : 'Inactive',
                  valueColor: hasCameraStream ? Colors.greenAccent : Colors.redAccent),
              _buildStatRow('Resolution', _webViewStats.resolution),
              _buildStatRow('Has Track', _webViewStats.hasVideoTrack ? 'Yes' : 'No',
                  valueColor: _webViewStats.hasVideoTrack ? Colors.greenAccent : Colors.orangeAccent),
              const SizedBox(height: 6),
            ] else ...[
              // Capture stats - different for glasses vs camera (legacy JPEG path)
              if (isGlassesMode) ...[
                _buildSectionLabel('Capture (I420)'),
                _buildStatRow('Recv/Proc/Skip', '$nativeReceived/$nativeProcessed/$nativeSkipped'),
                _buildStatRow('Skip Rate', '$nativeSkipRate%'),
                _buildStatRow('Process Time', '${encodeTimeMs}ms (avg ${avgEncodeMs}ms)'),
                const SizedBox(height: 6),
              ] else if (isCameraMode) ...[
                _buildSectionLabel('Capture (JPEG) - Legacy'),
                _buildStatRow('Frames', '$cameraFrameCount'),
                const SizedBox(height: 6),
              ],

              // Transport layer - show which path is active
              _buildSectionLabel('Transport'),
              _buildStatRow(
                'Path',
                usingNativePath ? 'Native WS (8766)' : 'Flutter WS (8765)',
                valueColor: usingNativePath ? Colors.greenAccent : Colors.orangeAccent,
              ),
              if (usingNativePath) ...[
                _buildStatRow('Sent/Drop', '$nativeFramesSent/$nativeFramesDropped'),
              ] else ...[
                _buildStatRow('EventCh Recv', '$flutterReceived @ ${eventChannelFps}fps'),
                if (isGlassesMode) _buildStatRow('EventCh Loss', '$eventChannelLoss%'),
                _buildStatRow('WS Sent/Drop', '$flutterSent/$flutterDropped'),
              ],
              const SizedBox(height: 6),

              // WebView frame processing stats (only for canvas mode)
              _buildSectionLabel('WebView'),
              _buildStatRow('WS', _webViewStats.wsConnected ? 'Connected' : 'Disconnected',
                  valueColor: _webViewStats.wsConnected ? Colors.greenAccent : Colors.redAccent),
              _buildStatRow('Recv/Drawn', '${_webViewStats.totalFrames}/${_webViewStats.framesDrawn}'),
              _buildStatRow('Drop (queue/stale)', '${_webViewStats.framesDroppedJs}/${_webViewStats.framesDroppedStale}'),
              _buildStatRow('Decode', '${_webViewStats.lastDecodeMs}ms (avg ${_webViewStats.avgDecodeMs}ms)'),
              _buildStatRow('Arrival Interval', '${_webViewStats.avgArrivalMs}ms'),
              _buildStatRow('FPS Out', '${_webViewStats.fps}'),
              _buildStatRow('Resolution', _webViewStats.resolution),
              const SizedBox(height: 6),
            ],

            // System
            _buildSectionLabel('System'),
            _buildStatRow('CPU', cpuUsage >= 0 ? '$cpuUsage%' : 'N/A'),
            _buildStatRow('Memory', '$memUsed / $memMax MB'),

            // Connection status
            if (_webViewStats.isJoined) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _webViewStats.hasAudioTrack ? Icons.mic : Icons.mic_off,
                    size: 12,
                    color: _webViewStats.hasAudioTrack ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _webViewStats.hasVideoTrack ? Icons.videocam : Icons.videocam_off,
                    size: 12,
                    color: _webViewStats.hasVideoTrack ? Colors.green : Colors.red,
                  ),
                  if (_webViewStats.isE2EEEnabled) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.lock, size: 12, color: Colors.green),
                  ],
                  const SizedBox(width: 8),
                  const Text(
                    'Connected',
                    style: TextStyle(color: Colors.green, fontSize: 10),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatVideoSource(String source, bool isDirectCamera) {
    switch (source) {
      case 'glasses':
        return 'Glasses (I420)';
      case 'frontCamera':
        return isDirectCamera ? 'Front Camera (Direct)' : 'Front Camera (JPEG)';
      case 'backCamera':
        return isDirectCamera ? 'Back Camera (Direct)' : 'Back Camera (JPEG)';
      default:
        return source;
    }
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.cyan,
        fontSize: 10,
        fontWeight: FontWeight.bold,
        fontFamily: 'monospace',
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.amber,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: const TextStyle(
            color: Colors.grey,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
