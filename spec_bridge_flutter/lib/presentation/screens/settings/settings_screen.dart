import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/models/app_settings.dart';
import '../../../services/settings_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  String _videoQualityLabel(VideoQuality quality) {
    switch (quality) {
      case VideoQuality.low:
        return 'Low (better for unstable connections)';
      case VideoQuality.medium:
        return 'Medium (recommended)';
      case VideoQuality.high:
        return 'High (best quality)';
    }
  }

  void _showAudioOutputPicker(
    BuildContext context,
    SettingsService settingsService,
    AppSettings settings,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Default Audio Output',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          RadioGroup<AudioOutput>(
            groupValue: settings.defaultAudioOutput,
            onChanged: (value) {
              if (value != null) {
                settingsService.setDefaultAudioOutput(value);
                Navigator.pop(context);
              }
            },
            child: Column(
              children: [
                RadioListTile<AudioOutput>(
                  title: const Text('Phone Speaker'),
                  subtitle: const Text('Best for glasses video streaming'),
                  value: AudioOutput.phoneSpeaker,
                ),
                RadioListTile<AudioOutput>(
                  title: const Text('Glasses'),
                  subtitle: const Text('May reduce video frame rate due to Bluetooth bandwidth'),
                  value: AudioOutput.glasses,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _showVideoQualityPicker(
    BuildContext context,
    SettingsService settingsService,
    AppSettings settings,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Video Quality',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          RadioGroup<VideoQuality>(
            groupValue: settings.defaultVideoQuality,
            onChanged: (value) {
              if (value != null) {
                settingsService.setDefaultVideoQuality(value);
                Navigator.pop(context);
              }
            },
            child: Column(
              children: [
                RadioListTile<VideoQuality>(
                  title: const Text('Low'),
                  subtitle: const Text('Lower bandwidth, better for unstable connections'),
                  value: VideoQuality.low,
                ),
                RadioListTile<VideoQuality>(
                  title: const Text('Medium'),
                  subtitle: const Text('Balanced quality (recommended)'),
                  value: VideoQuality.medium,
                ),
                RadioListTile<VideoQuality>(
                  title: const Text('High'),
                  subtitle: const Text('Best quality, higher bandwidth usage'),
                  value: VideoQuality.high,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

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
              const _SectionHeader('Default Room Name'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextFormField(
                  initialValue: settings.defaultRoomName,
                  decoration: const InputDecoration(
                    hintText: 'SpecBridgeRoom',
                    helperText: 'Used for auto-stream and as default in setup',
                  ),
                  onFieldSubmitted: (value) {
                    settingsService.setDefaultRoomName(
                      value.isEmpty ? 'SpecBridgeRoom' : value,
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
              const SizedBox(height: 16),
              const Divider(),
              const _SectionHeader('Streaming Defaults'),
              ListTile(
                leading: const Icon(Icons.volume_up),
                title: const Text('Default Audio Output'),
                subtitle: Text(
                  settings.defaultAudioOutput == AudioOutput.phoneSpeaker
                      ? 'Phone Speaker'
                      : 'Glasses (may reduce video frame rate)',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showAudioOutputPicker(context, settingsService, settings),
              ),
              ListTile(
                leading: const Icon(Icons.high_quality),
                title: const Text('Video Quality'),
                subtitle: Text(_videoQualityLabel(settings.defaultVideoQuality)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showVideoQualityPicker(context, settingsService, settings),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const _SectionHeader('Developer Options'),
              SwitchListTile(
                title: const Text('Show Pipeline Stats'),
                subtitle: const Text('Display frame rates, CPU usage, and encoding stats during streaming'),
                secondary: const Icon(Icons.analytics_outlined),
                value: settings.showPipelineStats,
                onChanged: (value) {
                  settingsService.setShowPipelineStats(value);
                },
              ),
              const SizedBox(height: 32),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Uses lib-jitsi-meet for WebRTC streaming. '
                            'Frames are sent directly to the meeting without screen capture.',
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
