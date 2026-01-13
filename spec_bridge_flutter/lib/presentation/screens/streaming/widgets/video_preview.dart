import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Widget displaying video preview frames from glasses or camera
class VideoPreview extends StatelessWidget {
  final Uint8List frameData;

  const VideoPreview({
    super.key,
    required this.frameData,
  });

  @override
  Widget build(BuildContext context) {
    return OrientationBuilder(
      builder: (context, orientation) {
        // Use BoxFit.cover in landscape to fill more screen,
        // BoxFit.contain in portrait to show full frame
        final fit = orientation == Orientation.landscape
            ? BoxFit.cover
            : BoxFit.contain;

        return Container(
          color: Colors.black,
          width: double.infinity,
          height: double.infinity,
          child: Image.memory(
            frameData,
            fit: fit,
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
        );
      },
    );
  }
}
