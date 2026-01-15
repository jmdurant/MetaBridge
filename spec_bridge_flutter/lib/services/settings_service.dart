import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/app_settings.dart';

class SettingsService extends ChangeNotifier {
  static const _keyDefaultServer = 'default_server';
  static const _keyDefaultRoomName = 'default_room_name';
  static const _keyDisplayName = 'display_name';
  static const _keyShowPipelineStats = 'show_pipeline_stats';
  static const _keyDefaultAudioOutput = 'default_audio_output';
  static const _keyDefaultVideoQuality = 'default_video_quality';
  static const _keyDefaultFrameRate = 'default_frame_rate';
  static const _keyUseNativeFrameServer = 'use_native_frame_server';
  static const _keyGlassesCameraPermissionGranted = 'glasses_camera_permission_granted';

  AppSettings _settings = const AppSettings();
  bool _glassesCameraPermissionGranted = false;

  /// Whether the Meta glasses camera permission has been granted (persisted)
  bool get glassesCameraPermissionGranted => _glassesCameraPermissionGranted;

  AppSettings get settings => _settings;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    // Parse audio output enum
    final audioOutputStr = prefs.getString(_keyDefaultAudioOutput);
    final audioOutput = audioOutputStr != null
        ? AudioOutput.values.firstWhere(
            (e) => e.name == audioOutputStr,
            orElse: () => AudioOutput.speakerphone,
          )
        : AudioOutput.speakerphone;

    // Parse video quality enum (default LOW for better BT bandwidth)
    final videoQualityStr = prefs.getString(_keyDefaultVideoQuality);
    final videoQuality = videoQualityStr != null
        ? VideoQuality.values.firstWhere(
            (e) => e.name == videoQualityStr,
            orElse: () => VideoQuality.low,
          )
        : VideoQuality.low;

    // Parse frame rate enum (default to 15fps for stable Bluetooth)
    final frameRateStr = prefs.getString(_keyDefaultFrameRate);
    final frameRate = frameRateStr != null
        ? TargetFrameRate.values.firstWhere(
            (e) => e.name == frameRateStr,
            orElse: () => TargetFrameRate.fps15,
          )
        : TargetFrameRate.fps15;

    _settings = AppSettings(
      jitsiMode: JitsiMode.libJitsiMeet, // Only lib-jitsi-meet mode now
      // Use community server - meet.jit.si requires login to be moderator
      defaultServer: prefs.getString(_keyDefaultServer) ?? 'https://meet.ffmuc.net',
      defaultRoomName: prefs.getString(_keyDefaultRoomName) ?? 'SpecBridgeRoom',
      displayName: prefs.getString(_keyDisplayName),
      showPipelineStats: prefs.getBool(_keyShowPipelineStats) ?? true,
      defaultAudioOutput: audioOutput,
      defaultVideoQuality: videoQuality,
      defaultFrameRate: frameRate,
      useNativeFrameServer: prefs.getBool(_keyUseNativeFrameServer) ?? true,
    );

    // Load glasses camera permission (persisted across sessions)
    _glassesCameraPermissionGranted = prefs.getBool(_keyGlassesCameraPermissionGranted) ?? false;

    notifyListeners();
  }

  Future<void> setDefaultServer(String server) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultServer, server);
    _settings = _settings.copyWith(defaultServer: server);
    notifyListeners();
  }

  Future<void> setDefaultRoomName(String roomName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultRoomName, roomName);
    _settings = _settings.copyWith(defaultRoomName: roomName);
    notifyListeners();
  }

  Future<void> setDisplayName(String? name) async {
    final prefs = await SharedPreferences.getInstance();
    if (name != null && name.isNotEmpty) {
      await prefs.setString(_keyDisplayName, name);
    } else {
      await prefs.remove(_keyDisplayName);
    }
    _settings = _settings.copyWith(displayName: name);
    notifyListeners();
  }

  Future<void> setShowPipelineStats(bool show) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowPipelineStats, show);
    _settings = _settings.copyWith(showPipelineStats: show);
    notifyListeners();
  }

  Future<void> setDefaultAudioOutput(AudioOutput output) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultAudioOutput, output.name);
    _settings = _settings.copyWith(defaultAudioOutput: output);
    notifyListeners();
  }

  Future<void> setDefaultVideoQuality(VideoQuality quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultVideoQuality, quality.name);
    _settings = _settings.copyWith(defaultVideoQuality: quality);
    notifyListeners();
  }

  Future<void> setDefaultFrameRate(TargetFrameRate frameRate) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultFrameRate, frameRate.name);
    _settings = _settings.copyWith(defaultFrameRate: frameRate);
    notifyListeners();
  }

  Future<void> setUseNativeFrameServer(bool use) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseNativeFrameServer, use);
    _settings = _settings.copyWith(useNativeFrameServer: use);
    notifyListeners();
  }

  /// Save glasses camera permission status (persists across app restarts)
  Future<void> setGlassesCameraPermissionGranted(bool granted) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyGlassesCameraPermissionGranted, granted);
    _glassesCameraPermissionGranted = granted;
    notifyListeners();
  }
}
