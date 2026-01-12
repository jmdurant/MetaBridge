import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'app/app.dart';
import 'app/routes.dart';
import 'services/bluetooth_audio_service.dart';
import 'services/deep_link_service.dart';
import 'services/glasses_service.dart';
import 'services/jitsi_service.dart';
import 'services/jitsi_webview_service.dart';
import 'services/permission_service.dart';
import 'services/platform_channels/bluetooth_audio_channel.dart';
import 'services/platform_channels/meta_dat_channel.dart';
import 'services/settings_service.dart';
import 'services/stream_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize services that need early setup
  final deepLinkService = DeepLinkService();
  await deepLinkService.initialize();

  final settingsService = SettingsService();
  await settingsService.load();

  // Create platform channels
  final metaDATChannel = MetaDATChannelImpl();
  final bluetoothAudioChannel = BluetoothAudioChannelImpl();

  runApp(
    MultiProvider(
      providers: [
        // Platform channels (no reactive state)
        Provider<MetaDATChannel>.value(value: metaDATChannel),
        Provider<BluetoothAudioChannel>.value(value: bluetoothAudioChannel),

        // Permission service (stateless utility)
        Provider<PermissionService>(create: (_) => PermissionService()),

        // Settings service (initialized early)
        ChangeNotifierProvider<SettingsService>.value(value: settingsService),

        // Deep link service (initialized early)
        ChangeNotifierProvider<DeepLinkService>.value(value: deepLinkService),

        // Bluetooth audio service (depends on platform channel)
        ChangeNotifierProxyProvider<BluetoothAudioChannel, BluetoothAudioService>(
          create: (context) => BluetoothAudioService(context.read<BluetoothAudioChannel>()),
          update: (context, channel, previous) =>
              previous ?? BluetoothAudioService(channel),
        ),

        // Glasses service (depends on platform channel)
        ChangeNotifierProxyProvider<MetaDATChannel, GlassesService>(
          create: (context) => GlassesService(context.read<MetaDATChannel>()),
          update: (context, channel, previous) =>
              previous ?? GlassesService(channel),
        ),

        // Jitsi SDK service
        ChangeNotifierProvider<JitsiService>(create: (_) => JitsiService()),

        // Jitsi WebView service (fallback)
        ChangeNotifierProvider<JitsiWebViewService>(
          create: (_) => JitsiWebViewService(),
        ),

        // Stream service (depends on glasses, jitsi, and bluetooth audio)
        ChangeNotifierProxyProvider3<GlassesService, JitsiService,
            BluetoothAudioService, StreamService>(
          create: (context) => StreamService(
            context.read<GlassesService>(),
            context.read<JitsiService>(),
            context.read<BluetoothAudioService>(),
          ),
          update: (context, glasses, jitsi, bluetoothAudio, previous) =>
              previous ?? StreamService(glasses, jitsi, bluetoothAudio),
        ),

        // Router
        Provider<GoRouter>(create: (_) => createRouter()),
      ],
      child: const SpecBridgeApp(),
    ),
  );
}
