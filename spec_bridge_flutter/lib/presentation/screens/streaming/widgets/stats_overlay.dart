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

    // Extract native stats
    final nativeReceived = _nativeStats['framesReceived'] ?? 0;
    final nativeProcessed = _nativeStats['framesProcessed'] ?? 0;
    final nativeSkipped = _nativeStats['framesSkipped'] ?? 0;
    final nativeSkipRate = _nativeStats['skipRate'] ?? 0;
    final encodeTimeMs = _nativeStats['lastEncodeTimeMs'] ?? 0;
    final avgEncodeMs = _nativeStats['avgEncodeTimeMs'] ?? 0;
    final cpuUsage = _nativeStats['cpuUsage'] ?? -1;
    final memUsed = _nativeStats['memoryUsedMB'] ?? 0;
    final memMax = _nativeStats['memoryMaxMB'] ?? 0;

    // Extract Flutter stats
    final flutterSent = _flutterStats['framesSent'] ?? 0;
    final flutterDropped = _flutterStats['framesDropped'] ?? 0;
    final flutterDropRate = _flutterStats['dropRate'] ?? 0;

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
            // Pipeline header
            _buildSectionHeader('PIPELINE STATS'),
            const SizedBox(height: 4),

            // Native (Glasses -> JPEG)
            _buildSectionLabel('Native (Encode)'),
            _buildStatRow('Recv/Proc/Skip', '$nativeReceived/$nativeProcessed/$nativeSkipped'),
            _buildStatRow('Skip Rate', '$nativeSkipRate%'),
            _buildStatRow('Encode Time', '${encodeTimeMs}ms (avg ${avgEncodeMs}ms)'),
            const SizedBox(height: 6),

            // Flutter (WebSocket to WebView)
            _buildSectionLabel('Flutter (WebSocket)'),
            _buildStatRow('WS Status', _webViewStats.wsConnected ? 'Connected' : 'Disconnected'),
            _buildStatRow('Sent/Dropped', '$flutterSent/$flutterDropped'),
            _buildStatRow('Drop Rate', '$flutterDropRate%'),
            const SizedBox(height: 6),

            // WebView (Canvas -> WebRTC)
            _buildSectionLabel('WebView (Decode)'),
            _buildStatRow('Recv/Drawn/Drop', '${_webViewStats.totalFrames}/${_webViewStats.framesDrawn}/${_webViewStats.framesDroppedJs}'),
            _buildStatRow('Drop Rate', '${_webViewStats.jsDropRate}%'),
            _buildStatRow('Decode Time', '${_webViewStats.lastDecodeMs}ms (avg ${_webViewStats.avgDecodeMs}ms)'),
            _buildStatRow('FPS Out', '${_webViewStats.fps}'),
            _buildStatRow('Resolution', _webViewStats.resolution),
            const SizedBox(height: 6),

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

  Widget _buildStatRow(String label, String value) {
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
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
