import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../services/lib_jitsi_service.dart';

/// WebView that hosts lib-jitsi-meet and displays the video preview
///
/// This WebView loads a local HTML page that uses lib-jitsi-meet.js
/// to connect to Jitsi servers. Video frames are rendered to a canvas
/// via WebGL, which is then captured for WebRTC transmission.
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
  @override
  Widget build(BuildContext context) {
    // WebView fills parent and shows video preview
    return ClipRect(
      child: InAppWebView(
            initialFile: 'assets/jitsi_bridge.html',
            initialSettings: widget.service.webViewSettings,
            onWebViewCreated: (controller) {
              debugPrint('LibJitsiWebView: WebView created');
              widget.service.setController(controller);
            },
            onLoadStart: (controller, url) {
              debugPrint('LibJitsiWebView: Loading $url');
            },
            onLoadStop: (controller, url) {
              debugPrint('LibJitsiWebView: Load complete');
            },
            onReceivedError: (controller, request, error) {
              debugPrint('LibJitsiWebView: Load error ${error.type}: ${error.description}');
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
    );
  }
}
