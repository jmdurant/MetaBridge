import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../data/models/glasses_state.dart';
import '../../../data/models/meeting_config.dart';
import '../../../services/glasses_service.dart';
import '../../../services/permission_service.dart';

/// Setup screen for glasses connection and meeting configuration
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _roomController = TextEditingController(text: 'SpecBridgeRoom');
  final _serverController = TextEditingController(text: 'https://meet.jit.si');
  final _nameController = TextEditingController(text: 'SpecBridge User');

  bool _isConnecting = false;
  bool _permissionsGranted = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  @override
  void dispose() {
    _roomController.dispose();
    _serverController.dispose();
    _nameController.dispose();
    super.dispose();
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
      if (!granted) {
        _showPermissionDeniedDialog();
      }
    }
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permissions Required'),
        content: const Text(
          'Camera and microphone permissions are required to stream. '
          'Please grant permissions in Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              context.read<PermissionService>().openSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
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

    final displayName = _nameController.text.trim();
    final config = MeetingConfig(
      roomName: _roomController.text.trim(),
      serverUrl: _serverController.text.trim(),
      displayName: displayName.isEmpty ? 'SpecBridge User' : displayName,
    );

    context.go('/streaming', extra: config);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SpecBridge Setup'),
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

            // Glasses Connection Section
            _buildSection(
              title: 'Glasses Connection',
              child: Consumer<GlassesService>(
                builder: (context, glassesService, _) {
                  return _buildGlassesCard(glassesService.currentState);
                },
              ),
            ),
            const SizedBox(height: 24),

            // Meeting Configuration Section
            _buildSection(
              title: 'Meeting Configuration',
              child: _buildMeetingCard(),
            ),
            const SizedBox(height: 32),

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
                    : 'Camera & microphone permissions required',
              ),
            ),
            if (!_permissionsGranted)
              TextButton(
                onPressed: _requestPermissions,
                child: const Text('Grant'),
              ),
          ],
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
              controller: _serverController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'https://meet.jit.si',
                prefixIcon: Icon(Icons.dns),
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

  Widget _buildStartButton(GlassesState state) {
    final isReady =
        state.connection == GlassesConnectionState.connected &&
        _permissionsGranted;

    return FilledButton.icon(
      onPressed: isReady ? _startStreaming : null,
      icon: const Icon(Icons.play_arrow),
      label: const Text('Start Streaming'),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
    );
  }
}
