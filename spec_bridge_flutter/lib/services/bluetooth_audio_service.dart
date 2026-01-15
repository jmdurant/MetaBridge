import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/models/app_settings.dart';
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

  /// Force audio to use phone's built-in microphone instead of Bluetooth.
  /// This prevents Bluetooth SCO from competing with glasses video stream.
  /// Call this BEFORE creating WebRTC audio tracks.
  Future<bool> forcePhoneMic() async {
    try {
      final success = await _channel.forcePhoneMic();
      if (success) {
        _activeDevice = null;
        notifyListeners();
      }
      debugPrint('Force phone mic: $success');
      return success;
    } catch (e) {
      debugPrint('Failed to force phone mic: $e');
      return false;
    }
  }

  // Track what type of Bluetooth connection is used for glasses audio
  String? _glassesAudioType; // "ble", "sco", or null
  String? get glassesAudioType => _glassesAudioType;

  /// Set audio output based on AudioOutput enum.
  /// - speakerphone: Loud hands-free mode via built-in speaker
  /// - earpiece: Quiet hold-to-ear mode via built-in earpiece
  /// - glasses: Route to Meta glasses via Bluetooth (prefers BLE over SCO)
  Future<bool> setAudioOutput(AudioOutput output) async {
    try {
      switch (output) {
        case AudioOutput.speakerphone:
          final success = await _channel.setPhoneAudioMode('speakerphone');
          if (success) {
            _activeDevice = null;
            _glassesAudioType = null;
            notifyListeners();
          }
          debugPrint('Set audio to speakerphone: $success');
          return success;

        case AudioOutput.earpiece:
          final success = await _channel.setPhoneAudioMode('earpiece');
          if (success) {
            _activeDevice = null;
            _glassesAudioType = null;
            notifyListeners();
          }
          debugPrint('Set audio to earpiece: $success');
          return success;

        case AudioOutput.glasses:
          // Prefer BLE Audio over SCO - BLE doesn't compete with Classic video
          final result = await _channel.routeToGlassesBle();
          final success = result['success'] as bool? ?? false;
          final type = result['type'] as String?;
          final deviceName = result['deviceName'] as String?;

          if (success) {
            _glassesAudioType = type;
            debugPrint('Set audio to glasses via $type ($deviceName)');
            notifyListeners();
          } else {
            debugPrint('Failed to route audio to glasses');
          }
          return success;
      }
    } catch (e) {
      debugPrint('Failed to set audio output: $e');
      return false;
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
