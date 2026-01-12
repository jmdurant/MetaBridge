import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../data/models/meeting_config.dart';
import '../../../data/models/stream_status.dart';
import '../../../services/jitsi_service.dart';
import '../../../services/stream_service.dart';
import 'widgets/control_buttons.dart';
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

class _StreamingScreenState extends State<StreamingScreen> {
  bool _isStarting = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _startStreaming();
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
    final streamService = context.read<StreamService>();
    await streamService.stopStreaming();
    if (mounted) {
      context.go('/setup');
    }
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

              // Video preview
              Expanded(
                child: _buildVideoArea(),
              ),

              // Controls
              Consumer<JitsiService>(
                builder: (context, jitsiService, _) {
                  return _buildControls(jitsiService.currentState);
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

  Widget _buildVideoArea() {
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

  Widget _buildControls(JitsiMeetingState meetingState) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.black54,
      child: ControlButtons(
        isAudioMuted: meetingState.isAudioMuted,
        isScreenSharing: meetingState.isScreenSharing,
        onToggleAudio: () async {
          final streamService = context.read<StreamService>();
          await streamService.toggleAudio();
        },
        onToggleScreenShare: () async {
          final streamService = context.read<StreamService>();
          await streamService.toggleScreenShare();
        },
        onEndCall: _stopStreaming,
      ),
    );
  }
}
