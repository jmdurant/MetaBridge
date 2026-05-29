import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Lists local recordings saved to app storage, with share/open + delete.
///
/// Recordings are written by LibJitsiService to <appDocs>/recordings as
/// rec_<timestamp>.(mp4|webm). Since app-private storage isn't visible in the
/// device gallery, this screen is how the user gets at them.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  List<FileSystemEntity> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Directory> _recordingsDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final recDir = Directory('${dir.path}/recordings');
    if (!recDir.existsSync()) recDir.createSync(recursive: true);
    return recDir;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final recDir = await _recordingsDir();
    final files = recDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.mp4') || f.path.endsWith('.webm'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    if (mounted) {
      setState(() {
        _files = files;
        _loading = false;
      });
    }
  }

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _open(File f) async {
    final res = await OpenFilex.open(f.path);
    if (res.type != ResultType.done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open: ${res.message}')),
      );
    }
  }

  Future<void> _share(File f) async {
    await Share.shareXFiles([XFile(f.path)], text: 'SpecBridge recording');
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text(f.path.split('/').last),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      try {
        f.deleteSync();
      } catch (_) {}
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No recordings yet.\nTap Record during a stream to save one here.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _files.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final f = _files[i] as File;
                    final stat = f.statSync();
                    return ListTile(
                      leading: const Icon(Icons.play_circle_outline, size: 32),
                      title: Text(f.path.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${_fmtDate(stat.modified)}  •  ${_fmtSize(stat.size)}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.ios_share),
                            tooltip: 'Share',
                            onPressed: () => _share(f),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Delete',
                            onPressed: () => _delete(f),
                          ),
                        ],
                      ),
                      // Tap = play in the system video viewer
                      onTap: () => _open(f),
                    );
                  },
                ),
    );
  }
}
