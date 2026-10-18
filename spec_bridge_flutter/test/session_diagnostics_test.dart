import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spec_bridge_flutter/services/lib_jitsi_service.dart';
import 'package:spec_bridge_flutter/services/session_diagnostics.dart';

SessionDiagnostics recorder({
  int Function()? elapsed,
  int samples = 180,
  int events = 100,
}) => SessionDiagnostics(
  platform: 'android',
  videoSource: 'glasses',
  videoQuality: 'low',
  frameRate: 15,
  audioOutput: 'speakerphone',
  useNativeServer: true,
  elapsedMs: elapsed,
  maxSamples: samples,
  maxEvents: events,
);

void addSample(
  SessionDiagnostics report, {
  Map<String, dynamic> native = const {},
  Map<String, dynamic>? webView,
}) {
  report.sample(
    native: native,
    webView: webView,
    flutter: {},
    state: 'streaming',
    requestedAudio: 'speakerphone',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('exports only diagnostic fields and typed SDK events', () {
    final report = recorder();
    addSample(
      report,
      native: {
        'sdkFps': 14.8,
        'glassesFirmware': 'v128',
        'jwt': 'secret-jwt',
        'deviceName': 'Personal glasses',
        'frameData': [1, 2, 3],
        'sdkEvents': [
          {
            'kind': 'streamError',
            'code': 'TIMEOUT',
            'elapsedMs': 500,
            'message': 'secret-room',
          },
        ],
      },
      webView: {
        'rtcFramesSent': 5,
        'room': 'private-room',
        'passphrase': 'private-key',
      },
    );
    final encoded = report.encode();
    expect(encoded, contains('v128'));
    expect(encoded, contains('TIMEOUT'));
    for (final secret in [
      'secret-jwt',
      'Personal glasses',
      'frameData',
      'secret-room',
      'private-room',
      'private-key',
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
  });

  test(
    'retains first sample and bounded tail with explicit discard counts',
    () {
      var time = 0;
      final report = recorder(elapsed: () => time, samples: 2, events: 2);
      for (time = 0; time < 5; time++) {
        addSample(report);
        report.event('state', value: '$time');
      }
      final data = report.toJson();
      expect((data['firstSample'] as Map)['elapsedMs'], 0);
      expect((data['samples'] as List).map((e) => e['elapsedMs']), [3, 4]);
      expect(data['samplesDiscarded'], 3);
      expect(data['eventsDiscarded'], 3);
    },
  );

  test(
    'finished reports freeze duration and ignore late collection results',
    () {
      var time = 1000;
      final report = recorder(elapsed: () => time);
      addSample(report);
      report.finish('startupFailed');
      time = 9999;
      addSample(report);
      report.event('late');
      report.finish('stopped');
      expect(report.toJson()['elapsedMs'], 1000);
      expect(report.toJson()['outcome'], 'startupFailed');
      expect((report.toJson()['samples'] as List).length, 1);
    },
  );

  test('startup samples exclude retained counters from an earlier capture', () {
    final report = recorder();
    report.sample(
      native: {
        'framesReceived': 999,
        'glassesFirmware': 'old',
        'metaDatVersion': '1.0.1',
      },
      webView: null,
      flutter: {},
      state: 'starting',
      requestedAudio: 'speakerphone',
      includeCaptureStats: false,
    );
    final sample = (report.toJson()['samples'] as List).single as Map;
    expect(sample['native'], {'metaDatVersion': '1.0.1'});
    expect(sample['captureRequested'], isFalse);
  });

  test('unknown route and unavailable WebView remain unknown', () {
    final report = recorder();
    addSample(report);
    final sample = (report.toJson()['samples'] as List).single as Map;
    expect(sample['phoneAudioRouteMatchesRequest'], isNull);
    expect(sample['webView'], isNull);
  });

  test('reports observed Bluetooth route conflicting with phone request', () {
    final report = recorder();
    addSample(
      report,
      native: {
        'audioRouteObserved': true,
        'communicationDeviceType': 'bluetoothSco',
      },
    );
    final sample = (report.toJson()['samples'] as List).single as Map;
    expect(sample['phoneAudioRouteMatchesRequest'], isFalse);
  });

  test('phone-local delay is unavailable without Android glasses frames', () {
    const stats = LibJitsiStats(framesDrawn: 10, lastLatencyMs: 8);
    expect(
      stats.diagnosticSnapshot(androidGlasses: false)['phoneLocalDelayMs'],
      isNull,
    );
    expect(
      stats.diagnosticSnapshot(androidGlasses: true)['phoneLocalDelayMs'],
      8,
    );
    expect(
      const LibJitsiStats().diagnosticSnapshot(
        androidGlasses: true,
      )['phoneLocalDelayMs'],
      isNull,
    );
  });

  test(
    'latest report persists across store instances and ordered writes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = DiagnosticReportStore();
      final first = recorder()..finish('startupFailed');
      final second = recorder()..finish('stopped');
      await Future.wait([
        store.save(first.encode()),
        store.save(second.encode()),
      ]);
      final restored = jsonDecode((await DiagnosticReportStore().load())!);
      expect(restored['outcome'], 'stopped');
    },
  );
}
