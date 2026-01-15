import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/models/app_settings.dart';
import '../../../services/permission_service.dart';
import '../../../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _permissionsGranted = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final permissionService = context.read<PermissionService>();
    final granted = await permissionService.checkAllPermissions();
    if (mounted) {
      setState(() => _permissionsGranted = granted);
    }
  }

  Future<void> _requestPermissions() async {
    final permissionService = context.read<PermissionService>();
    final granted = await permissionService.requestAllPermissions();
    if (mounted) {
      setState(() => _permissionsGranted = granted);
    }
  }

  void _openSettings() {
    context.read<PermissionService>().openSettings();
  }

  String _videoQualityLabel(VideoQuality quality) {
    switch (quality) {
      case VideoQuality.low:
        return 'Low (recommended for Bluetooth)';
      case VideoQuality.medium:
        return 'Medium (may cause fps drops)';
      case VideoQuality.high:
        return 'High (requires strong connection)';
    }
  }

  String _audioOutputLabel(AudioOutput output) {
    switch (output) {
      case AudioOutput.speakerphone:
        return 'Speakerphone (max video quality)';
      case AudioOutput.earpiece:
        return 'Earpiece (max video quality)';
      case AudioOutput.glasses:
        return 'Glasses (BLE 15fps / SCO 7fps)';
    }
  }

  IconData _audioOutputIcon(AudioOutput output) {
    switch (output) {
      case AudioOutput.speakerphone:
        return Icons.volume_up;
      case AudioOutput.earpiece:
        return Icons.phone_in_talk;
      case AudioOutput.glasses:
        return Icons.headphones;
    }
  }

  String _frameRateLabel(TargetFrameRate frameRate) {
    switch (frameRate) {
      case TargetFrameRate.fps30:
        return '30 fps (requires WiFi - not available)';
      case TargetFrameRate.fps24:
        return '24 fps (may drop on Bluetooth)';
      case TargetFrameRate.fps15:
        return '15 fps (recommended for Bluetooth)';
      case TargetFrameRate.fps7:
        return '7 fps (guaranteed stable)';
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
                  title: const Text('Speakerphone'),
                  subtitle: const Text('Loud hands-free, max video quality'),
                  value: AudioOutput.speakerphone,
                ),
                RadioListTile<AudioOutput>(
                  title: const Text('Earpiece'),
                  subtitle: const Text('Quiet hold-to-ear, max video quality'),
                  value: AudioOutput.earpiece,
                ),
                RadioListTile<AudioOutput>(
                  title: const Text('Glasses'),
                  subtitle: const Text('Prefers BLE (15fps) over SCO (7fps)'),
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
                  subtitle: const Text('Recommended - best for Bluetooth bandwidth'),
                  value: VideoQuality.low,
                ),
                RadioListTile<VideoQuality>(
                  title: const Text('Medium'),
                  subtitle: const Text('Higher quality, may cause fps drops on BT'),
                  value: VideoQuality.medium,
                ),
                RadioListTile<VideoQuality>(
                  title: const Text('High'),
                  subtitle: const Text('Best quality, requires strong connection'),
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

  void _showFrameRatePicker(
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
              'Target Frame Rate',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Meta glasses use Bluetooth which limits bandwidth. '
              'Lower frame rates are more stable.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 8),
          RadioGroup<TargetFrameRate>(
            groupValue: settings.defaultFrameRate,
            onChanged: (value) {
              if (value != null) {
                settingsService.setDefaultFrameRate(value);
                Navigator.pop(context);
              }
            },
            child: Column(
              children: [
                RadioListTile<TargetFrameRate>(
                  title: const Text('24 fps'),
                  subtitle: const Text('High - may drop if Bluetooth congested'),
                  value: TargetFrameRate.fps24,
                ),
                RadioListTile<TargetFrameRate>(
                  title: const Text('15 fps'),
                  subtitle: const Text('Recommended - stable on Bluetooth'),
                  value: TargetFrameRate.fps15,
                ),
                RadioListTile<TargetFrameRate>(
                  title: const Text('7 fps'),
                  subtitle: const Text('Low - guaranteed stable, fallback rate'),
                  value: TargetFrameRate.fps7,
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
              const _SectionHeader('Permissions'),
              ListTile(
                leading: Icon(
                  _permissionsGranted ? Icons.check_circle : Icons.warning,
                  color: _permissionsGranted ? Colors.green : Colors.orange,
                ),
                title: Text(
                  _permissionsGranted
                      ? 'All permissions granted'
                      : 'Some permissions missing',
                ),
                subtitle: Text(
                  _permissionsGranted
                      ? 'Camera, microphone, and Bluetooth access enabled'
                      : 'Tap to grant required permissions',
                ),
                trailing: _permissionsGranted
                    ? null
                    : const Icon(Icons.chevron_right),
                onTap: _permissionsGranted ? null : _requestPermissions,
              ),
              if (!_permissionsGranted)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextButton.icon(
                    onPressed: _openSettings,
                    icon: const Icon(Icons.settings, size: 18),
                    label: const Text('Open System Settings'),
                  ),
                ),
              const SizedBox(height: 8),
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
                leading: Icon(_audioOutputIcon(settings.defaultAudioOutput)),
                title: const Text('Default Audio Output'),
                subtitle: Text(_audioOutputLabel(settings.defaultAudioOutput)),
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
              ListTile(
                leading: const Icon(Icons.speed),
                title: const Text('Target Frame Rate'),
                subtitle: Text(_frameRateLabel(settings.defaultFrameRate)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showFrameRatePicker(context, settingsService, settings),
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
              SwitchListTile(
                title: const Text('Native Frame Server'),
                subtitle: const Text('Bypass Flutter UI thread for lower latency (experimental)'),
                secondary: const Icon(Icons.speed),
                value: settings.useNativeFrameServer,
                onChanged: (value) {
                  settingsService.setUseNativeFrameServer(value);
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
