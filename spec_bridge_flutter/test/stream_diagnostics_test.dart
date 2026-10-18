import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spec_bridge_flutter/data/models/meeting_config.dart';
import 'package:spec_bridge_flutter/services/bluetooth_audio_service.dart';
import 'package:spec_bridge_flutter/services/glasses_service.dart';
import 'package:spec_bridge_flutter/services/lib_jitsi_service.dart';
import 'package:spec_bridge_flutter/services/platform_channels/bluetooth_audio_channel.dart';
import 'package:spec_bridge_flutter/services/platform_channels/meta_dat_channel.dart';
import 'package:spec_bridge_flutter/services/session_diagnostics.dart';
import 'package:spec_bridge_flutter/services/stream_service.dart';

class MetaChannel extends Fake implements MetaDATChannel {
  final events = StreamController<MetaDATEvent>.broadcast(sync: true);
  int frames = 0;
  @override
  Stream<MetaDATEvent> get eventStream => events.stream;
  @override
  Stream<Uint8List> get previewFrameStream => const Stream.empty();
  @override
  Future<bool> setNativeServerEnabled(bool enabled) async => true;
  @override
  Future<bool> startStreaming(StreamConfig config) async {
    frames = 55;
    events.add(StreamStatusEvent('streaming'));
    return true;
  }

  @override
  Future<Map<String, dynamic>> getStreamStats() async => {
    'platform': 'android',
    'videoSource': 'glasses',
    'framesReceived': frames,
    'audioRouteObserved': true,
    'communicationDeviceType': 'bluetoothSco',
  };
  @override
  Future<void> stopStreaming() async {
    frames = 0;
  }

  @override
  Future<bool> resetFrameServer() async => true;
  @override
  void dispose() => unawaited(events.close());
}

class AudioChannel extends Fake implements BluetoothAudioChannel {
  @override
  Stream<BluetoothAudioEvent> get audioDeviceChanges => const Stream.empty();
  @override
  Future<List<BluetoothAudioDevice>> getAvailableDevices() async => [];
  @override
  Future<bool> forcePhoneMic() async => false;
  @override
  Future<void> clearAudioDevice() async {}
}

class Jitsi extends LibJitsiService {
  bool failJoin = false;
  @override
  Future<bool> waitForWebSocketConnected({
    Duration timeout = const Duration(seconds: 10),
  }) async => true;
  @override
  Future<void> joinMeeting(
    MeetingConfig config, {
    bool usePhoneMic = true,
  }) async {
    if (failJoin) throw StateError('private-token-and-room');
  }

  @override
  Future<bool> waitForJoined({
    Duration timeout = const Duration(seconds: 30),
  }) async => true;
  @override
  Future<LibJitsiStats> getStats() async =>
      const LibJitsiStats(available: true, rtcFramesSent: 12);
  @override
  Future<void> leaveMeeting() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MetaChannel native;
  late GlassesService glasses;
  late BluetoothAudioService audio;
  late Jitsi jitsi;
  late StreamService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    native = MetaChannel();
    glasses = GlassesService(native);
    audio = BluetoothAudioService(AudioChannel());
    jitsi = Jitsi();
    service = StreamService(glasses, audio)
      ..setNativeChannel(native)
      ..setLibJitsiService(jitsi);
  });
  tearDown(() {
    service.dispose();
    glasses.dispose();
    audio.dispose();
    jitsi.dispose();
  });

  test(
    'failed start persists a report without retaining raw error secrets',
    () async {
      jitsi.failJoin = true;
      await expectLater(
        service.startStreaming(const MeetingConfig(roomName: 'private-room')),
        throwsStateError,
      );
      final saved = (await DiagnosticReportStore().load())!;
      final report = jsonDecode(saved);
      expect(report['complete'], isTrue);
      expect(report['outcome'], 'startupFailed');
      expect(saved, isNot(contains('private-token')));
      expect(saved, isNot(contains('private-room')));
      expect(report['events'], contains(containsPair('accepted', false)));
      expect(
        (report['samples'] as List).last['phoneAudioRouteMatchesRequest'],
        isFalse,
      );
    },
  );

  test(
    'stop preserves a pre-teardown sample and saves a completed report',
    () async {
      await service.startStreaming(const MeetingConfig(roomName: 'room'));
      await service.diagnosticsReport();
      await service.stopStreaming();
      final report = jsonDecode((await DiagnosticReportStore().load())!);
      expect(report['outcome'], 'stopped');
      expect(
        (report['samples'] as List).any(
          (s) => s['native']['framesReceived'] == 55,
        ),
        isTrue,
      );
      expect(report['events'], contains(containsPair('kind', 'stopRequested')));
    },
  );
}
