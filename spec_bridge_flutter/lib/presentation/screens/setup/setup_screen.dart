import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../app/routes.dart';
import '../../../data/models/app_settings.dart';
import '../../../data/models/glasses_state.dart';
import '../../../data/models/meeting_config.dart';
import '../../../services/glasses_service.dart';
import '../../../services/permission_service.dart';
import '../../../services/settings_service.dart';

/// Setup screen for glasses connection and meeting configuration
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _roomController = TextEditingController(text: 'SpecBridgeRoom');
  final _nameController = TextEditingController(text: 'SpecBridge User');
  final _e2eePassphraseController = TextEditingController();

  bool _isConnecting = false;
  bool _permissionsGranted = false;
  bool _enableE2EE = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    // Auto-request permissions on open
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestPermissions();
    });
  }

  void _loadSettings() {
    final settings = context.read<SettingsService>().settings;
    if (settings.displayName != null) {
      _nameController.text = settings.displayName!;
    }
  }

  @override
  void dispose() {
    _roomController.dispose();
    _nameController.dispose();
    _e2eePassphraseController.dispose();
    super.dispose();
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

  Future<void> _connectGlasses() async {
    setState(() => _isConnecting = true);

    try {
      final glassesService = context.read<GlassesService>();
      await glassesService.startPairing();
      // The app will be backgrounded while Meta View handles pairing
      // When it returns, the deep link handler will complete the flow
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  void _startStreaming() {
    if (_roomController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a room name')),
      );
      return;
    }

    // Validate E2EE passphrase if enabled
    if (_enableE2EE && _e2eePassphraseController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter an E2EE passphrase')),
      );
      return;
    }

    final settings = context.read<SettingsService>().settings;
    final displayName = _nameController.text.trim();
    final config = MeetingConfig(
      roomName: _roomController.text.trim(),
      serverUrl: settings.defaultServer,
      displayName: displayName.isEmpty ? 'SpecBridge User' : displayName,
      enableE2EE: _enableE2EE,
      e2eePassphrase: _enableE2EE ? _e2eePassphraseController.text.trim() : null,
    );

    context.go('/streaming', extra: config);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SpecBridge Setup'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.goToSettings(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Permissions Section
            _buildSection(
              title: 'Permissions',
              child: _buildPermissionsCard(),
            ),
            const SizedBox(height: 24),

            // Video Source Section
            _buildSection(
              title: 'Video Source',
              child: Consumer<GlassesService>(
                builder: (context, glassesService, _) {
                  return _buildVideoSourceCard(glassesService);
                },
              ),
            ),
            const SizedBox(height: 24),

            // Glasses Connection Section (only shown when glasses is selected)
            Consumer<GlassesService>(
              builder: (context, glassesService, _) {
                if (glassesService.videoSource != VideoSource.glasses) {
                  return const SizedBox.shrink();
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildSection(
                      title: 'Glasses Connection',
                      child: _buildGlassesCard(glassesService.currentState),
                    ),
                    const SizedBox(height: 24),
                  ],
                );
              },
            ),

            // Meeting Configuration Section
            _buildSection(
              title: 'Meeting Configuration',
              child: _buildMeetingCard(),
            ),
            const SizedBox(height: 24),

            // E2EE Section (only for lib-jitsi-meet mode)
            Consumer<SettingsService>(
              builder: (context, settingsService, _) {
                if (settingsService.settings.jitsiMode != JitsiMode.libJitsiMeet) {
                  return const SizedBox.shrink();
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildSection(
                      title: 'End-to-End Encryption',
                      child: _buildE2EECard(),
                    ),
                    const SizedBox(height: 24),
                  ],
                );
              },
            ),

            // Start Streaming Button
            Consumer<GlassesService>(
              builder: (context, glassesService, _) {
                return _buildStartButton(glassesService.currentState);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection({required String title, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  Widget _buildPermissionsCard() {
    return Card(
      child: InkWell(
        onTap: _permissionsGranted ? null : _openSettings,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                _permissionsGranted ? Icons.check_circle : Icons.warning,
                color: _permissionsGranted ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  _permissionsGranted
                      ? 'All permissions granted'
                      : 'Tap to open Settings and grant permissions',
                ),
              ),
              if (!_permissionsGranted)
                const Icon(Icons.open_in_new, size: 18, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGlassesCard(GlassesState state) {
    final isConnected = state.connection == GlassesConnectionState.connected;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                  color: isConnected ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isConnected
                            ? 'Meta Glasses Connected'
                            : 'Meta Glasses Not Connected',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        _getConnectionStatusText(state.connection),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (!isConnected) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isConnecting ? null : _connectGlasses,
                  icon: _isConnecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: Text(_isConnecting ? 'Connecting...' : 'Connect Glasses'),
                ),
              ),
            ],
            if (state.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                state.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getConnectionStatusText(GlassesConnectionState state) {
    switch (state) {
      case GlassesConnectionState.disconnected:
        return 'Tap Connect to pair with Meta View app';
      case GlassesConnectionState.connecting:
        return 'Opening Meta View...';
      case GlassesConnectionState.connected:
        return 'Ready to stream';
      case GlassesConnectionState.error:
        return 'Connection failed';
    }
  }

  Widget _buildMeetingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _roomController,
              decoration: const InputDecoration(
                labelText: 'Room Name',
                hintText: 'Enter meeting room name',
                prefixIcon: Icon(Icons.meeting_room),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Display Name (optional)',
                hintText: 'Your name in the meeting',
                prefixIcon: Icon(Icons.person),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildE2EECard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              title: const Text('Enable E2EE'),
              subtitle: const Text('All participants must use the same passphrase'),
              secondary: Icon(
                _enableE2EE ? Icons.lock : Icons.lock_open,
                color: _enableE2EE ? Colors.green : Colors.grey,
              ),
              value: _enableE2EE,
              onChanged: (value) => setState(() => _enableE2EE = value),
              contentPadding: EdgeInsets.zero,
            ),
            if (_enableE2EE) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _e2eePassphraseController,
                decoration: const InputDecoration(
                  labelText: 'E2EE Passphrase',
                  hintText: 'Enter shared passphrase',
                  prefixIcon: Icon(Icons.key),
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 8),
              Text(
                'Share this passphrase securely with other participants',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildVideoSourceCard(GlassesService glassesService) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select where to capture video from:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            _buildVideoSourceOption(
              glassesService,
              VideoSource.glasses,
              Icons.visibility,
              'Meta Glasses',
              'Stream from Ray-Ban Meta glasses',
            ),
            _buildVideoSourceOption(
              glassesService,
              VideoSource.backCamera,
              Icons.camera_rear,
              'Back Camera',
              'Use phone\'s rear camera',
            ),
            _buildVideoSourceOption(
              glassesService,
              VideoSource.frontCamera,
              Icons.camera_front,
              'Front Camera',
              'Use phone\'s front camera',
            ),
            _buildVideoSourceOption(
              glassesService,
              VideoSource.screenShare,
              Icons.screen_share,
              'Screen Share',
              'Share your screen via Jitsi',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoSourceOption(
    GlassesService glassesService,
    VideoSource source,
    IconData icon,
    String title,
    String subtitle, {
    bool enabled = true,
  }) {
    final isSelected = glassesService.videoSource == source;

    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: RadioListTile<VideoSource>(
        value: source,
        groupValue: glassesService.videoSource,
        onChanged: enabled
            ? (value) {
                if (value != null) {
                  glassesService.setVideoSource(value);
                }
              }
            : null,
        title: Row(
          children: [
            Icon(icon, size: 20, color: isSelected ? Theme.of(context).primaryColor : null),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        contentPadding: EdgeInsets.zero,
        dense: true,
      ),
    );
  }

  Widget _buildStartButton(GlassesState state) {
    // Use the isReady getter which handles different video sources
    final isReady = state.isReady && _permissionsGranted;

    String buttonLabel;
    switch (state.videoSource) {
      case VideoSource.glasses:
        buttonLabel = 'Start Streaming (Glasses)';
        break;
      case VideoSource.backCamera:
        buttonLabel = 'Start Streaming (Back Camera)';
        break;
      case VideoSource.frontCamera:
        buttonLabel = 'Start Streaming (Front Camera)';
        break;
      case VideoSource.screenShare:
        buttonLabel = 'Start Streaming (Screen Share)';
        break;
    }

    return FilledButton.icon(
      onPressed: isReady ? _startStreaming : null,
      icon: const Icon(Icons.play_arrow),
      label: Text(buttonLabel),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
    );
  }
}
