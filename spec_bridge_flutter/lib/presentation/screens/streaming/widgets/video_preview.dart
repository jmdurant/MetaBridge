import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Widget displaying video preview frames from glasses
class VideoPreview extends StatelessWidget {
  final Uint8List frameData;

  const VideoPreview({
    super.key,
    required this.frameData,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Image.memory(
          frameData,
          fit: BoxFit.contain,
          gaplessPlayback: true, // Prevents flickering between frames
          errorBuilder: (context, error, stackTrace) {
            return const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.broken_image, color: Colors.grey, size: 64),
                SizedBox(height: 16),
                Text(
                  'Failed to decode frame',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
