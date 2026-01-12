import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../data/models/meeting_config.dart';
import '../../../../services/jitsi_webview_service.dart';

class JitsiWebView extends StatefulWidget {
  final MeetingConfig config;
  final JitsiWebViewService service;
  final VoidCallback? onMeetingLeft;

  const JitsiWebView({
    super.key,
    required this.config,
    required this.service,
    this.onMeetingLeft,
  });

  @override
  State<JitsiWebView> createState() => _JitsiWebViewState();
}

class _JitsiWebViewState extends State<JitsiWebView> {
  InAppWebViewController? _controller;
  bool _isLoading = true;

  @override
  Widget build(BuildContext context) {
    final url = widget.service.buildMeetingUrl(widget.config);

    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(url)),
          initialSettings: widget.service.webViewSettings,
          onWebViewCreated: (controller) {
            _controller = controller;
          },
          onLoadStart: (controller, url) {
            setState(() => _isLoading = true);
          },
          onLoadStop: (controller, url) {
            setState(() => _isLoading = false);
            widget.service.onMeetingJoined();
          },
          onPermissionRequest: (controller, request) async {
            // Grant all permissions for camera, mic, screen share
            return PermissionResponse(
              resources: request.resources,
              action: PermissionResponseAction.GRANT,
            );
          },
          onConsoleMessage: (controller, message) {
            debugPrint('Jitsi WebView: ${message.message}');
          },
          onCloseWindow: (controller) {
            widget.service.onMeetingLeft();
            widget.onMeetingLeft?.call();
          },
        ),
        if (_isLoading)
          const Center(
            child: CircularProgressIndicator(),
          ),
        // Close button overlay
        Positioned(
          top: 8,
          right: 8,
          child: SafeArea(
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
              ),
              onPressed: () {
                widget.service.onMeetingLeft();
                widget.onMeetingLeft?.call();
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}
