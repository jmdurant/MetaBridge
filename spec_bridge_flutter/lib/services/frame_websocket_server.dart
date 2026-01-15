import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// WebSocket server for streaming video frames to WebView
///
/// This bypasses the slow evaluateJavascript() bridge by sending
/// raw JPEG bytes over a local WebSocket connection.
class FrameWebSocketServer {
  static const int defaultPort = 8765;

  HttpServer? _server;
  WebSocket? _client;
  int _port = defaultPort;

  bool _isRunning = false;
  int _framesSent = 0;
  int _framesDropped = 0;
  int _framesWithSlowSend = 0;  // Frames where send took longer than expected
  int _lastSendTimeMs = 0;

  bool get isRunning => _isRunning;
  bool get hasClient => _client != null;
  int get port => _port;
  int get framesSent => _framesSent;
  int get framesDropped => _framesDropped;

  /// Start the WebSocket server
  Future<bool> start({int port = defaultPort}) async {
    if (_isRunning) {
      debugPrint('FrameWebSocketServer: Already running on port $_port');
      return true;
    }

    try {
      _port = port;
      // Bind to all interfaces so WebView can connect
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _isRunning = true;
      _framesSent = 0;
      _framesDropped = 0;
      _framesWithSlowSend = 0;
      _lastSendTimeMs = 0;

      debugPrint('FrameWebSocketServer: Started on ws://0.0.0.0:$port');

      // Listen for WebSocket upgrade requests
      _server!.listen((HttpRequest request) async {
        debugPrint('FrameWebSocketServer: Incoming request from ${request.connectionInfo?.remoteAddress}');
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          debugPrint('FrameWebSocketServer: WebSocket upgrade request');
          final socket = await WebSocketTransformer.upgrade(request);
          _handleClient(socket);
        } else {
          debugPrint('FrameWebSocketServer: Non-WebSocket request rejected');
          request.response
            ..statusCode = HttpStatus.forbidden
            ..write('WebSocket connections only')
            ..close();
        }
      }, onError: (e) {
        debugPrint('FrameWebSocketServer: Server error: $e');
      });

      return true;
    } catch (e) {
      debugPrint('FrameWebSocketServer: Failed to start: $e');
      _isRunning = false;
      return false;
    }
  }

  void _handleClient(WebSocket socket) {
    debugPrint('FrameWebSocketServer: Client connected');

    // Close any existing client
    _client?.close();
    _client = socket;

    socket.listen(
      (data) {
        // We don't expect data from client, but log if received
        debugPrint('FrameWebSocketServer: Received data from client: $data');
      },
      onDone: () {
        debugPrint('FrameWebSocketServer: Client disconnected');
        if (_client == socket) {
          _client = null;
        }
      },
      onError: (e) {
        debugPrint('FrameWebSocketServer: Client error: $e');
        if (_client == socket) {
          _client = null;
        }
      },
    );
  }

  /// Send a frame to the connected client
  void sendFrame(Uint8List frameData) {
    if (_client == null) {
      _framesDropped++;
      return;
    }

    try {
      final now = DateTime.now().millisecondsSinceEpoch;

      // Track if sends are happening slower than expected (>50ms gap indicates potential backpressure)
      if (_lastSendTimeMs > 0 && (now - _lastSendTimeMs) > 50) {
        _framesWithSlowSend++;
      }
      _lastSendTimeMs = now;

      _client!.add(frameData);
      _framesSent++;

      if (_framesSent == 1) {
        debugPrint('FrameWebSocketServer: Sent first frame (${frameData.length} bytes)');
      }
      if (_framesSent % 100 == 0) {
        debugPrint('FrameWebSocketServer: Sent $_framesSent frames, dropped $_framesDropped, slow $_framesWithSlowSend');
      }
    } catch (e) {
      debugPrint('FrameWebSocketServer: Send error: $e');
      _framesDropped++;
    }
  }

  /// Stop the server
  Future<void> stop() async {
    debugPrint('FrameWebSocketServer: Stopping...');

    await _client?.close();
    _client = null;

    await _server?.close();
    _server = null;

    _isRunning = false;
    debugPrint('FrameWebSocketServer: Stopped');
  }

  /// Get stats for display
  Map<String, dynamic> getStats() {
    return {
      'isRunning': _isRunning,
      'hasClient': _client != null,
      'port': _port,
      'framesSent': _framesSent,
      'framesDropped': _framesDropped,
      'framesWithSlowSend': _framesWithSlowSend,
    };
  }
}
