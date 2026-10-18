import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spec_bridge_flutter/services/frame_websocket_server.dart';

Future<void> eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition was not reached');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('concurrent starts share one listener', () async {
    final server = FrameWebSocketServer();
    addTearDown(server.stop);
    expect(await Future.wait([server.start(port: 0), server.start(port: 0)]), [
      true,
      true,
    ]);
    expect(server.isRunning, isTrue);
  });

  test(
    'slow clients cannot accumulate frames; receipt allows a fresh frame',
    () async {
      final server = FrameWebSocketServer();
      expect(await server.start(port: 0), isTrue);
      addTearDown(server.stop);
      final client = await WebSocket.connect('ws://127.0.0.1:${server.port}');
      addTearDown(client.close);
      final received = <dynamic>[];
      client.listen(received.add);
      await eventually(() => server.hasClient);

      server.sendFrame(Uint8List.fromList([1, 2, 3]));
      for (var i = 0; i < 100; i++) {
        server.sendFrame(Uint8List.fromList([4]));
      }
      await eventually(() => received.isNotEmpty);
      expect(received.single, [1, 2, 3]);
      expect(server.framesSent, 1);
      expect(server.framesDropped, 100);

      client.add('frameReceived');
      // Try fresh frames until the asynchronous receipt reaches the server.
      await eventually(() {
        if (server.framesSent == 1) server.sendFrame(Uint8List.fromList([5]));
        return server.framesSent == 2;
      });
      await eventually(() => received.length == 2);
      expect(received.last, [5]);
    },
  );

  test('replacing a client resets receipt state', () async {
    final server = FrameWebSocketServer();
    expect(await server.start(port: 0), isTrue);
    addTearDown(server.stop);
    final first = await WebSocket.connect('ws://127.0.0.1:${server.port}');
    first.listen((_) {});
    addTearDown(first.close);
    server.sendFrame(Uint8List.fromList([1]));
    final second = await WebSocket.connect('ws://127.0.0.1:${server.port}');
    addTearDown(second.close);
    final next = second.first;
    server.sendFrame(Uint8List.fromList([2]));
    expect(await next.timeout(const Duration(seconds: 3)), [2]);
  });
}
