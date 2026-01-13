import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Service for managing background streaming on Android.
/// Starts a foreground service that keeps the camera and WebView running
/// when the app is in the background or screen is off.
///
/// Note: This service is Android-only. iOS does not support background
/// camera access, so these methods return false on iOS.
class BackgroundStreamingService {
  static const _channel = MethodChannel('com.specbridge/streaming_service');

  /// Start the background streaming service
  /// Returns false on iOS (not supported)
  static Future<bool> startService() async {
    // iOS doesn't support background camera streaming
    if (!Platform.isAndroid) return false;

    try {
      final result = await _channel.invokeMethod<bool>('startService');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Stop the background streaming service
  /// Returns false on iOS (not supported)
  static Future<bool> stopService() async {
    // iOS doesn't support background camera streaming
    if (!Platform.isAndroid) return false;

    try {
      final result = await _channel.invokeMethod<bool>('stopService');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Check if the background service is currently running
  /// Returns false on iOS (not supported)
  static Future<bool> isServiceRunning() async {
    // iOS doesn't support background camera streaming
    if (!Platform.isAndroid) return false;

    try {
      final result = await _channel.invokeMethod<bool>('isServiceRunning');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
}
