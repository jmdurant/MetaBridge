import 'dart:async';
import 'package:flutter/foundation.dart';
import 'platform_channels/bluetooth_audio_channel.dart';

/// Service for managing Bluetooth audio routing to Meta glasses
class BluetoothAudioService extends ChangeNotifier {
  final BluetoothAudioChannel _channel;

  List<BluetoothAudioDevice> _availableDevices = [];
  BluetoothAudioDevice? _activeDevice;
  bool _isAutoRoutingEnabled = true;
  StreamSubscription<BluetoothAudioEvent>? _eventSubscription;

  BluetoothAudioService(this._channel) {
    _init();
  }

  List<BluetoothAudioDevice> get availableDevices => _availableDevices;
  BluetoothAudioDevice? get activeDevice => _activeDevice;
  bool get isAutoRoutingEnabled => _isAutoRoutingEnabled;
  bool get isGlassesAudioActive => _activeDevice?.isMetaGlasses ?? false;

  void _init() {
    _eventSubscription = _channel.audioDeviceChanges.listen(_handleAudioEvent);
    refreshDevices();
  }

  /// Refresh the list of available Bluetooth audio devices
  Future<void> refreshDevices() async {
    try {
      _availableDevices = await _channel.getAvailableDevices();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to refresh Bluetooth devices: $e');
    }
  }

  /// Find and return any connected Meta glasses
  BluetoothAudioDevice? findMetaGlasses() {
    return _availableDevices.where((d) => d.isMetaGlasses && d.isConnected).firstOrNull;
  }

  /// Automatically route audio to Meta glasses if connected
  /// Returns true if glasses were found and routing was set
  Future<bool> autoRouteToGlasses() async {
    if (!_isAutoRoutingEnabled) return false;

    await refreshDevices();
    final glasses = findMetaGlasses();

    if (glasses != null) {
      return await setAudioDevice(glasses);
    }
    return false;
  }

  /// Set a specific device as the audio input/output
  Future<bool> setAudioDevice(BluetoothAudioDevice device) async {
    try {
      final success = await _channel.setAudioDevice(device.id);
      if (success) {
        _activeDevice = device;
        notifyListeners();
      }
      return success;
    } catch (e) {
      debugPrint('Failed to set audio device: $e');
      return false;
    }
  }

  /// Clear audio routing and return to default
  Future<void> clearAudioDevice() async {
    try {
      await _channel.clearAudioDevice();
      _activeDevice = null;
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to clear audio device: $e');
    }
  }

  /// Enable or disable automatic routing to glasses
  void setAutoRoutingEnabled(bool enabled) {
    _isAutoRoutingEnabled = enabled;
    notifyListeners();
  }

  void _handleAudioEvent(BluetoothAudioEvent event) {
    switch (event) {
      case DeviceConnected(:final device):
        // Add to available devices if not already present
        if (!_availableDevices.any((d) => d.id == device.id)) {
          _availableDevices = [..._availableDevices, device];
        }
        // Auto-route if it's glasses and auto-routing is enabled
        if (device.isMetaGlasses && _isAutoRoutingEnabled) {
          setAudioDevice(device);
        }
        notifyListeners();

      case DeviceDisconnected(:final deviceId):
        _availableDevices =
            _availableDevices.where((d) => d.id != deviceId).toList();
        if (_activeDevice?.id == deviceId) {
          _activeDevice = null;
        }
        notifyListeners();

      case AudioRouteChanged(:final activeDeviceId):
        if (activeDeviceId == null) {
          _activeDevice = null;
        } else {
          _activeDevice = _availableDevices
              .where((d) => d.id == activeDeviceId)
              .firstOrNull;
        }
        notifyListeners();
    }
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    super.dispose();
  }
}
