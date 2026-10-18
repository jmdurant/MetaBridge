import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../services/stream_service.dart';

Future<void> showDiagnosticsReport(BuildContext context) {
  final service = context.read<StreamService>();
  return showDialog<void>(
    context: context,
    builder: (_) => DiagnosticsReportDialog(
      loadReport: service.diagnosticsReport,
      saveFailed: () => service.diagnosticsSaveFailed,
    ),
  );
}

class DiagnosticsReportDialog extends StatefulWidget {
  const DiagnosticsReportDialog({
    super.key,
    required this.loadReport,
    required this.saveFailed,
  });
  final Future<String?> Function() loadReport;
  final bool Function() saveFailed;

  @override
  State<DiagnosticsReportDialog> createState() =>
      _DiagnosticsReportDialogState();
}

class _DiagnosticsReportDialogState extends State<DiagnosticsReportDialog> {
  late final Future<String?> _report = widget.loadReport();
  bool _copied = false;

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _report,
    builder: (context, snapshot) {
      final text = snapshot.data;
      Map<String, dynamic>? report;
      if (text != null) {
        try {
          report = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {
          /* Show damaged report error below. */
        }
      }
      return AlertDialog(
        title: const Text('Session diagnostics'),
        content: SizedBox(
          width: 600,
          child: snapshot.connectionState != ConnectionState.done
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              : snapshot.hasError || (text != null && report == null)
              ? const Text('Could not read the saved session report.')
              : report == null
              ? const Text(
                  'No session report yet. Starting a stream creates one, even if the connection fails.',
                )
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Started: ${report['startedAtUtc']}'),
                      Text(
                        'Status: ${report['complete'] == true ? report['outcome'] : 'not finalized (snapshot)'}',
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.saveFailed()
                            ? 'Saving on this phone failed. Copy this report before closing the app.'
                            : 'The latest report is saved on this phone. Copy it to keep or share it.',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Includes device and pipeline measurements. Phone-local delay excludes Bluetooth and remote playback. No meeting credentials or media are included.',
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        text!,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        actions: [
          if (report != null)
            TextButton.icon(
              icon: Icon(_copied ? Icons.check : Icons.copy),
              label: Text(_copied ? 'Copied' : 'Copy report'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text!));
                if (mounted) setState(() => _copied = true);
              },
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
