import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'theme.dart';

class SpecBridgeApp extends StatelessWidget {
  const SpecBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final router = context.watch<GoRouter>();

    return MaterialApp.router(
      title: 'SpecBridge',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
