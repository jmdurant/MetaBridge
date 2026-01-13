import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/app_settings.dart';

class SettingsService extends ChangeNotifier {
  static const _keyJitsiMode = 'jitsi_mode';
  static const _keyDefaultServer = 'default_server';
  static const _keyDisplayName = 'display_name';

  AppSettings _settings = const AppSettings();

  AppSettings get settings => _settings;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    final modeString = prefs.getString(_keyJitsiMode);
    final mode = modeString == 'webview' ? JitsiMode.webview : JitsiMode.sdk;

    _settings = AppSettings(
      jitsiMode: mode,
      // Use community server - meet.jit.si requires login to be moderator
      defaultServer: prefs.getString(_keyDefaultServer) ?? 'https://meet.ffmuc.net',
      displayName: prefs.getString(_keyDisplayName),
    );

    notifyListeners();
  }

  Future<void> setJitsiMode(JitsiMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyJitsiMode, mode == JitsiMode.webview ? 'webview' : 'sdk');
    _settings = _settings.copyWith(jitsiMode: mode);
    notifyListeners();
  }

  Future<void> setDefaultServer(String server) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultServer, server);
    _settings = _settings.copyWith(defaultServer: server);
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
}
