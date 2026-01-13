import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../services/lib_jitsi_service.dart';

/// Hidden WebView that hosts lib-jitsi-meet for direct frame injection
///
/// This WebView loads a local HTML page that uses lib-jitsi-meet.js
/// to connect to Jitsi servers. The WebView is hidden (1x1 pixel)
/// but necessary for WebRTC to function.
class LibJitsiWebView extends StatefulWidget {
  final LibJitsiService service;

  const LibJitsiWebView({
    super.key,
    required this.service,
  });

  @override
  State<LibJitsiWebView> createState() => _LibJitsiWebViewState();
}

class _LibJitsiWebViewState extends State<LibJitsiWebView> {
  bool _isLoading = true;
  String? _error;

  @override
  Widget build(BuildContext context) {
    // Hidden WebView - 1x1 pixel, positioned off-screen
    return SizedBox(
      width: 1,
      height: 1,
      child: Stack(
        children: [
          InAppWebView(
            initialFile: 'assets/jitsi_bridge.html',
            initialSettings: widget.service.webViewSettings,
            onWebViewCreated: (controller) {
              debugPrint('LibJitsiWebView: WebView created');
              widget.service.setController(controller);
            },
            onLoadStart: (controller, url) {
              debugPrint('LibJitsiWebView: Loading $url');
              setState(() => _isLoading = true);
            },
            onLoadStop: (controller, url) {
              debugPrint('LibJitsiWebView: Load complete');
              setState(() => _isLoading = false);
            },
            onLoadError: (controller, url, code, message) {
              debugPrint('LibJitsiWebView: Load error $code: $message');
              setState(() {
                _isLoading = false;
                _error = message;
              });
            },
            onPermissionRequest: (controller, request) async {
              debugPrint('LibJitsiWebView: Permission request: ${request.resources}');
              // Grant all permissions for audio (mic)
              return PermissionResponse(
                resources: request.resources,
                action: PermissionResponseAction.GRANT,
              );
            },
            onConsoleMessage: (controller, message) {
              debugPrint('LibJitsiWebView console: ${message.message}');
            },
          ),
        ],
      ),
    );
  }
}
