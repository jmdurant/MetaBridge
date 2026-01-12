import 'package:flutter/services.dart';

/// Platform channel interface for Bluetooth audio routing
abstract class BluetoothAudioChannel {
  /// Get list of available Bluetooth audio devices
  Future<List<BluetoothAudioDevice>> getAvailableDevices();

  /// Set the preferred Bluetooth device for audio input/output
  /// Returns true if successfully set
  Future<bool> setAudioDevice(String deviceId);

  /// Clear the preferred device and return to default routing
  Future<void> clearAudioDevice();

  /// Check if a Bluetooth audio device is currently active
  Future<bool> isBluetoothAudioActive();

  /// Stream of Bluetooth audio device connection changes
  Stream<BluetoothAudioEvent> get audioDeviceChanges;
}

/// Represents a Bluetooth audio device
class BluetoothAudioDevice {
  final String id;
  final String name;
  final BluetoothAudioType type;
  final bool isConnected;

  const BluetoothAudioDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.isConnected,
  });

  factory BluetoothAudioDevice.fromMap(Map<String, dynamic> map) {
    return BluetoothAudioDevice(
      id: map['id'] as String,
      name: map['name'] as String,
      type: BluetoothAudioType.fromString(map['type'] as String),
      isConnected: map['isConnected'] as bool,
    );
  }

  /// Check if this device looks like Meta glasses
  bool get isMetaGlasses {
    final lowerName = name.toLowerCase();
    return lowerName.contains('ray-ban') ||
        lowerName.contains('meta') ||
        lowerName.contains('oakley');
  }
}

enum BluetoothAudioType {
  hfp, // Hands-Free Profile (calls, voice)
  a2dp, // Advanced Audio Distribution (music)
  ble, // Bluetooth Low Energy audio
  unknown;

  static BluetoothAudioType fromString(String value) {
    switch (value.toLowerCase()) {
      case 'hfp':
        return BluetoothAudioType.hfp;
      case 'a2dp':
        return BluetoothAudioType.a2dp;
      case 'ble':
        return BluetoothAudioType.ble;
      default:
        return BluetoothAudioType.unknown;
    }
  }
}

/// Events for Bluetooth audio device changes
sealed class BluetoothAudioEvent {}

class DeviceConnected extends BluetoothAudioEvent {
  final BluetoothAudioDevice device;
  DeviceConnected(this.device);
}

class DeviceDisconnected extends BluetoothAudioEvent {
  final String deviceId;
  DeviceDisconnected(this.deviceId);
}

class AudioRouteChanged extends BluetoothAudioEvent {
  final String? activeDeviceId;
  AudioRouteChanged(this.activeDeviceId);
}

/// Implementation using platform channels
class BluetoothAudioChannelImpl implements BluetoothAudioChannel {
  static const _methodChannel = MethodChannel('com.specbridge/bluetooth_audio');
  static const _eventChannel =
      EventChannel('com.specbridge/bluetooth_audio_events');

  Stream<BluetoothAudioEvent>? _eventStream;

  @override
  Future<List<BluetoothAudioDevice>> getAvailableDevices() async {
    final result = await _methodChannel.invokeMethod<List<dynamic>>(
      'getAvailableDevices',
    );
    if (result == null) return [];

    return result
        .map((e) => BluetoothAudioDevice.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  @override
  Future<bool> setAudioDevice(String deviceId) async {
    final result = await _methodChannel.invokeMethod<bool>(
      'setAudioDevice',
      {'deviceId': deviceId},
    );
    return result ?? false;
  }

  @override
  Future<void> clearAudioDevice() async {
    await _methodChannel.invokeMethod<void>('clearAudioDevice');
  }

  @override
  Future<bool> isBluetoothAudioActive() async {
    final result = await _methodChannel.invokeMethod<bool>(
      'isBluetoothAudioActive',
    );
    return result ?? false;
  }

  @override
  Stream<BluetoothAudioEvent> get audioDeviceChanges {
    _eventStream ??= _eventChannel.receiveBroadcastStream().map((event) {
      final map = Map<String, dynamic>.from(event);
      final type = map['type'] as String;

      switch (type) {
        case 'connected':
          return DeviceConnected(
            BluetoothAudioDevice.fromMap(
              Map<String, dynamic>.from(map['device']),
            ),
          );
        case 'disconnected':
          return DeviceDisconnected(map['deviceId'] as String);
        case 'routeChanged':
          return AudioRouteChanged(map['activeDeviceId'] as String?);
        default:
          return AudioRouteChanged(null);
      }
    });
    return _eventStream!;
  }
}
