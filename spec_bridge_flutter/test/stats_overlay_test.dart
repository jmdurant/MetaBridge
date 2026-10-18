import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spec_bridge_flutter/presentation/screens/streaming/widgets/stats_overlay.dart';
import 'package:spec_bridge_flutter/services/lib_jitsi_service.dart';
import 'package:spec_bridge_flutter/services/platform_channels/meta_dat_channel.dart';

class _StatsJitsi extends LibJitsiService {
  @override
  Future<LibJitsiStats> getStats() async =>
      const LibJitsiStats(available: true, framesDrawn: 10);
}

class _StatsNative extends Fake implements MetaDATChannel {
  @override
  Future<Map<String, dynamic>> getStreamStats() async => {
    'platform': 'android',
    'videoSource': 'glasses',
    'sdkFrameWidth': 360,
    'sdkFrameHeight': 640,
    'sdkFps': 14.9,
    'sdkCurrentGapMs': 65,
    'sdkLongestGapMs': 1250,
    'sdkStallCount': 1,
    'communicationDeviceType': 'bluetoothSco',
    'glassesFirmware': '128.0.0.203.324',
  };
}

void main() {
  testWidgets('expanded stats scroll within a small preview without overflow', (
    tester,
  ) async {
    final service = _StatsJitsi();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 300,
            child: Stack(
              children: [
                StatsOverlay(service: service, nativeChannel: _StatsNative()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('14.9'), findsOneWidget);
    expect(find.text('360x640'), findsOneWidget);
    expect(find.text('E2E Latency: '), findsNothing);
    await tester.ensureVisible(find.text('Comm. route: '));
    await tester.pumpAndSettle();
    expect(find.text('bluetoothSco'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
