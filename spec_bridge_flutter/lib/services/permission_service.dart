import 'package:permission_handler/permission_handler.dart';

/// Service for handling app permissions
class PermissionService {
  /// Request all required permissions
  Future<bool> requestAllPermissions() async {
    final camera = await requestCamera();
    final microphone = await requestMicrophone();
    final bluetooth = await requestBluetooth();

    return camera && microphone && bluetooth;
  }

  /// Check if all required permissions are granted
  Future<bool> checkAllPermissions() async {
    final camera = await Permission.camera.isGranted;
    final microphone = await Permission.microphone.isGranted;
    final bluetooth = await Permission.bluetooth.isGranted;

    return camera && microphone && bluetooth;
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
    // On iOS, Bluetooth permission is handled differently
    final status = await Permission.bluetooth.request();
    if (status.isGranted) return true;

    // Also try bluetoothConnect for newer Android
    final connectStatus = await Permission.bluetoothConnect.request();
    return connectStatus.isGranted || status.isGranted;
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
    return await Permission.bluetooth.isGranted;
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
    return await Permission.bluetooth.status;
  }
}
