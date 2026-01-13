import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'floating_preview_service.dart';

/// Service for handling app permissions
class PermissionService {
  /// Request all required permissions
  Future<bool> requestAllPermissions() async {
    final camera = await requestCamera();
    final microphone = await requestMicrophone();
    final bluetooth = await requestBluetooth();

    // Request overlay permission on Android (for camera/glasses streaming)
    if (Platform.isAndroid) {
      await requestOverlay();
    }

    return camera && microphone && bluetooth;
  }

  /// Check if all required permissions are granted
  Future<bool> checkAllPermissions() async {
    final camera = await Permission.camera.isGranted;
    final microphone = await Permission.microphone.isGranted;
    final bluetoothConnect = await Permission.bluetoothConnect.isGranted;

    return camera && microphone && bluetoothConnect;
  }

  /// Request camera permission
  Future<bool> requestCamera() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  /// Request microphone permission
  Future<bool> requestMicrophone() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  /// Request Bluetooth permission
  Future<bool> requestBluetooth() async {
    // Android 12+ requires BLUETOOTH_CONNECT for paired device access
    final connectStatus = await Permission.bluetoothConnect.request();

    // Also request scan permission for device discovery
    await Permission.bluetoothScan.request();

    // Legacy bluetooth permission for older Android
    await Permission.bluetooth.request();

    return connectStatus.isGranted;
  }

  /// Check camera permission status
  Future<bool> checkCamera() async {
    return await Permission.camera.isGranted;
  }

  /// Check microphone permission status
  Future<bool> checkMicrophone() async {
    return await Permission.microphone.isGranted;
  }

  /// Check Bluetooth permission status
  Future<bool> checkBluetooth() async {
    return await Permission.bluetoothConnect.isGranted;
  }

  /// Request overlay permission (Android only, for floating preview)
  Future<bool> requestOverlay() async {
    if (!Platform.isAndroid) return true;

    final hasPermission = await FloatingPreviewService.checkOverlayPermission();
    if (hasPermission) return true;

    // This opens system settings for overlay permission
    await FloatingPreviewService.requestOverlayPermission();
    return false; // User needs to manually enable and return
  }

  /// Check overlay permission status
  Future<bool> checkOverlay() async {
    if (!Platform.isAndroid) return true;
    return await FloatingPreviewService.checkOverlayPermission();
  }

  /// Open app settings
  Future<bool> openSettings() async {
    return await openAppSettings();
  }

  /// Get detailed permission status
  Future<PermissionStatus> getCameraStatus() async {
    return await Permission.camera.status;
  }

  Future<PermissionStatus> getMicrophoneStatus() async {
    return await Permission.microphone.status;
  }

  Future<PermissionStatus> getBluetoothStatus() async {
    return await Permission.bluetoothConnect.status;
  }
}
