import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/models/meeting_config.dart';
import '../presentation/screens/settings/settings_screen.dart';
import '../presentation/screens/splash/splash_screen.dart';
import '../presentation/screens/setup/setup_screen.dart';
import '../presentation/screens/streaming/streaming_screen.dart';

GoRouter createRouter() {
  return GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(
        path: '/splash',
        name: 'splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/setup',
        name: 'setup',
        builder: (context, state) => const SetupScreen(),
      ),
      GoRoute(
        path: '/streaming',
        name: 'streaming',
        builder: (context, state) {
          final config = state.extra as MeetingConfig?;
          if (config == null) {
            // If no config provided, redirect to setup
            return const SetupScreen();
          }
          return StreamingScreen(config: config);
        },
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text('Page not found: ${state.uri}'),
      ),
    ),
  );
}

// Navigation helper extension
extension GoRouterExtension on BuildContext {
  void goToSetup() => GoRouter.of(this).go('/setup');

  void goToStreaming(MeetingConfig config) {
    GoRouter.of(this).go('/streaming', extra: config);
  }

  void goToSettings() => GoRouter.of(this).push('/settings');
}
