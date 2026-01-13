import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../services/lib_jitsi_service.dart';

/// Overlay that displays streaming stats (resolution, FPS, bitrate)
class StatsOverlay extends StatefulWidget {
  final LibJitsiService service;
  final bool isVisible;

  const StatsOverlay({
    super.key,
    required this.service,
    this.isVisible = true,
  });

  @override
  State<StatsOverlay> createState() => _StatsOverlayState();
}

class _StatsOverlayState extends State<StatsOverlay> {
  LibJitsiStats _stats = const LibJitsiStats();
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
    final stats = await widget.service.getStats();
    if (mounted) {
      setState(() => _stats = stats);
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

    return Positioned(
      top: 60,
      right: 8,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildStatRow('Resolution', _stats.resolution),
            const SizedBox(height: 4),
            _buildStatRow('FPS', '${_stats.fps}'),
            const SizedBox(height: 4),
            _buildStatRow('Bitrate', _stats.bitrateFormatted),
            const SizedBox(height: 4),
            _buildStatRow('Frames', '${_stats.totalFrames}'),
            if (_stats.isJoined) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _stats.hasAudioTrack ? Icons.mic : Icons.mic_off,
                    size: 12,
                    color: _stats.hasAudioTrack ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _stats.hasVideoTrack ? Icons.videocam : Icons.videocam_off,
                    size: 12,
                    color: _stats.hasVideoTrack ? Colors.green : Colors.red,
                  ),
                ],
              ),
            ],
          ],
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
