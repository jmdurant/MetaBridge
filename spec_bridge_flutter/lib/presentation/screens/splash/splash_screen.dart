import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../data/models/meeting_config.dart';
import '../../../services/deep_link_service.dart';
import '../../../services/glasses_service.dart';
import '../../../services/permission_service.dart';
import '../../../services/settings_service.dart';

/// Launch configuration from dart-defines
///
/// Usage:
///   flutter run --dart-define=AUTO_STREAM=true
///
/// Room name, server, and display name are read from app settings (configured in Settings screen)
/// Optionally override room with: --dart-define=DEFAULT_ROOM=myroom
class LaunchConfig {
  static const autoStream = bool.fromEnvironment('AUTO_STREAM', defaultValue: false);
  // Empty string means use settings, otherwise override with dart-define value
  static const roomOverride = String.fromEnvironment('DEFAULT_ROOM', defaultValue: '');
}

/// Splash screen shown during app initialization
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // Request Android permissions first (Bluetooth required for Meta SDK)
    final permissionService = context.read<PermissionService>();
    await permissionService.requestAllPermissions();

    // Initialize glasses service (Meta SDK needs Bluetooth access)
    final glassesService = context.read<GlassesService>();
    final deepLinkService = context.read<DeepLinkService>();

    await glassesService.initialize();

    // Check for deep link meeting config
    final pendingConfig = deepLinkService.getPendingMeetingConfig();

    if (!mounted) return;

    if (pendingConfig != null) {
      // Deep link with meeting info - go directly to streaming
      context.go('/streaming', extra: pendingConfig);
    } else if (deepLinkService.isInitialLinkMetaViewCallback()) {
      // Returning from Meta View pairing
      final url = deepLinkService.initialLink!;
      await glassesService.handleMetaViewCallback(url);
      if (!mounted) return;
      context.go('/setup');
    } else if (LaunchConfig.autoStream) {
      // Auto-stream mode from dart-define - go directly to streaming
      // Use configured settings (room can be overridden via dart-define)
      final settings = context.read<SettingsService>().settings;
      final roomName = LaunchConfig.roomOverride.isNotEmpty
          ? LaunchConfig.roomOverride
          : settings.defaultRoomName;
      debugPrint('LaunchConfig: Auto-streaming to $roomName on ${settings.defaultServer}');
      final config = MeetingConfig(
        roomName: roomName,
        serverUrl: settings.defaultServer,
        displayName: settings.displayName ?? 'SpecBridge User',
      );
      context.go('/streaming', extra: config);
    } else {
      // Normal startup
      context.go('/setup');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App icon placeholder
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.videocam,
                size: 64,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'SpecBridge',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Stream your glasses to Jitsi',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 48),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
