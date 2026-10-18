import 'dart:collection';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Bounded metadata only. Meeting details, credentials and media never enter it.
class SessionDiagnostics {
  SessionDiagnostics({
    required this.platform,
    required this.videoSource,
    required this.videoQuality,
    required this.frameRate,
    required this.audioOutput,
    required this.useNativeServer,
    this.maxSamples = 180,
    this.maxEvents = 100,
    DateTime? startedAt,
    int Function()? elapsedMs,
  }) : startedAt = (startedAt ?? DateTime.now()).toUtc(),
       _elapsedMs =
           elapsedMs ?? (Stopwatch()..start()).elapsedMillisecondsGetter;

  final String platform, videoSource, videoQuality, audioOutput;
  final int frameRate, maxSamples, maxEvents;
  final bool useNativeServer;
  final DateTime startedAt;
  final int Function() _elapsedMs;
  final _samples = Queue<Map<String, Object?>>();
  final _events = Queue<Map<String, Object?>>();
  Map<String, Object?>? _firstSample;
  int _samplesDiscarded = 0, _eventsDiscarded = 0;
  int? _endedAtMs;
  String? _outcome;
  String? jitsiVersion;
  bool captureRequested = false;
  bool get isComplete => _endedAtMs != null;

  void event(String kind, {String? value, bool? accepted}) {
    if (isComplete) return;
    if (_events.length == maxEvents) {
      _events.removeFirst();
      _eventsDiscarded++;
    }
    _events.add({
      'elapsedMs': _elapsedMs(),
      'kind': kind,
      'value': ?value,
      'accepted': ?accepted,
    });
  }

  void sample({
    required Map<String, dynamic> native,
    required Map<String, dynamic>? webView,
    required Map<String, dynamic> flutter,
    required String state,
    required String requestedAudio,
    bool includeCaptureStats = true,
  }) {
    if (isComplete) return;
    final observedRoute = native['communicationDeviceType'];
    final bool? matches =
        native['audioRouteObserved'] != true || observedRoute == null
        ? null
        : switch (requestedAudio) {
            'speakerphone' || 'earpiece' => observedRoute == requestedAudio,
            // Bluetooth selection alone cannot identify the particular accessory.
            _ => null,
          };
    final entry = <String, Object?>{
      'elapsedMs': _elapsedMs(),
      'state': state,
      'requestedAudio': requestedAudio,
      'phoneAudioRouteMatchesRequest': matches,
      'native': _select(
        native,
        includeCaptureStats ? _nativeKeys : _environmentKeys,
      ),
      'captureRequested': includeCaptureStats,
      'webView': webView == null ? null : _select(webView, _webViewKeys),
      'flutter': _select(flutter, _flutterKeys),
    };
    final events = native['sdkEvents'];
    if (includeCaptureStats && events is List) {
      (entry['native'] as Map<String, Object?>)['sdkEvents'] = events
          .whereType<Map>()
          .take(32)
          .map((e) => _select(e, {'elapsedMs', 'kind', 'code'}))
          .toList();
    }
    _firstSample ??= entry;
    if (_samples.length == maxSamples) {
      _samples.removeFirst();
      _samplesDiscarded++;
    }
    _samples.add(entry);
  }

  void finish(String outcome) {
    if (isComplete) return;
    event('finished', value: outcome);
    _endedAtMs = _elapsedMs();
    _outcome = outcome;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'startedAtUtc': startedAt.toIso8601String(),
    'elapsedMs': _endedAtMs ?? _elapsedMs(),
    'complete': isComplete,
    'outcome': _outcome,
    'platform': platform,
    'jitsiVersion': jitsiVersion,
    'requested': {
      'videoSource': videoSource,
      'quality': videoQuality,
      'fps': frameRate,
      'audioOutput': audioOutput,
      'nativeFrameServer': useNativeServer,
    },
    'measurementNotes': [
      'SDK delivery is measured on the phone after SDK decoding, not over Bluetooth.',
      'SDK FPS uses a rolling window of up to 5 seconds; null until 1 second of streaming.',
      'SDK stalls are gaps of at least 1 second while streaming, including an ongoing gap. Pauses are excluded.',
      'Phone-local delay runs from Android SDK frame receipt to WebView processing; it excludes glasses capture, Bluetooth and remote playback.',
      'Android communication-device selection does not prove the actual WebRTC microphone source.',
      'Unknown measurements are null or absent. Samples are collected about every 5 seconds.',
      'Counters can reset on capture restart (captureSequence) or WebView reload; do not subtract across resets.',
      'SDK event elapsedMs is relative to its native capture; application events and samples are relative to this report session.',
    ],
    'samplesDiscarded': _samplesDiscarded,
    'eventsDiscarded': _eventsDiscarded,
    'firstSample': _firstSample,
    'samples': _samples.toList(),
    'events': _events.toList(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static Map<String, Object?> _select(Map data, Set<String> keys) => {
    for (final key in keys)
      if (data.containsKey(key) &&
          (data[key] == null ||
              data[key] is num ||
              data[key] is bool ||
              data[key] is String))
        key: data[key] is String && (data[key] as String).length > 256
            ? (data[key] as String).substring(0, 256)
            : data[key],
  };

  static const _environmentKeys = {
    'platform',
    'phoneModel',
    'androidVersion',
    'androidApiLevel',
    'appVersion',
    'appBuild',
    'metaDatVersion',
    'audioRouteObserved',
    'audioMode',
    'communicationDeviceType',
    'bluetoothCommunicationSelected',
  };

  static const _nativeKeys = {
    'platform',
    'phoneModel',
    'androidVersion',
    'androidApiLevel',
    'appVersion',
    'appBuild',
    'metaDatVersion',
    'videoSource',
    'captureSequence',
    'captureStatus',
    'requestedVideoQuality',
    'requestedFrameRate',
    'sdkFrameWidth',
    'sdkFrameHeight',
    'sdkFps',
    'sdkFpsWindowMs',
    'sdkFrameAgeMs',
    'sdkCurrentGapMs',
    'sdkLongestGapMs',
    'sdkStallCount',
    'sdkStallThresholdMs',
    'sdkResolutionChanges',
    'framesReceived',
    'framesProcessed',
    'framesSkipped',
    'nativeProcessingMs',
    'nativeAvgProcessingMs',
    'nativeServerRunning',
    'nativeServerHasClient',
    'nativeFramesSent',
    'nativeFramesDropped',
    'nativeBackpressure',
    'useNativeServer',
    'cpuUsage',
    'memoryUsedMB',
    'memoryMaxMB',
    'glassesModel',
    'glassesFirmware',
    'glassesLinkState',
    'glassesCompatibility',
    'glassesThermalState',
    'glassesBatteryPercent',
    'glassesChargingState',
    'glassesDonState',
    'glassesHingeState',
    'audioRouteObserved',
    'audioMode',
    'communicationDeviceType',
    'bluetoothCommunicationSelected',
  };
  static const _webViewKeys = {
    'width',
    'height',
    'fps',
    'totalFrames',
    'framesDrawn',
    'framesDroppedJs',
    'framesDroppedStale',
    'lastDecodeMs',
    'avgDecodeMs',
    'avgArrivalMs',
    'phoneLocalDelayMs',
    'phoneLocalDelayAvgMs',
    'phoneLocalDelayMaxMs',
    'isJoined',
    'wsConnected',
    'hasAudioTrack',
    'hasVideoTrack',
    'rtcFramesEncoded',
    'rtcFramesSent',
    'rtcQualityLimitation',
    'rtcEncoderImpl',
    'rtcEncodeWidth',
    'rtcEncodeHeight',
    'rtcEncodeFps',
    'rtcBytesSent',
    'rtcRetransmits',
  };
  static const _flutterKeys = {'framesSent', 'framesDropped', 'wsSlowSends'};
}

extension on Stopwatch {
  int elapsedMillisecondsGetter() => elapsedMilliseconds;
}

/// Keeps the most recent session locally; serial writes cannot overwrite a newer report.
class DiagnosticReportStore {
  static const storageKey = 'latestSessionDiagnostics.v1';
  Future<void> _pending = Future.value();

  Future<void> save(String report) {
    final write = _pending.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(storageKey, report)) {
        throw StateError('Could not save diagnostics');
      }
    });
    _pending = write;
    return write;
  }

  Future<String?> load() async {
    await _pending.catchError((Object _) {});
    return (await SharedPreferences.getInstance()).getString(storageKey);
  }
}
