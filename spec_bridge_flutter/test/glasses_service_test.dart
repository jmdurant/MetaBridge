import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spec_bridge_flutter/data/models/glasses_state.dart';
import 'package:spec_bridge_flutter/services/glasses_service.dart';
import 'package:spec_bridge_flutter/services/platform_channels/meta_dat_channel.dart';

class FakeMetaChannel implements MetaDATChannel {
  final events = StreamController<MetaDATEvent>.broadcast(sync: true);
  @override
  Stream<MetaDATEvent> get eventStream => events.stream;
  @override
  Future<bool> startStreaming(StreamConfig config) async => true;
  @override
  Future<bool> handleUrl(String url) async => true;
  @override
  void dispose() => unawaited(events.close());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'capture acceptance does not report success before SDK streaming',
    () async {
      final channel = FakeMetaChannel();
      final service = GlassesService(channel);
      addTearDown(service.dispose);
      var ready = false;
      final started = service.startStreaming().then((value) {
        ready = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      channel.events.add(StreamStatusEvent('streaming'));
      expect(await started, isTrue);
      channel.events.add(StreamStatusEvent('paused'));
      expect(service.captureStatus, 'paused');
      channel.events.add(StreamStatusEvent('streaming'));
      expect(service.captureStatus, 'streaming');
    },
  );

  test('capture startup surfaces native failure', () async {
    final channel = FakeMetaChannel();
    final service = GlassesService(channel);
    addTearDown(service.dispose);
    final started = service.startStreaming();
    channel.events.add(
      StreamStatusEvent('error', errorMessage: 'Camera permission denied'),
    );
    expect(await started, isFalse);
    expect(service.captureError, 'Camera permission denied');
  });

  test(
    'handled Meta callback does not imply successful registration',
    () async {
      final channel = FakeMetaChannel();
      final service = GlassesService(channel);
      addTearDown(service.dispose);
      expect(
        await service.handleMetaViewCallback('specbridge://callback'),
        isTrue,
      );
      expect(service.currentState.isConnected, isFalse);
      channel.events.add(
        ConnectionStateEvent(GlassesConnectionState.connected),
      );
      expect(service.currentState.isConnected, isTrue);
    },
  );
}
