import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../data/models/meeting_config.dart';

/// Events that can be received via deep links
sealed class DeepLinkEvent {}

/// Meta View app returned after pairing
class MetaViewCallbackEvent extends DeepLinkEvent {
  final String url;
  MetaViewCallbackEvent(this.url);
}

/// Request to join a meeting
class MeetingJoinEvent extends DeepLinkEvent {
  final String roomName;
  final String serverUrl;
  final String? displayName;
  final String? jwt;

  MeetingJoinEvent({
    required this.roomName,
    required this.serverUrl,
    this.displayName,
    this.jwt,
  });

  MeetingConfig toConfig() => MeetingConfig.fromDeepLink(
        roomName: roomName,
        serverUrl: serverUrl,
        displayName: displayName,
        jwt: jwt,
      );
}

/// Service for handling deep links
class DeepLinkService extends ChangeNotifier {
  final _appLinks = AppLinks();
  StreamSubscription? _linkSubscription;
  final _linkController = StreamController<DeepLinkEvent>.broadcast();

  String? _initialLink;
  bool _initialized = false;
  DeepLinkEvent? _lastEvent;

  /// Stream of deep link events
  Stream<DeepLinkEvent> get linkStream => _linkController.stream;

  /// Last received deep link event
  DeepLinkEvent? get lastEvent => _lastEvent;

  /// Initialize the deep link service
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Get initial link (cold start)
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        _initialLink = initialUri.toString();
        _handleLink(_initialLink!);
      }
    } catch (e) {
      // Ignore initial link errors
    }

    // Set up app_links stream
    _linkSubscription = _appLinks.uriLinkStream.listen((Uri uri) {
      _handleLink(uri.toString());
    });
  }

  /// Handle an incoming deep link
  void _handleLink(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null) return;

    DeepLinkEvent? event;

    // Check if Meta View callback
    // specbridge://callback or specbridge://
    if (uri.scheme == 'specbridge') {
      if (uri.host == 'callback' || uri.path.contains('callback')) {
        event = MetaViewCallbackEvent(link);
      }
      // Check if meeting join link
      // specbridge://join?room=X&server=Y&name=Z&jwt=W
      else if (uri.host == 'join' || uri.path == '/join') {
        final room = uri.queryParameters['room'];
        final server = uri.queryParameters['server'] ?? 'https://meet.jit.si';
        final name = uri.queryParameters['name'];
        final jwt = uri.queryParameters['jwt'];

        if (room != null && room.isNotEmpty) {
          event = MeetingJoinEvent(
            roomName: room,
            serverUrl: server,
            displayName: name,
            jwt: jwt,
          );
        }
      }
    }
    // Standard cross-platform format: openemr-telehealth://join?room=X&server=Y&name=Z&jwt=W
    // Works on Quest, Meta Glasses (Android), Meta Glasses (iOS)
    else if (uri.scheme == 'openemr-telehealth') {
      if (uri.host == 'join' || uri.path == '/join') {
        final room = uri.queryParameters['room'];
        final server = uri.queryParameters['server'] ?? 'https://meet.jit.si';
        final name = uri.queryParameters['name'];
        final jwt = uri.queryParameters['jwt'];

        if (room != null && room.isNotEmpty) {
          event = MeetingJoinEvent(
            roomName: room,
            serverUrl: server,
            displayName: name,
            jwt: jwt,
          );
        }
      }
    }
    // Check if Jitsi universal link
    // https://meet.jit.si/ROOM
    else if (uri.host == 'meet.jit.si' && uri.pathSegments.isNotEmpty) {
      event = MeetingJoinEvent(
        roomName: uri.pathSegments.first,
        serverUrl: 'https://meet.jit.si',
      );
    }
    // Check for custom Jitsi server links
    // https://custom.jitsi.server/ROOM
    else if (uri.scheme == 'https' && uri.pathSegments.isNotEmpty) {
      // Assume it's a Jitsi link if path looks like a room name
      final roomName = uri.pathSegments.first;
      if (roomName.isNotEmpty && !roomName.contains('.')) {
        event = MeetingJoinEvent(
          roomName: roomName,
          serverUrl: '${uri.scheme}://${uri.host}',
        );
      }
    }

    if (event != null) {
      _lastEvent = event;
      _linkController.add(event);
      notifyListeners();
    }
  }

  /// Get the initial link that launched the app
  String? get initialLink => _initialLink;

  /// Check if there's a pending meeting join from initial link
  MeetingConfig? getPendingMeetingConfig() {
    if (_initialLink == null) return null;

    final uri = Uri.tryParse(_initialLink!);
    if (uri == null) return null;

    // Parse meeting info from initial link
    // Supports both specbridge:// and openemr-telehealth:// schemes
    if ((uri.scheme == 'specbridge' || uri.scheme == 'openemr-telehealth') &&
        (uri.host == 'join' || uri.path == '/join')) {
      final room = uri.queryParameters['room'];
      if (room != null && room.isNotEmpty) {
        return MeetingConfig.fromDeepLink(
          roomName: room,
          serverUrl: uri.queryParameters['server'],
          displayName: uri.queryParameters['name'],
          jwt: uri.queryParameters['jwt'],
        );
      }
    }

    if (uri.host == 'meet.jit.si' && uri.pathSegments.isNotEmpty) {
      return MeetingConfig.fromDeepLink(
        roomName: uri.pathSegments.first,
        serverUrl: 'https://meet.jit.si',
      );
    }

    return null;
  }

  /// Check if initial link is a Meta View callback
  bool isInitialLinkMetaViewCallback() {
    if (_initialLink == null) return false;
    final uri = Uri.tryParse(_initialLink!);
    if (uri == null) return false;
    return uri.scheme == 'specbridge' &&
        (uri.host == 'callback' || uri.path.contains('callback'));
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    _linkController.close();
    super.dispose();
  }
}
