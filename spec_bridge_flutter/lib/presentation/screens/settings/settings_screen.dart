import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/models/app_settings.dart';
import '../../../services/settings_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: Consumer<SettingsService>(
        builder: (context, settingsService, _) {
          final settings = settingsService.settings;

          return ListView(
            children: [
              const _SectionHeader('Jitsi Connection Mode'),
              RadioListTile<JitsiMode>(
                title: const Text('SDK (Recommended)'),
                subtitle: const Text(
                  'Native integration with direct frame injection. '
                  'Higher quality, auto-starts screen share.',
                ),
                value: JitsiMode.sdk,
                groupValue: settings.jitsiMode,
                onChanged: (mode) {
                  if (mode != null) {
                    settingsService.setJitsiMode(mode);
                  }
                },
              ),
              RadioListTile<JitsiMode>(
                title: const Text('WebView (Fallback)'),
                subtitle: const Text(
                  'Opens Jitsi in browser view. '
                  'Uses screen capture - lower quality but fewer dependencies.',
                ),
                value: JitsiMode.webview,
                groupValue: settings.jitsiMode,
                onChanged: (mode) {
                  if (mode != null) {
                    settingsService.setJitsiMode(mode);
                  }
                },
              ),
              const Divider(),
              const _SectionHeader('Default Server'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextFormField(
                  initialValue: settings.defaultServer,
                  decoration: const InputDecoration(
                    hintText: 'https://meet.ffmuc.net',
                    helperText: 'Community server (meet.jit.si requires login)',
                  ),
                  onFieldSubmitted: (value) {
                    settingsService.setDefaultServer(
                      value.isEmpty ? 'https://meet.ffmuc.net' : value,
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const _SectionHeader('Display Name'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextFormField(
                  initialValue: settings.displayName ?? '',
                  decoration: const InputDecoration(
                    hintText: 'Your name in meetings',
                  ),
                  onFieldSubmitted: (value) {
                    settingsService.setDisplayName(value.isEmpty ? null : value);
                  },
                ),
              ),
              const SizedBox(height: 32),
              if (settings.jitsiMode == JitsiMode.webview)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Card(
                    color: Colors.amber,
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'WebView mode requires manual screen share. '
                              'Show glasses preview, then tap Share Screen in Jitsi.',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
