import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../services/lib_jitsi_service.dart';

bool isJitsiBridgeDocument(Uri? url) =>
    url?.scheme == 'file' &&
    url!.path.endsWith('/flutter_assets/assets/jitsi_bridge.html');

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
            shouldOverrideUrlLoading: (controller, navigation) async {
              return isJitsiBridgeDocument(navigation.request.url)
                  ? NavigationActionPolicy.ALLOW
                  : NavigationActionPolicy.CANCEL;
            },
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
              final localBridge = isJitsiBridgeDocument(await controller.getUrl()) &&
                  request.origin.scheme == 'file';
              final mediaOnly = request.resources.every((resource) =>
                  resource == PermissionResourceType.CAMERA ||
                  resource == PermissionResourceType.MICROPHONE ||
                  resource == PermissionResourceType.CAMERA_AND_MICROPHONE);
              return PermissionResponse(
                resources: request.resources,
                action: localBridge && mediaOnly
                    ? PermissionResponseAction.GRANT
                    : PermissionResponseAction.DENY,
              );
            },
            onConsoleMessage: (controller, message) {
              debugPrint('LibJitsiWebView console: ${message.message}');
            },
          ),
    );
  }
}
