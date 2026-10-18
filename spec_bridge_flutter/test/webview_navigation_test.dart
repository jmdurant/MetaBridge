import 'package:flutter_test/flutter_test.dart';
import 'package:spec_bridge_flutter/presentation/screens/streaming/widgets/lib_jitsi_webview.dart';

void main() {
  test(
    'only the bundled bridge document may navigate the privileged WebView',
    () {
      expect(
        isJitsiBridgeDocument(
          Uri.parse(
            'file:///android_asset/flutter_assets/assets/jitsi_bridge.html',
          ),
        ),
        isTrue,
      );
      expect(
        isJitsiBridgeDocument(
          Uri.parse(
            'file:///app/Frameworks/App.framework/flutter_assets/assets/jitsi_bridge.html',
          ),
        ),
        isTrue,
      );
      expect(
        isJitsiBridgeDocument(
          Uri.parse(
            'https://example.com/flutter_assets/assets/jitsi_bridge.html',
          ),
        ),
        isFalse,
      );
      expect(
        isJitsiBridgeDocument(Uri.parse('file:///private/other.html')),
        isFalse,
      );
      expect(isJitsiBridgeDocument(null), isFalse);
    },
  );
}
