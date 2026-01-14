import 'package:flutter/material.dart';

/// Control buttons for the streaming screen
class ControlButtons extends StatelessWidget {
  final bool isAudioMuted;
  final bool isVideoMuted;
  final String currentSource;  // 'glasses', 'frontCamera', 'backCamera'
  final VoidCallback onToggleAudio;
  final VoidCallback onToggleVideo;
  final VoidCallback onSwitchSource;
  final VoidCallback onEndCall;

  const ControlButtons({
    super.key,
    required this.isAudioMuted,
    required this.isVideoMuted,
    this.currentSource = 'glasses',
    required this.onToggleAudio,
    required this.onToggleVideo,
    required this.onSwitchSource,
    required this.onEndCall,
  });

  IconData _getSourceIcon() {
    switch (currentSource) {
      case 'frontCamera':
        return Icons.camera_front;
      case 'backCamera':
        return Icons.camera_rear;
      case 'glasses':
      default:
        return Icons.visibility;
    }
  }

  String _getSourceLabel() {
    switch (currentSource) {
      case 'frontCamera':
        return 'Front';
      case 'backCamera':
        return 'Back';
      case 'glasses':
      default:
        return 'Glasses';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Mute button
        _ControlButton(
          icon: isAudioMuted ? Icons.mic_off : Icons.mic,
          label: isAudioMuted ? 'Unmute' : 'Mute',
          isActive: !isAudioMuted,
          onPressed: onToggleAudio,
        ),

        // Video toggle button
        _ControlButton(
          icon: isVideoMuted ? Icons.videocam_off : Icons.videocam,
          label: isVideoMuted ? 'Start Video' : 'Stop Video',
          isActive: !isVideoMuted,
          onPressed: onToggleVideo,
        ),

        // Switch source button
        _ControlButton(
          icon: _getSourceIcon(),
          label: _getSourceLabel(),
          isActive: true,
          activeColor: Colors.blue,
          onPressed: onSwitchSource,
        ),

        // End call button
        _ControlButton(
          icon: Icons.call_end,
          label: 'End',
          isActive: true,
          activeColor: Colors.red,
          inactiveColor: Colors.red,
          onPressed: onEndCall,
        ),
      ],
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final Color inactiveColor;
  final VoidCallback onPressed;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.isActive,
    this.activeColor = Colors.white,
    this.inactiveColor = Colors.grey,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: isActive
              ? activeColor.withValues(alpha: 0.2)
              : inactiveColor.withValues(alpha: 0.2),
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              child: Icon(
                icon,
                color: isActive ? activeColor : inactiveColor,
                size: 28,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: isActive ? activeColor : inactiveColor,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
