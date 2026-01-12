import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../services/deep_link_service.dart';
import '../../../services/glasses_service.dart';

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
    // Initialize glasses service
    final glassesService = context.read<GlassesService>();
    await glassesService.initialize();

    // Check for deep link meeting config
    final deepLinkService = context.read<DeepLinkService>();
    final pendingConfig = deepLinkService.getPendingMeetingConfig();

    if (!mounted) return;

    if (pendingConfig != null) {
      // Deep link with meeting info - go directly to streaming
      context.go('/streaming', extra: pendingConfig);
    } else if (deepLinkService.isInitialLinkMetaViewCallback()) {
      // Returning from Meta View pairing
      final url = deepLinkService.initialLink!;
      await glassesService.handleMetaViewCallback(url);
      context.go('/setup');
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
