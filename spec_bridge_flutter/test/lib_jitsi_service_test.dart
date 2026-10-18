import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spec_bridge_flutter/data/models/meeting_config.dart';
import 'package:spec_bridge_flutter/services/lib_jitsi_service.dart';

class RecordingWebView extends PlatformInAppWebViewController {
  RecordingWebView()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 1),
      );

  final scripts = <String>[];
  final handlers = <String, Function>{};

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    scripts.add(source);
    return null;
  }

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required Function callback,
  }) {
    handlers[handlerName] = callback;
  }

  void event(String name, [Map<String, Object?> data = const {}]) {
    handlers['jitsiEvent']!([name, jsonEncode(data)]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibJitsiService service;
  late RecordingWebView webView;

  setUp(() async {
    service = LibJitsiService();
    expect(await service.wsServer.start(port: 0), isTrue);
    webView = RecordingWebView();
    service.setController(
      InAppWebViewController.fromPlatform(platform: webView),
    );
    webView.event('initialized');
  });

  tearDown(() async {
    await service.wsServer.stop();
    service.dispose();
  });

  test(
    'meeting details remain data even with quotes and script fragments',
    () async {
      const config = MeetingConfig(
        serverUrl: 'https://meet.example.org',
        roomName: 'Room "A"\\B\nC',
        displayName: '"); globalThis.injected = true; //',
        enableE2EE: true,
        e2eePassphrase: 'secret"\\\n\u2028',
        jwt: 'token"\\\n',
      );
      await service.joinMeeting(config, usePhoneMic: false);
      final script = webView.scripts.single;
      expect(script, startsWith('joinRoom(...'));
      final arguments = jsonDecode(
        script.substring('joinRoom(...'.length, script.length - 1),
      );
      expect(arguments, [
        config.serverUrl,
        config.roomName,
        config.displayName,
        true,
        config.e2eePassphrase,
        false,
        config.jwt,
      ]);
    },
  );

  test('joining waits for the actual conference event', () async {
    var completed = false;
    final joined = service.waitForJoined().then((value) {
      completed = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    webView.event('joined', {'room': 'room'});
    expect(await joined, isTrue);
  });

  test(
    'encryption failure aborts a pending join and is visible to UI',
    () async {
      final joined = service.waitForJoined();
      webView.event('e2eeError', {'message': 'Unsupported encryption'});
      expect(await joined, isFalse);
      expect(service.currentState.isE2EEEnabled, isFalse);
      expect(service.currentState.errorMessage, 'Unsupported encryption');
    },
  );

  test('a join without a conference event times out', () async {
    expect(await service.waitForJoined(timeout: Duration.zero), isFalse);
    expect(service.isInMeeting, isFalse);
  });
}
