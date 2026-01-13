import 'package:flutter/services.dart';

/// Service for managing the floating preview overlay on Android.
/// The overlay displays camera/glasses frames on top of other apps,
/// allowing MediaProjection to capture them during screen share.
class FloatingPreviewService {
  static const _channel = MethodChannel('com.specbridge/floating_preview');

  /// Check if overlay permission is granted
  static Future<bool> checkOverlayPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkOverlayPermission');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Request overlay permission (opens system settings)
  static Future<bool> requestOverlayPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestOverlayPermission');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Start the floating preview overlay
  static Future<bool> startOverlay() async {
    try {
      final result = await _channel.invokeMethod<bool>('startOverlay');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Stop the floating preview overlay
  static Future<bool> stopOverlay() async {
    try {
      final result = await _channel.invokeMethod<bool>('stopOverlay');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Check if overlay is currently running
  static Future<bool> isOverlayRunning() async {
    try {
      final result = await _channel.invokeMethod<bool>('isOverlayRunning');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
}
