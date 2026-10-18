import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spec_bridge_flutter/presentation/screens/streaming/widgets/diagnostics_report.dart';
import 'package:spec_bridge_flutter/services/session_diagnostics.dart';

void main() {
  testWidgets('report can be copied after a failed start on a small display', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final report = SessionDiagnostics(
      platform: 'android',
      videoSource: 'glasses',
      videoQuality: 'low',
      frameRate: 15,
      audioOutput: 'speakerphone',
      useNativeServer: true,
    )..finish('startupFailed');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiagnosticsReportDialog(
            loadReport: () async => report.encode(),
            saveFailed: () => false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Status: startupFailed'), findsOneWidget);
    await tester.tap(find.text('Copy report'));
    await tester.pumpAndSettle();
    expect(copied, report.encode());
    expect(find.text('Copied'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no hardware or session shows an honest empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiagnosticsReportDialog(
            loadReport: () async => null,
            saveFailed: () => false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No session report yet'), findsOneWidget);
    expect(find.text('Copy report'), findsNothing);
  });
}
